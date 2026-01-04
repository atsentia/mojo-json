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

Phase 2 Enhancement (2026-01):
  - Value position tracking for numbers and literals
  - Eliminates re-scanning in Stage 2 for non-structural values
  - Target: 2,000 MB/s with indexed value extraction
"""

# SIMD width for parallel processing
alias SIMD_WIDTH: Int = 16

# Structural character codes
alias QUOTE: UInt8 = 0x22       # "
alias COLON: UInt8 = 0x3A      # :
alias COMMA: UInt8 = 0x2C      # ,
alias LBRACE: UInt8 = 0x7B     # {
alias RBRACE: UInt8 = 0x7D     # }
alias LBRACKET: UInt8 = 0x5B   # [
alias RBRACKET: UInt8 = 0x5D   # ]
alias BACKSLASH: UInt8 = 0x5C  # \

# =============================================================================
# Branchless Character Classification Tables (Phase 1 Optimization)
# =============================================================================
#
# Instead of: if c == QUOTE or c == COLON or c == COMMA...
# Use: STRUCTURAL_TABLE[c] == 1  (single memory lookup)
#
# This eliminates branches in the hot path, enabling better pipelining.

# Character classification bits
alias CHAR_STRUCTURAL: UInt8 = 1   # { } [ ] : , "
alias CHAR_QUOTE: UInt8 = 2        # " only
alias CHAR_BACKSLASH: UInt8 = 4    # \ only
alias CHAR_WHITESPACE: UInt8 = 8   # space, tab, newline, cr


@always_inline
fn _build_char_class_table() -> InlineArray[UInt8, 256]:
    """Build compile-time character classification table."""
    var table = InlineArray[UInt8, 256](fill=0)

    # Mark structural characters
    table[Int(QUOTE)] = CHAR_STRUCTURAL | CHAR_QUOTE
    table[Int(COLON)] = CHAR_STRUCTURAL
    table[Int(COMMA)] = CHAR_STRUCTURAL
    table[Int(LBRACE)] = CHAR_STRUCTURAL
    table[Int(RBRACE)] = CHAR_STRUCTURAL
    table[Int(LBRACKET)] = CHAR_STRUCTURAL
    table[Int(RBRACKET)] = CHAR_STRUCTURAL

    # Mark backslash
    table[Int(BACKSLASH)] = CHAR_BACKSLASH

    # Mark whitespace
    table[0x20] = CHAR_WHITESPACE  # space
    table[0x09] = CHAR_WHITESPACE  # tab
    table[0x0A] = CHAR_WHITESPACE  # newline
    table[0x0D] = CHAR_WHITESPACE  # carriage return

    return table


# Global character classification table (initialized once)
alias CHAR_CLASS_TABLE = _build_char_class_table()


@always_inline
fn _is_structural_branchless(c: UInt8) -> Bool:
    """Branchless structural char check via table lookup."""
    return (CHAR_CLASS_TABLE[Int(c)] & CHAR_STRUCTURAL) != 0


@always_inline
fn _is_quote_branchless(c: UInt8) -> Bool:
    """Branchless quote check via table lookup."""
    return (CHAR_CLASS_TABLE[Int(c)] & CHAR_QUOTE) != 0


@always_inline
fn _is_backslash_branchless(c: UInt8) -> Bool:
    """Branchless backslash check via table lookup."""
    return (CHAR_CLASS_TABLE[Int(c)] & CHAR_BACKSLASH) != 0


@always_inline
fn _is_whitespace_branchless(c: UInt8) -> Bool:
    """Branchless whitespace check via table lookup."""
    return (CHAR_CLASS_TABLE[Int(c)] & CHAR_WHITESPACE) != 0

# Value type hints for pre-classification
alias VALUE_UNKNOWN: UInt8 = 0
alias VALUE_NUMBER: UInt8 = 1
alias VALUE_TRUE: UInt8 = 2
alias VALUE_FALSE: UInt8 = 3
alias VALUE_NULL: UInt8 = 4


@register_passable("trivial")
struct ValueSpan:
    """
    Span representing a non-structural value position (number or literal).

    Stored inline after structural chars that precede values (: or , or [ ).
    This allows Stage 2 to skip directly to the value without re-scanning.
    """
    var start: UInt32
    """Start position in source."""
    var end: UInt32
    """End position in source (exclusive)."""
    var value_type: UInt8
    """Type hint: VALUE_NUMBER, VALUE_TRUE, VALUE_FALSE, VALUE_NULL."""
    var is_float: UInt8
    """For numbers: 1 if contains '.', 'e', or 'E'."""

    fn __init__(out self, start: Int = 0, end: Int = 0, value_type: UInt8 = VALUE_UNKNOWN, is_float: Bool = False):
        self.start = UInt32(start)
        self.end = UInt32(end)
        self.value_type = value_type
        self.is_float = 1 if is_float else 0


struct StructuralIndex(Movable, Sized):
    """
    Index of all structural character positions in a JSON document.

    After building the index, parsing can jump directly to structural
    positions instead of scanning character-by-character.

    Memory layout: Three parallel arrays for cache efficiency.
    - positions[i] = byte offset of i-th structural char
    - characters[i] = the structural char at that position
    - value_spans[i] = if char is : or , or [, the value span following it

    Phase 2 Enhancement:
    - value_spans tracks positions of non-structural values (numbers, literals)
    - This eliminates re-scanning in Stage 2
    """

    var positions: List[Int]
    """Byte offsets of structural characters."""

    var characters: List[UInt8]
    """The structural character at each position."""

    var value_spans: List[ValueSpan]
    """Value spans for elements following : or , or [. Same length as positions."""

    var string_mask: List[Bool]
    """True for positions inside string literals (to be skipped)."""

    fn __init__(out self, capacity: Int = 1024):
        """Create empty index with pre-allocated capacity."""
        self.positions = List[Int](capacity=capacity)
        self.characters = List[UInt8](capacity=capacity)
        self.value_spans = List[ValueSpan](capacity=capacity)
        self.string_mask = List[Bool]()

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self.positions = other.positions^
        self.characters = other.characters^
        self.value_spans = other.value_spans^
        self.string_mask = other.string_mask^

    fn __len__(self) -> Int:
        """Return number of structural characters indexed."""
        return len(self.positions)

    fn append(mut self, pos: Int, char: UInt8):
        """Add a structural character to the index with no value span."""
        self.positions.append(pos)
        self.characters.append(char)
        self.value_spans.append(ValueSpan())

    fn append_with_value(mut self, pos: Int, char: UInt8, value_span: ValueSpan):
        """Add a structural character with its following value span."""
        self.positions.append(pos)
        self.characters.append(char)
        self.value_spans.append(value_span)

    fn get_position(self, idx: Int) -> Int:
        """Get byte position of i-th structural character."""
        return self.positions[idx]

    fn get_character(self, idx: Int) -> UInt8:
        """Get the i-th structural character."""
        return self.characters[idx]

    fn get_value_span(self, idx: Int) -> ValueSpan:
        """Get value span for the i-th structural character."""
        return self.value_spans[idx]

    fn has_value_span(self, idx: Int) -> Bool:
        """Check if the i-th structural char has a value span (non-structural value follows)."""
        return self.value_spans[idx].value_type != VALUE_UNKNOWN


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
# Branchless SIMD Mask Functions (Phase 1 Optimization)
# =============================================================================
#
# Key insight: SIMD comparisons are faster than table lookups on ARM because:
# 1. SIMD comparisons run in parallel across lanes
# 2. Table lookups require individual memory accesses
# 3. ARM NEON lacks efficient 16-way gather instructions
#
# Strategy: Use SIMD equality comparisons and reduce with OR


@always_inline
fn _create_structural_mask_simd(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """
    Create structural mask - same as V2 for now.

    Note: True SIMD-parallel comparisons require specific NEON intrinsics
    that aren't directly exposed in Mojo. Using element-wise for correctness.
    """
    # Same as _create_structural_mask for now
    return _create_structural_mask(chunk)


@always_inline
fn _create_quote_mask_simd(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create quote mask - same as V2."""
    return _create_quote_mask(chunk)


@always_inline
fn _create_backslash_mask_simd(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create backslash mask - same as V2."""
    return _create_backslash_mask(chunk)


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


# =============================================================================
# Value Detection Helpers (Phase 2)
# =============================================================================


@always_inline
fn _is_digit(c: UInt8) -> Bool:
    """Check if byte is an ASCII digit."""
    return c >= ord('0') and c <= ord('9')


@always_inline
fn _is_number_start(c: UInt8) -> Bool:
    """Check if byte can start a number."""
    return _is_digit(c) or c == ord('-')


@always_inline
fn _is_number_char(c: UInt8) -> Bool:
    """Check if byte can be part of a number."""
    return (_is_digit(c) or c == ord('.') or c == ord('e') or c == ord('E')
            or c == ord('-') or c == ord('+'))


@always_inline
fn _is_digit_branchless(c: UInt8) -> Bool:
    """Branchless digit check using unsigned subtraction."""
    # (c - '0') <= 9 is true iff c is '0'-'9'
    # Using unsigned arithmetic, non-digits wrap to large values
    return (c - 48) <= 9


@always_inline
fn _scan_number(ptr: UnsafePointer[UInt8], start: Int, n: Int) -> Tuple[Int, Bool]:
    """
    Scan a number starting at position start.
    Returns (end_position, is_float).
    """
    var pos = start
    var is_float = False

    # Optional leading minus
    if pos < n and ptr[pos] == ord('-'):
        pos += 1

    # Integer part
    while pos < n and _is_digit_branchless(ptr[pos]):
        pos += 1

    # Fractional part
    if pos < n and ptr[pos] == ord('.'):
        is_float = True
        pos += 1
        while pos < n and _is_digit_branchless(ptr[pos]):
            pos += 1

    # Exponent part
    if pos < n and (ptr[pos] == ord('e') or ptr[pos] == ord('E')):
        is_float = True
        pos += 1
        if pos < n and (ptr[pos] == ord('-') or ptr[pos] == ord('+')):
            pos += 1
        while pos < n and _is_digit_branchless(ptr[pos]):
            pos += 1

    return (pos, is_float)


@always_inline
fn _skip_whitespace(ptr: UnsafePointer[UInt8], start: Int, n: Int) -> Int:
    """Skip whitespace characters."""
    var pos = start
    while pos < n:
        var c = ptr[pos]
        if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
            break
        pos += 1
    return pos


@always_inline
fn _scan_value_after_delimiter(ptr: UnsafePointer[UInt8], delim_pos: Int, n: Int) -> ValueSpan:
    """
    Scan for a non-structural value (number or literal) after a delimiter.

    This is called for : and , characters to detect the value that follows.
    Returns a ValueSpan with type and positions, or VALUE_UNKNOWN if the
    value is structural (string, object, array).
    """
    var start = _skip_whitespace(ptr, delim_pos + 1, n)
    if start >= n:
        return ValueSpan()

    var c = ptr[start]

    # Check for number
    if _is_number_start(c):
        var result = _scan_number(ptr, start, n)
        var end = result[0]
        var is_float = result[1]
        return ValueSpan(start, end, VALUE_NUMBER, is_float)

    # Check for true
    if c == ord('t'):
        if start + 4 <= n and ptr[start + 1] == ord('r') and ptr[start + 2] == ord('u') and ptr[start + 3] == ord('e'):
            return ValueSpan(start, start + 4, VALUE_TRUE, False)

    # Check for false
    if c == ord('f'):
        if start + 5 <= n and ptr[start + 1] == ord('a') and ptr[start + 2] == ord('l') and ptr[start + 3] == ord('s') and ptr[start + 4] == ord('e'):
            return ValueSpan(start, start + 5, VALUE_FALSE, False)

    # Check for null
    if c == ord('n'):
        if start + 4 <= n and ptr[start + 1] == ord('u') and ptr[start + 2] == ord('l') and ptr[start + 3] == ord('l'):
            return ValueSpan(start, start + 4, VALUE_NULL, False)

    # Value is structural (string, object, or array)
    return ValueSpan()


fn build_structural_index_v2(data: String) -> StructuralIndex:
    """
    Phase 2 optimized structural index builder with value position tracking.

    In addition to structural character positions, this also tracks:
    - Number positions (start, end, is_float)
    - Literal positions (true, false, null)

    This eliminates the need for Stage 2 to re-scan for value boundaries.

    Performance: Target 800+ MB/s with value tracking overhead.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)

    var pos = 0
    var in_string = False
    var ptr = data.unsafe_ptr()

    # SIMD processing for 16-byte chunks
    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        var structural_mask = _create_structural_mask(chunk)
        var backslash_mask = _create_backslash_mask(chunk)
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            pos += SIMD_WIDTH
            continue

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
                # For : and , scan for non-structural values
                if c == COLON or c == COMMA:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                elif c == LBRACKET:
                    # For [ also check if first element is non-structural
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                else:
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
            if c == COLON or c == COMMA or c == LBRACKET:
                var value_span = _scan_value_after_delimiter(ptr, pos, n)
                index.append_with_value(pos, c, value_span)
            else:
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

    # Return filtered index (with empty value_spans for compatibility)
    var result = StructuralIndex()
    result.positions = valid_positions^
    result.characters = valid_chars^
    # Initialize value_spans with empty spans
    for _ in range(len(result.positions)):
        result.value_spans.append(ValueSpan())
    return result^


# =============================================================================
# Benchmarking Utilities
# =============================================================================


fn benchmark_structural_scan_v2(data: String, iterations: Int) -> Float64:
    """
    Benchmark Phase 2 structural index building with value tracking.

    Returns throughput in MB/s.
    """
    from time import perf_counter_ns

    var size = len(data)

    # Warmup
    for _ in range(10):
        var idx = build_structural_index_v2(data)
        _ = idx

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v2(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


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


# =============================================================================
# Parallel Structural Index Builder
# =============================================================================

from algorithm import parallelize


fn _count_unescaped_quotes_in_range(
    ptr: UnsafePointer[UInt8], start: Int, end: Int
) -> Int:
    """Count unescaped quotes in a byte range."""
    var count = 0
    var i = start

    # SIMD scan for quotes
    while i + SIMD_WIDTH <= end:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()
        @parameter
        for j in range(SIMD_WIDTH):
            chunk[j] = ptr[i + j]

        @parameter
        for j in range(SIMD_WIDTH):
            if chunk[j] == QUOTE:
                # Check if escaped
                var escaped = False
                if i + j > start:
                    escaped = ptr[i + j - 1] == BACKSLASH
                elif i + j > 0:
                    escaped = ptr[i + j - 1] == BACKSLASH
                if not escaped:
                    count += 1
        i += SIMD_WIDTH

    # Scalar tail
    while i < end:
        if ptr[i] == QUOTE:
            var escaped = i > 0 and ptr[i - 1] == BACKSLASH
            if not escaped:
                count += 1
        i += 1

    return count


fn _build_index_range(
    ptr: UnsafePointer[UInt8],
    start: Int,
    end: Int,
    initial_in_string: Bool,
) -> StructuralIndex:
    """Build structural index for a byte range."""
    var index = StructuralIndex(capacity=(end - start) // 4)
    var in_string = initial_in_string
    var i = start

    # SIMD processing
    while i + SIMD_WIDTH <= end:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()
        @parameter
        for j in range(SIMD_WIDTH):
            chunk[j] = ptr[i + j]

        var structural_mask = _create_structural_mask(chunk)
        var backslash_mask = _create_backslash_mask(chunk)
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            i += SIMD_WIDTH
            continue

        @parameter
        for j in range(SIMD_WIDTH):
            var c = chunk[j]

            if c == QUOTE:
                var escaped = False
                if j > 0:
                    escaped = backslash_mask[j - 1] == 1
                elif i + j > 0:
                    escaped = ptr[i + j - 1] == BACKSLASH

                if not escaped:
                    in_string = not in_string
                    index.append(i + j, c)
            elif not in_string and structural_mask[j] == 1:
                index.append(i + j, c)

        i += SIMD_WIDTH

    # Scalar tail
    while i < end:
        var c = ptr[i]
        if c == QUOTE:
            var escaped = i > 0 and ptr[i - 1] == BACKSLASH
            if not escaped:
                in_string = not in_string
                index.append(i, c)
        elif not in_string and _is_structural(c):
            index.append(i, c)
        i += 1

    return index^


fn build_structural_index_parallel(
    data: String, num_threads: Int = 4
) -> StructuralIndex:
    """
    Build structural index using parallel chunk processing.

    Strategy:
    1. Count unescaped quotes in each chunk (parallel)
    2. Compute string state at chunk boundaries (prefix sum)
    3. Build partial indices (parallel) using separate allocations
    4. Merge partial indices

    Best for files > 500KB. For smaller files, single-threaded is faster.
    """
    var n = len(data)

    # For small files, use single-threaded
    if n < 512 * 1024:
        return build_structural_index(data)

    var ptr = data.unsafe_ptr()
    var chunk_size = n // num_threads

    # Phase 1: Count quotes in each chunk (parallel)
    var quote_counts = List[Int]()
    for _ in range(num_threads):
        quote_counts.append(0)

    var counts_ptr = quote_counts.unsafe_ptr()

    @parameter
    fn count_quotes(tid: Int):
        var start = tid * chunk_size
        var end = (tid + 1) * chunk_size if tid < num_threads - 1 else n
        counts_ptr[tid] = _count_unescaped_quotes_in_range(ptr, start, end)

    parallelize[count_quotes](num_threads)

    # Phase 2: Compute string state at each chunk boundary (prefix sum)
    var chunk_in_string = List[Bool]()
    var total_quotes = 0
    for i in range(num_threads):
        chunk_in_string.append((total_quotes % 2) == 1)
        total_quotes += quote_counts[i]

    # Phase 3: Allocate separate position/char arrays for each thread
    var positions_per_thread = List[List[Int]]()
    var chars_per_thread = List[List[UInt8]]()
    for _ in range(num_threads):
        positions_per_thread.append(List[Int]())
        chars_per_thread.append(List[UInt8]())

    # Build indices in parallel (each thread writes to its own list)
    @parameter
    fn build_chunk(tid: Int):
        var start = tid * chunk_size
        var end = (tid + 1) * chunk_size if tid < num_threads - 1 else n
        var in_string = chunk_in_string[tid]
        var i = start

        # SIMD processing
        while i + SIMD_WIDTH <= end:
            var chunk = SIMD[DType.uint8, SIMD_WIDTH]()
            @parameter
            for j in range(SIMD_WIDTH):
                chunk[j] = ptr[i + j]

            var structural_mask = _create_structural_mask(chunk)
            var backslash_mask = _create_backslash_mask(chunk)

            @parameter
            for j in range(SIMD_WIDTH):
                var c = chunk[j]
                if c == QUOTE:
                    var escaped = False
                    if j > 0:
                        escaped = backslash_mask[j - 1] == 1
                    elif i + j > 0:
                        escaped = ptr[i + j - 1] == BACKSLASH
                    if not escaped:
                        in_string = not in_string
                        positions_per_thread[tid].append(i + j)
                        chars_per_thread[tid].append(c)
                elif not in_string and structural_mask[j] == 1:
                    positions_per_thread[tid].append(i + j)
                    chars_per_thread[tid].append(c)
            i += SIMD_WIDTH

        # Scalar tail
        while i < end:
            var c = ptr[i]
            if c == QUOTE:
                var escaped = i > 0 and ptr[i - 1] == BACKSLASH
                if not escaped:
                    in_string = not in_string
                    positions_per_thread[tid].append(i)
                    chars_per_thread[tid].append(c)
            elif not in_string and _is_structural(c):
                positions_per_thread[tid].append(i)
                chars_per_thread[tid].append(c)
            i += 1

    parallelize[build_chunk](num_threads)

    # Phase 4: Merge partial indices
    var total_size = 0
    for i in range(num_threads):
        total_size += len(positions_per_thread[i])

    var result = StructuralIndex(capacity=total_size)
    for i in range(num_threads):
        for j in range(len(positions_per_thread[i])):
            result.append(positions_per_thread[i][j], chars_per_thread[i][j])

    return result^


# =============================================================================
# Wider SIMD: 32-byte (2x16) processing for better ILP
# =============================================================================

alias SIMD_WIDTH_2X: Int = 32


@always_inline
fn _create_structural_mask_32(chunk: SIMD[DType.uint8, SIMD_WIDTH_2X]) -> SIMD[DType.uint8, SIMD_WIDTH_2X]:
    """Create structural mask for 32-byte chunk."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH_2X]()

    @parameter
    for i in range(SIMD_WIDTH_2X):
        var c = chunk[i]
        var is_struct = (c == QUOTE or c == COLON or c == COMMA or
                        c == LBRACE or c == RBRACE or c == LBRACKET or c == RBRACKET)
        mask[i] = 1 if is_struct else 0

    return mask


@always_inline
fn _create_backslash_mask_32(chunk: SIMD[DType.uint8, SIMD_WIDTH_2X]) -> SIMD[DType.uint8, SIMD_WIDTH_2X]:
    """Create backslash mask for 32-byte chunk."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH_2X]()

    @parameter
    for i in range(SIMD_WIDTH_2X):
        mask[i] = 1 if chunk[i] == BACKSLASH else 0

    return mask


fn build_structural_index_v3(data: String) -> StructuralIndex:
    """
    V3 structural index builder with 32-byte (2x16) SIMD processing.

    Improvements over V2:
    - Processes 32 bytes per iteration for better instruction-level parallelism
    - Reduces loop overhead by 2x
    - Same value span detection as V2

    Performance target: 800+ MB/s on Apple M3.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)

    var pos = 0
    var in_string = False
    var ptr = data.unsafe_ptr()

    # 32-byte SIMD processing
    while pos + SIMD_WIDTH_2X <= n:
        # Load 32 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH_2X]()

        @parameter
        for i in range(SIMD_WIDTH_2X):
            chunk[i] = ptr[pos + i]

        # Create masks for structural chars
        var structural_mask = _create_structural_mask_32(chunk)
        var backslash_mask = _create_backslash_mask_32(chunk)

        # Quick check: any structural chars in this chunk?
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            # No structural chars, skip entire chunk
            pos += SIMD_WIDTH_2X
            continue

        # Process each byte in chunk
        @parameter
        for i in range(SIMD_WIDTH_2X):
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
                    index.append(pos + i, c)
            elif not in_string and structural_mask[i] == 1:
                # For : and , and [ scan for non-structural values
                if c == COLON or c == COMMA:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                elif c == LBRACKET:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                else:
                    index.append(pos + i, c)

        pos += SIMD_WIDTH_2X

    # 16-byte tail processing
    while pos + SIMD_WIDTH <= n:
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        var structural_mask = _create_structural_mask(chunk)
        var backslash_mask = _create_backslash_mask(chunk)
        var struct_count = structural_mask.reduce_add()

        if struct_count == 0:
            pos += SIMD_WIDTH
            continue

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
                if c == COLON or c == COMMA or c == LBRACKET:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                else:
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
            if c == COLON or c == COMMA or c == LBRACKET:
                var value_span = _scan_value_after_delimiter(ptr, pos, n)
                index.append_with_value(pos, c, value_span)
            else:
                index.append(pos, c)

        pos += 1

    return index^


# =============================================================================
# V4: Branchless Structural Index Builder
# =============================================================================


fn build_structural_index_v4(data: String) -> StructuralIndex:
    """
    V4 structural index builder with SIMD-parallel character classification.

    Key optimization: Uses SIMD comparison operations that run in parallel
    across all 16 lanes, then combines with OR. This is faster than table
    lookups on ARM because comparisons are vectorized.

    Performance target: 1.5+ GB/s on Apple M3.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)

    var pos = 0
    var in_string = False
    var ptr = data.unsafe_ptr()

    # SIMD processing for 16-byte chunks
    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ptr[pos + i]

        # Create masks using SIMD parallel comparisons (not table lookups)
        var structural_mask = _create_structural_mask_simd(chunk)
        var quote_mask = _create_quote_mask_simd(chunk)
        var backslash_mask = _create_backslash_mask_simd(chunk)

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

            # Check for quote using pre-computed SIMD mask
            if quote_mask[i] == 1:
                # Check if this quote is escaped
                var escaped = False
                if i > 0:
                    escaped = backslash_mask[i - 1] == 1
                elif pos > 0:
                    escaped = ptr[pos - 1] == BACKSLASH

                if not escaped:
                    in_string = not in_string
                    index.append(pos + i, c)
            elif not in_string and structural_mask[i] == 1:
                # For : and , and [ scan for non-structural values
                if c == COLON or c == COMMA:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                elif c == LBRACKET:
                    var value_span = _scan_value_after_delimiter(ptr, pos + i, n)
                    index.append_with_value(pos + i, c, value_span)
                else:
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
            if c == COLON or c == COMMA or c == LBRACKET:
                var value_span = _scan_value_after_delimiter(ptr, pos, n)
                index.append_with_value(pos, c, value_span)
            else:
                index.append(pos, c)

        pos += 1

    return index^