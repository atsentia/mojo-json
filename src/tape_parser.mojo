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

# Compile-time character constants (avoid ord() runtime calls)
alias CHAR_SPACE: UInt8 = 32      # ' '
alias CHAR_TAB: UInt8 = 9         # '\t'
alias CHAR_NEWLINE: UInt8 = 10    # '\n'
alias CHAR_CR: UInt8 = 13         # '\r'
alias CHAR_MINUS: UInt8 = 45      # '-'
alias CHAR_PLUS: UInt8 = 43       # '+'
alias CHAR_DOT: UInt8 = 46        # '.'
alias CHAR_ZERO: UInt8 = 48       # '0'
alias CHAR_NINE: UInt8 = 57       # '9'
alias CHAR_E_LOWER: UInt8 = 101   # 'e'
alias CHAR_E_UPPER: UInt8 = 69    # 'E'
alias CHAR_T: UInt8 = 116         # 't'
alias CHAR_F: UInt8 = 102         # 'f'
alias CHAR_N: UInt8 = 110         # 'n'
alias CHAR_QUOTE: UInt8 = 34      # '"'
alias CHAR_LBRACE: UInt8 = 123    # '{'
alias CHAR_RBRACE: UInt8 = 125    # '}'
alias CHAR_LBRACKET: UInt8 = 91   # '['
alias CHAR_RBRACKET: UInt8 = 93   # ']'
alias CHAR_COLON: UInt8 = 58      # ':'
alias CHAR_COMMA: UInt8 = 44      # ','
alias CHAR_BACKSLASH: UInt8 = 92  # '\\'

from memory import bitcast, ArcPointer


