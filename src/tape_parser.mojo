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
    build_structural_index_v2,
    build_structural_index_v3,
    build_structural_index_v4,
    StructuralIndex,
    ValueSpan,
    QUOTE,
    LBRACE,
    RBRACE,
    LBRACKET,
    RBRACKET,
    COLON,
    COMMA,
    VALUE_UNKNOWN,
    VALUE_NUMBER,
    VALUE_TRUE,
    VALUE_FALSE,
    VALUE_NULL,
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

# Character constants for number parsing (compile-time for better optimization)
alias CHAR_MINUS: UInt8 = 45     # '-'
alias CHAR_PLUS: UInt8 = 43      # '+'
alias CHAR_DOT: UInt8 = 46       # '.'
alias CHAR_0: UInt8 = 48         # '0'
alias CHAR_9: UInt8 = 57         # '9'
alias CHAR_E_LOWER: UInt8 = 101  # 'e'
alias CHAR_E_UPPER: UInt8 = 69   # 'E'

from memory import bitcast


# =============================================================================
# SWAR Number Parsing Helpers (Phase 3 Optimization)
# =============================================================================
#
# SWAR = SIMD Within A Register
# Parse 8 digits at once using 64-bit integer operations
#
# Key insight: Use 64-bit arithmetic to process multiple bytes in parallel
# - Load 8 bytes into a UInt64
# - Subtract '0' from each byte in parallel
# - Validate all bytes are digits
# - Combine using multiplication


@always_inline
fn _swar_parse_8_digits(ptr: UnsafePointer[UInt8], pos: Int) -> Tuple[UInt64, Bool]:
    """
    Parse up to 8 digits using SWAR technique.

    Returns (value, valid) where valid=True if all 8 bytes are digits.
    If fewer than 8 digits before non-digit, returns partial result with valid=False.
    """
    # Load 8 bytes into a single 64-bit value (little-endian)
    var chunk: UInt64 = 0
    for i in range(8):
        chunk |= UInt64(ptr[pos + i]) << (i * 8)

    # Subtract '0' (0x30) from each byte
    # Magic constant: 0x3030303030303030 = '0' repeated 8 times
    alias zeros = UInt64(0x3030303030303030)
    var digits = chunk - zeros

    # Check if all bytes are in range 0-9
    # After subtracting '0', valid digits are 0x00-0x09
    # Invalid chars become >= 0x0A or wrap to negative (high bit set)
    # Magic: (digit | (0x09 - digit)) has high bit set if digit > 9
    alias nines = UInt64(0x0909090909090909)
    alias high_bits = UInt64(0x8080808080808080)
    var invalid = (digits | (nines - digits)) & high_bits

    if invalid != 0:
        return (0, False)

    # All 8 bytes are valid digits!
    # Extract each byte and combine: d0 + d1*10 + d2*100 + ...
    # Or equivalently for little-endian: d0*10^7 + d1*10^6 + ...
    var d0 = (digits) & 0xFF
    var d1 = (digits >> 8) & 0xFF
    var d2 = (digits >> 16) & 0xFF
    var d3 = (digits >> 24) & 0xFF
    var d4 = (digits >> 32) & 0xFF
    var d5 = (digits >> 40) & 0xFF
    var d6 = (digits >> 48) & 0xFF
    var d7 = (digits >> 56) & 0xFF

    # Combine: first byte is highest digit in left-to-right reading
    var result = (d0 * 10000000 + d1 * 1000000 + d2 * 100000 + d3 * 10000 +
                  d4 * 1000 + d5 * 100 + d6 * 10 + d7)

    return (result, True)


@always_inline
fn _swar_count_digits(ptr: UnsafePointer[UInt8], pos: Int, max_len: Int) -> Int:
    """Count consecutive digit characters starting at pos."""
    var count = 0
    while count < max_len:
        var c = ptr[pos + count]
        if c < CHAR_0 or c > CHAR_9:
            break
        count += 1
    return count


