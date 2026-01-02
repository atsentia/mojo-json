"""
JSON Serializer

Converts JsonValue structures to JSON strings.

Features:
- Compact output (no extra whitespace)
- Pretty-printed output with configurable indentation
- Proper string escaping (including unicode)
- Handles all JSON types

Example:
    from mojo_json import JsonValue, serialize, serialize_pretty

    var obj = JsonObject()
    obj["name"] = JsonValue.from_string("Alice")
    obj["age"] = JsonValue.from_int(30)
    obj["active"] = JsonValue.from_bool(True)

    var value = JsonValue.from_object(obj)

    # Compact
    print(serialize(value))
    # {"name":"Alice","age":30,"active":true}

    # Pretty
    print(serialize_pretty(value))
    # {
    #   "name": "Alice",
    #   "age": 30,
    #   "active": true
    # }
"""

from .value import JsonValue, JsonArray, JsonObject, JsonType


@value
struct SerializerConfig:
    """Configuration for JSON serialization."""

    var indent: String
    """Indentation string for pretty printing (empty for compact)."""

    var sort_keys: Bool
    """Whether to sort object keys alphabetically."""

    var escape_unicode: Bool
    """Whether to escape non-ASCII characters as \\uXXXX."""

    var escape_forward_slash: Bool
    """Whether to escape forward slashes (for HTML embedding)."""

    fn __init__(out self):
        """Create default configuration (compact output)."""
        self.indent = ""
        self.sort_keys = False
        self.escape_unicode = False
        self.escape_forward_slash = False

    fn __init__(
        out self,
        indent: String = "",
        sort_keys: Bool = False,
        escape_unicode: Bool = False,
        escape_forward_slash: Bool = False,
    ):
        """Create custom configuration."""
        self.indent = indent
        self.sort_keys = sort_keys
        self.escape_unicode = escape_unicode
        self.escape_forward_slash = escape_forward_slash

    @staticmethod
    fn compact() -> Self:
        """Create compact serializer configuration."""
        return SerializerConfig()

    @staticmethod
    fn pretty(indent: String = "  ") -> Self:
        """Create pretty-print serializer configuration."""
        return SerializerConfig(indent=indent)


struct JsonSerializer:
    """
    JSON serializer implementation.

    Converts JsonValue to string representation.
    """

    var config: SerializerConfig
    """Serialization configuration."""

    fn __init__(out self):
        """Create serializer with default configuration."""
        self.config = SerializerConfig()

    fn __init__(out self, config: SerializerConfig):
        """Create serializer with custom configuration."""
        self.config = config

    # ============================================================
    # Public interface
    # ============================================================

    fn serialize(self, value: JsonValue) -> String:
        """
        Serialize a JsonValue to a JSON string.

        Args:
            value: The JsonValue to serialize.

        Returns:
            JSON string representation.
        """
        if len(self.config.indent) > 0:
            return self._serialize_pretty(value, 0)
        else:
            return self._serialize_compact(value)

    # ============================================================
    # Compact serialization
    # ============================================================

    fn _serialize_compact(self, value: JsonValue) -> String:
        """Serialize to compact JSON (no whitespace)."""
        if value.is_null():
            return "null"
        elif value.is_bool():
            if value.as_bool():
                return "true"
            else:
                return "false"
        elif value.is_int():
            return str(value.as_int())
        elif value.is_float():
            return self._format_float(value.as_float())
        elif value.is_string():
            return self._escape_string(value.as_string())
        elif value.is_array():
            return self._serialize_array_compact(value.as_array())
        elif value.is_object():
            return self._serialize_object_compact(value.as_object())
        else:
            return "null"

    fn _serialize_array_compact(self, arr: List[JsonValue]) -> String:
        """Serialize array to compact JSON."""
        var result = String("[")
        for i in range(len(arr)):
            if i > 0:
                result += ","
            result += self._serialize_compact(arr[i])
        result += "]"
        return result

    fn _serialize_object_compact(self, obj: Dict[String, JsonValue]) -> String:
        """Serialize object to compact JSON."""
        var result = String("{")

        var keys = List[String]()
        for key in obj.keys():
            keys.append(key[])

        if self.config.sort_keys:
            # Simple bubble sort for key sorting
            for i in range(len(keys)):
                for j in range(len(keys) - i - 1):
                    if keys[j] > keys[j + 1]:
                        var temp = keys[j]
                        keys[j] = keys[j + 1]
                        keys[j + 1] = temp

        var first = True
        for i in range(len(keys)):
            var key = keys[i]
            if not first:
                result += ","
            first = False

            result += self._escape_string(key)
            result += ":"
            result += self._serialize_compact(obj[key])

        result += "}"
        return result

    # ============================================================
    # Pretty serialization
    # ============================================================

    fn _serialize_pretty(self, value: JsonValue, depth: Int) -> String:
        """Serialize to pretty-printed JSON."""
        if value.is_null():
            return "null"
        elif value.is_bool():
            if value.as_bool():
                return "true"
            else:
                return "false"
        elif value.is_int():
            return str(value.as_int())
        elif value.is_float():
            return self._format_float(value.as_float())
        elif value.is_string():
            return self._escape_string(value.as_string())
        elif value.is_array():
            return self._serialize_array_pretty(value.as_array(), depth)
        elif value.is_object():
            return self._serialize_object_pretty(value.as_object(), depth)
        else:
            return "null"

    fn _serialize_array_pretty(self, arr: List[JsonValue], depth: Int) -> String:
        """Serialize array with pretty printing."""
        if len(arr) == 0:
            return "[]"

        var indent = self._make_indent(depth + 1)
        var close_indent = self._make_indent(depth)

        var result = String("[\n")
        for i in range(len(arr)):
            if i > 0:
                result += ",\n"
            result += indent
            result += self._serialize_pretty(arr[i], depth + 1)
        result += "\n"
        result += close_indent
        result += "]"
        return result

    fn _serialize_object_pretty(self, obj: Dict[String, JsonValue], depth: Int) -> String:
        """Serialize object with pretty printing."""
        if len(obj) == 0:
            return "{}"

        var indent = self._make_indent(depth + 1)
        var close_indent = self._make_indent(depth)

        var keys = List[String]()
        for key in obj.keys():
            keys.append(key[])

        if self.config.sort_keys:
            # Simple bubble sort for key sorting
            for i in range(len(keys)):
                for j in range(len(keys) - i - 1):
                    if keys[j] > keys[j + 1]:
                        var temp = keys[j]
                        keys[j] = keys[j + 1]
                        keys[j + 1] = temp

        var result = String("{\n")
        for i in range(len(keys)):
            var key = keys[i]
            if i > 0:
                result += ",\n"
            result += indent
            result += self._escape_string(key)
            result += ": "
            result += self._serialize_pretty(obj[key], depth + 1)
        result += "\n"
        result += close_indent
        result += "}"
        return result

    fn _make_indent(self, depth: Int) -> String:
        """Create indentation string for given depth."""
        var result = String("")
        for _ in range(depth):
            result += self.config.indent
        return result

    # ============================================================
    # String formatting
    # ============================================================

    fn _escape_string(self, s: String) -> String:
        """Escape string for JSON output."""
        var result = String('"')

        for i in range(len(s)):
            var c = s[i]
            var code = ord(c)

            if c == '"':
                result += '\\"'
            elif c == '\\':
                result += '\\\\'
            elif c == '\n':
                result += '\\n'
            elif c == '\r':
                result += '\\r'
            elif c == '\t':
                result += '\\t'
            elif c == '/' and self.config.escape_forward_slash:
                result += '\\/'
            elif code == 8:  # Backspace
                result += '\\b'
            elif code == 12:  # Form feed
                result += '\\f'
            elif code < 32:
                # Control characters
                result += '\\u'
                result += self._hex_digit((code >> 12) & 0xF)
                result += self._hex_digit((code >> 8) & 0xF)
                result += self._hex_digit((code >> 4) & 0xF)
                result += self._hex_digit(code & 0xF)
            elif self.config.escape_unicode and code > 127:
                # Non-ASCII characters
                result += '\\u'
                result += self._hex_digit((code >> 12) & 0xF)
                result += self._hex_digit((code >> 8) & 0xF)
                result += self._hex_digit((code >> 4) & 0xF)
                result += self._hex_digit(code & 0xF)
            else:
                result += c

        result += '"'
        return result

    fn _hex_digit(self, value: Int) -> String:
        """Convert 0-15 to hex digit."""
        if value < 10:
            return chr(ord('0') + value)
        else:
            return chr(ord('a') + value - 10)

    fn _format_float(self, value: Float64) -> String:
        """Format float for JSON output."""
        # Handle special cases
        if value != value:  # NaN check
            return "null"  # JSON doesn't support NaN
        if value == Float64.MAX or value == -Float64.MAX:
            return "null"  # JSON doesn't support Infinity

        var s = str(value)

        # Ensure there's a decimal point for floats
        var has_decimal = False
        var has_exp = False
        for i in range(len(s)):
            if s[i] == '.':
                has_decimal = True
            elif s[i] == 'e' or s[i] == 'E':
                has_exp = True

        # If it looks like an integer, add .0
        if not has_decimal and not has_exp:
            s += ".0"

        return s


# ============================================================
# Convenience functions
# ============================================================


fn serialize(value: JsonValue) -> String:
    """
    Serialize a JsonValue to a compact JSON string.

    Args:
        value: The JsonValue to serialize.

    Returns:
        Compact JSON string with no extra whitespace.

    Example:
        var value = JsonValue.from_int(42)
        print(serialize(value))  # "42"
    """
    var serializer = JsonSerializer()
    return serializer.serialize(value)


fn serialize_pretty(value: JsonValue, indent: String = "  ") -> String:
    """
    Serialize a JsonValue to a pretty-printed JSON string.

    Args:
        value: The JsonValue to serialize.
        indent: Indentation string (default: 2 spaces).

    Returns:
        Pretty-printed JSON string with newlines and indentation.

    Example:
        var obj = JsonObject()
        obj["key"] = JsonValue.from_string("value")
        var value = JsonValue.from_object(obj)
        print(serialize_pretty(value))
        # {
        #   "key": "value"
        # }
    """
    var config = SerializerConfig(indent=indent)
    var serializer = JsonSerializer(config)
    return serializer.serialize(value)


fn serialize_with_config(value: JsonValue, config: SerializerConfig) -> String:
    """
    Serialize a JsonValue with custom configuration.

    Args:
        value: The JsonValue to serialize.
        config: Serialization configuration.

    Returns:
        JSON string formatted according to configuration.
    """
    var serializer = JsonSerializer(config)
    return serializer.serialize(value)


fn to_json(value: JsonValue) -> String:
    """
    Alias for serialize() for convenience.

    Args:
        value: The JsonValue to serialize.

    Returns:
        Compact JSON string.
    """
    return serialize(value)