@always_inline
fn _fast_parse_int(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Int64:
    """Fast integer parsing with SIMD acceleration for 8-16 digit numbers."""
    var pos = start
    var negative = False
    var result: Int64 = 0

    # Handle sign
    if ptr[pos] == CHAR_MINUS:
        negative = True
        pos += 1
    elif ptr[pos] == CHAR_PLUS:
        pos += 1

    var digit_count = end - pos

    # SIMD path for 16+ digits (process first 8, then next 8)
    if digit_count >= 16:
        # Load first 8 bytes
        var chunk1 = SIMD[DType.uint8, 8]()
        @parameter
        for i in range(8):
            chunk1[i] = ptr[pos + i]

        var min1 = chunk1.reduce_min()
        var max1 = chunk1.reduce_max()

        # Load second 8 bytes
        var chunk2 = SIMD[DType.uint8, 8]()
        @parameter
        for i in range(8):
            chunk2[i] = ptr[pos + 8 + i]

        var min2 = chunk2.reduce_min()
        var max2 = chunk2.reduce_max()

        # Check all 16 bytes are digits
        var all_digits = (min1 >= CHAR_ZERO and max1 <= CHAR_NINE and
                         min2 >= CHAR_ZERO and max2 <= CHAR_NINE)

        if all_digits:
            # Convert first 8 digits
            var digits1 = (chunk1 - CHAR_ZERO).cast[DType.int64]()
            alias powers_high = SIMD[DType.int64, 8](
                1000000000000000, 100000000000000, 10000000000000, 1000000000000,
                100000000000, 10000000000, 1000000000, 100000000
            )
            var high_part = (digits1 * powers_high).reduce_add()

            # Convert second 8 digits
            var digits2 = (chunk2 - CHAR_ZERO).cast[DType.int64]()
            alias powers_low = SIMD[DType.int64, 8](
                10000000, 1000000, 100000, 10000, 1000, 100, 10, 1
            )
            var low_part = (digits2 * powers_low).reduce_add()

            result = high_part + low_part
            pos += 16

    # SIMD path for 8+ digits
    elif digit_count >= 8:
        # Load 8 bytes
        var chunk = SIMD[DType.uint8, 8]()
        @parameter
        for i in range(8):
            chunk[i] = ptr[pos + i]

        # Check if all are digits: min >= '0' and max <= '9'
        var min_val = chunk.reduce_min()
        var max_val = chunk.reduce_max()
        var all_digits = min_val >= CHAR_ZERO and max_val <= CHAR_NINE

        if all_digits:
            # Convert 8 digits in parallel
            var digits = (chunk - CHAR_ZERO).cast[DType.int64]()

            # Multiply by powers of 10: [10^7, 10^6, ..., 10^0]
            alias powers = SIMD[DType.int64, 8](
                10000000, 1000000, 100000, 10000, 1000, 100, 10, 1
            )
            result = (digits * powers).reduce_add()
            pos += 8

    # Scalar path for remaining digits
    while pos < end:
        var c = ptr[pos]
        if c < CHAR_ZERO or c > CHAR_NINE:
            break
        result = result * 10 + Int64(c - CHAR_ZERO)
        pos += 1

    return -result if negative else result


@always_inline
fn _fast_parse_float(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Float64:
    """Fast float parsing without string allocation.

    Parses: integer part . fractional part [e/E exponent]
    """
    var pos = start
    var negative = False

    # Handle sign
    if pos < end and ptr[pos] == CHAR_MINUS:
        negative = True
        pos += 1
    elif pos < end and ptr[pos] == CHAR_PLUS:
        pos += 1

    # Parse integer part
    var int_part: Float64 = 0.0
    while pos < end:
        var c = ptr[pos]
        if c < CHAR_ZERO or c > CHAR_NINE:
            break
        int_part = int_part * 10.0 + Float64(Int(c - CHAR_ZERO))
        pos += 1

    # Parse fractional part
    var frac_part: Float64 = 0.0
    var frac_scale: Float64 = 1.0
    if pos < end and ptr[pos] == CHAR_DOT:
        pos += 1
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            frac_part = frac_part * 10.0 + Float64(Int(c - CHAR_ZERO))
            frac_scale *= 10.0
            pos += 1

    var result = int_part + frac_part / frac_scale

    # Parse exponent
    if pos < end and (ptr[pos] == CHAR_E_LOWER or ptr[pos] == CHAR_E_UPPER):
        pos += 1
        var exp_negative = False
        if pos < end and ptr[pos] == CHAR_MINUS:
            exp_negative = True
            pos += 1
        elif pos < end and ptr[pos] == CHAR_PLUS:
            pos += 1

        var exp: Int = 0
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            exp = exp * 10 + Int(c - CHAR_ZERO)
            pos += 1

        # Apply exponent using precomputed powers
        if exp_negative:
            for _ in range(exp):
                result /= 10.0
        else:
            for _ in range(exp):
                result *= 10.0

    return -result if negative else result


@always_inline
fn _skip_whitespace_simd(ptr: UnsafePointer[UInt8], start: Int, end: Int) -> Int:
    """Skip whitespace using SIMD. Returns position of first non-whitespace."""
    var pos = start

    # SIMD path: check 8 bytes at once
    while pos + 8 <= end:
        var chunk = SIMD[DType.uint8, 8]()
        @parameter
        for i in range(8):
            chunk[i] = ptr[pos + i]

        # Check each byte for non-whitespace and return early
        # This is faster than building a SIMD mask for short runs
        @parameter
        for i in range(8):
            var c = chunk[i]
            if c != CHAR_SPACE and c != CHAR_TAB and c != CHAR_NEWLINE and c != CHAR_CR:
                return pos + i
        pos += 8

    # Scalar fallback
    while pos < end:
        var c = ptr[pos]
        if c != CHAR_SPACE and c != CHAR_TAB and c != CHAR_NEWLINE and c != CHAR_CR:
            return pos
        pos += 1

    return pos


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
        if c < CHAR_ZERO or c > CHAR_NINE:
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + UInt64(c - CHAR_ZERO)
            pos += 1
            int_digits -= 1
    else:
        # Few digits, parse directly
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + UInt64(c - CHAR_ZERO)
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
                    if c < CHAR_ZERO or c > CHAR_NINE:
                        break
                    mantissa = mantissa * 10 + UInt64(c - CHAR_ZERO)
                    extra_frac += 1
                    pos += 1
                frac_digits += extra_frac
            else:
                # Less than 8 valid digits, fall back
                while pos < end:
                    var c = ptr[pos]
                    if c < CHAR_ZERO or c > CHAR_NINE:
                        break
                    mantissa = mantissa * 10 + UInt64(c - CHAR_ZERO)
                    pos += 1
                frac_digits = pos - frac_start
        else:
            # Few fractional digits, parse directly
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                mantissa = mantissa * 10 + UInt64(c - CHAR_ZERO)
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            exp_val = exp_val * 10 + Int(c - CHAR_ZERO)
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

        # Store start position and length in string buffer (9 bytes total)
        # Optimized: Reserve space and write directly instead of 9 appends
        var start_bytes = UInt32(start)
        var len_bytes = UInt32(length)
        var flags = UInt8(1) if needs_unescape else UInt8(0)

        # Reserve 9 bytes at once
        self.string_buffer.reserve(offset + 9)

        # Write all 9 bytes using extend pattern (reduces append overhead)
        self.string_buffer.append(UInt8(start_bytes & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 8) & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 16) & 0xFF))
        self.string_buffer.append(UInt8((start_bytes >> 24) & 0xFF))
        self.string_buffer.append(UInt8(len_bytes & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 8) & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 16) & 0xFF))
        self.string_buffer.append(UInt8((len_bytes >> 24) & 0xFF))
        self.string_buffer.append(flags)

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

    @always_inline
    fn get_string_range(self, offset: Int) -> Tuple[Int, Int]:
        """Get string start and length without copying. PERF: Zero allocation."""
        var start = Int(self.string_buffer[offset])
        start |= Int(self.string_buffer[offset + 1]) << 8
        start |= Int(self.string_buffer[offset + 2]) << 16
        start |= Int(self.string_buffer[offset + 3]) << 24

        var length = Int(self.string_buffer[offset + 4])
        length |= Int(self.string_buffer[offset + 5]) << 8
        length |= Int(self.string_buffer[offset + 6]) << 16
        length |= Int(self.string_buffer[offset + 7]) << 24

        return (start, length)

    @always_inline
    fn string_equals(self, offset: Int, key: String) -> Bool:
        """
        Compare tape string against key using SIMD. PERF: No string allocation.

        Uses vectorized comparison for strings >= 8 bytes, with early exit
        on length mismatch. ~2-4x faster than get_string() + == for long keys.
        """
        var str_range = self.get_string_range(offset)
        var start = str_range[0]
        var length = str_range[1]

        # Early exit on length mismatch
        if length != len(key):
            return False

        # Empty strings are equal
        if length == 0:
            return True

        # Get pointers for comparison
        var src_ptr = self.source.unsafe_ptr().bitcast[UInt8]()
        var key_ptr = key.unsafe_ptr().bitcast[UInt8]()

        var pos = 0

        # SIMD path: Compare 8 bytes at a time
        while pos + 8 <= length:
            var src_chunk = SIMD[DType.uint8, 8]()
            var key_chunk = SIMD[DType.uint8, 8]()

            @parameter
            for i in range(8):
                src_chunk[i] = src_ptr[start + pos + i]
                key_chunk[i] = key_ptr[pos + i]

            # If any byte differs, strings are not equal
            # XOR gives non-zero for differing bytes
            var diff = src_chunk ^ key_chunk
            if diff.reduce_or() != 0:
                return False

            pos += 8

        # Scalar path for remaining bytes
        while pos < length:
            if src_ptr[start + pos] != key_ptr[pos]:
                return False
            pos += 1

        return True

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

        # Find start of value (SIMD whitespace skip)
        var start = _skip_whitespace_simd(ptr, delim_pos + 1, n)

        if start >= n:
            return

        var c = ptr[start]

        # Check what the value is
        if c == CHAR_LBRACE or c == CHAR_LBRACKET or c == CHAR_QUOTE:
            # These should be handled by structural index, advance and recurse
            self.idx_pos += 1
            self._parse_value(tape)
        elif c == CHAR_T:  # true
            tape.append_true()
            self.idx_pos += 1  # Move past next structural char
        elif c == CHAR_F:  # false
            tape.append_false()
            self.idx_pos += 1
        elif c == CHAR_N:  # null
            tape.append_null()
            self.idx_pos += 1
        elif c == CHAR_MINUS or (c >= CHAR_ZERO and c <= CHAR_NINE):
            # Number - find end
            var end = start + 1
            var is_float = False

            while end < n:
                var nc = ptr[end]
                if nc == CHAR_DOT or nc == CHAR_E_LOWER or nc == CHAR_E_UPPER:
                    is_float = True
                    end += 1
                elif nc == CHAR_MINUS or nc == CHAR_PLUS or (nc >= CHAR_ZERO and nc <= CHAR_NINE):
                    end += 1
                else:
                    break

            if is_float:
                # Fast float parsing without string allocation
                tape.append_double(_fast_parse_float(ptr, start, end))
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
        var limit = min(end, n)

        # Skip leading whitespace (SIMD)
        var pos = _skip_whitespace_simd(ptr, start, limit)

        if pos >= limit:
            return

        var c = ptr[pos]

        if c == CHAR_T:  # true
            tape.append_true()
        elif c == CHAR_F:  # false
            tape.append_false()
        elif c == CHAR_N:  # null
            tape.append_null()
        elif c == CHAR_MINUS or (c >= CHAR_ZERO and c <= CHAR_NINE):
            # Number - find end
            var num_end = pos + 1
            var is_float = False

            while num_end < limit:
                var nc = ptr[num_end]
                if nc == CHAR_DOT or nc == CHAR_E_LOWER or nc == CHAR_E_UPPER:
                    is_float = True
                    num_end += 1
                elif nc == CHAR_MINUS or nc == CHAR_PLUS or (nc >= CHAR_ZERO and nc <= CHAR_NINE):
                    num_end += 1
                else:
                    break

            if is_float:
                # Fast float parsing without string allocation
                tape.append_double(_fast_parse_float(ptr, pos, num_end))
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

        if c == CHAR_T:  # true
            tape.append_true()
        elif c == CHAR_F:  # false
            tape.append_false()
        elif c == CHAR_N:  # null
            tape.append_null()
        elif c == CHAR_MINUS or (c >= CHAR_ZERO and c <= CHAR_NINE):
            # Number - find end
            var end = pos + 1
            var is_float = False

            while end < n:
                var nc = ptr[end]
                if nc == CHAR_DOT or nc == CHAR_E_LOWER or nc == CHAR_E_UPPER:
                    is_float = True
                    end += 1
                elif nc == CHAR_MINUS or nc == CHAR_PLUS or (nc >= CHAR_ZERO and nc <= CHAR_NINE):
                    end += 1
                else:
                    break

            # Parse number without string allocation
            if is_float:
                tape.append_double(_fast_parse_float(ptr, pos, end))
            else:
                tape.append_int64(_fast_parse_int(ptr, pos, end))


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
# Tape-to-JsonValue Conversion
# =============================================================================

