"""
Tape-Based JSON Parser

Integrates structural index (Stage 1) with tape data structure (Stage 2)
for high-performance JSON parsing following simdjson architecture.

Performance target: 1,000+ MB/s on Apple M3 Ultra

Architecture:
  JSON String → Structural Index → Tape → LazyJsonValue
                 (1.3 GB/s scan)    (O(1) access)
"""

from .structural_index import (
    build_structural_index,
    StructuralIndex,
    QUOTE,
    LBRACE,
    RBRACE,
    LBRACKET,
    RBRACKET,
    COLON,
    COMMA,
)

# Import tape types - using relative path for when mojo-tape is a sibling
# For now, we inline the necessary constants
alias TAPE_ROOT: UInt8 = ord('r')
alias TAPE_START_ARRAY: UInt8 = ord('[')
alias TAPE_END_ARRAY: UInt8 = ord(']')
alias TAPE_START_OBJECT: UInt8 = ord('{')
alias TAPE_END_OBJECT: UInt8 = ord('}')
alias TAPE_STRING: UInt8 = ord('"')
alias TAPE_INT64: UInt8 = ord('l')
alias TAPE_DOUBLE: UInt8 = ord('d')
alias TAPE_TRUE: UInt8 = ord('t')
alias TAPE_FALSE: UInt8 = ord('f')
alias TAPE_NULL: UInt8 = ord('n')

alias PAYLOAD_MASK: UInt64 = 0x00FFFFFFFFFFFFFF

from memory import bitcast


