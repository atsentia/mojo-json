"""
Lazy JSON Parser - Parse values on-demand

simdjson-inspired on-demand parsing:
- Stage 1: Build structural index (fast, SIMD)
- Stage 2: DON'T parse all values upfront
- Access: Parse only when value is requested

Benefits:
- Faster initial parse for large JSON
- Lower memory for partial access patterns
- Same throughput when accessing all values
"""

from .structural_index import build_structural_index, StructuralIndex
from .structural_index import QUOTE, LBRACE, RBRACE, LBRACKET, RBRACKET, COLON, COMMA


struct LazyJsonDocument:
    """
    Lazy JSON document - parses values on access.

    Usage:
        var doc = LazyJsonDocument.parse('{"key": 123}')
        var root = doc.root()
        var value = root["key"].as_int()  # Parses 123 here
    """

    var source: String
    var index: StructuralIndex

    fn __init__(out self, source: String):
        """Create lazy document from JSON source."""
        self.source = source
        self.index = build_structural_index(source)

    @staticmethod
    fn parse(json: String) -> Self:
        """Parse JSON into lazy document."""
        return LazyJsonDocument(json)

    fn root(self) -> LazyValue:
        """Get root value."""
        if len(self.index) == 0:
            return LazyValue(self.source, self.index.positions, self.index.characters, 0)
        return LazyValue(self.source, self.index.positions, self.index.characters, 0)