from src.value import JsonValue, JsonArray, JsonObject


struct TapeConverter:
    """Helper for tape-to-JsonValue conversion with mutable index."""
    var tape: JsonTape
    var idx: Int

    fn __init__(out self, var tape: JsonTape):
        self.tape = tape^
        self.idx = 1

    fn convert(mut self) -> JsonValue:
        """Convert tape to JsonValue tree."""
        if len(self.tape) <= 1:
            return JsonValue.null()
        return self._convert_entry()

    fn _convert_entry(mut self) -> JsonValue:
        """Convert tape entry at current idx to JsonValue."""
        var entry = self.tape.get_entry(self.idx)
        var tag = entry.type_tag()

        if tag == TAPE_NULL:
            self.idx += 1
            return JsonValue.null()
        elif tag == TAPE_TRUE:
            self.idx += 1
            return JsonValue.from_bool(True)
        elif tag == TAPE_FALSE:
            self.idx += 1
            return JsonValue.from_bool(False)
        elif tag == TAPE_INT64:
            var value = self.tape.get_int64(self.idx)
            self.idx += 2
            return JsonValue.from_int(value)
        elif tag == TAPE_DOUBLE:
            var value = self.tape.get_double(self.idx)
            self.idx += 2
            return JsonValue.from_float(value)
        elif tag == TAPE_STRING:
            var offset = entry.payload()
            var str_value = self.tape.get_string(offset)
            self.idx += 1
            return JsonValue.from_string(str_value)
        elif tag == TAPE_START_ARRAY:
            var end_idx = entry.payload()
            var arr = List[JsonValue](capacity=8)
            self.idx += 1

            while self.idx < end_idx:
                var elem = self._convert_entry()
                arr.append(elem^)

            self.idx = end_idx + 1
            return JsonValue.from_array_move(arr^)
        elif tag == TAPE_START_OBJECT:
            var end_idx = entry.payload()
            var obj = Dict[String, JsonValue]()
            self.idx += 1

            while self.idx < end_idx:
                # Key (string)
                var key_entry = self.tape.get_entry(self.idx)
                if key_entry.type_tag() == TAPE_STRING:
                    var key_offset = key_entry.payload()
                    var key = self.tape.get_string(key_offset)
                    self.idx += 1

                    # Value
                    var val = self._convert_entry()
                    obj[key] = val^
                else:
                    self.idx += 1

            self.idx = end_idx + 1
            return JsonValue.from_object_move(obj^)
        else:
            self.idx += 1
            return JsonValue.null()


fn tape_to_json_value(var tape: JsonTape) -> JsonValue:
    """
    Convert tape representation to JsonValue tree.

    This is for API compatibility when JsonValue is needed.
    For maximum performance, use the tape directly.
    """
    var converter = TapeConverter(tape^)
    return converter.convert()


fn parse_fast(json: String) raises -> JsonValue:
    """
    High-performance JSON parser using tape-based architecture.

    ~50-70x faster than recursive descent parser for large files.
    Uses two-stage parsing:
      Stage 1: SIMD structural scan (1+ GB/s)
      Stage 2: Tape building from index

    Returns JsonValue for API compatibility.
    For maximum performance, use parse_to_tape() directly.

    Example:
        var value = parse_fast('{"name": "Alice", "age": 30}')
        print(value["name"].as_string())  # Alice
    """
    var tape = parse_to_tape(json)
    return tape_to_json_value(tape^)


# =============================================================================
# Lazy JSON Value - On-Demand Parsing (High Performance)
# =============================================================================


struct LazyArrayIterator:
    """
    Zero-allocation iterator over lazy JSON array.

    PERF: Yields LazyJsonValue for each element without building a List.
    Uses ArcPointer to share tape with parent LazyJsonValue.

    Example:
        var lazy = parse_lazy('[1, 2, 3, 4, 5]')
        for item in lazy.iter_array():
            print(item.as_int())
    """
    var _tape: ArcPointer[JsonTape]
    var _pos: Int
    var _end_idx: Int

    fn __init__(out self, tape: ArcPointer[JsonTape], start_idx: Int, end_idx: Int):
        self._tape = tape
        self._pos = start_idx
        self._end_idx = end_idx

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) -> LazyJsonValue:
        """Return next element or null if exhausted."""
        if self._pos >= self._end_idx:
            # Return null for exhausted iterator
            var empty_tape = JsonTape(capacity=2)
            empty_tape.append_root()
            empty_tape.append_null()
            empty_tape.finalize()
            return LazyJsonValue(empty_tape^, 1)

        var result = LazyJsonValue(self._tape, self._pos)
        self._pos = self._tape[].skip_value(self._pos)
        return result

    fn __len__(self) -> Int:
        """Count remaining elements (O(n) - iterates through)."""
        var count = 0
        var pos = self._pos
        while pos < self._end_idx:
            count += 1
            pos = self._tape[].skip_value(pos)
        return count

    fn __has_next__(self) -> Bool:
        """Check if more elements remain."""
        return self._pos < self._end_idx