@always_inline
fn _fast_parse_int(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Int64:
    """Fast integer parsing with SIMD acceleration for 8+ digit numbers."""
    var pos = start
    var negative = False
    var result: Int64 = 0

    # Handle sign
    if ptr[pos] == ord('-'):
        negative = True
        pos += 1
    elif ptr[pos] == ord('+'):
        pos += 1

    var digit_count = end - pos

    # SIMD path for 8+ digits
    if digit_count >= 8:
        # Load 8 bytes
        var chunk = SIMD[DType.uint8, 8]()
        @parameter
        for i in range(8):
            chunk[i] = ptr[pos + i]

        # Check if all are digits: min >= '0' and max <= '9'
        var min_val = chunk.reduce_min()
        var max_val = chunk.reduce_max()
        var all_digits = min_val >= ord('0') and max_val <= ord('9')

        if all_digits:
            # Convert 8 digits in parallel
            var digits = (chunk - ord('0')).cast[DType.int64]()

            # Multiply by powers of 10: [10^7, 10^6, ..., 10^0]
            alias powers = SIMD[DType.int64, 8](
                10000000, 1000000, 100000, 10000, 1000, 100, 10, 1
            )
            result = (digits * powers).reduce_add()
            pos += 8

    # Scalar path for remaining digits
    while pos < end:
        var c = ptr[pos]
        if c < ord('0') or c > ord('9'):
            break
        result = result * 10 + Int64(c - ord('0'))
        pos += 1

    return -result if negative else result


@register_passable("trivial")
struct TapeEntry:
    """64-bit tape entry: [8-bit type | 56-bit payload]."""

    var data: UInt64

    fn __init__(out self, data: UInt64 = 0):
        self.data = data

    @staticmethod
    fn create(type_tag: UInt8, payload: Int = 0) -> Self:
        var tag_shifted = UInt64(type_tag) << 56
        var payload_masked = UInt64(payload) & PAYLOAD_MASK
        return TapeEntry(tag_shifted | payload_masked)

    @always_inline
    fn type_tag(self) -> UInt8:
        return UInt8(self.data >> 56)

    @always_inline
    fn payload(self) -> Int:
        return Int(self.data & PAYLOAD_MASK)

    @always_inline
    fn raw_u64(self) -> UInt64:
        return self.data


struct JsonTape(Movable, Sized):
    """
    Tape representation of a parsed JSON document.

    Provides O(1) access to any value via tape indices.
    No Dict/List allocations - everything is flat.
    """

    var entries: List[TapeEntry]
    var string_buffer: List[UInt8]
    var source: String
    """Original JSON source for string extraction."""

    fn __init__(out self, capacity: Int = 1024):
        self.entries = List[TapeEntry](capacity=capacity)
        self.string_buffer = List[UInt8](capacity=capacity * 4)
        self.source = String("")

    fn __moveinit__(out self, deinit other: Self):
        self.entries = other.entries^
        self.string_buffer = other.string_buffer^
        self.source = other.source^

    fn __len__(self) -> Int:
        return len(self.entries)

    # =========================================================================
    # Building Methods
    # =========================================================================

    fn append_root(mut self):
        self.entries.append(TapeEntry.create(TAPE_ROOT, 0))

    fn append_null(mut self):
        self.entries.append(TapeEntry.create(TAPE_NULL, 0))

    fn append_true(mut self):
        self.entries.append(TapeEntry.create(TAPE_TRUE, 0))

    fn append_false(mut self):
        self.entries.append(TapeEntry.create(TAPE_FALSE, 0))

    fn append_int64(mut self, value: Int64):
        self.entries.append(TapeEntry.create(TAPE_INT64, 0))
        self.entries.append(TapeEntry(UInt64(value)))

    fn append_double(mut self, value: Float64):
        self.entries.append(TapeEntry.create(TAPE_DOUBLE, 0))
        self.entries.append(TapeEntry(bitcast[DType.uint64](value)))

    fn append_string_ref(mut self, start: Int, length: Int) -> Int:
        """Append string as reference to source (zero-copy)."""
        var offset = len(self.string_buffer)

        # Store start position and length in string buffer
        # Format: [4 bytes start][4 bytes length]
        var start_bytes = UInt32(start)
        var len_bytes = UInt32(length)

        self.string_buffer.append(UInt8(start_bytes & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 8) & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 16) & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 24) & 0xFF))
        self.string_buffer.append(UInt8(len_bytes & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 8) & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 16) & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 24) & 0xFF))

        self.entries.append(TapeEntry.create(TAPE_STRING, offset))
        return offset

    fn start_array(mut self) -> Int:
        var idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_START_ARRAY, 0))
        return idx

    fn end_array(mut self, start_idx: Int):
        var end_idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_END_ARRAY, start_idx))
        self.entries[start_idx] = TapeEntry.create(TAPE_START_ARRAY, end_idx)

    fn start_object(mut self) -> Int:
        var idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_START_OBJECT, 0))
        return idx

    fn end_object(mut self, start_idx: Int):
        var end_idx = len(self.entries)
        self.entries.append(TapeEntry.create(TAPE_END_OBJECT, start_idx))
        self.entries[start_idx] = TapeEntry.create(TAPE_START_OBJECT, end_idx)

    fn finalize(mut self):
        if len(self.entries) > 0:
            self.entries[0] = TapeEntry.create(TAPE_ROOT, len(self.entries))

    # =========================================================================
    # Reading Methods
    # =========================================================================

    fn get_entry(self, idx: Int) -> TapeEntry:
        return self.entries[idx]

    fn get_string(self, offset: Int) -> String:
        """Get string from source using stored reference."""
        # Read start position (4 bytes little-endian)
        var start = Int(self.string_buffer[offset])
        start |= Int(self.string_buffer[offset + 1]) << 8
        start |= Int(self.string_buffer[offset + 2]) << 16
        start |= Int(self.string_buffer[offset + 3]) << 24

        # Read length (4 bytes little-endian)
        var length = Int(self.string_buffer[offset + 4])
        length |= Int(self.string_buffer[offset + 5]) << 8
        length |= Int(self.string_buffer[offset + 6]) << 16
        length |= Int(self.string_buffer[offset + 7]) << 24

        # Extract from source
        return self.source[start : start + length]

    fn get_int64(self, idx: Int) -> Int64:
        var entry = self.entries[idx]
        if entry.type_tag() == TAPE_INT64 and idx + 1 < len(self.entries):
            return Int64(self.entries[idx + 1].raw_u64())
        return 0

    fn get_double(self, idx: Int) -> Float64:
        var entry = self.entries[idx]
        if entry.type_tag() == TAPE_DOUBLE and idx + 1 < len(self.entries):
            return bitcast[DType.float64](self.entries[idx + 1].raw_u64())
        return 0.0

    fn skip_value(self, idx: Int) -> Int:
        """Skip value at idx, return index of next value."""
        var entry = self.entries[idx]
        var tag = entry.type_tag()

        if tag == TAPE_START_ARRAY or tag == TAPE_START_OBJECT:
            return entry.payload() + 1
        elif tag == TAPE_INT64 or tag == TAPE_DOUBLE:
            return idx + 2
        else:
            return idx + 1

    fn memory_usage(self) -> Int:
        return len(self.entries) * 8 + len(self.string_buffer)


