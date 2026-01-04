"""
Streaming JSON Parser

SAX-style streaming parser for processing large JSON files or network streams
without loading the entire document into memory.

Usage:
    var parser = StreamingParser()

    # Process chunks as they arrive
    for chunk in read_chunks(file):
        var events = parser.feed(chunk)
        for event in events:
            if event.type == JsonEventType.KEY:
                print("Key:", event.string_value)
            elif event.type == JsonEventType.STRING:
                print("String:", event.string_value)
            elif event.type == JsonEventType.INT:
                print("Int:", event.int_value)
"""


@register_passable("trivial")
struct JsonEventType:
    """Types of events emitted by the streaming parser."""
    var value: UInt8

    fn __init__(out self, value: UInt8):
        self.value = value

    alias OBJECT_START = JsonEventType(1)   # {
    alias OBJECT_END = JsonEventType(2)     # }
    alias ARRAY_START = JsonEventType(3)    # [
    alias ARRAY_END = JsonEventType(4)      # ]
    alias KEY = JsonEventType(5)            # Object key string
    alias STRING = JsonEventType(6)         # String value
    alias INT = JsonEventType(7)            # Integer value
    alias FLOAT = JsonEventType(8)          # Float value
    alias BOOL_TRUE = JsonEventType(9)      # true
    alias BOOL_FALSE = JsonEventType(10)    # false
    alias NULL = JsonEventType(11)          # null
    alias ERROR = JsonEventType(255)        # Parse error

    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn __ne__(self, other: Self) -> Bool:
        return self.value != other.value


struct JsonEvent(Movable, Copyable):
    """Event emitted by the streaming parser."""
    var type: JsonEventType
    var string_value: String
    var int_value: Int64
    var float_value: Float64
    var depth: Int  # Nesting depth

    fn __init__(out self, type: JsonEventType):
        self.type = type
        self.string_value = String("")
        self.int_value = 0
        self.float_value = 0.0
        self.depth = 0

    fn __init__(out self, type: JsonEventType, string_value: String, int_value: Int64, float_value: Float64, depth: Int):
        self.type = type
        self.string_value = string_value
        self.int_value = int_value
        self.float_value = float_value
        self.depth = depth

    fn __copyinit__(out self, existing: Self):
        self.type = existing.type
        self.string_value = existing.string_value
        self.int_value = existing.int_value
        self.float_value = existing.float_value
        self.depth = existing.depth

    fn __moveinit__(out self, deinit existing: Self):
        self.type = existing.type
        self.string_value = existing.string_value^
        self.int_value = existing.int_value
        self.float_value = existing.float_value
        self.depth = existing.depth

    @staticmethod
    fn object_start(depth: Int) -> Self:
        return JsonEvent(JsonEventType.OBJECT_START, String(""), 0, 0.0, depth)

    @staticmethod
    fn object_end(depth: Int) -> Self:
        return JsonEvent(JsonEventType.OBJECT_END, String(""), 0, 0.0, depth)

    @staticmethod
    fn array_start(depth: Int) -> Self:
        return JsonEvent(JsonEventType.ARRAY_START, String(""), 0, 0.0, depth)

    @staticmethod
    fn array_end(depth: Int) -> Self:
        return JsonEvent(JsonEventType.ARRAY_END, String(""), 0, 0.0, depth)

    @staticmethod
    fn key(s: String, depth: Int) -> Self:
        return JsonEvent(JsonEventType.KEY, s, 0, 0.0, depth)

    @staticmethod
    fn string(s: String, depth: Int) -> Self:
        return JsonEvent(JsonEventType.STRING, s, 0, 0.0, depth)

    @staticmethod
    fn int_val(v: Int64, depth: Int) -> Self:
        return JsonEvent(JsonEventType.INT, String(""), v, 0.0, depth)

    @staticmethod
    fn float_val(v: Float64, depth: Int) -> Self:
        return JsonEvent(JsonEventType.FLOAT, String(""), 0, v, depth)

    @staticmethod
    fn bool_true(depth: Int) -> Self:
        return JsonEvent(JsonEventType.BOOL_TRUE, String(""), 0, 0.0, depth)

    @staticmethod
    fn bool_false(depth: Int) -> Self:
        return JsonEvent(JsonEventType.BOOL_FALSE, String(""), 0, 0.0, depth)

    @staticmethod
    fn null_val(depth: Int) -> Self:
        return JsonEvent(JsonEventType.NULL, String(""), 0, 0.0, depth)

    @staticmethod
    fn error(msg: String) -> Self:
        return JsonEvent(JsonEventType.ERROR, msg, 0, 0.0, 0)