struct LazyObjectIterator:
    """
    Zero-allocation iterator over lazy JSON object key-value pairs.

    PERF: Yields (key, LazyJsonValue) for each entry without building a Dict.
    Uses ArcPointer to share tape with parent LazyJsonValue.

    Example:
        var lazy = parse_lazy('{"a": 1, "b": 2}')
        for kv in lazy.iter_object():
            print(kv[0], "=", kv[1].as_int())
    """
    var _tape: ArcPointer[JsonTape]
    var _pos: Int
    var _end_idx: Int

    fn __init__(out self, tape: ArcPointer[JsonTape], start_idx: Int, end_idx: Int):
        self._tape = tape
        self._pos = start_idx
        self._end_idx = end_idx

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) -> Tuple[String, LazyJsonValue]:
        """Return next (key, value) pair or ("", null) if exhausted."""
        if self._pos >= self._end_idx:
            var empty_tape = JsonTape(capacity=2)
            empty_tape.append_root()
            empty_tape.append_null()
            empty_tape.finalize()
            return (String(""), LazyJsonValue(empty_tape^, 1))

        # Read key
        var key_entry = self._tape[].get_entry(self._pos)
        var key = String("")
        if key_entry.type_tag() == TAPE_STRING:
            var key_offset = key_entry.payload()
            key = self._tape[].get_string(key_offset)
        self._pos += 1

        # Get value
        var value = LazyJsonValue(self._tape, self._pos)
        self._pos = self._tape[].skip_value(self._pos)

        return (key, value)

    fn __has_next__(self) -> Bool:
        """Check if more entries remain."""
        return self._pos < self._end_idx


