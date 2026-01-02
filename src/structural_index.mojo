"""
Structural Index for High-Performance JSON Parsing

Implements simdjson's two-stage parsing architecture:
- Stage 1: SIMD scan to find all structural character positions
- Stage 2: Parse values using the index (no re-scanning)

Structural characters in JSON:
  { } [ ] " : ,

This provides O(1) access to any structural position, eliminating
the need for character-by-character scanning during value extraction.

Performance target: 500+ MB/s throughput on Stage 1 scan.
"""

# SIMD width for parallel processing
alias SIMD_WIDTH: Int = 16
alias SIMD_WIDTH_32: Int = 32  # Wider SIMD for better throughput

# Structural character codes
alias QUOTE: UInt8 = 0x22       # "
alias COLON: UInt8 = 0x3A      # :
alias COMMA: UInt8 = 0x2C      # ,
alias LBRACE: UInt8 = 0x7B     # {
alias RBRACE: UInt8 = 0x7D     # }
alias LBRACKET: UInt8 = 0x5B   # [
alias RBRACKET: UInt8 = 0x5D   # ]
alias BACKSLASH: UInt8 = 0x5C  # \


struct StructuralIndex(Movable, Sized):
    """
    Index of all structural character positions in a JSON document.

    After building the index, parsing can jump directly to structural
    positions instead of scanning character-by-character.

    Memory layout: Two parallel arrays for cache efficiency.
    - positions[i] = byte offset of i-th structural char
    - characters[i] = the structural char at that position
    """

    var positions: List[Int]
    """Byte offsets of structural characters."""

    var characters: List[UInt8]
    """The structural character at each position."""

    var string_mask: List[Bool]
    """True for positions inside string literals (to be skipped)."""

    fn __init__(out self, capacity: Int = 1024):
        """Create empty index with pre-allocated capacity."""
        self.positions = List[Int](capacity=capacity)
        self.characters = List[UInt8](capacity=capacity)
        self.string_mask = List[Bool]()

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self.positions = other.positions^
        self.characters = other.characters^
        self.string_mask = other.string_mask^

    fn __len__(self) -> Int:
        """Return number of structural characters indexed."""
        return len(self.positions)

    fn append(mut self, pos: Int, char: UInt8):
        """Add a structural character to the index."""
        self.positions.append(pos)
        self.characters.append(char)

    fn get_position(self, idx: Int) -> Int:
        """Get byte position of i-th structural character."""
        return self.positions[idx]

    fn get_character(self, idx: Int) -> UInt8:
        """Get the i-th structural character."""
        return self.characters[idx]


@always_inline
fn _is_structural(c: UInt8) -> Bool:
    """Check if byte is a JSON structural character."""
    return (c == QUOTE or c == COLON or c == COMMA or
            c == LBRACE or c == RBRACE or c == LBRACKET or c == RBRACKET)