struct LazyValue:
    """
    Lazy JSON value - parses on access.

    Stores copies of document data to avoid pointer ownership issues.
    """

    var _source: String
    """Copy of source string for parsing."""
    var _positions: List[Int]
    """Copy of structural positions."""
    var _characters: List[UInt8]
    """Copy of structural characters."""
    var idx_pos: Int
    """Position in structural index."""

    fn __init__(out self, source: String, positions: List[Int], characters: List[UInt8], idx_pos: Int):
        """Create lazy value with copies of document data."""
        self._source = source
        self._positions = positions.copy()
        self._characters = characters.copy()
        self.idx_pos = idx_pos

    fn _index_len(self) -> Int:
        """Get length of structural index."""
        return len(self._positions)

    fn _get_character(self, idx: Int) -> UInt8:
        """Get structural character at index."""
        return self._characters[idx]

    fn _get_position(self, idx: Int) -> Int:
        """Get byte position at index."""
        return self._positions[idx]

    fn type(self) -> String:
        """Get value type without fully parsing."""
        var char = self._value_char()
        if char == 0:
            return "unknown"

        if char == LBRACE:
            return "object"
        elif char == LBRACKET:
            return "array"
        elif char == QUOTE:
            return "string"
        else:
            # Need to check source for literal type - find value start
            var pos = self._find_value_start()
            if pos < 0:
                return "unknown"
            var ptr = self._source.unsafe_ptr()
            var c = ptr[pos]

            if c == ord('t'):
                return "true"
            elif c == ord('f'):
                return "false"
            elif c == ord('n'):
                return "null"
            elif c == ord('-') or (c >= ord('0') and c <= ord('9')):
                return "number"
            else:
                return "unknown"

    fn _value_char(self) -> UInt8:
        """Get the structural character of the value (after colon if applicable)."""
        if self.idx_pos < 0 or self.idx_pos >= self._index_len():
            return 0
        var char = self._get_character(self.idx_pos)
        # If pointing at colon, look at next structural char
        if char == COLON and self.idx_pos + 1 < self._index_len():
            return self._get_character(self.idx_pos + 1)
        return char

    fn is_object(self) -> Bool:
        """Check if value is object."""
        return self._value_char() == LBRACE

    fn is_array(self) -> Bool:
        """Check if value is array."""
        return self._value_char() == LBRACKET

    fn is_string(self) -> Bool:
        """Check if value is string."""
        return self._value_char() == QUOTE

    fn as_string(self) -> String:
        """Parse and return string value."""
        if not self.is_string():
            return ""

        # Find the quote index (might be idx_pos or idx_pos+1 if pointing at colon)
        var quote_idx = self.idx_pos
        if self._get_character(self.idx_pos) == COLON:
            quote_idx = self.idx_pos + 1

        var start_pos = self._get_position(quote_idx) + 1  # Skip opening quote
        var end_pos = start_pos

        # Find closing quote
        var next_idx = quote_idx + 1
        if next_idx < self._index_len():
            var next_char = self._get_character(next_idx)
            if next_char == QUOTE:
                end_pos = self._get_position(next_idx)

        return self._source[start_pos:end_pos]

    fn as_int(self) -> Int64:
        """Parse and return integer value."""
        var pos = self._find_value_start()
        if pos < 0:
            return 0

        var ptr = self._source.unsafe_ptr()
        var n = len(self._source)

        var negative = False
        var result: Int64 = 0

        if ptr[pos] == ord('-'):
            negative = True
            pos += 1

        while pos < n:
            var c = ptr[pos]
            if c < ord('0') or c > ord('9'):
                break
            result = result * 10 + Int64(c - ord('0'))
            pos += 1

        return -result if negative else result

    fn as_float(self) -> Float64:
        """Parse and return float value."""
        var pos = self._find_value_start()
        if pos < 0:
            return 0.0

        # Find end of number
        var end = pos
        var ptr = self._source.unsafe_ptr()
        var n = len(self._source)

        while end < n:
            var c = ptr[end]
            if c == ord('-') or c == ord('+') or c == ord('.') or c == ord('e') or c == ord('E'):
                end += 1
            elif c >= ord('0') and c <= ord('9'):
                end += 1
            else:
                break

        return atof(self._source[pos:end])

    fn as_bool(self) -> Bool:
        """Parse and return boolean value."""
        var pos = self._find_value_start()
        if pos < 0:
            return False

        var ptr = self._source.unsafe_ptr()
        return ptr[pos] == ord('t')

    fn is_null(self) -> Bool:
        """Check if value is null."""
        var pos = self._find_value_start()
        if pos < 0:
            return False

        var ptr = self._source.unsafe_ptr()
        return ptr[pos] == ord('n')

    fn _find_value_start(self) -> Int:
        """Find start of value in source (after : or ,)."""
        if self.idx_pos == 0:
            # Root value - find first non-whitespace
            var ptr = self._source.unsafe_ptr()
            var n = len(self._source)
            var pos = 0
            while pos < n:
                var c = ptr[pos]
                if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                    return pos
                pos += 1
            return -1

        # After colon - find value start
        var colon_pos = self._get_position(self.idx_pos)
        var ptr = self._source.unsafe_ptr()
        var n = len(self._source)
        var pos = colon_pos + 1

        while pos < n:
            var c = ptr[pos]
            if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                return pos
            pos += 1

        return -1

    fn __getitem__(self, key: String) -> LazyValue:
        """Get object member by key."""
        if not self.is_object():
            return LazyValue(self._source, self._positions, self._characters, -1)

        var idx = self.idx_pos + 1  # Skip '{'

        while idx < self._index_len():
            var char = self._get_character(idx)

            if char == RBRACE:
                break  # End of object

            if char == QUOTE:
                # Get key string
                var key_start = self._get_position(idx) + 1
                idx += 1
                if idx < self._index_len():
                    var next_char = self._get_character(idx)
                    if next_char == QUOTE:
                        var key_end = self._get_position(idx)
                        var found_key = self._source[key_start:key_end]

                        # Move past closing quote
                        idx += 1

                        # Check for colon
                        if idx < self._index_len():
                            var colon_char = self._get_character(idx)
                            if colon_char == COLON:
                                if found_key == key:
                                    # Found! Return LazyValue with colon index
                                    # _find_value_start will find the value in source
                                    return LazyValue(self._source, self._positions, self._characters, idx)
                                else:
                                    # Skip this value
                                    idx = self._skip_value(idx + 1)
                                    # Skip comma if present
                                    if idx < self._index_len():
                                        if self._get_character(idx) == COMMA:
                                            idx += 1
                                    continue

            idx += 1

        return LazyValue(self._source, self._positions, self._characters, -1)

    fn _skip_value(self, start_idx: Int) -> Int:
        """Skip over a value, return index after it."""
        if start_idx >= self._index_len():
            return start_idx

        var char = self._get_character(start_idx)

        if char == LBRACE:
            # Find matching }
            var depth = 1
            var idx = start_idx + 1
            while idx < self._index_len() and depth > 0:
                var c = self._get_character(idx)
                if c == LBRACE:
                    depth += 1
                elif c == RBRACE:
                    depth -= 1
                idx += 1
            return idx

        elif char == LBRACKET:
            # Find matching ]
            var depth = 1
            var idx = start_idx + 1
            while idx < self._index_len() and depth > 0:
                var c = self._get_character(idx)
                if c == LBRACKET:
                    depth += 1
                elif c == RBRACKET:
                    depth -= 1
                idx += 1
            return idx

        elif char == QUOTE:
            # Skip string (2 quotes)
            return start_idx + 2

        else:
            # Literal - advance to next structural
            return start_idx + 1


fn parse_lazy(json: String) -> LazyJsonDocument:
    """Parse JSON lazily - values parsed on access."""
    return LazyJsonDocument.parse(json)