struct LazyJsonValue(Movable, Copyable, Stringable):
    """
    Lazy JSON value that parses only when accessed.

    PERFORMANCE: This maintains the 300-886 MB/s parse speed by deferring
    JsonValue tree construction. Values are only parsed when explicitly
    accessed via get(), as_string(), as_int(), etc.

    ZERO-COPY: Uses ArcPointer for shared tape ownership. Nested access
    (get_object_value, get_array_element) shares the same tape without copying.

    Example:
        var lazy = parse_lazy('{"users": [...huge array...], "count": 42}')
        # Fast! Only parses up to "count" field
        print(lazy["count"].as_int())  # 42
        # The huge array is never parsed unless accessed

    Comparison:
        parse()      - ~14 MB/s  (full recursive descent)
        parse_fast() - ~15 MB/s  (tape + full conversion)
        parse_lazy() - ~500 MB/s (tape only, on-demand)
    """

    var _tape: ArcPointer[JsonTape]
    """Shared reference to the tape containing all JSON data."""

    var _idx: Int
    """Index in tape for this value."""

    fn __init__(out self, var tape: JsonTape, idx: Int = 1):
        """Create lazy value from tape at given index."""
        self._tape = ArcPointer(tape^)
        self._idx = idx

    fn __init__(out self, tape_arc: ArcPointer[JsonTape], idx: Int):
        """Create lazy value sharing existing tape reference."""
        self._tape = tape_arc
        self._idx = idx

    fn __copyinit__(out self, other: Self):
        """Copy constructor - shares tape reference."""
        self._tape = other._tape
        self._idx = other._idx

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self._tape = other._tape^
        self._idx = other._idx

    fn copy(self) -> Self:
        """Create explicit copy (shares tape reference via ArcPointer)."""
        return LazyJsonValue(self._tape, self._idx)

    # =========================================================================
    # Type Checking (O(1) - no parsing needed)
    # =========================================================================

    @always_inline
    fn type_tag(self) -> UInt8:
        """Get tape type tag."""
        if self._idx >= len(self._tape[]):
            return TAPE_NULL
        return self._tape[].get_entry(self._idx).type_tag()

    fn is_null(self) -> Bool:
        return self.type_tag() == TAPE_NULL

    fn is_bool(self) -> Bool:
        var tag = self.type_tag()
        return tag == TAPE_TRUE or tag == TAPE_FALSE

    fn is_int(self) -> Bool:
        return self.type_tag() == TAPE_INT64

    fn is_float(self) -> Bool:
        return self.type_tag() == TAPE_DOUBLE

    fn is_number(self) -> Bool:
        var tag = self.type_tag()
        return tag == TAPE_INT64 or tag == TAPE_DOUBLE

    fn is_string(self) -> Bool:
        return self.type_tag() == TAPE_STRING

    fn is_array(self) -> Bool:
        return self.type_tag() == TAPE_START_ARRAY

    fn is_object(self) -> Bool:
        return self.type_tag() == TAPE_START_OBJECT

    # =========================================================================
    # Value Access (O(1) for primitives, O(n) for nested access)
    # =========================================================================

    fn as_bool(self) -> Bool:
        """Get boolean value. Returns False for non-booleans."""
        return self.type_tag() == TAPE_TRUE

    fn as_int(self) -> Int64:
        """Get integer value. Returns 0 for non-integers."""
        if self.type_tag() == TAPE_INT64:
            return self._tape[].get_int64(self._idx)
        elif self.type_tag() == TAPE_DOUBLE:
            return Int64(self._tape[].get_double(self._idx))
        return 0

    fn as_float(self) -> Float64:
        """Get float value. Returns 0.0 for non-numbers."""
        if self.type_tag() == TAPE_DOUBLE:
            return self._tape[].get_double(self._idx)
        elif self.type_tag() == TAPE_INT64:
            return Float64(self._tape[].get_int64(self._idx))
        return 0.0

    fn as_string(self) -> String:
        """Get string value. Returns empty string for non-strings."""
        if self.type_tag() == TAPE_STRING:
            var offset = self._tape[].get_entry(self._idx).payload()
            return self._tape[].get_string(offset)
        return String("")

    # =========================================================================
    # Subscript Operators (Ergonomic API)
    # =========================================================================

    fn __getitem__(self, key: String) -> LazyJsonValue:
        """
        Get object value by key using subscript notation.

        Example:
            var lazy = parse_lazy('{"user": {"name": "Alice"}}')
            var name = lazy["user"]["name"].as_string()  # "Alice"
        """
        return self.get_object_value(key)

    fn __getitem__(self, index: Int) -> LazyJsonValue:
        """
        Get array element by index using subscript notation.

        Example:
            var lazy = parse_lazy('[1, 2, 3]')
            var second = lazy[1].as_int()  # 2
        """
        return self.get_array_element(index)

    # =========================================================================
    # Iterators (Zero-Allocation)
    # =========================================================================

    fn iter_array(self) -> LazyArrayIterator:
        """
        Get zero-allocation iterator over array elements.

        PERF: No List allocation - yields LazyJsonValue for each element.

        Example:
            var lazy = parse_lazy('[1, 2, 3, 4, 5]')
            for item in lazy.iter_array():
                print(item.as_int())
        """
        if self.type_tag() != TAPE_START_ARRAY:
            # Empty iterator for non-arrays
            return LazyArrayIterator(self._tape, 0, 0)

        var end_idx = self._tape[].get_entry(self._idx).payload()
        return LazyArrayIterator(self._tape, self._idx + 1, end_idx)

    fn iter_object(self) -> LazyObjectIterator:
        """
        Get zero-allocation iterator over object key-value pairs.

        PERF: No Dict allocation - yields (key, LazyJsonValue) for each entry.

        Example:
            var lazy = parse_lazy('{"a": 1, "b": 2, "c": 3}')
            for kv in lazy.iter_object():
                print(kv[0], "=", kv[1].as_int())
        """
        if self.type_tag() != TAPE_START_OBJECT:
            # Empty iterator for non-objects
            return LazyObjectIterator(self._tape, 0, 0)

        var end_idx = self._tape[].get_entry(self._idx).payload()
        return LazyObjectIterator(self._tape, self._idx + 1, end_idx)

    # =========================================================================
    # Container Access (Zero-Copy with ArcPointer)
    # =========================================================================

    fn len(self) -> Int:
        """Get array/object length. Returns 0 for non-containers."""
        var tag = self.type_tag()
        if tag != TAPE_START_ARRAY and tag != TAPE_START_OBJECT:
            return 0

        var end_idx = self._tape[].get_entry(self._idx).payload()
        var count = 0
        var pos = self._idx + 1

        while pos < end_idx:
            count += 1
            # Skip key for objects
            if tag == TAPE_START_OBJECT:
                pos = self._tape[].skip_value(pos)  # Skip key
            pos = self._tape[].skip_value(pos)  # Skip value

        return count

    fn get_array_element(self, index: Int) -> LazyJsonValue:
        """
        Get array element by index.

        PERF: O(index) scan time, but ZERO-COPY - shares tape via ArcPointer.
        For repeated access, convert to JsonValue or use tape directly.
        """
        if self.type_tag() != TAPE_START_ARRAY:
            # Return empty lazy value
            var empty_tape = JsonTape(capacity=2)
            empty_tape.append_root()
            empty_tape.append_null()
            empty_tape.finalize()
            return LazyJsonValue(empty_tape^, 1)

        var end_idx = self._tape[].get_entry(self._idx).payload()
        var pos = self._idx + 1
        var current_idx = 0

        while pos < end_idx:
            if current_idx == index:
                # Found it - share tape reference (zero-copy!)
                return LazyJsonValue(self._tape, pos)
            pos = self._tape[].skip_value(pos)
            current_idx += 1

        # Out of bounds
        var empty_tape = JsonTape(capacity=2)
        empty_tape.append_root()
        empty_tape.append_null()
        empty_tape.finalize()
        return LazyJsonValue(empty_tape^, 1)

    fn get_object_value(self, key: String) -> LazyJsonValue:
        """
        Get object value by key.

        PERF: O(n) key scan with SIMD string comparison.
        Zero-copy - shares tape via ArcPointer.
        """
        if self.type_tag() != TAPE_START_OBJECT:
            var empty_tape = JsonTape(capacity=2)
            empty_tape.append_root()
            empty_tape.append_null()
            empty_tape.finalize()
            return LazyJsonValue(empty_tape^, 1)

        var end_idx = self._tape[].get_entry(self._idx).payload()
        var pos = self._idx + 1

        while pos < end_idx:
            # Read key
            var key_entry = self._tape[].get_entry(pos)
            if key_entry.type_tag() == TAPE_STRING:
                var key_offset = key_entry.payload()
                pos += 1  # Move past key

                # PERF: SIMD string comparison - no allocation!
                if self._tape[].string_equals(key_offset, key):
                    # Found it - share tape reference (zero-copy!)
                    return LazyJsonValue(self._tape, pos)

                # Skip value
                pos = self._tape[].skip_value(pos)
            else:
                pos += 1

        # Key not found
        var empty_tape = JsonTape(capacity=2)
        empty_tape.append_root()
        empty_tape.append_null()
        empty_tape.finalize()
        return LazyJsonValue(empty_tape^, 1)

    # =========================================================================
    # Conversion (Full Parse)
    # =========================================================================

    fn to_json_value(self) -> JsonValue:
        """
        Convert to JsonValue tree (full parse).

        Use this when you need to iterate all values or pass to APIs
        expecting JsonValue. Prefer lazy access for selective parsing.
        """
        var tag = self.type_tag()

        if tag == TAPE_NULL:
            return JsonValue.null()
        elif tag == TAPE_TRUE:
            return JsonValue.from_bool(True)
        elif tag == TAPE_FALSE:
            return JsonValue.from_bool(False)
        elif tag == TAPE_INT64:
            return JsonValue.from_int(self._tape[].get_int64(self._idx))
        elif tag == TAPE_DOUBLE:
            return JsonValue.from_float(self._tape[].get_double(self._idx))
        elif tag == TAPE_STRING:
            var offset = self._tape[].get_entry(self._idx).payload()
            return JsonValue.from_string(self._tape[].get_string(offset))
        elif tag == TAPE_START_ARRAY:
            var arr = List[JsonValue](capacity=8)
            var end_idx = self._tape[].get_entry(self._idx).payload()
            var pos = self._idx + 1

            while pos < end_idx:
                var elem = self._convert_at(pos)
                arr.append(elem^)
                pos = self._tape[].skip_value(pos)

            return JsonValue.from_array_move(arr^)
        elif tag == TAPE_START_OBJECT:
            var obj = Dict[String, JsonValue]()
            var end_idx = self._tape[].get_entry(self._idx).payload()
            var pos = self._idx + 1

            while pos < end_idx:
                var key_entry = self._tape[].get_entry(pos)
                if key_entry.type_tag() == TAPE_STRING:
                    var key_offset = key_entry.payload()
                    var key = self._tape[].get_string(key_offset)
                    pos += 1

                    var val = self._convert_at(pos)
                    obj[key] = val^
                    pos = self._tape[].skip_value(pos)
                else:
                    pos += 1

            return JsonValue.from_object_move(obj^)
        else:
            return JsonValue.null()

    fn _convert_at(self, pos: Int) -> JsonValue:
        """Convert value at tape position to JsonValue."""
        var entry = self._tape[].get_entry(pos)
        var tag = entry.type_tag()

        if tag == TAPE_NULL:
            return JsonValue.null()
        elif tag == TAPE_TRUE:
            return JsonValue.from_bool(True)
        elif tag == TAPE_FALSE:
            return JsonValue.from_bool(False)
        elif tag == TAPE_INT64:
            return JsonValue.from_int(self._tape[].get_int64(pos))
        elif tag == TAPE_DOUBLE:
            return JsonValue.from_float(self._tape[].get_double(pos))
        elif tag == TAPE_STRING:
            var offset = entry.payload()
            return JsonValue.from_string(self._tape[].get_string(offset))
        elif tag == TAPE_START_ARRAY:
            var arr = List[JsonValue](capacity=8)
            var end_idx = entry.payload()
            var inner_pos = pos + 1

            while inner_pos < end_idx:
                var elem = self._convert_at(inner_pos)
                arr.append(elem^)
                inner_pos = self._tape[].skip_value(inner_pos)

            return JsonValue.from_array_move(arr^)
        elif tag == TAPE_START_OBJECT:
            var obj = Dict[String, JsonValue]()
            var end_idx = entry.payload()
            var inner_pos = pos + 1

            while inner_pos < end_idx:
                var key_entry = self._tape[].get_entry(inner_pos)
                if key_entry.type_tag() == TAPE_STRING:
                    var key_offset = key_entry.payload()
                    var key = self._tape[].get_string(key_offset)
                    inner_pos += 1

                    var val = self._convert_at(inner_pos)
                    obj[key] = val^
                    inner_pos = self._tape[].skip_value(inner_pos)
                else:
                    inner_pos += 1

            return JsonValue.from_object_move(obj^)
        else:
            return JsonValue.null()

    # =========================================================================
    # Stringable
    # =========================================================================

    fn __str__(self) -> String:
        """Convert to JSON string."""
        return String(self.to_json_value())