@always_inline
fn _create_structural_mask(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """
    Create bitmask for structural characters in a 16-byte chunk.
    Returns 1 for structural chars, 0 otherwise.

    Uses element-wise comparison (ARM NEON friendly pattern).
    """
    var mask = SIMD[DType.uint8, SIMD_WIDTH]()

    @parameter
    for i in range(SIMD_WIDTH):
        var c = chunk[i]
        # Check all structural characters
        var is_struct = (c == QUOTE or c == COLON or c == COMMA or
                        c == LBRACE or c == RBRACE or c == LBRACKET or c == RBRACKET)
        mask[i] = 1 if is_struct else 0

    return mask


@always_inline
fn _create_quote_mask(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create bitmask for quote characters only."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH]()

    @parameter
    for i in range(SIMD_WIDTH):
        mask[i] = 1 if chunk[i] == QUOTE else 0

    return mask


@always_inline
fn _create_backslash_mask(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create bitmask for backslash characters."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH]()

    @parameter
    for i in range(SIMD_WIDTH):
        mask[i] = 1 if chunk[i] == BACKSLASH else 0

    return mask


# =============================================================================
# 32-byte SIMD functions for higher throughput
# =============================================================================

@always_inline
fn _create_structural_mask_32(chunk: SIMD[DType.uint8, SIMD_WIDTH_32]) -> SIMD[DType.uint8, SIMD_WIDTH_32]:
    """Create bitmask for structural characters in a 32-byte chunk."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH_32]()

    @parameter
    for i in range(SIMD_WIDTH_32):
        var c = chunk[i]
        var is_struct = (c == QUOTE or c == COLON or c == COMMA or
                        c == LBRACE or c == RBRACE or c == LBRACKET or c == RBRACKET)
        mask[i] = 1 if is_struct else 0

    return mask


@always_inline
fn _create_backslash_mask_32(chunk: SIMD[DType.uint8, SIMD_WIDTH_32]) -> SIMD[DType.uint8, SIMD_WIDTH_32]:
    """Create bitmask for backslash characters in 32-byte chunk."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH_32]()

    @parameter
    for i in range(SIMD_WIDTH_32):
        mask[i] = 1 if chunk[i] == BACKSLASH else 0

    return mask


fn build_structural_index(data: String) -> StructuralIndex:
    """
    Build structural index using SIMD scanning.

    Stage 1 of simdjson architecture:
    1. Scan 16 bytes at a time using SIMD
    2. Find all structural characters
    3. Track string boundaries to skip quoted content

    Args:
        data: JSON string to index

    Returns:
        StructuralIndex with positions of all structural chars

    Performance: Target 500+ MB/s on Apple M3 Ultra
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)  # Estimate: 1 structural per 4 bytes

    var pos = 0
    var in_string = False
    var ptr = data.unsafe_ptr()

    # SIMD processing for 16-byte chunks
    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes using unsafe_ptr for correct byte access
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        # Create masks for structural chars and quotes
        var structural_mask = _create_structural_mask(chunk)
        var quote_mask = _create_quote_mask(chunk)
        var backslash_mask = _create_backslash_mask(chunk)

        # Quick check: any structural chars in this chunk?
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            # No structural chars, skip entire chunk
            pos += SIMD_WIDTH
            continue

        # Process each byte in chunk
        @parameter
        for i in range(SIMD_WIDTH):
            var c = chunk[i]

            if c == QUOTE:
                # Check if this quote is escaped
                var escaped = False
                if i > 0:
                    escaped = backslash_mask[i - 1] == 1
                elif pos > 0:
                    escaped = ptr[pos - 1] == BACKSLASH

                if not escaped:
                    in_string = not in_string
                    # Record quote as structural (for string boundaries)
                    index.append(pos + i, c)
            elif not in_string and structural_mask[i] == 1:
                # Record structural char outside strings
                index.append(pos + i, c)

        pos += SIMD_WIDTH

    # Scalar tail for remaining bytes
    while pos < n:
        var c = ptr[pos]

        if c == QUOTE:
            # Check if escaped
            var escaped = pos > 0 and ptr[pos - 1] == BACKSLASH
            if not escaped:
                in_string = not in_string
                index.append(pos, c)
        elif not in_string and _is_structural(c):
            index.append(pos, c)

        pos += 1

    return index^


fn build_structural_index_fast(data: String) -> StructuralIndex:
    """
    Faster structural index builder - simplified for common JSON.

    Optimizations:
    1. Don't track string boundaries in first pass
    2. Post-filter to remove quoted structural chars

    This is faster for JSON without many structural chars in strings.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)

    var pos = 0
    var ptr = data.unsafe_ptr()

    # Phase 1: Collect ALL potential structural positions
    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        var structural_mask = _create_structural_mask(chunk)
        var struct_count = structural_mask.reduce_add()

        if struct_count > 0:
            @parameter
            for i in range(SIMD_WIDTH):
                if structural_mask[i] == 1:
                    index.append(pos + i, chunk[i])

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        var c = ptr[pos]
        if _is_structural(c):
            index.append(pos, c)
        pos += 1

    # Phase 2: Mark positions inside strings
    # Walk through quotes to determine string regions
    var in_string = False
    var valid_positions = List[Int]()
    var valid_chars = List[UInt8]()

    var idx = 0
    while idx < len(index):
        var char = index.get_character(idx)
        var position = index.get_position(idx)

        if char == QUOTE:
            # Check if escaped
            var escaped = position > 0 and ptr[position - 1] == BACKSLASH
            if not escaped:
                in_string = not in_string
            # Always keep quotes
            valid_positions.append(position)
            valid_chars.append(char)
        elif not in_string:
            # Keep structural chars outside strings
            valid_positions.append(position)
            valid_chars.append(char)

        idx += 1

    # Return filtered index
    var result = StructuralIndex()
    result.positions = valid_positions^
    result.characters = valid_chars^
    return result^


fn build_structural_index_32(data: String) -> StructuralIndex:
    """
    Build structural index using 32-byte SIMD scanning.

    Wider SIMD = higher throughput on large JSON files.
    Uses 32-byte chunks instead of 16-byte for 2x parallelism.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)

    var pos = 0
    var in_string = False
    var ptr = data.unsafe_ptr()

    # 32-byte SIMD processing
    while pos + SIMD_WIDTH_32 <= n:
        # Load 32 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH_32]()

        @parameter
        for i in range(SIMD_WIDTH_32):
            chunk[i] = ptr[pos + i]

        # Create masks
        var structural_mask = _create_structural_mask_32(chunk)
        var backslash_mask = _create_backslash_mask_32(chunk)

        # Quick check: any structural chars?
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            pos += SIMD_WIDTH_32
            continue

        # Process each byte
        @parameter
        for i in range(SIMD_WIDTH_32):
            var c = chunk[i]

            if c == QUOTE:
                # Check if escaped
                var escaped = False
                if i > 0:
                    escaped = backslash_mask[i - 1] == 1
                elif pos > 0:
                    escaped = ptr[pos - 1] == BACKSLASH

                if not escaped:
                    in_string = not in_string
                    index.append(pos + i, c)
            elif not in_string and structural_mask[i] == 1:
                index.append(pos + i, c)

        pos += SIMD_WIDTH_32

    # 16-byte tail processing
    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        var structural_mask = _create_structural_mask(chunk)
        var backslash_mask = _create_backslash_mask(chunk)
        var struct_count = structural_mask.reduce_add()

        if struct_count > 0:
            @parameter
            for i in range(SIMD_WIDTH):
                var c = chunk[i]

                if c == QUOTE:
                    var escaped = False
                    if i > 0:
                        escaped = backslash_mask[i - 1] == 1
                    elif pos > 0:
                        escaped = ptr[pos - 1] == BACKSLASH

                    if not escaped:
                        in_string = not in_string
                        index.append(pos + i, c)
                elif not in_string and structural_mask[i] == 1:
                    index.append(pos + i, c)

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        var c = ptr[pos]

        if c == QUOTE:
            var escaped = pos > 0 and ptr[pos - 1] == BACKSLASH
            if not escaped:
                in_string = not in_string
                index.append(pos, c)
        elif not in_string and _is_structural(c):
            index.append(pos, c)

        pos += 1

    return index^


# =============================================================================
# Benchmarking Utilities
# =============================================================================


fn benchmark_structural_scan(data: String, iterations: Int) -> Float64:
    """
    Benchmark structural index building.

    Returns throughput in MB/s.
    """
    from time import perf_counter_ns

    var size = len(data)

    # Warmup
    for _ in range(10):
        var idx = build_structural_index(data)
        _ = idx

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    var throughput_mbps = total_bytes / (1024.0 * 1024.0) / seconds

    return throughput_mbps