@always_inline
fn _swar_parse_float(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Float64:
    """
    SWAR-optimized float parsing.

    Optimized for typical JSON floats (e.g., GeoJSON coordinates like -65.613617).
    Uses 8-digit SWAR parsing for integer and fractional parts.
    """
    var pos = start
    var negative = False

    # Handle negative
    if ptr[pos] == CHAR_MINUS:
        negative = True
        pos += 1

    # Count integer part digits
    var int_start = pos
    var remaining = end - pos
    var int_digits = _swar_count_digits(ptr, pos, remaining)

    var mantissa: UInt64 = 0
    var frac_digits = 0

    # Parse integer part
    if int_digits >= 8:
        # Use SWAR for first 8 digits
        var result = _swar_parse_8_digits(ptr, pos)
        mantissa = result[0]
        pos += 8
        int_digits -= 8
        # Parse remaining integer digits one by one
        while int_digits > 0 and pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + UInt64(c - CHAR_0)
            pos += 1
            int_digits -= 1
    else:
        # Few digits, parse directly
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + UInt64(c - CHAR_0)
            pos += 1

    # Parse fractional part
    if pos < end and ptr[pos] == CHAR_DOT:
        pos += 1
        var frac_start = pos

        # Count fractional digits
        remaining = end - pos
        frac_digits = _swar_count_digits(ptr, pos, remaining)

        if frac_digits >= 8:
            # Use SWAR for first 8 fractional digits
            var result = _swar_parse_8_digits(ptr, pos)
            if result[1]:  # All 8 are valid digits
                mantissa = mantissa * 100000000 + result[0]
                pos += 8
                frac_digits = 8
                # Parse any remaining fractional digits
                var extra_frac = 0
                while pos < end:
                    var c = ptr[pos]
                    if c < CHAR_0 or c > CHAR_9:
                        break
                    mantissa = mantissa * 10 + UInt64(c - CHAR_0)
                    extra_frac += 1
                    pos += 1
                frac_digits += extra_frac
            else:
                # Less than 8 valid digits, fall back
                while pos < end:
                    var c = ptr[pos]
                    if c < CHAR_0 or c > CHAR_9:
                        break
                    mantissa = mantissa * 10 + UInt64(c - CHAR_0)
                    pos += 1
                frac_digits = pos - frac_start
        else:
            # Few fractional digits, parse directly
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                mantissa = mantissa * 10 + UInt64(c - CHAR_0)
                pos += 1
            frac_digits = pos - frac_start

    # Parse exponent part
    var exponent = -frac_digits  # Decimal shift from fractional part

    if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
        pos += 1
        var exp_negative = False

        if pos < end and ptr[pos] == CHAR_MINUS:
            exp_negative = True
            pos += 1
        elif pos < end and ptr[pos] == CHAR_PLUS:
            pos += 1

        var exp_val = 0
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            exp_val = exp_val * 10 + Int(c - CHAR_0)
            pos += 1

        if exp_negative:
            exponent -= exp_val
        else:
            exponent += exp_val

    var result = _apply_exponent(Float64(mantissa), exponent)
    return -result if negative else result


# =============================================================================
# String Escape Helpers
# =============================================================================


fn _parse_hex4(s: String) -> Int:
    """Parse 4-digit hex string to integer. Returns -1 on error."""
    if len(s) != 4:
        return -1
    var result = 0
    var ptr = s.unsafe_ptr()
    for i in range(4):
        var c = ptr[i]
        var digit: Int
        if c >= ord('0') and c <= ord('9'):
            digit = Int(c - ord('0'))
        elif c >= ord('a') and c <= ord('f'):
            digit = Int(c - ord('a') + 10)
        elif c >= ord('A') and c <= ord('F'):
            digit = Int(c - ord('A') + 10)
        else:
            return -1
        result = result * 16 + digit
    return result


fn _code_point_to_utf8(code_point: Int) -> String:
    """Convert Unicode code point to UTF-8 string."""
    if code_point < 0x80:
        return chr(code_point)
    elif code_point < 0x800:
        var b1 = 0xC0 | (code_point >> 6)
        var b2 = 0x80 | (code_point & 0x3F)
        return chr(b1) + chr(b2)
    elif code_point < 0x10000:
        var b1 = 0xE0 | (code_point >> 12)
        var b2 = 0x80 | ((code_point >> 6) & 0x3F)
        var b3 = 0x80 | (code_point & 0x3F)
        return chr(b1) + chr(b2) + chr(b3)
    else:
        var b1 = 0xF0 | (code_point >> 18)
        var b2 = 0x80 | ((code_point >> 12) & 0x3F)
        var b3 = 0x80 | ((code_point >> 6) & 0x3F)
        var b4 = 0x80 | (code_point & 0x3F)
        return chr(b1) + chr(b2) + chr(b3) + chr(b4)


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

    fn append_string_ref(mut self, start: Int, length: Int, needs_unescape: Bool = False) -> Int:
        """
        Append string as reference to source (zero-copy when possible).

        Args:
            start: Start position in source string.
            length: Length of string content (excluding quotes).
            needs_unescape: True if string contains escape sequences.

        Format in string_buffer: [4 bytes start][4 bytes length][1 byte flags]
        """
        var offset = len(self.string_buffer)

        # Store start position and length in string buffer
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
        # Flags byte: bit 0 = needs_unescape
        self.string_buffer.append(UInt8(1) if needs_unescape else UInt8(0))

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
        """
        Get string from source, unescaping if needed.

        On-demand unescaping: only processes escape sequences when the
        string actually contains them, providing zero-copy for most strings.
        """
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

        # Read flags byte
        var flags = self.string_buffer[offset + 8]
        var needs_unescape = (flags & 1) != 0

        # Extract from source
        var raw = self.source[start : start + length]

        # Only unescape if needed (on-demand)
        if needs_unescape:
            return self._unescape_string(raw)
        return raw

    fn get_string_raw(self, offset: Int) -> String:
        """Get string without unescaping (for SIMD key comparison)."""
        var start = Int(self.string_buffer[offset])
        start |= Int(self.string_buffer[offset + 1]) << 8
        start |= Int(self.string_buffer[offset + 2]) << 16
        start |= Int(self.string_buffer[offset + 3]) << 24

        var length = Int(self.string_buffer[offset + 4])
        length |= Int(self.string_buffer[offset + 5]) << 8
        length |= Int(self.string_buffer[offset + 6]) << 16
        length |= Int(self.string_buffer[offset + 7]) << 24

        return self.source[start : start + length]

    fn string_needs_unescape(self, offset: Int) -> Bool:
        """Check if string at offset needs unescaping."""
        return (self.string_buffer[offset + 8] & 1) != 0

    fn _unescape_string(self, s: String) -> String:
        """Unescape JSON string escape sequences."""
        var result = String()
        var ptr = s.unsafe_ptr()
        var n = len(s)
        var i = 0

        while i < n:
            var c = ptr[i]
            if c == ord('\\') and i + 1 < n:
                var next_c = ptr[i + 1]
                if next_c == ord('"'):
                    result += '"'
                elif next_c == ord('\\'):
                    result += '\\'
                elif next_c == ord('/'):
                    result += '/'
                elif next_c == ord('b'):
                    result += '\x08'  # Backspace
                elif next_c == ord('f'):
                    result += '\x0C'  # Form feed
                elif next_c == ord('n'):
                    result += '\n'
                elif next_c == ord('r'):
                    result += '\r'
                elif next_c == ord('t'):
                    result += '\t'
                elif next_c == ord('u') and i + 5 < n:
                    # Unicode escape \uXXXX
                    var hex_str = s[i + 2 : i + 6]
                    var code_point = _parse_hex4(hex_str)
                    if code_point >= 0:
                        result += _code_point_to_utf8(code_point)
                    i += 4  # Extra skip for \uXXXX
                else:
                    result += chr(Int(next_c))
                i += 2
            else:
                result += chr(Int(c))
                i += 1

        return result

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

    fn get_string_at(self, offset: Int) -> String:
        """Get string from source using stored reference at offset."""
        return self.get_string(offset)

    fn _get_string_length(self, offset: Int) -> Int:
        """Get string length from stored reference."""
        # Read length (4 bytes little-endian, at offset + 4)
        var length = Int(self.string_buffer[offset + 4])
        length |= Int(self.string_buffer[offset + 5]) << 8
        length |= Int(self.string_buffer[offset + 6]) << 16
        length |= Int(self.string_buffer[offset + 7]) << 24
        return length

    fn _get_string_start(self, offset: Int) -> Int:
        """Get string start position from stored reference."""
        var start = Int(self.string_buffer[offset])
        start |= Int(self.string_buffer[offset + 1]) << 8
        start |= Int(self.string_buffer[offset + 2]) << 16
        start |= Int(self.string_buffer[offset + 3]) << 24
        return start


# =============================================================================
# Compressed Tape with String Interning
# =============================================================================


struct CompressedJsonTape(Movable, Sized):
    """
    Tape with string deduplication for memory efficiency.

    Useful for JSON with repeated strings (e.g., arrays of objects with
    the same keys). String interning reduces memory usage by storing each
    unique string only once.

    Example savings for [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}, ...]:
    - Without compression: "id" and "name" stored N times
    - With compression: "id" and "name" stored once, referenced N times
    """

    var entries: List[TapeEntry]
    var string_buffer: List[UInt8]
    var source: String
    var intern_table: Dict[String, Int]
    """Maps string content to offset in string_buffer."""
    var strings_interned: Int
    """Count of strings that were deduplicated."""
    var bytes_saved: Int
    """Bytes saved through deduplication."""

    fn __init__(out self, capacity: Int = 1024):
        self.entries = List[TapeEntry](capacity=capacity)
        self.string_buffer = List[UInt8](capacity=capacity * 4)
        self.source = String("")
        self.intern_table = Dict[String, Int]()
        self.strings_interned = 0
        self.bytes_saved = 0

    fn __moveinit__(out self, deinit other: Self):
        self.entries = other.entries^
        self.string_buffer = other.string_buffer^
        self.source = other.source^
        self.intern_table = other.intern_table^
        self.strings_interned = other.strings_interned
        self.bytes_saved = other.bytes_saved

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

    fn append_string_interned(mut self, start: Int, length: Int, needs_unescape: Bool = False) -> Int:
        """
        Append string with interning - reuses existing strings if found.

        Args:
            start: Start position in source string.
            length: Length of string content (excluding quotes).
            needs_unescape: True if string contains escape sequences.

        Returns:
            Offset in string_buffer (may be existing or new).
        """
        # Extract string content for lookup
        var src_ptr = self.source.unsafe_ptr()
        var content = String("")
        for i in range(length):
            content += chr(Int(src_ptr[start + i]))

        # Check if already interned
        if content in self.intern_table:
            try:
                var existing_offset = self.intern_table[content]
                self.entries.append(TapeEntry.create(TAPE_STRING, existing_offset))
                self.strings_interned += 1
                self.bytes_saved += 9 + length  # 9 bytes metadata + string length
                return existing_offset
            except:
                pass  # Should never happen since we checked 'in'

        # New string - add to buffer and intern table
        var offset = len(self.string_buffer)

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
        self.string_buffer.append(UInt8(1) if needs_unescape else UInt8(0))

        self.entries.append(TapeEntry.create(TAPE_STRING, offset))
        self.intern_table[content] = offset
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
        """Get string from source."""
        var start = Int(self.string_buffer[offset])
        start |= Int(self.string_buffer[offset + 1]) << 8
        start |= Int(self.string_buffer[offset + 2]) << 16
        start |= Int(self.string_buffer[offset + 3]) << 24

        var length = Int(self.string_buffer[offset + 4])
        length |= Int(self.string_buffer[offset + 5]) << 8
        length |= Int(self.string_buffer[offset + 6]) << 16
        length |= Int(self.string_buffer[offset + 7]) << 24

        var flags = self.string_buffer[offset + 8]
        var needs_unescape = (flags & 1) != 0

        var src_ptr = self.source.unsafe_ptr()
        var raw = String("")
        for i in range(length):
            raw += chr(Int(src_ptr[start + i]))

        if needs_unescape:
            return self._unescape_string(raw)
        return raw

    fn _unescape_string(self, s: String) -> String:
        """Unescape JSON string."""
        var result = String("")
        var ptr = s.unsafe_ptr()
        var n = len(s)
        var i = 0

        while i < n:
            var c = ptr[i]
            if c == ord('\\') and i + 1 < n:
                var next_c = ptr[i + 1]
                if next_c == ord('n'):
                    result += '\n'
                elif next_c == ord('t'):
                    result += '\t'
                elif next_c == ord('r'):
                    result += '\r'
                elif next_c == ord('\\'):
                    result += '\\'
                elif next_c == ord('"'):
                    result += '"'
                elif next_c == ord('/'):
                    result += '/'
                elif next_c == ord('b'):
                    result += chr(8)
                elif next_c == ord('f'):
                    result += chr(12)
                elif next_c == ord('u') and i + 5 < n:
                    var hex_str = s[i + 2 : i + 6]
                    var code_point = _parse_hex4(hex_str)
                    if code_point >= 0:
                        result += _code_point_to_utf8(code_point)
                    i += 4
                else:
                    result += chr(Int(next_c))
                i += 2
            else:
                result += chr(Int(c))
                i += 1

        return result

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
        """Total memory used by tape."""
        return len(self.entries) * 8 + len(self.string_buffer)

    fn compression_ratio(self) -> Float64:
        """Ratio of bytes saved to original size."""
        var original = self.memory_usage() + self.bytes_saved
        if original == 0:
            return 1.0
        return Float64(self.memory_usage()) / Float64(original)

    fn compression_stats(self) -> String:
        """Human-readable compression statistics."""
        var used = self.memory_usage()
        var saved = self.bytes_saved
        var original = used + saved
        var ratio = self.compression_ratio()
        return String("Strings interned: ") + String(self.strings_interned) + \
               ", Bytes saved: " + String(saved) + \
               ", Memory: " + String(used) + "/" + String(original) + \
               " (" + String(Int(ratio * 100)) + "%)"


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
        var tape = JsonTape(capacity=len(self.index))
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

            var num_str = self.source[start:end]
            if is_float:
                tape.append_double(atof(num_str))
            else:
                tape.append_int64(atol(num_str))
            self.idx_pos += 1  # Move past next structural char
        else:
            self.idx_pos += 1

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

            var num_str = self.source[pos:num_end]
            if is_float:
                tape.append_double(atof(num_str))
            else:
                tape.append_int64(atol(num_str))

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


# =============================================================================
# Phase 2: Optimized Tape Parser with Value Spans
# =============================================================================


struct TapeParserV2:
    """
    Phase 2 optimized two-stage JSON parser using value-indexed structural index.

    Key optimization: Uses pre-computed value positions from build_structural_index_v2
    to avoid re-scanning for numbers and literals in Stage 2.

    Stage 1: Build structural index WITH value positions (SIMD scan)
    Stage 2: Build tape using indexed positions (no re-scanning)

    Target performance: 2,000+ MB/s on Apple M3 Ultra
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index_v2(source)
        self.idx_pos = 0

    fn parse(mut self) raises -> JsonTape:
        """Parse JSON into tape representation using indexed values."""
        var tape = JsonTape(capacity=len(self.index))
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: JsonTape) raises:
        """Parse a single JSON value using indexed positions."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)
        else:
            self.idx_pos += 1

    @always_inline
    fn _fast_parse_int_inline(self, start: Int, end: Int) -> Int64:
        """
        Fast integer parsing without string allocation.

        Uses SIMD for 16-digit and 8-digit chunks when possible, otherwise
        falls back to direct byte access. Avoids string allocation entirely.

        Optimized for large integers (up to 18 digits for Int64 range).
        """
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False

        # Check for negative
        if ptr[pos] == ord('-'):
            negative = True
            pos += 1

        var digit_count = end - pos
        var result: Int64 = 0

        # SIMD path for 16+ digits (process 16 digits at once)
        if digit_count >= 16:
            # Load 16 bytes as SIMD vector
            var chunk = SIMD[DType.uint8, 16]()
            @parameter
            for i in range(16):
                chunk[i] = ptr[pos + i]

            # Convert ASCII to digits (subtract '0')
            var digits = chunk - SIMD[DType.uint8, 16](ord('0'))

            # Process in two 8-digit chunks for numerical stability
            # First 8 digits: multiply by 10^8 to 10^15
            var high_chunk = SIMD[DType.uint8, 8]()
            var low_chunk = SIMD[DType.uint8, 8]()
            @parameter
            for i in range(8):
                high_chunk[i] = digits[i]
                low_chunk[i] = digits[i + 8]

            # High 8 digits: weights 10^15 to 10^8
            var high_weights = SIMD[DType.uint64, 8](
                1000000000000000, 100000000000000, 10000000000000, 1000000000000,
                100000000000, 10000000000, 1000000000, 100000000
            )
            var high_expanded = high_chunk.cast[DType.uint64]()
            var high_result = (high_expanded * high_weights).reduce_add()

            # Low 8 digits: weights 10^7 to 10^0
            var low_weights = SIMD[DType.uint64, 8](10000000, 1000000, 100000, 10000, 1000, 100, 10, 1)
            var low_expanded = low_chunk.cast[DType.uint64]()
            var low_result = (low_expanded * low_weights).reduce_add()

            result = Int64(high_result + low_result)
            pos += 16
        # SIMD path for 8+ digits
        elif digit_count >= 8:
            # Load 8 bytes as SIMD vector
            var chunk = SIMD[DType.uint8, 8]()
            @parameter
            for i in range(8):
                chunk[i] = ptr[pos + i]

            # Convert ASCII to digits (subtract '0')
            var digits = chunk - SIMD[DType.uint8, 8](ord('0'))

            # Multiply by positional weights: 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1
            var weights = SIMD[DType.uint64, 8](10000000, 1000000, 100000, 10000, 1000, 100, 10, 1)
            var expanded = digits.cast[DType.uint64]()
            var products = expanded * weights
            result = Int64(products.reduce_add())
            pos += 8

        # Handle remaining digits (0-7 digits)
        while pos < end:
            var c = ptr[pos]
            if c < ord('0') or c > ord('9'):
                break
            result = result * 10 + Int64(c - ord('0'))
            pos += 1

        return -result if negative else result

    @always_inline
    fn _fast_parse_float_inline(self, start: Int, end: Int) -> Float64:
        """
        Fast float parsing without string allocation.

        Uses direct byte access for mantissa/exponent extraction.
        Uses compile-time character constants for optimization.
        """
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False
        var mantissa: Int64 = 0
        var exponent: Int = 0

        # Check for negative
        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        # Integer part
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_0)
            pos += 1

        # Fractional part
        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_0)
                exponent -= 1
                pos += 1

        # Exponent part
        if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
            pos += 1
            var exp_negative = False
            if pos < end and ptr[pos] == CHAR_MINUS:
                exp_negative = True
                pos += 1
            elif pos < end and ptr[pos] == CHAR_PLUS:
                pos += 1

            var exp_val: Int = 0
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_0)
                pos += 1

            if exp_negative:
                exponent -= exp_val
            else:
                exponent += exp_val

        var result = _apply_exponent(Float64(mantissa), exponent)
        return -result if negative else result

    @always_inline
    fn _use_value_span(mut self, mut tape: JsonTape, span: ValueSpan) raises:
        """Use pre-computed value span to add value to tape without re-scanning."""
        var start = Int(span.start)
        var end = Int(span.end)

        if span.value_type == VALUE_NUMBER:
            if span.is_float == 1:
                # Use fast inline float parser instead of atof
                tape.append_double(self._fast_parse_float_inline(start, end))
            else:
                # Use fast inline int parser instead of atol
                tape.append_int64(self._fast_parse_int_inline(start, end))
        elif span.value_type == VALUE_TRUE:
            tape.append_true()
        elif span.value_type == VALUE_FALSE:
            tape.append_false()
        elif span.value_type == VALUE_NULL:
            tape.append_null()

    fn _parse_object(mut self, mut tape: JsonTape) raises:
        """Parse JSON object {...} using indexed values."""
        var start_idx = tape.start_object()
        self.idx_pos += 1  # Skip '{'

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                # Key
                self._parse_string(tape)

                # Handle colon and value
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var span = self.index.get_value_span(self.idx_pos)
                        self.idx_pos += 1  # Skip colon

                        # Check if we have a pre-computed value span
                        if span.value_type != VALUE_UNKNOWN:
                            # Use indexed value - no re-scanning needed!
                            self._use_value_span(tape, span)
                        else:
                            # Value is structural (string/object/array)
                            if self.idx_pos < len(self.index):
                                self._parse_value(tape)

                # Skip comma if present
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COMMA:
                        self.idx_pos += 1
            else:
                self.idx_pos += 1

        tape.end_object(start_idx)

    fn _parse_array(mut self, mut tape: JsonTape) raises:
        """Parse JSON array [...] using indexed values."""
        var start_idx = tape.start_array()

        # Check if first element is a pre-computed value
        var first_span = self.index.get_value_span(self.idx_pos)
        self.idx_pos += 1  # Skip '['

        # Handle first element if it's a non-structural value
        if first_span.value_type != VALUE_UNKNOWN:
            self._use_value_span(tape, first_span)

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACKET:
                self.idx_pos += 1
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                var span = self.index.get_value_span(self.idx_pos)
                self.idx_pos += 1  # Skip comma

                # Check if value after comma is indexed
                if span.value_type != VALUE_UNKNOWN:
                    self._use_value_span(tape, span)
                else:
                    # Value is structural - parse it
                    if self.idx_pos < len(self.index):
                        var next_char = self.index.get_character(self.idx_pos)
                        if next_char == QUOTE or next_char == LBRACE or next_char == LBRACKET:
                            self._parse_value(tape)
            elif char == QUOTE or char == LBRACE or char == LBRACKET:
                self._parse_value(tape)
            else:
                self.idx_pos += 1

        tape.end_array(start_idx)

    fn _parse_string(mut self, mut tape: JsonTape) raises:
        """Parse JSON string "..." with escape detection."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1  # Skip opening quote

        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1  # Skip closing quote

        # Detect escape sequences using SIMD scan for backslash
        var str_start = start_pos + 1
        var str_len = end_pos - start_pos - 1
        var needs_unescape = self._string_has_escape(str_start, str_len)

        _ = tape.append_string_ref(str_start, str_len, needs_unescape)

    @always_inline
    fn _string_has_escape(self, start: Int, length: Int) -> Bool:
        """SIMD-accelerated scan for backslash in string."""
        if length == 0:
            return False

        var ptr = self.source.unsafe_ptr()
        var i = 0
        alias BACKSLASH = SIMD[DType.uint8, 16](0x5C)

        # SIMD path: scan 16 bytes at a time
        while i + 16 <= length:
            var chunk = SIMD[DType.uint8, 16]()
            @parameter
            for j in range(16):
                chunk[j] = ptr[start + i + j]

            # Check for backslash (0x5C) - XOR with backslash, if any byte is 0 we found it
            var diff = chunk ^ BACKSLASH
            # A byte is 0 if it was backslash - check by OR-reducing and seeing if any position had a match
            var has_match = False
            @parameter
            for j in range(16):
                if diff[j] == 0:
                    has_match = True
            if has_match:
                return True
            i += 16

        # Scalar tail
        while i < length:
            if ptr[start + i] == 0x5C:  # backslash
                return True
            i += 1

        return False


fn parse_to_tape_v2(json: String) raises -> JsonTape:
    """
    Phase 2 optimized JSON parsing with value position indexing.

    This version uses pre-computed value positions to avoid re-scanning
    for numbers and literals, providing significant speedup for number-heavy JSON.

    Example:
        var tape = parse_to_tape_v2('[1, 2, 3, 4, 5]')
        print(len(tape))  # Faster than parse_to_tape for number arrays
    """
    var parser = TapeParserV2(json)
    return parser.parse()


struct TapeParserV3:
    """
    V3 parser using 32-byte SIMD structural indexing.

    Same parsing logic as TapeParserV2, but uses build_structural_index_v3
    for faster Stage 1 on large files.
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index_v3(source)  # V3 uses 32-byte SIMD
        self.idx_pos = 0

    fn parse(mut self) raises -> JsonTape:
        """Parse JSON into tape representation using V3 indexed values."""
        var tape = JsonTape(capacity=len(self.index))
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: JsonTape) raises:
        """Parse a single JSON value."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)

    fn _parse_string(mut self, mut tape: JsonTape) raises:
        """Parse JSON string with escape detection."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1  # Skip opening quote

        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1  # Skip closing quote

        var str_start = start_pos + 1
        var str_len = end_pos - start_pos - 1
        var needs_unescape = self._string_has_escape(str_start, str_len)

        _ = tape.append_string_ref(str_start, str_len, needs_unescape)

    @always_inline
    fn _string_has_escape(self, start: Int, length: Int) -> Bool:
        """Quick scan for backslash in string."""
        if length == 0:
            return False

        var ptr = self.source.unsafe_ptr()
        for i in range(length):
            if ptr[start + i] == 0x5C:  # backslash
                return True
        return False

    @always_inline
    fn _use_value_span(mut self, mut tape: JsonTape, span: ValueSpan) raises:
        """Use pre-computed value span."""
        var ptr = self.source.unsafe_ptr()
        var start = Int(span.start)
        var end = Int(span.end)

        if span.value_type == VALUE_NUMBER:
            if span.is_float == 1:
                tape.append_double(self._fast_parse_float_inline(start, end))
            else:
                tape.append_int64(self._fast_parse_int_inline(start, end))
        elif span.value_type == VALUE_TRUE:
            tape.append_true()
        elif span.value_type == VALUE_FALSE:
            tape.append_false()
        elif span.value_type == VALUE_NULL:
            tape.append_null()

    @always_inline
    fn _fast_parse_int_inline(self, start: Int, end: Int) -> Int64:
        """Fast integer parsing."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        var result: Int64 = 0
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            result = result * 10 + Int64(c - CHAR_0)
            pos += 1

        return -result if negative else result

    @always_inline
    fn _fast_parse_float_inline(self, start: Int, end: Int) -> Float64:
        """Fast float parsing."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False
        var mantissa: Int64 = 0
        var exponent: Int = 0

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_0)
            pos += 1

        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_0)
                exponent -= 1
                pos += 1

        if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
            pos += 1
            var exp_negative = False
            if pos < end and ptr[pos] == CHAR_MINUS:
                exp_negative = True
                pos += 1
            elif pos < end and ptr[pos] == CHAR_PLUS:
                pos += 1

            var exp_val: Int = 0
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_0)
                pos += 1

            if exp_negative:
                exponent -= exp_val
            else:
                exponent += exp_val

        var result = _apply_exponent(Float64(mantissa), exponent)
        return -result if negative else result

    fn _parse_object(mut self, mut tape: JsonTape) raises:
        """Parse JSON object."""
        var start_idx = tape.start_object()
        self.idx_pos += 1

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                self._parse_string(tape)
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var span = self.index.get_value_span(self.idx_pos)
                        self.idx_pos += 1
                        if span.value_type != VALUE_UNKNOWN:
                            self._use_value_span(tape, span)
                        else:
                            self._parse_value(tape)
            elif char == COMMA:
                self.idx_pos += 1
            else:
                self.idx_pos += 1

    fn _parse_array(mut self, mut tape: JsonTape) raises:
        """Parse JSON array."""
        var start_idx = tape.start_array()
        var first_span = self.index.get_value_span(self.idx_pos)
        self.idx_pos += 1

        # First element
        if first_span.value_type != VALUE_UNKNOWN:
            self._use_value_span(tape, first_span)
        elif self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)
            if char != RBRACKET and char != COMMA:
                self._parse_value(tape)

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACKET:
                self.idx_pos += 1
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                var span = self.index.get_value_span(self.idx_pos)
                self.idx_pos += 1
                if span.value_type != VALUE_UNKNOWN:
                    self._use_value_span(tape, span)
                else:
                    self._parse_value(tape)
            else:
                self._parse_value(tape)