fn parse_lazy(json: String) raises -> LazyJsonValue:
    """
    High-performance lazy JSON parser.

    PERFORMANCE: 300-886 MB/s parse, values extracted on-demand.

    This is the fastest way to parse JSON when you only need to access
    a subset of the data. The tape is built once, then values are
    extracted lazily as needed.

    Example:
        # Fast even for huge JSON - only parses what you access
        var lazy = parse_lazy(huge_json)
        var name = lazy["config"]["user"]["name"].as_string()
        var count = lazy["stats"]["count"].as_int()

    vs parse_fast():
        parse_fast() builds full JsonValue tree (~15 MB/s)
        parse_lazy() builds tape only (~500 MB/s), extracts on demand

    For accessing ALL values, use parse_fast() instead.
    """
    var tape = parse_to_tape(json)
    return LazyJsonValue(tape^, 1)


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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
            pos += 1

        # Fractional part
        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
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
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_ZERO)
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            result = result * 10 + Int64(c - CHAR_ZERO)
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
            pos += 1

        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
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
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_ZERO)
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
        while pos < end and ptr[pos] >= CHAR_ZERO and ptr[pos] <= CHAR_NINE:
            result = result * 10.0 + Float64(Int(ptr[pos]) - 48)
            pos += 1

        # Fractional part
        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            var frac_mult: Float64 = 0.1
            while pos < end and ptr[pos] >= CHAR_ZERO and ptr[pos] <= CHAR_NINE:
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
            while pos < end and ptr[pos] >= CHAR_ZERO and ptr[pos] <= CHAR_NINE:
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            result = result * 10 + Int64(c - CHAR_ZERO)
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
            pos += 1

        if pos < end and ptr[pos] == CHAR_DOT:
            pos += 1
            while pos < end:
                var c = ptr[pos]
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
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
                if c < CHAR_ZERO or c > CHAR_NINE:
                    break
                exp_val = exp_val * 10 + Int(c - CHAR_ZERO)
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
        if c < CHAR_ZERO or c > CHAR_NINE:
            break
        result = result * 10 + Int64(c - CHAR_ZERO)
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
        if c < CHAR_ZERO or c > CHAR_NINE:
            break
        mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
        pos += 1

    # Fractional part
    if pos < end and ptr[pos] == CHAR_DOT:
        pos += 1
        while pos < end:
            var c = ptr[pos]
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            mantissa = mantissa * 10 + Int64(c - CHAR_ZERO)
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
            if c < CHAR_ZERO or c > CHAR_NINE:
                break
            exp_val = exp_val * 10 + Int(c - CHAR_ZERO)
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


# =============================================================================
# On-Demand JSON Parser (Phase 2 Optimization)
# =============================================================================
#
# True on-demand parsing: NO tape building, just structural index + source.
# Values are parsed directly from source when accessed.
#
# Performance target: 1.5-2x faster than LazyJsonValue for sparse access.
#
# Key differences from LazyJsonValue:
# - LazyJsonValue: JSON → structural index → tape → lazy extraction
# - OnDemandDocument: JSON → structural index → direct parsing (no tape)


