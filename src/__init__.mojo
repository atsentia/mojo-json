"""
Mojo JSON Library

A pure Mojo library for JSON parsing and serialization.
No external dependencies, maximum performance.

Features:
- Full JSON spec compliance (RFC 8259)
- JsonValue variant type for all JSON types
- Fast recursive descent parser
- Compact and pretty-print serialization
- Unicode support including surrogate pairs
- Detailed error messages with position info

Basic Usage:
    from mojo_json import parse, serialize, JsonValue

    # Parse JSON string
    var value = parse('{"name": "Alice", "age": 30}')

    # Access values
    print(value["name"].as_string())  # Alice
    print(value["age"].as_int())      # 30

    # Create values
    var obj = JsonObject()
    obj["greeting"] = JsonValue.from_string("Hello, World!")
    obj["count"] = JsonValue.from_int(42)
    obj["active"] = JsonValue.from_bool(True)

    var json_value = JsonValue.from_object(obj)

    # Serialize to JSON
    print(serialize(json_value))
    # {"greeting":"Hello, World!","count":42,"active":true}

    print(serialize_pretty(json_value))
    # {
    #   "greeting": "Hello, World!",
    #   "count": 42,
    #   "active": true
    # }

Error Handling:
    from mojo_json import parse_safe

    var result = parse_safe('{"invalid": }')
    if result.get[2, Bool]():
        var value = result.get[0, JsonValue]()
        # use value
    else:
        var error = result.get[1, JsonParseError]()
        print(error.format())
        # JSON parse error at line 1, column 13: Expected value

Type Aliases:
    - JsonArray = List[JsonValue]
    - JsonObject = Dict[String, JsonValue]
"""

# Error types
from .error import JsonParseError, JsonErrorCode

# Value types
from .value import JsonValue, JsonArray, JsonObject, JsonType

# Parser
from .parser import (
    JsonParser,
    ParserConfig,
    parse,
    parse_safe,
    parse_with_config,
)

# Serializer
from .serializer import (
    JsonSerializer,
    SerializerConfig,
    serialize,
    serialize_pretty,
    serialize_with_config,
    to_json,
)
