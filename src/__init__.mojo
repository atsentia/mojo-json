"""
Mojo JSON Library

A pure Mojo library for JSON parsing and serialization.
No external dependencies, maximum performance.

Features:
- Full JSON spec compliance (RFC 8259)
- JsonValue variant type for all JSON types
- Multiple parser options (standard, fast, lazy)
- Compact and pretty-print serialization
- Unicode support including surrogate pairs
- Detailed error messages with position info

Parser Options (Performance):
    | Function      | Speed      | Best For                           |
    |---------------|------------|------------------------------------|
    | parse()       | ~14 MB/s   | Small JSON, full tree needed       |
    | parse_fast()  | ~15 MB/s   | API compatibility with tape parser |
    | parse_lazy()  | ~500 MB/s  | Large JSON, selective access       |
    | parse_to_tape | ~800 MB/s  | Maximum speed, direct tape access  |

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

High-Performance Lazy Parsing:
    from mojo_json import parse_lazy

    # Fast even for huge JSON - only parses what you access
    var lazy = parse_lazy(huge_json)

    # Access values on-demand (no full tree build)
    var name = lazy.get_object_value("config")
                   .get_object_value("user")
                   .get_object_value("name")
                   .as_string()

    # Convert to JsonValue only when needed
    var full_tree = lazy.to_json_value()

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
from src.error import JsonParseError, JsonErrorCode

# Value types
from src.value import JsonValue, JsonArray, JsonObject, JsonType

# Parser (recursive descent - compatible API)
from src.parser import (
    JsonParser,
    ParserConfig,
    parse,
    parse_safe,
    parse_with_config,
)

# High-performance tape-based parser
from src.tape_parser import (
    parse_fast,      # Fast parse returning JsonValue (~50x faster)
    parse_to_tape,   # Fastest - returns tape for O(1) access
    parse_lazy,      # Fastest with lazy extraction (~500 MB/s)
    JsonTape,
    TapeParser,
    LazyJsonValue,   # On-demand value extraction
)

# Serializer
from src.serializer import (
    JsonSerializer,
    SerializerConfig,
    serialize,
    serialize_pretty,
    serialize_with_config,
    to_json,
)