struct OnDemandValue(Movable, Copyable, Stringable):
    """
    On-demand JSON value that parses from source when accessed.

    PERFORMANCE: No tape overhead. Values parsed directly from JSON source.

    Use this when accessing <50% of fields for maximum performance.
    Trade-off: Forward-only navigation, re-parsing if accessed multiple times.
    """
    var _source: String
    var _index: StructuralIndex
    var _idx_pos: Int  # Position in structural index

    fn __init__(out self, source: String, var index: StructuralIndex, idx_pos: Int):
        self._source = source
        self._index = index^
        self._idx_pos = idx_pos

    fn __moveinit__(out self, deinit other: Self):
        self._source = other._source^
        self._index = other._index^
        self._idx_pos = other._idx_pos

    fn __copyinit__(out self, other: Self):
        self._source = other._source
        self._index = StructuralIndex()
        self._index.positions = other._index.positions.copy()
        self._index.characters = other._index.characters.copy()
        self._index.value_spans = other._index.value_spans.copy()
        self._idx_pos = other._idx_pos

    fn is_null(self) -> Bool:
        """Check if value is null."""
        if self._idx_pos >= len(self._index):
            return True
        var char = self._index.get_character(self._idx_pos)
        if char != CHAR_N:
            return False
        # Verify it's actually "null"
        var pos = self._index.get_position(self._idx_pos)
        var ptr = self._source.unsafe_ptr()
        return (ptr[pos] == ord('n') and ptr[pos + 1] == ord('u') and
                ptr[pos + 2] == ord('l') and ptr[pos + 3] == ord('l'))

    fn is_bool(self) -> Bool:
        """Check if value is a boolean."""
        if self._idx_pos >= len(self._index):
            return False
        var char = self._index.get_character(self._idx_pos)
        return char == CHAR_T or char == CHAR_F

    fn is_int(self) -> Bool:
        """Check if value is an integer (no decimal point or exponent)."""
        if self._idx_pos >= len(self._index):
            return False
        var span = self._index.get_value_span(self._idx_pos)
        if span.value_type != VALUE_NUMBER:
            return False
        # Check if number has decimal or exponent
        var ptr = self._source.unsafe_ptr()
        for i in range(Int(span.start), Int(span.end)):
            var c = ptr[i]
            if c == CHAR_DOT or c == CHAR_E_LOWER or c == CHAR_E_UPPER:
                return False
        return True

    fn is_float(self) -> Bool:
        """Check if value is a number (int or float)."""
        if self._idx_pos >= len(self._index):
            return False
        var span = self._index.get_value_span(self._idx_pos)
        return span.value_type == VALUE_NUMBER

    fn is_string(self) -> Bool:
        """Check if value is a string."""
        if self._idx_pos >= len(self._index):
            return False
        var char = self._index.get_character(self._idx_pos)
        return char == QUOTE

    fn is_array(self) -> Bool:
        """Check if value is an array."""
        if self._idx_pos >= len(self._index):
            return False
        var char = self._index.get_character(self._idx_pos)
        return char == LBRACKET

    fn is_object(self) -> Bool:
        """Check if value is an object."""
        if self._idx_pos >= len(self._index):
            return False
        var char = self._index.get_character(self._idx_pos)
        return char == LBRACE

    fn get_bool(self) -> Bool:
        """Get boolean value. Returns False if not a boolean."""
        if self._idx_pos >= len(self._index):
            return False
        var char = self._index.get_character(self._idx_pos)
        return char == CHAR_T

    fn get_int(self) -> Int64:
        """
        Get integer value directly from source.

        PERF: No intermediate parsing - reads digits directly.
        """
        if self._idx_pos >= len(self._index):
            return 0

        var span = self._index.get_value_span(self._idx_pos)
        if span.value_type != VALUE_NUMBER:
            return 0

        var ptr = self._source.unsafe_ptr()
        return _fast_parse_int(ptr, Int(span.start), Int(span.end))

    fn get_float(self) -> Float64:
        """
        Get float value directly from source.

        PERF: No intermediate parsing - reads digits directly.
        """
        if self._idx_pos >= len(self._index):
            return 0.0

        var span = self._index.get_value_span(self._idx_pos)
        if span.value_type != VALUE_NUMBER:
            return 0.0

        var ptr = self._source.unsafe_ptr()
        return _fast_parse_float(ptr, Int(span.start), Int(span.end))

    fn get_string(self) -> String:
        """
        Get string value directly from source.

        PERF: Single allocation for result string only.
        """
        if self._idx_pos >= len(self._index):
            return ""

        var char = self._index.get_character(self._idx_pos)
        if char != QUOTE:
            return ""

        # String starts after opening quote
        var start = self._index.get_position(self._idx_pos) + 1
        var ptr = self._source.unsafe_ptr()
        var n = len(self._source)

        # Find closing quote (handle escapes)
        var end = start
        while end < n:
            var c = ptr[end]
            if c == QUOTE:
                break
            if c == CHAR_BACKSLASH and end + 1 < n:
                end += 2  # Skip escaped character
            else:
                end += 1

        return self._source[start:end]

    fn __getitem__(self, key: String) -> OnDemandValue:
        """
        Get object field by key.

        PERF: Scans structural index to find key, no full object parsing.
        """
        if not self.is_object():
            return OnDemandValue(self._source, StructuralIndex(), 0)

        var ptr = self._source.unsafe_ptr()
        var idx = self._idx_pos + 1  # Skip opening brace
        var depth = 1

        while idx < len(self._index) and depth > 0:
            var char = self._index.get_character(idx)
            var pos = self._index.get_position(idx)

            if char == LBRACE or char == LBRACKET:
                depth += 1
                idx += 1
            elif char == RBRACE or char == RBRACKET:
                depth -= 1
                idx += 1
            elif char == QUOTE and depth == 1:
                # This is a key at our depth
                var key_start = pos + 1
                var key_end = key_start
                while key_end < len(self._source) and ptr[key_end] != QUOTE:
                    if ptr[key_end] == CHAR_BACKSLASH:
                        key_end += 2
                    else:
                        key_end += 1

                # Compare key
                var key_len = key_end - key_start
                if key_len == len(key):
                    var is_match = True
                    for i in range(key_len):
                        if ptr[key_start + i] != key.unsafe_ptr()[i]:
                            is_match = False
                            break

                    if is_match:
                        # Found the key, return value (next structural position)
                        idx += 1
                        # Skip colon
                        if idx < len(self._index) and self._index.get_character(idx) == COLON:
                            idx += 1

                        # Return value - copy index for new value
                        var new_index = StructuralIndex()
                        new_index.positions = self._index.positions.copy()
                        new_index.characters = self._index.characters.copy()
                        new_index.value_spans = self._index.value_spans.copy()
                        return OnDemandValue(self._source, new_index^, idx)

                idx += 1
            else:
                idx += 1

        return OnDemandValue(self._source, StructuralIndex(), 0)

    fn __getitem__(self, index: Int) -> OnDemandValue:
        """
        Get array element by index.

        PERF: Scans structural index, skips nested structures efficiently.
        """
        if not self.is_array():
            return OnDemandValue(self._source, StructuralIndex(), 0)

        var idx = self._idx_pos + 1  # Skip opening bracket
        var current_index = 0
        var depth = 1

        while idx < len(self._index) and depth > 0:
            var char = self._index.get_character(idx)

            if char == RBRACKET and depth == 1:
                break  # End of array

            if depth == 1 and current_index == index:
                # Found the element - copy index for new value
                var new_index = StructuralIndex()
                new_index.positions = self._index.positions.copy()
                new_index.characters = self._index.characters.copy()
                new_index.value_spans = self._index.value_spans.copy()
                return OnDemandValue(self._source, new_index^, idx)

            # Skip current value
            if char == LBRACE or char == LBRACKET:
                depth += 1
            elif char == RBRACE or char == RBRACKET:
                depth -= 1
            elif char == COMMA and depth == 1:
                current_index += 1

            idx += 1

        return OnDemandValue(self._source, StructuralIndex(), 0)

    fn __str__(self) -> String:
        """Convert to string representation."""
        if self.is_null():
            return "null"
        elif self.is_bool():
            return "true" if self.get_bool() else "false"
        elif self.is_string():
            return '"' + self.get_string() + '"'
        elif self.is_int():
            return String(self.get_int())
        elif self.is_float():
            return String(self.get_float())
        elif self.is_array():
            return "[...]"
        elif self.is_object():
            return "{...}"
        else:
            return "<invalid>"


struct OnDemandDocument(Movable):
    """
    On-demand JSON document - ultra-fast for sparse field access.

    PERFORMANCE:
    - Stage 1 only: No tape building (saves Stage 2 time)
    - Values parsed directly from source when accessed
    - 1.5-2x faster than LazyJsonValue for <50% field access

    Trade-offs:
    - Forward-only navigation (can't go back efficiently)
    - Re-parses values if accessed multiple times
    - For accessing ALL fields, use parse_to_tape_v2 instead

    Example:
        var doc = parse_on_demand(json_string)
        var name = doc.root()["user"]["name"].get_string()
        var age = doc.root()["user"]["age"].get_int()
    """
    var _source: String
    var _index: StructuralIndex

    fn __init__(out self, source: String):
        """Create on-demand document from JSON string."""
        self._source = source
        # Use V2 index which includes value spans for numbers/literals
        self._index = build_structural_index_v2(source)

    fn __moveinit__(out self, deinit other: Self):
        self._source = other._source^
        self._index = other._index^

    fn root(self) -> OnDemandValue:
        """Get the root value of the document."""
        var new_index = StructuralIndex()
        new_index.positions = self._index.positions.copy()
        new_index.characters = self._index.characters.copy()
        new_index.value_spans = self._index.value_spans.copy()
        return OnDemandValue(self._source, new_index^, 0)

    fn is_valid(self) -> Bool:
        """Check if document was parsed successfully."""
        return len(self._index) > 0