fn parse_to_tape_v3(json: String) raises -> JsonTape:
    """
    V3 JSON parsing with 32-byte SIMD structural indexing.

    Uses wider SIMD (32-byte chunks) for Stage 1 to improve throughput
    through better instruction-level parallelism.

    Example:
        var tape = parse_to_tape_v3(large_json)
        # ~10-20% faster Stage 1 on large files
    """
    var parser = TapeParserV3(json)
    return parser.parse()


# =============================================================================
# TapeParserV4: Branchless Character Classification
# =============================================================================


struct TapeParserV4:
    """
    V4 parser using branchless character classification.

    Uses lookup table for character classification instead of conditional
    comparisons, eliminating branches in the hot Stage 1 path.
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index_v4(source)  # V4 uses branchless lookup
        self.idx_pos = 0

    fn parse(mut self) raises -> JsonTape:
        """Parse JSON into tape representation using V4 indexed values."""
        var tape = JsonTape(capacity=len(self.index))
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: JsonTape) raises:
        """Parse a single JSON value."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)

    fn _parse_string(mut self, mut tape: JsonTape) raises:
        """Parse JSON string with escape detection."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1  # Skip opening quote

        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1  # Skip closing quote

        var str_start = start_pos + 1
        var str_len = end_pos - start_pos - 1
        var needs_unescape = self._string_has_escape(str_start, str_len)

        _ = tape.append_string_ref(str_start, str_len, needs_unescape)

    @always_inline
    fn _string_has_escape(self, start: Int, length: Int) -> Bool:
        """Quick scan for backslash in string."""
        if length == 0:
            return False

        var ptr = self.source.unsafe_ptr()
        for i in range(length):
            if ptr[start + i] == 0x5C:  # backslash
                return True
        return False

    @always_inline
    fn _use_value_span(mut self, mut tape: JsonTape, span: ValueSpan) raises:
        """Use pre-computed value span."""
        var ptr = self.source.unsafe_ptr()
        var start = Int(span.start)
        var end = Int(span.end)

        if span.value_type == VALUE_NUMBER:
            if span.is_float == 1:
                tape.append_double(self._fast_parse_float_inline(start, end))
            else:
                tape.append_int64(self._fast_parse_int_inline(start, end))
        elif span.value_type == VALUE_TRUE:
            tape.append_true()
        elif span.value_type == VALUE_FALSE:
            tape.append_false()
        elif span.value_type == VALUE_NULL:
            tape.append_null()

    @always_inline
    fn _fast_parse_int_inline(self, start: Int, end: Int) -> Int64:
        """Fast integer parsing."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var result: Int64 = 0
        var negative = False

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        while pos < end:
            var digit = Int64(ptr[pos]) - 48
            result = result * 10 + digit
            pos += 1

        return -result if negative else result

    @always_inline
    fn _fast_parse_float_inline(self, start: Int, end: Int) -> Float64:
        """Fast float parsing with inlined common exponents."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var result: Float64 = 0.0
        var negative = False

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        # Integer part
        while pos < end and ptr[pos] >= CHAR_0 and ptr[pos] <= CHAR_9:
            result = result * 10.0 + Float64(Int(ptr[pos]) - 48)
            pos += 1

        # Fractional part
        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            var frac_mult: Float64 = 0.1
            while pos < end and ptr[pos] >= CHAR_0 and ptr[pos] <= CHAR_9:
                result += Float64(Int(ptr[pos]) - 48) * frac_mult
                frac_mult *= 0.1
                pos += 1

        # Exponent part
        if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
            pos += 1
            var exp_negative = False

            if pos < end and ptr[pos] == CHAR_MINUS:
                exp_negative = True
                pos += 1
            elif pos < end and ptr[pos] == CHAR_PLUS:
                pos += 1

            var exponent = 0
            while pos < end and ptr[pos] >= CHAR_0 and ptr[pos] <= CHAR_9:
                exponent = exponent * 10 + (Int(ptr[pos]) - 48)
                pos += 1

            if exp_negative:
                exponent = -exponent

            result = _apply_exponent(result, exponent)

        return -result if negative else result

    fn _parse_object(mut self, mut tape: JsonTape) raises:
        """Parse JSON object."""
        var start_idx = tape.start_object()
        self.idx_pos += 1  # Skip {

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                self._parse_string(tape)
                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var span = self.index.get_value_span(self.idx_pos)
                        self.idx_pos += 1
                        if span.value_type != VALUE_UNKNOWN:
                            self._use_value_span(tape, span)
                        else:
                            self._parse_value(tape)
            elif char == COMMA:
                self.idx_pos += 1
            else:
                self.idx_pos += 1

    fn _parse_array(mut self, mut tape: JsonTape) raises:
        """Parse JSON array."""
        var start_idx = tape.start_array()
        var first_span = self.index.get_value_span(self.idx_pos)
        self.idx_pos += 1  # Skip [

        # First element
        if first_span.value_type != VALUE_UNKNOWN:
            self._use_value_span(tape, first_span)
        elif self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)
            if char != RBRACKET and char != COMMA:
                self._parse_value(tape)

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACKET:
                self.idx_pos += 1
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                var span = self.index.get_value_span(self.idx_pos)
                self.idx_pos += 1
                if span.value_type != VALUE_UNKNOWN:
                    self._use_value_span(tape, span)
                else:
                    self._parse_value(tape)
            else:
                self._parse_value(tape)


fn parse_to_tape_v4(json: String) raises -> JsonTape:
    """
    V4 JSON parsing with branchless character classification.

    Uses lookup table for character classification instead of conditional
    comparisons, eliminating branches in the hot Stage 1 path.

    Example:
        var tape = parse_to_tape_v4(large_json)
        # Branchless Stage 1 for better pipelining
    """
    var parser = TapeParserV4(json)
    return parser.parse()


fn benchmark_tape_parse_v2(data: String, iterations: Int) -> Float64:
    """
    Benchmark Phase 2 tape parsing throughput.

    Returns MB/s.
    """
    from time import perf_counter_ns

    var size = len(data)

    # Warmup
    for _ in range(5):
        try:
            var tape = parse_to_tape_v2(data)
            _ = tape
        except:
            pass

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape_v2(data)
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


# =============================================================================
# Compressed Tape Parser with String Interning
# =============================================================================


struct CompressedTapeParser:
    """
    JSON parser that produces a compressed tape with string interning.

    Useful for JSON with repeated strings (arrays of objects with same keys).
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index_v2(source)
        self.idx_pos = 0

    fn parse(mut self) raises -> CompressedJsonTape:
        """Parse JSON into compressed tape with string interning."""
        var tape = CompressedJsonTape(capacity=len(self.index))
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: CompressedJsonTape) raises:
        """Parse a single JSON value."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)
        else:
            # Use value span for primitives
            var span = self.index.get_value_span(self.idx_pos)
            if span.value_type != VALUE_UNKNOWN:
                self._use_value_span(tape, span)
            self.idx_pos += 1

    fn _use_value_span(mut self, mut tape: CompressedJsonTape, span: ValueSpan) raises:
        """Use pre-computed value span."""
        var start = Int(span.start)
        var end = Int(span.end)

        if span.value_type == VALUE_NUMBER:
            if span.is_float == 1:
                tape.append_double(self._fast_parse_float_inline(start, end))
            else:
                tape.append_int64(self._fast_parse_int_inline(start, end))
        elif span.value_type == VALUE_TRUE:
            tape.append_true()
        elif span.value_type == VALUE_FALSE:
            tape.append_false()
        elif span.value_type == VALUE_NULL:
            tape.append_null()

    fn _fast_parse_int_inline(self, start: Int, end: Int) -> Int64:
        """Fast integer parsing using character constants."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        var result: Int64 = 0
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            result = result * 10 + Int64(c - CHAR_0)
            pos += 1

        return -result if negative else result

    fn _fast_parse_float_inline(self, start: Int, end: Int) -> Float64:
        """Fast float parsing using character constants."""
        var ptr = self.source.unsafe_ptr()
        var pos = start
        var negative = False
        var mantissa: Int64 = 0
        var exponent: Int = 0

        if ptr[pos] == CHAR_MINUS:
            negative = True
            pos += 1

        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_0)
            pos += 1

        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_0)
                exponent -= 1
                pos += 1

        if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
            pos += 1
            var exp_negative = False
            if pos < end and ptr[pos] == CHAR_MINUS:
                exp_negative = True
                pos += 1
            elif pos < end and ptr[pos] == CHAR_PLUS:
                pos += 1

            var exp_val: Int = 0
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_0 or c > CHAR_9:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_0)
                pos += 1

            if exp_negative:
                exponent -= exp_val
            else:
                exponent += exp_val

        var result = _apply_exponent(Float64(mantissa), exponent)
        return -result if negative else result

    fn _parse_object(mut self, mut tape: CompressedJsonTape) raises:
        """Parse JSON object with string interning for keys."""
        var start_idx = tape.start_object()
        self.idx_pos += 1

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                self._parse_string(tape)

                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var span = self.index.get_value_span(self.idx_pos)
                        self.idx_pos += 1

                        if span.value_type != VALUE_UNKNOWN:
                            self._use_value_span(tape, span)
                        else:
                            if self.idx_pos < len(self.index):
                                self._parse_value(tape)

                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COMMA:
                        self.idx_pos += 1
            else:
                self.idx_pos += 1

        tape.end_object(start_idx)

    fn _parse_array(mut self, mut tape: CompressedJsonTape) raises:
        """Parse JSON array."""
        var start_idx = tape.start_array()
        var first_span = self.index.get_value_span(self.idx_pos)
        self.idx_pos += 1

        if first_span.value_type != VALUE_UNKNOWN:
            self._use_value_span(tape, first_span)

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACKET:
                self.idx_pos += 1
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                var span = self.index.get_value_span(self.idx_pos)
                self.idx_pos += 1

                if span.value_type != VALUE_UNKNOWN:
                    self._use_value_span(tape, span)
                else:
                    if self.idx_pos < len(self.index):
                        var next_char = self.index.get_character(self.idx_pos)
                        if next_char == QUOTE or next_char == LBRACE or next_char == LBRACKET:
                            self._parse_value(tape)
            elif char == QUOTE or char == LBRACE or char == LBRACKET:
                self._parse_value(tape)
            else:
                self.idx_pos += 1

        tape.end_array(start_idx)

    fn _parse_string(mut self, mut tape: CompressedJsonTape) raises:
        """Parse JSON string with interning."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1

        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1

        var str_start = start_pos + 1
        var str_len = end_pos - start_pos - 1
        var needs_unescape = self._string_has_escape(str_start, str_len)

        _ = tape.append_string_interned(str_start, str_len, needs_unescape)

    fn _string_has_escape(self, start: Int, length: Int) -> Bool:
        """Check for escape sequences in string."""
        if length == 0:
            return False

        var ptr = self.source.unsafe_ptr()
        for i in range(length):
            if ptr[start + i] == 0x5C:  # backslash
                return True
        return False


fn parse_to_tape_compressed(json: String) raises -> CompressedJsonTape:
    """
    Parse JSON with string interning for memory efficiency.

    Best for JSON with repeated strings (arrays of objects with same keys).

    Example:
        var tape = parse_to_tape_compressed('[{"id": 1}, {"id": 2}]')
        print(tape.compression_stats())  # Shows bytes saved
    """
    var parser = CompressedTapeParser(json)
    return parser.parse()


# =============================================================================
# Lazy JSON Access Functions (Functional API)
# =============================================================================
#
# These functions provide lazy access to parsed JSON data without using
# UnsafePointer to struct types (which has compatibility issues in Mojo 0.25.7).
#
# Usage:
#     var tape = parse_to_tape_v2(json)
#     var name_idx = tape_get_object_value(tape, 1, "name")
#     var name = tape_get_string(tape, name_idx)


@always_inline
fn _simd_string_eq_tape(tape: JsonTape, buf_offset: Int, key: String) -> Bool:
    """
    SIMD-accelerated string comparison for tape string vs key.

    Compares 16 bytes at a time, falling back to scalar for remainder.
    """
    var str_len = tape._get_string_length(buf_offset)
    var key_len = len(key)

    if str_len != key_len:
        return False

    var str_start = tape._get_string_start(buf_offset)
    var src_ptr = tape.source.unsafe_ptr()
    var key_ptr = key.unsafe_ptr()

    var i = 0

    # SIMD path: compare 16 bytes at a time
    while i + 16 <= str_len:
        var chunk_a = SIMD[DType.uint8, 16]()
        var chunk_b = SIMD[DType.uint8, 16]()

        @parameter
        for j in range(16):
            chunk_a[j] = src_ptr[str_start + i + j]
            chunk_b[j] = key_ptr[i + j]

        # XOR and check if any bytes differ
        var diff = chunk_a ^ chunk_b
        if diff.reduce_or() != 0:
            return False

        i += 16

    # Scalar tail
    while i < str_len:
        if src_ptr[str_start + i] != key_ptr[i]:
            return False
        i += 1

    return True


fn tape_skip_value(tape: JsonTape, idx: Int) -> Int:
    """Skip a value in the tape, returning the next index."""
    var entry = tape.entries[idx]
    var tag = entry.type_tag()

    if tag == TAPE_START_OBJECT or tag == TAPE_START_ARRAY:
        return entry.payload() + 1
    elif tag == TAPE_INT64 or tag == TAPE_DOUBLE:
        return idx + 2
    else:
        return idx + 1


fn tape_get_object_value(tape: JsonTape, obj_idx: Int, key: String) -> Int:
    """
    Get object value index by key using SIMD-accelerated string matching.

    Returns the tape index of the value, or 0 if not found.

    Example:
        var tape = parse_to_tape_v2('{"name": "Alice", "age": 30}')
        var name_idx = tape_get_object_value(tape, 1, "name")
        if name_idx > 0:
            var name = tape.get_string(tape.entries[name_idx].payload())
    """
    var entry = tape.entries[obj_idx]
    if entry.type_tag() != TAPE_START_OBJECT:
        return 0  # Not an object

    var idx = obj_idx + 1  # Skip '{'
    var end_idx = entry.payload()

    while idx < end_idx:
        var e = tape.entries[idx]
        var tag = e.type_tag()

        if tag == TAPE_STRING:
            # This is a key - compare using SIMD
            var buf_offset = e.payload()
            if _simd_string_eq_tape(tape, buf_offset, key):
                # Found! Return value at next position
                return idx + 1

            # Skip to value after this key
            idx += 1
            idx = tape_skip_value(tape, idx)
        elif tag == TAPE_END_OBJECT:
            break
        else:
            idx += 1

    return 0  # Not found


fn tape_get_array_element(tape: JsonTape, arr_idx: Int, index: Int) -> Int:
    """
    Get array element index by position.

    Returns the tape index of the element, or 0 if out of bounds.

    Example:
        var tape = parse_to_tape_v2('[1, 2, 3, 4, 5]')
        var third_idx = tape_get_array_element(tape, 1, 2)
        if third_idx > 0:
            var val = tape.get_int64(third_idx)
    """
    var entry = tape.entries[arr_idx]
    if entry.type_tag() != TAPE_START_ARRAY:
        return 0  # Not an array

    var idx = arr_idx + 1  # Skip '['
    var end_idx = entry.payload()
    var current_index = 0

    while idx < end_idx:
        var e = tape.entries[idx]
        var tag = e.type_tag()

        if tag == TAPE_END_ARRAY:
            break

        if current_index == index:
            return idx

        idx = tape_skip_value(tape, idx)
        current_index += 1

    return 0  # Out of bounds


fn tape_is_object(tape: JsonTape, idx: Int) -> Bool:
    """Check if value at index is an object."""
    return tape.entries[idx].type_tag() == TAPE_START_OBJECT


fn tape_is_array(tape: JsonTape, idx: Int) -> Bool:
    """Check if value at index is an array."""
    return tape.entries[idx].type_tag() == TAPE_START_ARRAY


fn tape_is_string(tape: JsonTape, idx: Int) -> Bool:
    """Check if value at index is a string."""
    return tape.entries[idx].type_tag() == TAPE_STRING


fn tape_is_int(tape: JsonTape, idx: Int) -> Bool:
    """Check if value at index is an integer."""
    return tape.entries[idx].type_tag() == TAPE_INT64


fn tape_is_float(tape: JsonTape, idx: Int) -> Bool:
    """Check if value at index is a float."""
    return tape.entries[idx].type_tag() == TAPE_DOUBLE


fn tape_get_string_value(tape: JsonTape, idx: Int) -> String:
    """Get string value at index."""
    var entry = tape.entries[idx]
    if entry.type_tag() == TAPE_STRING:
        return tape.get_string(entry.payload())
    return String("")


fn tape_get_int_value(tape: JsonTape, idx: Int) -> Int64:
    """Get integer value at index."""
    return tape.get_int64(idx)


fn tape_get_float_value(tape: JsonTape, idx: Int) -> Float64:
    """Get float value at index."""
    return tape.get_double(idx)


fn tape_get_bool_value(tape: JsonTape, idx: Int) -> Bool:
    """Get boolean value at index."""
    return tape.entries[idx].type_tag() == TAPE_TRUE


fn tape_array_len(tape: JsonTape, arr_idx: Int) -> Int:
    """Get length of array at index."""
    var entry = tape.entries[arr_idx]
    if entry.type_tag() != TAPE_START_ARRAY:
        return 0

    var idx = arr_idx + 1
    var end_idx = entry.payload()
    var count = 0

    while idx < end_idx:
        var tag = tape.entries[idx].type_tag()
        if tag == TAPE_END_ARRAY:
            break
        idx = tape_skip_value(tape, idx)
        count += 1

    return count


fn tape_object_len(tape: JsonTape, obj_idx: Int) -> Int:
    """Get number of key-value pairs in object at index."""
    var entry = tape.entries[obj_idx]
    if entry.type_tag() != TAPE_START_OBJECT:
        return 0

    var idx = obj_idx + 1
    var end_idx = entry.payload()
    var count = 0

    while idx < end_idx:
        var tag = tape.entries[idx].type_tag()
        if tag == TAPE_END_OBJECT:
            break
        if tag == TAPE_STRING:
            # Skip key and value
            idx += 1
            idx = tape_skip_value(tape, idx)
            count += 1
        else:
            idx += 1

    return count


# =============================================================================
# LazyArrayIterator - Zero-Allocation Array Iteration (Functional)
# =============================================================================
#
# Note: Due to Mojo 0.25.7 lifetime parameter limitations, LazyJsonValue and
# LazyArrayIterator are implemented as functional helpers rather than
# lifetime-parameterized structs. Use the tape_* functions directly:
#
#   var tape = parse_to_tape_v2(json)
#   var name_idx = tape_get_object_value(tape, 1, "name")
#   var name = tape_get_string_value(tape, name_idx)
#
#   # Array iteration:
#   var arr_idx = 1  # Array at root
#   var iter_pos = arr_idx + 1
#   var end_idx = tape.entries[arr_idx].payload()
#   while iter_pos < end_idx:
#       if tape.entries[iter_pos].type_tag() == TAPE_END_ARRAY:
#           break
#       var value = tape_get_int_value(tape, iter_pos)
#       iter_pos = tape_skip_value(tape, iter_pos)


fn tape_array_iter_start(tape: JsonTape, arr_idx: Int) -> Int:
    """Get starting position for array iteration."""
    if tape.entries[arr_idx].type_tag() == TAPE_START_ARRAY:
        return arr_idx + 1
    return 0


fn tape_array_iter_end(tape: JsonTape, arr_idx: Int) -> Int:
    """Get ending position for array iteration."""
    if tape.entries[arr_idx].type_tag() == TAPE_START_ARRAY:
        return tape.entries[arr_idx].payload()
    return 0


fn tape_array_iter_has_next(tape: JsonTape, pos: Int, end_idx: Int) -> Bool:
    """Check if there are more elements in array iteration."""
    if pos >= end_idx:
        return False
    return tape.entries[pos].type_tag() != TAPE_END_ARRAY


# =============================================================================
# Prefetch Optimization
# =============================================================================
#
# Prefetch hints help the CPU load data into cache before it's needed,
# reducing memory latency during sequential tape access.

from sys.intrinsics import PrefetchOptions, PrefetchLocality, PrefetchRW, prefetch
from memory import UnsafePointer


@always_inline
fn tape_prefetch_entry(tape: JsonTape, idx: Int):
    """
    Prefetch a single tape entry into L1 cache.

    Use before accessing an entry to reduce memory latency.
    Most effective when called 10-50 entries ahead of access.
    """
    if idx >= 0 and idx < len(tape.entries):
        alias opts = PrefetchOptions()
        # Cast TapeEntry pointer to UInt64 pointer for prefetch
        var entry_ptr = tape.entries.unsafe_ptr()
        var u64_ptr = entry_ptr.bitcast[UInt64]()
        prefetch[opts](u64_ptr.offset(idx))


@always_inline
fn tape_prefetch_range(tape: JsonTape, start: Int, count: Int):
    """
    Prefetch a range of tape entries into cache.

    Args:
        tape: The JSON tape.
        start: Starting index.
        count: Number of entries to prefetch (max 64 recommended).

    Use when iterating through arrays or objects to prefetch upcoming entries.
    """
    alias opts = PrefetchOptions()
    var entry_ptr = tape.entries.unsafe_ptr()
    var u64_ptr = entry_ptr.bitcast[UInt64]()
    var n = len(tape.entries)
    var end = min(start + count, n)

    # Prefetch in cache-line sized chunks (8 entries = 64 bytes)
    var i = start
    while i < end:
        prefetch[opts](u64_ptr.offset(i))
        i += 8  # 8 x 8-byte entries = 64 byte cache line


@always_inline
fn tape_prefetch_children(tape: JsonTape, container_idx: Int):
    """
    Prefetch all direct children of an array or object.

    Call this before iterating through a container's elements
    to pre-load them into CPU cache.

    Args:
        tape: The JSON tape.
        container_idx: Index of array or object start entry.
    """
    if container_idx < 0 or container_idx >= len(tape.entries):
        return

    var entry = tape.entries[container_idx]
    var tag = entry.type_tag()

    # Only works on containers
    if tag != TAPE_START_ARRAY and tag != TAPE_START_OBJECT:
        return

    var end_idx = entry.payload()
    if end_idx <= container_idx:
        return

    # Prefetch up to 64 entries (512 bytes)
    var count = min(end_idx - container_idx, 64)
    tape_prefetch_range(tape, container_idx + 1, count)


@always_inline
fn tape_prefetch_string_data(tape: JsonTape, string_offset: Int):
    """
    Prefetch string buffer data for a string entry.

    Call this before accessing a string value to pre-load
    the string reference data into cache.

    Args:
        tape: The JSON tape.
        string_offset: Offset into string_buffer (from tape entry payload).
    """
    if string_offset < 0 or string_offset + 9 > len(tape.string_buffer):
        return

    alias opts = PrefetchOptions()
    var ptr = tape.string_buffer.unsafe_ptr()
    prefetch[opts](ptr.offset(string_offset))


# =============================================================================
# JSON Pointer (RFC 6901) Support
# =============================================================================
#
# JSON Pointer provides a string syntax for identifying a specific value
# within a JSON document. Examples:
#   ""           -> root document
#   "/foo"       -> key "foo" in root object
#   "/foo/0"     -> first element of array "foo"
#   "/a~1b"      -> key "a/b" (/ escaped as ~1)
#   "/m~0n"      -> key "m~n" (~ escaped as ~0)


fn _unescape_json_pointer_segment(segment: String) -> String:
    """Unescape JSON Pointer segment (~0 -> ~, ~1 -> /)."""
    var result = String()
    var ptr = segment.unsafe_ptr()
    var n = len(segment)
    var i = 0

    while i < n:
        if ptr[i] == ord('~') and i + 1 < n:
            if ptr[i + 1] == ord('0'):
                result += '~'
                i += 2
                continue
            elif ptr[i + 1] == ord('1'):
                result += '/'
                i += 2
                continue
        result += chr(Int(ptr[i]))
        i += 1

    return result


fn _parse_array_index(segment: String) -> Int:
    """Parse array index from pointer segment. Returns -1 if not a valid index."""
    if len(segment) == 0:
        return -1

    var ptr = segment.unsafe_ptr()

    # Leading zeros not allowed except for "0"
    if len(segment) > 1 and ptr[0] == ord('0'):
        return -1

    var result = 0
    for i in range(len(segment)):
        var c = ptr[i]
        if c < ord('0') or c > ord('9'):
            return -1
        result = result * 10 + Int(c - ord('0'))

    return result


fn tape_get_pointer(tape: JsonTape, pointer: String) -> Int:
    """
    Get tape index at JSON Pointer path (RFC 6901).

    Args:
        tape: The parsed JSON tape.
        pointer: JSON Pointer string (e.g., "/users/0/name").

    Returns:
        Tape index of the value, or 0 if not found.

    Examples:
        var tape = parse_to_tape_v2('{"users": [{"name": "Alice"}]}')
        var idx = tape_get_pointer(tape, "/users/0/name")
        if idx > 0:
            print(tape_get_string_value(tape, idx))  # "Alice"
    """
    if len(pointer) == 0:
        # Empty pointer -> root document
        return 1

    var ptr = pointer.unsafe_ptr()
    if ptr[0] != ord('/'):
        # Invalid pointer - must start with /
        return 0

    var current_idx = 1  # Start at root value
    var n = len(pointer)
    var seg_start = 1  # Skip leading /

    while seg_start < n:
        # Find end of segment
        var seg_end = seg_start
        while seg_end < n and ptr[seg_end] != ord('/'):
            seg_end += 1

        # Extract and unescape segment
        var segment = pointer[seg_start:seg_end]
        if len(segment) > 0:
            # Check for ~0 or ~1 escapes
            var has_escape = False
            for i in range(len(segment) - 1):
                if ptr[seg_start + i] == ord('~'):
                    has_escape = True
                    break

            var key = segment if not has_escape else _unescape_json_pointer_segment(segment)

            # Navigate based on current value type
            var entry = tape.entries[current_idx]
            var tag = entry.type_tag()

            if tag == TAPE_START_OBJECT:
                # Object - lookup by key
                current_idx = tape_get_object_value(tape, current_idx, key)
                if current_idx == 0:
                    return 0  # Key not found
            elif tag == TAPE_START_ARRAY:
                # Array - lookup by index
                var index = _parse_array_index(key)
                if index < 0:
                    return 0  # Invalid array index
                current_idx = tape_get_array_element(tape, current_idx, index)
                if current_idx == 0:
                    return 0  # Index out of bounds
            else:
                # Cannot navigate into scalar values
                return 0

        seg_start = seg_end + 1  # Skip /

    return current_idx


fn tape_get_pointer_string(tape: JsonTape, pointer: String) -> String:
    """Get string value at JSON Pointer path."""
    var idx = tape_get_pointer(tape, pointer)
    if idx > 0:
        return tape_get_string_value(tape, idx)
    return String("")


fn tape_get_pointer_int(tape: JsonTape, pointer: String) -> Int64:
    """Get integer value at JSON Pointer path."""
    var idx = tape_get_pointer(tape, pointer)
    if idx > 0:
        return tape_get_int_value(tape, idx)
    return 0


fn tape_get_pointer_float(tape: JsonTape, pointer: String) -> Float64:
    """Get float value at JSON Pointer path."""
    var idx = tape_get_pointer(tape, pointer)
    if idx > 0:
        return tape_get_float_value(tape, idx)
    return 0.0


fn tape_get_pointer_bool(tape: JsonTape, pointer: String) -> Bool:
    """Get boolean value at JSON Pointer path."""
    var idx = tape_get_pointer(tape, pointer)
    if idx > 0:
        return tape_get_bool_value(tape, idx)
    return False


# =============================================================================
# Parallel Tape Parser (Phase 3b)
# =============================================================================
#
# Uses Mojo's parallelize to parse numbers concurrently.
# Provides ~50% speedup for number-heavy JSON.
#

from algorithm import parallelize


@register_passable("trivial")
struct ParsedNumber:
    """Pre-parsed number value for parallel processing."""
    var int_value: Int64
    var float_value: Float64
    var is_float: UInt8  # 0 = int, 1 = float
    var span_idx: Int  # Index in structural index

    fn __init__(out self):
        self.int_value = 0
        self.float_value = 0.0
        self.is_float = 0
        self.span_idx = 0

    fn __init__(out self, int_val: Int64, float_val: Float64, is_flt: UInt8, idx: Int):
        self.int_value = int_val
        self.float_value = float_val
        self.is_float = is_flt
        self.span_idx = idx

    @staticmethod
    fn from_int(value: Int64, idx: Int) -> Self:
        var result = ParsedNumber()
        result.int_value = value
        result.span_idx = idx
        result.is_float = 0
        return result

    @staticmethod
    fn from_float(value: Float64, idx: Int) -> Self:
        var result = ParsedNumber()
        result.float_value = value
        result.span_idx = idx
        result.is_float = 1
        return result


struct ParallelTapeParser:
    """
    Tape parser with parallel number parsing.

    Strategy:
    1. Build structural index (single-threaded SIMD, ~1.3 GB/s)
    2. Extract all number spans from index
    3. Parse numbers in parallel using `parallelize`
    4. Build tape using pre-parsed values

    Best for: Number-heavy JSON (sensor data, coordinates, metrics).
    """

    var source: String
    var index: StructuralIndex
    var idx_pos: Int
    var parsed_numbers: List[ParsedNumber]
    var number_lookup: Dict[Int, Int]  # span_idx -> parsed_numbers index

    fn __init__(out self, source: String):
        self.source = source
        self.index = build_structural_index_v2(source)
        self.idx_pos = 0
        self.parsed_numbers = List[ParsedNumber]()
        self.number_lookup = Dict[Int, Int]()

    fn parse(mut self, parallel_threshold: Int = 50) raises -> JsonTape:
        """
        Parse JSON into tape with parallel number parsing.

        Args:
            parallel_threshold: Minimum number of numbers to use parallelism.
                               Default 50 (below this, parallel overhead not worth it).
        """
        # Collect all number spans
        var number_spans = List[ValueSpan]()
        var span_indices = List[Int]()

        for i in range(len(self.index)):
            var span = self.index.get_value_span(i)
            if span.value_type == VALUE_NUMBER:
                number_spans.append(span)
                span_indices.append(i)

        # Pre-allocate parsed numbers
        for _ in range(len(number_spans)):
            self.parsed_numbers.append(ParsedNumber())

        # Parse numbers (parallel if enough)
        if len(number_spans) >= parallel_threshold:
            self._parse_numbers_parallel(number_spans, span_indices)
        else:
            self._parse_numbers_sequential(number_spans, span_indices)

        # Build lookup table
        for i in range(len(span_indices)):
            self.number_lookup[span_indices[i]] = i

        # Build tape using pre-parsed numbers
        return self._build_tape()

    fn _parse_numbers_parallel(
        mut self,
        spans: List[ValueSpan],
        indices: List[Int]
    ):
        """Parse numbers in parallel using Mojo's parallelize."""
        var src_ptr = self.source.unsafe_ptr()
        var n = len(spans)

        # Capture what we need for the closure
        var results_ptr = self.parsed_numbers.unsafe_ptr()

        @parameter
        fn parse_one(idx: Int):
            var span = spans[idx]
            var start = Int(span.start)
            var end = Int(span.end)
            var span_idx = indices[idx]

            if span.is_float == 1:
                var value = _parallel_parse_float(src_ptr, start, end)
                results_ptr[idx] = ParsedNumber.from_float(value, span_idx)
            else:
                var value = _parallel_parse_int(src_ptr, start, end)
                results_ptr[idx] = ParsedNumber.from_int(value, span_idx)

        parallelize[parse_one](n)

    fn _parse_numbers_sequential(
        mut self,
        spans: List[ValueSpan],
        indices: List[Int]
    ):
        """Parse numbers sequentially (for small counts)."""
        var src_ptr = self.source.unsafe_ptr()

        for i in range(len(spans)):
            var span = spans[i]
            var start = Int(span.start)
            var end = Int(span.end)
            var span_idx = indices[i]

            if span.is_float == 1:
                var value = _parallel_parse_float(src_ptr, start, end)
                self.parsed_numbers[i] = ParsedNumber.from_float(value, span_idx)
            else:
                var value = _parallel_parse_int(src_ptr, start, end)
                self.parsed_numbers[i] = ParsedNumber.from_int(value, span_idx)

    fn _build_tape(mut self) raises -> JsonTape:
        """Build tape using pre-parsed numbers."""
        var tape = JsonTape(capacity=len(self.index))
        tape.source = self.source
        tape.append_root()

        if len(self.index) == 0:
            tape.finalize()
            return tape^

        self.idx_pos = 0
        self._parse_value(tape)
        tape.finalize()
        return tape^

    fn _parse_value(mut self, mut tape: JsonTape) raises:
        """Parse a single JSON value."""
        if self.idx_pos >= len(self.index):
            return

        var char = self.index.get_character(self.idx_pos)

        if char == LBRACE:
            self._parse_object(tape)
        elif char == LBRACKET:
            self._parse_array(tape)
        elif char == QUOTE:
            self._parse_string(tape)
        else:
            # Use pre-parsed number or parse literal
            var span = self.index.get_value_span(self.idx_pos)
            if span.value_type != VALUE_UNKNOWN:
                self._use_value_span(tape, span)
            self.idx_pos += 1

    fn _use_value_span(mut self, mut tape: JsonTape, span: ValueSpan) raises:
        """Use pre-parsed value from span."""
        if span.value_type == VALUE_NUMBER:
            # Look up pre-parsed number
            if self.idx_pos in self.number_lookup:
                try:
                    var num_idx = self.number_lookup[self.idx_pos]
                    var parsed = self.parsed_numbers[num_idx]
                    if parsed.is_float == 1:
                        tape.append_double(parsed.float_value)
                    else:
                        tape.append_int64(parsed.int_value)
                except:
                    # Fallback to inline parsing
                    var start = Int(span.start)
                    var end = Int(span.end)
                    if span.is_float == 1:
                        tape.append_double(self._fast_parse_float(start, end))
                    else:
                        tape.append_int64(self._fast_parse_int(start, end))
            else:
                var start = Int(span.start)
                var end = Int(span.end)
                if span.is_float == 1:
                    tape.append_double(self._fast_parse_float(start, end))
                else:
                    tape.append_int64(self._fast_parse_int(start, end))
        elif span.value_type == VALUE_TRUE:
            tape.append_true()
        elif span.value_type == VALUE_FALSE:
            tape.append_false()
        elif span.value_type == VALUE_NULL:
            tape.append_null()

    fn _fast_parse_int(self, start: Int, end: Int) -> Int64:
        """Fast integer parsing (inline)."""
        var ptr = self.source.unsafe_ptr()
        return _parallel_parse_int(ptr, start, end)

    fn _fast_parse_float(self, start: Int, end: Int) -> Float64:
        """Fast float parsing (inline)."""
        var ptr = self.source.unsafe_ptr()
        return _parallel_parse_float(ptr, start, end)

    fn _parse_object(mut self, mut tape: JsonTape) raises:
        """Parse JSON object."""
        var start_idx = tape.start_object()
        self.idx_pos += 1

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACE:
                self.idx_pos += 1
                tape.end_object(start_idx)
                return
            elif char == QUOTE:
                self._parse_string(tape)

                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COLON:
                        var span = self.index.get_value_span(self.idx_pos)
                        self.idx_pos += 1

                        if span.value_type != VALUE_UNKNOWN:
                            self._use_value_span(tape, span)
                        else:
                            if self.idx_pos < len(self.index):
                                self._parse_value(tape)

                if self.idx_pos < len(self.index):
                    var next_char = self.index.get_character(self.idx_pos)
                    if next_char == COMMA:
                        self.idx_pos += 1
            else:
                self.idx_pos += 1

        tape.end_object(start_idx)

    fn _parse_array(mut self, mut tape: JsonTape) raises:
        """Parse JSON array."""
        var start_idx = tape.start_array()
        var first_span = self.index.get_value_span(self.idx_pos)
        self.idx_pos += 1

        if first_span.value_type != VALUE_UNKNOWN:
            self._use_value_span(tape, first_span)

        while self.idx_pos < len(self.index):
            var char = self.index.get_character(self.idx_pos)

            if char == RBRACKET:
                self.idx_pos += 1
                tape.end_array(start_idx)
                return
            elif char == COMMA:
                var span = self.index.get_value_span(self.idx_pos)
                self.idx_pos += 1

                if span.value_type != VALUE_UNKNOWN:
                    self._use_value_span(tape, span)
                else:
                    if self.idx_pos < len(self.index):
                        var next_char = self.index.get_character(self.idx_pos)
                        if next_char == QUOTE or next_char == LBRACE or next_char == LBRACKET:
                            self._parse_value(tape)
            elif char == QUOTE or char == LBRACE or char == LBRACKET:
                self._parse_value(tape)
            else:
                self.idx_pos += 1

        tape.end_array(start_idx)

    fn _parse_string(mut self, mut tape: JsonTape) raises:
        """Parse JSON string."""
        var start_pos = self.index.get_position(self.idx_pos)
        self.idx_pos += 1

        var end_pos = start_pos + 1
        if self.idx_pos < len(self.index):
            var next_char = self.index.get_character(self.idx_pos)
            if next_char == QUOTE:
                end_pos = self.index.get_position(self.idx_pos)
                self.idx_pos += 1

        var str_start = start_pos + 1
        var str_len = end_pos - start_pos - 1
        var needs_unescape = self._string_has_escape(str_start, str_len)

        _ = tape.append_string_ref(str_start, str_len, needs_unescape)

    fn _string_has_escape(self, start: Int, length: Int) -> Bool:
        """Check if string contains escape sequences."""
        if length == 0:
            return False
        var ptr = self.source.unsafe_ptr()
        for i in range(length):
            if ptr[start + i] == 0x5C:
                return True
        return False


