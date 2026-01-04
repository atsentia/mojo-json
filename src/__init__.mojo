"""
Mojo JSON Library

A pure Mojo library for JSON parsing and serialization.
No external dependencies, maximum performance.

Features:
- Full JSON spec compliance (RFC 8259)
- JsonValue variant type for all JSON types
- Fast recursive descent parser
- High-performance tape-based parser (300+ MB/s)
- JSON Pointer support (RFC 6901)
- Compact and pretty-print serialization
- Unicode support including surrogate pairs
- Detailed error messages with position info
- String interning for memory efficiency (50%+ savings)
- SAX-style streaming parser for large files

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

High-Performance Tape API:
    from mojo_json import parse_to_tape_v2, tape_get_pointer_string

    # Parse to tape (300+ MB/s)
    var tape = parse_to_tape_v2(json_string)

    # Access via JSON Pointer (RFC 6901)
    var name = tape_get_pointer_string(tape, "/users/0/name")
    var age = tape_get_pointer_int(tape, "/users/0/age")

Memory-Optimized Compressed Tape:
    from mojo_json import parse_to_tape_compressed

    # Parse with string interning (saves ~50% memory for repeated strings)
    var tape = parse_to_tape_compressed(json_with_repeated_keys)
    print(tape.compression_stats())  # Shows bytes saved

Error Handling:
    from mojo_json import parse_safe

    var result = parse_safe('{"invalid": }')
    if result[2]:
        var value = result[0].copy()
        # use value
    else:
        var error = result[1].copy()
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

# Parser
from src.parser import (
    JsonParser,
    ParserConfig,
    parse,
    parse_safe,
    parse_with_config,
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

# Tape-based parser (high-performance)
from src.tape_parser import (
    # Types
    JsonTape,
    TapeEntry,
    # Parsing functions
    parse_to_tape_v2,
    # Value access functions
    tape_get_string_value,
    tape_get_int_value,
    tape_get_float_value,
    tape_get_bool_value,
    tape_get_object_value,
    tape_get_array_element,
    tape_skip_value,
    # Array iteration helpers
    tape_array_iter_start,
    tape_array_iter_end,
    tape_array_iter_has_next,
    # JSON Pointer (RFC 6901) support
    tape_get_pointer,
    tape_get_pointer_string,
    tape_get_pointer_int,
    tape_get_pointer_float,
    tape_get_pointer_bool,
    # Prefetch optimization
    tape_prefetch_entry,
    tape_prefetch_range,
    tape_prefetch_children,
    tape_prefetch_string_data,
    # Compressed tape with string interning (memory-optimized)
    CompressedJsonTape,
    parse_to_tape_compressed,
)

# Streaming parser
from src.streaming import (
    JsonEventType,
    JsonEvent,
    StreamingParser,
    parse_streaming,
    count_elements,
    find_keys_at_depth,
)