fn parse_on_demand(json: String) -> OnDemandDocument:
    """
    Parse JSON using on-demand parsing.

    FASTEST for sparse access: Only builds structural index (Stage 1).
    Values are parsed directly from source when accessed.

    Performance comparison:
    - parse_to_tape_v2: ~600 MB/s (builds full tape)
    - parse_on_demand: ~1200 MB/s (Stage 1 only)

    Best for:
    - Accessing <50% of fields
    - Config file parsing
    - API response filtering
    - Large JSON with few needed fields

    Example:
        var doc = parse_on_demand(api_response)
        var user_id = doc.root()["data"]["user"]["id"].get_int()
        var email = doc.root()["data"]["user"]["email"].get_string()
        # Other 50+ fields in response are never parsed
    """
    return OnDemandDocument(json)


# =============================================================================
# Adaptive Parser Selection
# =============================================================================


struct JsonContentProfile(Copyable, Movable, Stringable):
    """Profile of JSON content for parser selection."""
    var quote_ratio: Float64
    var digit_ratio: Float64
    var structural_ratio: Float64
    var sample_size: Int
    var recommended_parser: String

    fn __init__(out self, quote_ratio: Float64, digit_ratio: Float64,
                structural_ratio: Float64, sample_size: Int,
                recommended_parser: String):
        self.quote_ratio = quote_ratio
        self.digit_ratio = digit_ratio
        self.structural_ratio = structural_ratio
        self.sample_size = sample_size
        self.recommended_parser = recommended_parser

    fn __copyinit__(out self, existing: Self):
        self.quote_ratio = existing.quote_ratio
        self.digit_ratio = existing.digit_ratio
        self.structural_ratio = existing.structural_ratio
        self.sample_size = existing.sample_size
        self.recommended_parser = existing.recommended_parser

    fn __moveinit__(out self, deinit existing: Self):
        self.quote_ratio = existing.quote_ratio
        self.digit_ratio = existing.digit_ratio
        self.structural_ratio = existing.structural_ratio
        self.sample_size = existing.sample_size
        self.recommended_parser = existing.recommended_parser^

    fn __str__(self) -> String:
        return (
            "JsonContentProfile(quotes=" + String(Int(self.quote_ratio * 100)) + "%, "
            "digits=" + String(Int(self.digit_ratio * 100)) + "%, "
            "structural=" + String(Int(self.structural_ratio * 100)) + "%, "
            "recommended=" + self.recommended_parser + ")"
        )


fn analyze_json_content(json: String, sample_size: Int = 1024) -> JsonContentProfile:
    """
    Analyze JSON content to determine optimal parser.

    Samples the first N bytes and classifies character types.
    Returns a profile with recommended parser.

    Args:
        json: JSON string to analyze.
        sample_size: Number of bytes to sample (default 1024).

    Returns:
        JsonContentProfile with character ratios and recommendation.
    """
    var ptr = json.unsafe_ptr()
    var n = min(len(json), sample_size)

    var quote_count = 0
    var digit_count = 0
    var structural_count = 0  # {, }, [, ], :, ,
    var in_string = False

    for i in range(n):
        var c = ptr[i]

        if c == ord('"') and (i == 0 or ptr[i - 1] != ord('\\')):
            in_string = not in_string
            quote_count += 1
        elif not in_string:
            if c >= ord('0') and c <= ord('9'):
                digit_count += 1
            elif c == ord('.') or c == ord('-') or c == ord('+') or c == ord('e') or c == ord('E'):
                # Part of number
                digit_count += 1
            elif c == ord('{') or c == ord('}') or c == ord('[') or c == ord(']') or c == ord(':') or c == ord(','):
                structural_count += 1

    var quote_ratio = Float64(quote_count) / Float64(n) if n > 0 else 0.0
    var digit_ratio = Float64(digit_count) / Float64(n) if n > 0 else 0.0
    var structural_ratio = Float64(structural_count) / Float64(n) if n > 0 else 0.0

    # Decision logic based on benchmarks:
    # - V1 wins for string-heavy (citm_catalog: lots of quotes)
    # - V4 wins for number-heavy (canada.json: lots of coordinates)
    # - V2 is balanced default
    #
    # Thresholds tuned on standard benchmark files:
    # - twitter.json: 4% quotes → V1 (7% faster than V2)
    # - canada.json: 76% digits → V4 (18% faster than V2)
    # - citm_catalog: 8% quotes → V1 (14% faster than V2)
    var recommended: String
    if digit_ratio > 0.20:  # Number-heavy (>20% digits) - check first
        recommended = "V4"
    elif quote_ratio > 0.03:  # String-heavy (>3% quotes)
        recommended = "V1"
    else:
        recommended = "V2"

    return JsonContentProfile(
        quote_ratio,
        digit_ratio,
        structural_ratio,
        n,
        recommended
    )


fn parse_adaptive(json: String) raises -> JsonTape:
    """
    Parse JSON using the optimal parser based on content analysis.

    Automatically selects between V1, V2, and V4 parsers based on
    a quick analysis of the JSON content:
    - V1: Best for string-heavy JSON (many quoted values)
    - V2: Balanced default (good all-around)
    - V4: Best for number-heavy JSON (coordinates, metrics)

    Performance:
    - Analysis overhead: ~0.5μs for 1KB sample
    - Can provide 10-30% speedup by avoiding suboptimal parser

    Example:
        # Automatically picks best parser
        var tape = parse_adaptive(json_string)

        # Or analyze first to understand content
        var profile = analyze_json_content(json_string)
        print(profile)  # Shows content ratios and recommendation

    Args:
        json: JSON string to parse.

    Returns:
        JsonTape parsed with optimal parser.
    """
    var profile = analyze_json_content(json)

    if profile.recommended_parser == "V1":
        return parse_to_tape(json)
    elif profile.recommended_parser == "V4":
        return parse_to_tape_v4(json)
    else:
        return parse_to_tape_v2(json)


fn get_recommended_parser(json: String) -> String:
    """
    Get the recommended parser name without parsing.

    Useful for debugging or logging which parser will be selected.

    Example:
        var parser = get_recommended_parser(json)
        print("Will use:", parser)  # "V1", "V2", or "V4"

    Args:
        json: JSON string to analyze.

    Returns:
        Parser name: "V1", "V2", or "V4".
    """
    var profile = analyze_json_content(json)
    return profile.recommended_parser