struct TapeParser:
    """
    Two-stage JSON parser using structural index and tape.

    Stage 1: Build structural index (SIMD scan, 1.3 GB/s)
    Stage 2: Build tape from index (sequential, O(n))
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int
    """Current position in structural index."""

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index(source)
        self.idx_pos = 0

    fn parse(mut self) raises -> JsonTape:
        """Parse JSON into tape representation."""
        # Pre-allocate: estimate ~1.5 tape entries per structural char
        # (numbers use 2 entries, strings/literals use 1)
        var estimated_entries = len(self.index) * 3 // 2 + 10
        var tape = JsonTape(capacity=estimated_entries)
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        # Start parsing from first structural char
        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: JsonTape) raises:
        """Parse a single JSON value."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)
        var pos = self.index.get_position(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)
        elif char == COLON or char == COMMA:
            # After : or , we need to scan source for literal/number
            # Skip whitespace and find actual value start
            self._parse_value_after_delimiter(tape, pos)
        else:
            # Check for literals at current source position
            self._parse_literal(tape, pos)

    fn _parse_value_after_delimiter(mut self, mut tape: JsonTape, delim_pos: Int) raises:
        """Parse value after : or , by scanning source."""
        var ptr = self.source.unsafe_ptr()
        var n = len(self.source)

        # Find start of value (skip whitespace after delimiter)
        var start = delim_pos + 1
        while start < n:
            var c = ptr[start]
            if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                break
            start += 1

        if start >= n:
            return

        var c = ptr[start]

        # Check what the value is
        if c == ord('{') or c == ord('[') or c == ord('"'):
            # These should be handled by structural index, advance and recurse
            self.idx_pos += 1
            self._parse_value(tape)
        elif c == ord('t'):  # true
            tape.append_true()
            self.idx_pos += 1  # Move past next structural char
        elif c == ord('f'):  # false
            tape.append_false()
            self.idx_pos += 1
        elif c == ord('n'):  # null
            tape.append_null()
            self.idx_pos += 1
        elif c == ord('-') or (c >= ord('0') and c <= ord('9')):
            # Number - find end
            var end = start + 1
            var is_float = False

            while end < n:
                var nc = ptr[end]
                if nc == ord('.') or nc == ord('e') or nc == ord('E'):
                    is_float = True
                    end += 1
                elif nc == ord('-') or nc == ord('+') or (nc >= ord('0') and nc <= ord('9')):
                    end += 1
                else:
                    break

            if is_float:
                var num_str = self.source[start:end]
                tape.append_double(atof(num_str))
            else:
                # Fast path: parse integer directly
                tape.append_int64(_fast_parse_int(ptr, start, end))
            self.idx_pos += 1  # Move past next structural char
        else:
            self.idx_pos += 1

    @always_inline
    fn _parse_literal_between(mut self, mut tape: JsonTape, start: Int, end: Int) raises:
        """Parse literal/number value between two source positions."""
        var ptr = self.source.unsafe_ptr()
        var n = len(self.source)

        # Skip leading whitespace
        var pos = start
        while pos < end and pos < n:
            var c = ptr[pos]
            if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                break
            pos += 1

        if pos >= end or pos >= n:
            return

        var c = ptr[pos]

        if c == ord('t'):  # true
            tape.append_true()
        elif c == ord('f'):  # false
            tape.append_false()
        elif c == ord('n'):  # null
            tape.append_null()
        elif c == ord('-') or (c >= ord('0') and c <= ord('9')):
            # Number - find end
            var num_end = pos + 1
            var is_float = False

            while num_end < end and num_end < n:
                var nc = ptr[num_end]
                if nc == ord('.') or nc == ord('e') or nc == ord('E'):
                    is_float = True
                    num_end += 1
                elif nc == ord('-') or nc == ord('+') or (nc >= ord('0') and nc <= ord('9')):
                    num_end += 1
                else:
                    break

            if is_float:
                var num_str = self.source[pos:num_end]
                tape.append_double(atof(num_str))
            else:
                # Fast path: parse integer directly without string allocation
                tape.append_int64(_fast_parse_int(ptr, pos, num_end))

    fn _parse_object(mut self, mut tape: JsonTape) raises:
        """Parse JSON object {...}."""
        var start_idx = tape.start_object()
        self.idx_pos += 1  # Skip '{'

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1  # Skip '}'
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                # Key
                self._parse_string(tape)

                # Handle colon and value
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var colon_pos = self.index.get_position(self.idx_pos)
                        self.idx_pos += 1  # Skip colon

                        # Check what's next - could be struct char or literal/number
                        if self.idx_pos < len(self.index):
                            var value_char = self.index.get_character(self.idx_pos)
                            if value_char == QUOTE or value_char == LBRACE or value_char == LBRACKET:
                                self._parse_value(tape)
                            elif value_char == RBRACE or value_char == COMMA:
                                # Value is a literal/number between colon and this char
                                self._parse_literal_between(tape, colon_pos + 1, self.index.get_position(self.idx_pos))
                            else:
                                self._parse_value(tape)

                # Skip comma if present
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COMMA:
                        self.idx_pos += 1
            else:
                self.idx_pos += 1  # Skip unexpected char

        tape.end_object(start_idx)

    fn _parse_array(mut self, mut tape: JsonTape) raises:
        """Parse JSON array [...]."""
        var start_idx = tape.start_array()
        var prev_pos = self.index.get_position(self.idx_pos)  # Position of '['
        self.idx_pos += 1  # Skip '['

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)
            var curr_pos = self.index.get_position(self.idx_pos)

            if char == RBRACKET:
                # Parse any value between previous char and ]
                if curr_pos > prev_pos + 1:
                    self._parse_literal_between(tape, prev_pos + 1, curr_pos)
                self.idx_pos += 1  # Skip ']'
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                # Parse value between previous char and this comma
                if curr_pos > prev_pos + 1:
                    self._parse_literal_between(tape, prev_pos + 1, curr_pos)
                prev_pos = curr_pos
                self.idx_pos += 1  # Skip ','
            elif char == QUOTE or char == LBRACE or char == LBRACKET:
                # Nested structure - parse it
                self._parse_value(tape)
                # Update prev_pos to after this structure
                if self.idx_pos > 0 and self.idx_pos <= len(self.index):
                    prev_pos = self.index.get_position(self.idx_pos - 1)
            else:
                self._parse_value(tape)

        tape.end_array(start_idx)

    fn _parse_string(mut self, mut tape: JsonTape) raises:
        """Parse JSON string "..."."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1  # Skip opening quote

        # Find closing quote
        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1  # Skip closing quote

        # Store string reference (excluding quotes)
        _ = tape.append_string_ref(start_pos + 1, end_pos - start_pos - 1)

    fn _parse_literal(mut self, mut tape: JsonTape, pos: Int) raises:
        """Parse JSON literal (true, false, null, number)."""
        var ptr = self.source.unsafe_ptr()
        var n = len(self.source)

        if pos >= n:
            return

        var c = ptr[pos]

        if c == ord('t'):  # true
            tape.append_true()
        elif c == ord('f'):  # false
            tape.append_false()
        elif c == ord('n'):  # null
            tape.append_null()
        elif c == ord('-') or (c >= ord('0') and c <= ord('9')):
            # Number - find end
            var end = pos + 1
            var is_float = False

            while end < n:
                var nc = ptr[end]
                if nc == ord('.') or nc == ord('e') or nc == ord('E'):
                    is_float = True
                    end += 1
                elif nc == ord('-') or nc == ord('+') or (nc >= ord('0') and nc <= ord('9')):
                    end += 1
                else:
                    break

            # Parse number
            var num_str = self.source[pos:end]
            if is_float:
                tape.append_double(atof(num_str))
            else:
                tape.append_int64(atol(num_str))


fn parse_to_tape(json: String) raises -> JsonTape:
    """
    Parse JSON string into tape representation.

    This is the high-performance entry point for JSON parsing.
    Returns a tape that supports O(1) value access.

    Example:
        var tape = parse_to_tape('{"key": "value"}')
        print(len(tape))  # Number of tape entries
    """
    var parser = TapeParser(json)
    return parser.parse()


# =============================================================================
# Benchmarking
# =============================================================================


fn benchmark_tape_parse(data: String, iterations: Int) -> Float64:
    """
    Benchmark tape parsing throughput.

    Returns MB/s.
    """
    from time import perf_counter_ns

    var size = len(data)

    # Warmup
    for _ in range(5):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds
