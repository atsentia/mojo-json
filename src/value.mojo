"""
JSON Value Type

Provides a variant type that can hold any JSON value:
- null
- boolean
- integer (Int64)
- floating point (Float64)
- string (String)
- array (List[JsonValue])
- object (Dict[String, JsonValue])

Example:
    # Create values
    var null_val = JsonValue.null()
    var bool_val = JsonValue.from_bool(True)
    var num_val = JsonValue.from_int(42)
    var str_val = JsonValue.from_string("hello")

    # Create array
    var arr = JsonArray()
    arr.append(JsonValue.from_int(1))
    arr.append(JsonValue.from_int(2))
    var arr_val = JsonValue.from_array(arr)

    # Create object
    var obj = JsonObject()
    obj["name"] = JsonValue.from_string("Alice")
    obj["age"] = JsonValue.from_int(30)
    var obj_val = JsonValue.from_object(obj)

    # Type checking
    if obj_val.is_object():
        var o = obj_val.as_object()
        print(o["name"].as_string())  # "Alice"
"""


# Type aliases for clarity
alias JsonArray = List[JsonValue]
alias JsonObject = Dict[String, JsonValue]


struct JsonType:
    """JSON value type constants."""

    alias NULL: Int = 0
    alias BOOL: Int = 1
    alias INT: Int = 2
    alias FLOAT: Int = 3
    alias STRING: Int = 4
    alias ARRAY: Int = 5
    alias OBJECT: Int = 6

    @staticmethod
    fn name(type_id: Int) -> String:
        """Get human-readable type name."""
        if type_id == Self.NULL:
            return "null"
        elif type_id == Self.BOOL:
            return "boolean"
        elif type_id == Self.INT:
            return "integer"
        elif type_id == Self.FLOAT:
            return "float"
        elif type_id == Self.STRING:
            return "string"
        elif type_id == Self.ARRAY:
            return "array"
        elif type_id == Self.OBJECT:
            return "object"
        else:
            return "unknown"


struct JsonValue(Copyable, Movable, Stringable):
    """
    A variant type representing any JSON value.

    This type uses tagged union semantics to store one of:
    - null
    - boolean
    - integer (Int64)
    - float (Float64)
    - string
    - array of JsonValue
    - object (string -> JsonValue mapping)

    Memory layout optimized for common cases (numbers, strings, booleans).
    """

    var _type: Int
    """Type tag indicating which variant is active."""

    var _bool_val: Bool
    """Boolean value (valid when _type == BOOL)."""

    var _int_val: Int64
    """Integer value (valid when _type == INT)."""

    var _float_val: Float64
    """Float value (valid when _type == FLOAT)."""

    var _string_val: String
    """String value (valid when _type == STRING)."""

    var _array_val: List[JsonValue]
    """Array value (valid when _type == ARRAY)."""

    var _object_val: Dict[String, JsonValue]
    """Object value (valid when _type == OBJECT)."""

    # ============================================================
    # Constructors
    # ============================================================

    fn __init__(out self):
        """Create a null value.

        PERF: Only allocates minimal storage. List/Dict are created
        lazily only when needed for array/object types.
        """
        self._type = JsonType.NULL
        self._bool_val = False
        self._int_val = 0
        self._float_val = 0.0
        self._string_val = ""
        # PERF: Create with zero capacity to minimize allocation
        self._array_val = List[JsonValue]()
        self._object_val = Dict[String, JsonValue]()

    fn __copyinit__(out self, other: Self):
        """Copy constructor."""
        self._type = other._type
        self._bool_val = other._bool_val
        self._int_val = other._int_val
        self._float_val = other._float_val
        self._string_val = other._string_val
        self._array_val = other._array_val.copy()
        self._object_val = other._object_val.copy()

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self._type = other._type
        self._bool_val = other._bool_val
        self._int_val = other._int_val
        self._float_val = other._float_val
        self._string_val = other._string_val^
        self._array_val = other._array_val^
        self._object_val = other._object_val^

    fn copy(self) -> Self:
        """Create a copy of this value."""
        var v = JsonValue()
        v._type = self._type
        v._bool_val = self._bool_val
        v._int_val = self._int_val
        v._float_val = self._float_val
        v._string_val = self._string_val
        v._array_val = self._array_val.copy()
        v._object_val = self._object_val.copy()
        return v^

    # ============================================================
    # Static factory methods
    # ============================================================

    @staticmethod
    fn null() -> JsonValue:
        """Create a null value."""
        return JsonValue()

    @staticmethod
    fn from_bool(value: Bool) -> JsonValue:
        """Create a boolean value."""
        var v = JsonValue()
        v._type = JsonType.BOOL
        v._bool_val = value
        return v^

    @staticmethod
    fn from_int(value: Int64) -> JsonValue:
        """Create an integer value."""
        var v = JsonValue()
        v._type = JsonType.INT
        v._int_val = value
        return v^

    @staticmethod
    fn from_int(value: Int) -> JsonValue:
        """Create an integer value from Int."""
        return JsonValue.from_int(Int64(value))

    @staticmethod
    fn from_float(value: Float64) -> JsonValue:
        """Create a floating point value."""
        var v = JsonValue()
        v._type = JsonType.FLOAT
        v._float_val = value
        return v^

    @staticmethod
    fn from_string(value: String) -> JsonValue:
        """Create a string value."""
        var v = JsonValue()
        v._type = JsonType.STRING
        v._string_val = value
        return v^

    @staticmethod
    fn from_array(value: List[JsonValue]) -> JsonValue:
        """Create an array value (copies the list)."""
        var v = JsonValue()
        v._type = JsonType.ARRAY
        v._array_val = value.copy()
        return v^

    @staticmethod
    fn from_array_move(deinit value: List[JsonValue]) -> JsonValue:
        """Create an array value (moves the list, no copy). PERF optimization."""
        var v = JsonValue()
        v._type = JsonType.ARRAY
        v._array_val = value^
        return v^

    @staticmethod
    fn from_object(value: Dict[String, JsonValue]) -> JsonValue:
        """Create an object value (copies the dict)."""
        var v = JsonValue()
        v._type = JsonType.OBJECT
        v._object_val = value.copy()
        return v^

    @staticmethod
    fn from_object_move(deinit value: Dict[String, JsonValue]) -> JsonValue:
        """Create an object value (moves the dict, no copy). PERF optimization."""
        var v = JsonValue()
        v._type = JsonType.OBJECT
        v._object_val = value^
        return v^

    # ============================================================
    # Type checking
    # ============================================================

    fn type_id(self) -> Int:
        """Get the type identifier."""
        return self._type

    fn type_name(self) -> String:
        """Get the type name as a string."""
        return JsonType.name(self._type)

    fn is_null(self) -> Bool:
        """Check if this is a null value."""
        return self._type == JsonType.NULL

    fn is_bool(self) -> Bool:
        """Check if this is a boolean value."""
        return self._type == JsonType.BOOL

    fn is_int(self) -> Bool:
        """Check if this is an integer value."""
        return self._type == JsonType.INT

    fn is_float(self) -> Bool:
        """Check if this is a float value."""
        return self._type == JsonType.FLOAT

    fn is_number(self) -> Bool:
        """Check if this is any numeric value (int or float)."""
        return self._type == JsonType.INT or self._type == JsonType.FLOAT

    fn is_string(self) -> Bool:
        """Check if this is a string value."""
        return self._type == JsonType.STRING

    fn is_array(self) -> Bool:
        """Check if this is an array value."""
        return self._type == JsonType.ARRAY

    fn is_object(self) -> Bool:
        """Check if this is an object value."""
        return self._type == JsonType.OBJECT

    # ============================================================
    # Value access
    # ============================================================

    fn as_bool(self) -> Bool:
        """
        Get the boolean value.

        Precondition: is_bool() must be True.
        Returns False for non-boolean types.
        """
        if self._type == JsonType.BOOL:
            return self._bool_val
        return False

    fn as_int(self) -> Int64:
        """
        Get the integer value.

        Precondition: is_int() must be True.
        For floats, truncates to integer.
        Returns 0 for non-numeric types.
        """
        if self._type == JsonType.INT:
            return self._int_val
        elif self._type == JsonType.FLOAT:
            return Int64(self._float_val)
        return 0

    fn as_float(self) -> Float64:
        """
        Get the float value.

        Works for both int and float types.
        Returns 0.0 for non-numeric types.
        """
        if self._type == JsonType.FLOAT:
            return self._float_val
        elif self._type == JsonType.INT:
            return Float64(self._int_val)
        return 0.0

    fn as_string(self) -> String:
        """
        Get the string value.

        Precondition: is_string() must be True.
        Returns empty string for non-string types.
        """
        if self._type == JsonType.STRING:
            return self._string_val
        return ""

    fn as_array(self) -> List[JsonValue]:
        """
        Get the array value.

        Precondition: is_array() must be True.
        Returns empty array for non-array types.
        """
        if self._type == JsonType.ARRAY:
            return self._array_val.copy()
        return List[JsonValue]()

    fn as_object(self) -> Dict[String, JsonValue]:
        """
        Get the object value.

        Precondition: is_object() must be True.
        Returns empty object for non-object types.
        """
        if self._type == JsonType.OBJECT:
            return self._object_val.copy()
        return Dict[String, JsonValue]()

    # ============================================================
    # PERF: Reference accessors (zero-copy access)
    # ============================================================

    @always_inline
    fn string_ref(ref [_] self) -> ref [self._string_val] String:
        """Get reference to string value without copying.

        PERF-FIX: Returns reference instead of copy.
        Caller must ensure is_string() is True.
        """
        return self._string_val

    @always_inline
    fn array_ref(ref [_] self) -> ref [self._array_val] List[JsonValue]:
        """Get reference to array value without copying.

        PERF-FIX: Returns reference instead of copy.
        Caller must ensure is_array() is True.
        """
        return self._array_val

    @always_inline
    fn object_ref(ref [_] self) -> ref [self._object_val] Dict[String, JsonValue]:
        """Get reference to object value without copying.

        PERF-FIX: Returns reference instead of copy.
        Caller must ensure is_object() is True.
        """
        return self._object_val

    # ============================================================
    # Array operations (convenience)
    # ============================================================

    fn len(self) -> Int:
        """
        Get length of array or object, or 0 for other types.
        """
        if self._type == JsonType.ARRAY:
            return len(self._array_val)
        elif self._type == JsonType.OBJECT:
            return len(self._object_val)
        return 0

    fn __getitem__(self, index: Int) -> JsonValue:
        """
        Get array element by index.

        Returns null for out of bounds or non-array types.
        """
        if self._type == JsonType.ARRAY:
            if index >= 0 and index < len(self._array_val):
                return self._array_val[index].copy()
        return JsonValue.null()

    fn __getitem__(self, key: String) raises -> JsonValue:
        """
        Get object value by key.

        Returns null for missing keys or non-object types.
        """
        if self._type == JsonType.OBJECT:
            if key in self._object_val:
                return self._object_val[key].copy()
        return JsonValue.null()

    fn contains(self, key: String) -> Bool:
        """Check if object contains key."""
        if self._type == JsonType.OBJECT:
            return key in self._object_val
        return False

    fn keys(self) -> List[String]:
        """Get all keys from object. Returns empty list for non-objects."""
        var result = List[String]()
        if self._type == JsonType.OBJECT:
            for entry in self._object_val.items():
                result.append(entry.key)
        return result^

    # ============================================================
    # Stringable implementation
    # ============================================================

    fn __str__(self) -> String:
        """Convert to JSON string representation."""
        if self._type == JsonType.NULL:
            return "null"
        elif self._type == JsonType.BOOL:
            if self._bool_val:
                return "true"
            else:
                return "false"
        elif self._type == JsonType.INT:
            return String(self._int_val)
        elif self._type == JsonType.FLOAT:
            return String(self._float_val)
        elif self._type == JsonType.STRING:
            return self._format_string()
        elif self._type == JsonType.ARRAY:
            return self._format_array()
        elif self._type == JsonType.OBJECT:
            return self._format_object()
        return "null"

    fn _format_string(self) -> String:
        """Format string with proper JSON escaping."""
        var result = String('"')
        for i in range(len(self._string_val)):
            var c = self._string_val[i]
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
            else:
                # Check for control characters
                var code = ord(c)
                if code < 32:
                    result += '\\u'
                    result += _hex_digit((code >> 12) & 0xF)
                    result += _hex_digit((code >> 8) & 0xF)
                    result += _hex_digit((code >> 4) & 0xF)
                    result += _hex_digit(code & 0xF)
                else:
                    result += c
        result += '"'
        return result

    fn _format_array(self) -> String:
        """Format array as JSON."""
        var result = String("[")
        for i in range(len(self._array_val)):
            if i > 0:
                result += ","
            result += String(self._array_val[i])
        result += "]"
        return result

    fn _format_object(self) -> String:
        """Format object as JSON."""
        var result = String("{")
        var first = True
        for entry in self._object_val.items():
            if not first:
                result += ","
            first = False
            # Format key
            result += '"'
            result += entry.key
            result += '":'
            # Format value
            result += String(entry.value)
        result += "}"
        return result

    # ============================================================
    # Comparison
    # ============================================================

    fn __eq__(self, other: Self) -> Bool:
        """Check equality."""
        if self._type != other._type:
            return False

        if self._type == JsonType.NULL:
            return True
        elif self._type == JsonType.BOOL:
            return self._bool_val == other._bool_val
        elif self._type == JsonType.INT:
            return self._int_val == other._int_val
        elif self._type == JsonType.FLOAT:
            return self._float_val == other._float_val
        elif self._type == JsonType.STRING:
            return self._string_val == other._string_val
        # For arrays and objects, compare string representations
        # (deep comparison would be more efficient but complex)
        return String(self) == String(other)

    fn __ne__(self, other: Self) -> Bool:
        """Check inequality."""
        return not self.__eq__(other)


# Helper function for hex formatting
fn _hex_digit(value: Int) -> String:
    """Convert 0-15 to hex digit."""
    if value < 10:
        return chr(ord('0') + value)
    else:
        return chr(ord('a') + value - 10)