# Thread-safe number parsing functions (no shared state)


@always_inline
fn _apply_exponent(value: Float64, exponent: Int) -> Float64:
    """
    Apply power-of-10 exponent with inlined common cases.

    Most JSON floats (coordinates, sensor data) have exponents in [-10, 10].
    We inline these for maximum performance.
    """
    if exponent == 0:
        return value
    elif exponent == -1:
        return value * 0.1
    elif exponent == -2:
        return value * 0.01
    elif exponent == -3:
        return value * 0.001
    elif exponent == -4:
        return value * 0.0001
    elif exponent == -5:
        return value * 0.00001
    elif exponent == -6:
        return value * 0.000001
    elif exponent == -7:
        return value * 0.0000001
    elif exponent == -8:
        return value * 0.00000001
    elif exponent == -9:
        return value * 0.000000001
    elif exponent == -10:
        return value * 0.0000000001
    elif exponent == 1:
        return value * 10.0
    elif exponent == 2:
        return value * 100.0
    elif exponent == 3:
        return value * 1000.0
    elif exponent == 4:
        return value * 10000.0
    elif exponent == 5:
        return value * 100000.0
    elif exponent > 0:
        # Positive exponent > 5
        var result = value
        for _ in range(exponent):
            result *= 10.0
        return result
    else:
        # Negative exponent < -10
        var result = value
        for _ in range(-exponent):
            result *= 0.1
        return result


@always_inline
fn _parallel_parse_int(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Int64:
    """Thread-safe integer parsing using character constants."""
    var pos = start
    var negative = False

    if ptr[pos] == CHAR_MINUS:
        negative = True
        pos += 1
    elif ptr[pos] == CHAR_PLUS:
        pos += 1

    var result: Int64 = 0
    while pos < end:
        var c = ptr[pos]
        if c < CHAR_0 or c > CHAR_9:
            break
        result = result * 10 + Int64(c - CHAR_0)
        pos += 1

    return -result if negative else result


@always_inline
fn _parallel_parse_float(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Float64:
    """
    Thread-safe float parsing with optimized power-of-10 lookup.

    Uses compile-time character constants and inlined exponent application
    for maximum performance on coordinate-heavy data.
    """
    var pos = start
    var negative = False
    var mantissa: Int64 = 0
    var exponent: Int = 0

    if ptr[pos] == CHAR_MINUS:
        negative = True
        pos += 1
    elif ptr[pos] == CHAR_PLUS:
        pos += 1

    # Integer part
    while pos < end:
        var c = ptr[pos]
        if c < CHAR_0 or c > CHAR_9:
            break
        mantissa = mantissa * 10 + Int64(c - CHAR_0)
        pos += 1

    # Fractional part
    if pos < end and ptr[pos] == CHAR_DOT:
        pos += 1
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_0)
            exponent -= 1
            pos += 1

    # Exponent part
    if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
        pos += 1
        var exp_neg = False
        if pos < end and ptr[pos] == CHAR_MINUS:
            exp_neg = True
            pos += 1
        elif pos < end and ptr[pos] == CHAR_PLUS:
            pos += 1

        var exp_val = 0
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_0 or c > CHAR_9:
                break
            exp_val = exp_val * 10 + Int(c - CHAR_0)
            pos += 1

        exponent += -exp_val if exp_neg else exp_val

    var result = _apply_exponent(Float64(mantissa), exponent)
    return -result if negative else result


fn parse_to_tape_parallel(json: String, parallel_threshold: Int = 50) raises -> JsonTape:
    """
    Parse JSON with parallel number parsing.

    Uses Mojo's `parallelize` to parse numbers concurrently.
    Best for number-heavy JSON (sensor data, coordinates, metrics).

    Args:
        json: JSON string to parse.
        parallel_threshold: Minimum numbers to use parallelism (default 50).

    Returns:
        Parsed tape representation.

    Example:
        var tape = parse_to_tape_parallel(sensor_data_json)
        var temp = tape_get_pointer_float(tape, "/readings/0/temperature")
    """
    var parser = ParallelTapeParser(json)
    return parser.parse(parallel_threshold)