@register_passable("trivial")
struct ParserState:
    """Internal state of the streaming parser."""
    var value: UInt8

    fn __init__(out self, value: UInt8):
        self.value = value

    alias READY = ParserState(0)          # Ready for any value
    alias IN_STRING = ParserState(1)      # Inside a string
    alias IN_STRING_ESCAPE = ParserState(2)  # After backslash in string
    alias IN_NUMBER = ParserState(3)      # Inside a number
    alias IN_TRUE = ParserState(4)        # Parsing "true"
    alias IN_FALSE = ParserState(5)       # Parsing "false"
    alias IN_NULL = ParserState(6)        # Parsing "null"
    alias AFTER_VALUE = ParserState(7)    # After a complete value
    alias AFTER_KEY = ParserState(8)      # After object key, expecting :
    alias ERROR = ParserState(255)        # Error state

    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value


struct StreamingParser:
    """
    SAX-style streaming JSON parser.

    Processes JSON in chunks and emits events for each structural element.
    Maintains state across chunks to handle partial tokens.
    """
    var state: ParserState
    var buffer: String          # Partial token buffer
    var depth: Int              # Current nesting depth
    var context_stack: List[UInt8]  # Stack of container types ('{' or '[')
    var expect_key: Bool        # In object, expecting key next
    var keyword_pos: Int        # Position in keyword (true/false/null)

    fn __init__(out self):
        self.state = ParserState.READY
        self.buffer = String("")
        self.depth = 0
        self.context_stack = List[UInt8]()
        self.expect_key = False
        self.keyword_pos = 0

    fn reset(mut self):
        """Reset parser to initial state."""
        self.state = ParserState.READY
        self.buffer = String("")
        self.depth = 0
        self.context_stack.clear()
        self.expect_key = False
        self.keyword_pos = 0

    fn feed(mut self, data: String) -> List[JsonEvent]:
        """
        Process a chunk of JSON data and return events.

        Args:
            data: Chunk of JSON text to process.

        Returns:
            List of events for complete tokens found in this chunk.
        """
        var events = List[JsonEvent]()
        var ptr = data.unsafe_ptr()
        var n = len(data)
        var i = 0

        while i < n:
            var c = ptr[i]

            if self.state == ParserState.READY:
                i = self._handle_ready(ptr, i, n, events)
            elif self.state == ParserState.IN_STRING:
                i = self._handle_string(ptr, i, n, events)
            elif self.state == ParserState.IN_STRING_ESCAPE:
                i = self._handle_string_escape(ptr, i, n, events)
            elif self.state == ParserState.IN_NUMBER:
                i = self._handle_number(ptr, i, n, events)
            elif self.state == ParserState.IN_TRUE:
                i = self._handle_keyword(ptr, i, n, events, "true", JsonEventType.BOOL_TRUE)
            elif self.state == ParserState.IN_FALSE:
                i = self._handle_keyword(ptr, i, n, events, "false", JsonEventType.BOOL_FALSE)
            elif self.state == ParserState.IN_NULL:
                i = self._handle_keyword(ptr, i, n, events, "null", JsonEventType.NULL)
            elif self.state == ParserState.AFTER_VALUE:
                i = self._handle_after_value(ptr, i, n, events)
            elif self.state == ParserState.AFTER_KEY:
                i = self._handle_after_key(ptr, i, n, events)
            else:
                # Error state
                break

        return events^

    fn _is_whitespace(self, c: UInt8) -> Bool:
        return c == ord(' ') or c == ord('\t') or c == ord('\n') or c == ord('\r')

    fn _handle_ready(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle READY state - expecting a value."""
        var i = start

        # Skip whitespace
        while i < n and self._is_whitespace(ptr[i]):
            i += 1

        if i >= n:
            return i

        var c = ptr[i]

        if c == ord('{'):
            events.append(JsonEvent.object_start(self.depth))
            self.depth += 1
            self.context_stack.append(ord('{'))
            self.expect_key = True
            self.state = ParserState.READY
            return i + 1

        elif c == ord('['):
            events.append(JsonEvent.array_start(self.depth))
            self.depth += 1
            self.context_stack.append(ord('['))
            self.expect_key = False
            self.state = ParserState.READY
            return i + 1

        elif c == ord('"'):
            self.state = ParserState.IN_STRING
            self.buffer = String("")
            return i + 1

        elif c == ord('t'):
            self.state = ParserState.IN_TRUE
            self.keyword_pos = 1
            return i + 1

        elif c == ord('f'):
            self.state = ParserState.IN_FALSE
            self.keyword_pos = 1
            return i + 1

        elif c == ord('n'):
            self.state = ParserState.IN_NULL
            self.keyword_pos = 1
            return i + 1

        elif c == ord('-') or (c >= ord('0') and c <= ord('9')):
            self.state = ParserState.IN_NUMBER
            self.buffer = chr(Int(c))
            return i + 1

        elif c == ord('}'):
            if self.depth > 0 and len(self.context_stack) > 0:
                self.depth -= 1
                _ = self.context_stack.pop()
                events.append(JsonEvent.object_end(self.depth))
                self.state = ParserState.AFTER_VALUE
            return i + 1

        elif c == ord(']'):
            if self.depth > 0 and len(self.context_stack) > 0:
                self.depth -= 1
                _ = self.context_stack.pop()
                events.append(JsonEvent.array_end(self.depth))
                self.state = ParserState.AFTER_VALUE
            return i + 1

        else:
            events.append(JsonEvent.error("Unexpected character: " + chr(Int(c))))
            self.state = ParserState.ERROR
            return i + 1

    fn _handle_string(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle IN_STRING state - reading string content."""
        var i = start

        while i < n:
            var c = ptr[i]

            if c == ord('\\'):
                self.state = ParserState.IN_STRING_ESCAPE
                return i + 1

            elif c == ord('"'):
                # End of string
                if self.expect_key and len(self.context_stack) > 0 and self.context_stack[len(self.context_stack) - 1] == ord('{'):
                    events.append(JsonEvent.key(self.buffer, self.depth))
                    self.state = ParserState.AFTER_KEY
                    self.expect_key = False
                else:
                    events.append(JsonEvent.string(self.buffer, self.depth))
                    self.state = ParserState.AFTER_VALUE
                self.buffer = String("")
                return i + 1

            else:
                self.buffer += chr(Int(c))
                i += 1

        return i

    fn _handle_string_escape(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle escape sequence in string."""
        if start >= n:
            return start

        var c = ptr[start]

        if c == ord('n'):
            self.buffer += '\n'
        elif c == ord('t'):
            self.buffer += '\t'
        elif c == ord('r'):
            self.buffer += '\r'
        elif c == ord('\\'):
            self.buffer += '\\'
        elif c == ord('"'):
            self.buffer += '"'
        elif c == ord('/'):
            self.buffer += '/'
        elif c == ord('b'):
            self.buffer += chr(8)  # Backspace
        elif c == ord('f'):
            self.buffer += chr(12)  # Form feed
        elif c == ord('u'):
            # Unicode escape - simplified, just add placeholder
            # Full implementation would parse 4 hex digits
            self.buffer += '?'
        else:
            self.buffer += chr(Int(c))

        self.state = ParserState.IN_STRING
        return start + 1

    fn _parse_int_simple(self, s: String) -> Int64:
        """Simple integer parser without raising."""
        var result: Int64 = 0
        var negative = False
        var ptr = s.unsafe_ptr()
        var n = len(s)
        var i = 0

        if n > 0 and ptr[0] == ord('-'):
            negative = True
            i = 1
        elif n > 0 and ptr[0] == ord('+'):
            i = 1

        while i < n:
            var c = ptr[i]
            if c >= ord('0') and c <= ord('9'):
                result = result * 10 + Int64(c - ord('0'))
            i += 1

        return -result if negative else result

    fn _parse_float_simple(self, s: String) -> Float64:
        """Simple float parser without raising."""
        # Parse integer part
        var integer_part: Float64 = 0.0
        var fraction_part: Float64 = 0.0
        var exponent: Int = 0
        var negative = False
        var exp_negative = False
        var ptr = s.unsafe_ptr()
        var n = len(s)
        var i = 0

        # Handle sign
        if n > 0 and ptr[0] == ord('-'):
            negative = True
            i = 1
        elif n > 0 and ptr[0] == ord('+'):
            i = 1

        # Parse integer part
        while i < n and ptr[i] >= ord('0') and ptr[i] <= ord('9'):
            integer_part = integer_part * 10.0 + Float64(ptr[i] - ord('0'))
            i += 1

        # Parse fraction
        if i < n and ptr[i] == ord('.'):
            i += 1
            var fraction_divisor: Float64 = 10.0
            while i < n and ptr[i] >= ord('0') and ptr[i] <= ord('9'):
                fraction_part += Float64(ptr[i] - ord('0')) / fraction_divisor
                fraction_divisor *= 10.0
                i += 1

        # Parse exponent
        if i < n and (ptr[i] == ord('e') or ptr[i] == ord('E')):
            i += 1
            if i < n and ptr[i] == ord('-'):
                exp_negative = True
                i += 1
            elif i < n and ptr[i] == ord('+'):
                i += 1

            while i < n and ptr[i] >= ord('0') and ptr[i] <= ord('9'):
                exponent = exponent * 10 + Int(ptr[i] - ord('0'))
                i += 1

        var result = integer_part + fraction_part
        if negative:
            result = -result

        # Apply exponent
        if exponent > 0:
            var mult: Float64 = 1.0
            for _ in range(exponent):
                mult *= 10.0
            if exp_negative:
                result /= mult
            else:
                result *= mult

        return result

    fn _handle_number(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle IN_NUMBER state - reading number."""
        var i = start
        var is_float = False

        while i < n:
            var c = ptr[i]

            if (c >= ord('0') and c <= ord('9')) or c == ord('-') or c == ord('+'):
                self.buffer += chr(Int(c))
                i += 1
            elif c == ord('.') or c == ord('e') or c == ord('E'):
                is_float = True
                self.buffer += chr(Int(c))
                i += 1
            else:
                # End of number
                if is_float or '.' in self.buffer or 'e' in self.buffer or 'E' in self.buffer:
                    var f = self._parse_float_simple(self.buffer)
                    events.append(JsonEvent.float_val(f, self.depth))
                else:
                    var v = self._parse_int_simple(self.buffer)
                    events.append(JsonEvent.int_val(v, self.depth))

                self.buffer = String("")
                self.state = ParserState.AFTER_VALUE
                return i  # Don't consume current char

        return i

    fn _handle_keyword(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent], keyword: String, event_type: JsonEventType) -> Int:
        """Handle keyword parsing (true/false/null)."""
        var i = start
        var kw_ptr = keyword.unsafe_ptr()
        var kw_len = len(keyword)

        while i < n and self.keyword_pos < kw_len:
            if ptr[i] != kw_ptr[self.keyword_pos]:
                events.append(JsonEvent.error("Invalid keyword"))
                self.state = ParserState.ERROR
                return i + 1

            self.keyword_pos += 1
            i += 1

        if self.keyword_pos >= kw_len:
            # Complete keyword
            if event_type == JsonEventType.BOOL_TRUE:
                events.append(JsonEvent.bool_true(self.depth))
            elif event_type == JsonEventType.BOOL_FALSE:
                events.append(JsonEvent.bool_false(self.depth))
            else:
                events.append(JsonEvent.null_val(self.depth))

            self.state = ParserState.AFTER_VALUE
            self.keyword_pos = 0

        return i

    fn _handle_after_value(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle AFTER_VALUE state - expecting comma, ] or }."""
        var i = start

        # Skip whitespace
        while i < n and self._is_whitespace(ptr[i]):
            i += 1

        if i >= n:
            return i

        var c = ptr[i]

        if c == ord(','):
            # More values coming
            if len(self.context_stack) > 0 and self.context_stack[len(self.context_stack) - 1] == ord('{'):
                self.expect_key = True
            self.state = ParserState.READY
            return i + 1

        elif c == ord('}'):
            if self.depth > 0 and len(self.context_stack) > 0:
                self.depth -= 1
                _ = self.context_stack.pop()
                events.append(JsonEvent.object_end(self.depth))
            return i + 1

        elif c == ord(']'):
            if self.depth > 0 and len(self.context_stack) > 0:
                self.depth -= 1
                _ = self.context_stack.pop()
                events.append(JsonEvent.array_end(self.depth))
            return i + 1

        else:
            events.append(JsonEvent.error("Expected comma or closing bracket"))
            self.state = ParserState.ERROR
            return i + 1

    fn _handle_after_key(mut self, ptr: UnsafePointer[UInt8], start: Int, n: Int, mut events: List[JsonEvent]) -> Int:
        """Handle AFTER_KEY state - expecting colon."""
        var i = start

        # Skip whitespace
        while i < n and self._is_whitespace(ptr[i]):
            i += 1

        if i >= n:
            return i

        var c = ptr[i]

        if c == ord(':'):
            self.state = ParserState.READY
            return i + 1
        else:
            events.append(JsonEvent.error("Expected colon after key"))
            self.state = ParserState.ERROR
            return i + 1


# =============================================================================
# Convenience Functions
# =============================================================================


fn parse_streaming(json: String) -> List[JsonEvent]:
    """
    Parse JSON string and return all events.

    This is a convenience function for processing complete JSON strings
    with the streaming parser. For incremental parsing, use StreamingParser
    directly.

    Args:
        json: Complete JSON string to parse.

    Returns:
        List of all events from parsing the JSON.
    """
    var parser = StreamingParser()
    return parser.feed(json)


fn count_elements(json: String) -> Int:
    """
    Count total number of elements in JSON using streaming parser.

    Counts: objects, arrays, strings, numbers, bools, nulls.
    Does not load full structure into memory.
    """
    var events = parse_streaming(json)
    var count = 0

    for i in range(len(events)):
        var event = events[i].copy()
        if event.type != JsonEventType.KEY and event.type != JsonEventType.ERROR:
            count += 1

    return count


fn find_keys_at_depth(json: String, target_depth: Int) -> List[String]:
    """
    Find all object keys at a specific nesting depth.

    Args:
        json: JSON string to search.
        target_depth: Nesting depth to search (0 = root level).

    Returns:
        List of key names found at the specified depth.
    """
    var events = parse_streaming(json)
    var keys = List[String]()

    for i in range(len(events)):
        var event = events[i].copy()
        if event.type == JsonEventType.KEY and event.depth == target_depth:
            keys.append(event.string_value)

    return keys^
