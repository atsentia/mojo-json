"""Tests for mojo-json library."""

from testing import assert_true, assert_false, assert_equal
from src import (
    JsonValue,
    JsonArray,
    JsonObject,
    JsonType,
    JsonParseError,
    parse,
    parse_safe,
    serialize,
    serialize_pretty,
)


# ============================================================
# JsonValue tests
# ============================================================


fn test_null_value():
    """Test null value creation and access."""
    var value = JsonValue.null()

    assert_true(value.is_null(), "Should be null")
    assert_false(value.is_bool(), "Should not be bool")
    assert_false(value.is_int(), "Should not be int")
    assert_false(value.is_string(), "Should not be string")
    assert_equal(value.type_name(), "null")
    assert_equal(String(value), "null")


fn test_bool_value():
    """Test boolean value creation and access."""
    var true_val = JsonValue.from_bool(True)
    var false_val = JsonValue.from_bool(False)

    assert_true(true_val.is_bool(), "Should be bool")
    assert_true(true_val.as_bool(), "Should be True")
    assert_equal(String(true_val), "true")

    assert_true(false_val.is_bool(), "Should be bool")
    assert_false(false_val.as_bool(), "Should be False")
    assert_equal(String(false_val), "false")


fn test_int_value():
    """Test integer value creation and access."""
    var value = JsonValue.from_int(42)

    assert_true(value.is_int(), "Should be int")
    assert_true(value.is_number(), "Should be number")
    assert_equal(value.as_int(), 42)
    assert_equal(String(value), "42")

    # Negative
    var neg = JsonValue.from_int(-100)
    assert_equal(neg.as_int(), -100)
    assert_equal(String(neg), "-100")


fn test_float_value():
    """Test float value creation and access."""
    var value = JsonValue.from_float(3.14159)

    assert_true(value.is_float(), "Should be float")
    assert_true(value.is_number(), "Should be number")

    # Float comparison with tolerance
    var diff = value.as_float() - 3.14159
    if diff < 0:
        diff = -diff
    assert_true(diff < 0.00001, "Float value should match")


fn test_string_value():
    """Test string value creation and access."""
    var value = JsonValue.from_string("hello, world!")

    assert_true(value.is_string(), "Should be string")
    assert_equal(value.as_string(), "hello, world!")
    assert_equal(String(value), '"hello, world!"')


fn test_array_value():
    """Test array value creation and access."""
    var arr = List[JsonValue]()
    arr.append(JsonValue.from_int(1))
    arr.append(JsonValue.from_int(2))
    arr.append(JsonValue.from_int(3))

    var value = JsonValue.from_array(arr)

    assert_true(value.is_array(), "Should be array")
    assert_equal(value.len(), 3)
    assert_equal(value[0].as_int(), 1)
    assert_equal(value[1].as_int(), 2)
    assert_equal(value[2].as_int(), 3)
    assert_equal(String(value), "[1,2,3]")


fn test_object_value():
    """Test object value creation and access."""
    var obj = Dict[String, JsonValue]()
    obj["name"] = JsonValue.from_string("Alice")
    obj["age"] = JsonValue.from_int(30)

    var value = JsonValue.from_object(obj)

    assert_true(value.is_object(), "Should be object")
    assert_equal(value.len(), 2)
    assert_equal(value["name"].as_string(), "Alice")
    assert_equal(value["age"].as_int(), 30)
    assert_true(value.contains("name"), "Should contain 'name'")
    assert_false(value.contains("missing"), "Should not contain 'missing'")


# ============================================================
# Parser tests
# ============================================================


fn test_parse_null() raises:
    """Test parsing null."""
    var value = parse("null")
    assert_true(value.is_null(), "Should parse null")


fn test_parse_bool() raises:
    """Test parsing booleans."""
    var true_val = parse("true")
    assert_true(true_val.is_bool(), "Should be bool")
    assert_true(true_val.as_bool(), "Should be True")

    var false_val = parse("false")
    assert_true(false_val.is_bool(), "Should be bool")
    assert_false(false_val.as_bool(), "Should be False")


fn test_parse_integers() raises:
    """Test parsing integers."""
    assert_equal(parse("0").as_int(), 0)
    assert_equal(parse("42").as_int(), 42)
    assert_equal(parse("-1").as_int(), -1)
    assert_equal(parse("123456789").as_int(), 123456789)


fn test_parse_floats() raises:
    """Test parsing floating point numbers."""
    var pi = parse("3.14159")
    assert_true(pi.is_float(), "Should be float")

    var exp = parse("1e10")
    assert_true(exp.is_float(), "Should be float")

    var neg_exp = parse("1.5e-3")
    assert_true(neg_exp.is_float(), "Should be float")


fn test_parse_strings() raises:
    """Test parsing strings."""
    assert_equal(parse('"hello"').as_string(), "hello")
    assert_equal(parse('""').as_string(), "")
    assert_equal(parse('"with spaces"').as_string(), "with spaces")


fn test_parse_escape_sequences() raises:
    """Test parsing escape sequences."""
    assert_equal(parse('"line1\\nline2"').as_string(), "line1\nline2")
    assert_equal(parse('"tab\\there"').as_string(), "tab\there")
    assert_equal(parse('"quote\\"here"').as_string(), 'quote"here')
    assert_equal(parse('"back\\\\slash"').as_string(), "back\\slash")


fn test_parse_unicode_escape() raises:
    """Test parsing unicode escapes."""
    # Simple ASCII via unicode
    assert_equal(parse('"\\u0041"').as_string(), "A")

    # Euro sign
    var euro = parse('"\\u20AC"')
    assert_true(euro.is_string(), "Should parse unicode")


fn test_parse_array() raises:
    """Test parsing arrays."""
    var empty = parse("[]")
    assert_true(empty.is_array(), "Should be array")
    assert_equal(empty.len(), 0)

    var simple = parse("[1, 2, 3]")
    assert_equal(simple.len(), 3)
    assert_equal(simple[0].as_int(), 1)
    assert_equal(simple[1].as_int(), 2)
    assert_equal(simple[2].as_int(), 3)

    var mixed = parse('[null, true, 42, "text"]')
    assert_equal(mixed.len(), 4)
    assert_true(mixed[0].is_null(), "First should be null")
    assert_true(mixed[1].as_bool(), "Second should be true")
    assert_equal(mixed[2].as_int(), 42)
    assert_equal(mixed[3].as_string(), "text")


fn test_parse_object() raises:
    """Test parsing objects."""
    var empty = parse("{}")
    assert_true(empty.is_object(), "Should be object")
    assert_equal(empty.len(), 0)

    var simple = parse('{"key": "value"}')
    assert_equal(simple["key"].as_string(), "value")

    var complex_obj = parse('{"name": "Bob", "age": 25, "active": true}')
    assert_equal(complex_obj["name"].as_string(), "Bob")
    assert_equal(complex_obj["age"].as_int(), 25)
    assert_true(complex_obj["active"].as_bool(), "Should be true")


fn test_parse_nested() raises:
    """Test parsing nested structures."""
    var nested_arr = parse("[[1, 2], [3, 4]]")
    assert_equal(nested_arr[0][0].as_int(), 1)
    assert_equal(nested_arr[1][1].as_int(), 4)

    var nested_obj = parse('{"user": {"name": "Charlie", "scores": [90, 85, 88]}}')
    assert_equal(nested_obj["user"]["name"].as_string(), "Charlie")
    assert_equal(nested_obj["user"]["scores"][0].as_int(), 90)


fn test_parse_whitespace() raises:
    """Test that whitespace is handled correctly."""
    var value = parse("  \n\t  { \"key\"  :  \"value\"  }  \n  ")
    assert_equal(value["key"].as_string(), "value")


fn test_parse_safe_success():
    """Test parse_safe with valid JSON."""
    var result = parse_safe('{"valid": true}')
    var is_ok = result.get[2, Bool]()
    assert_true(is_ok, "Should succeed")

    if is_ok:
        var value = result.get[0, JsonValue]()
        assert_true(value["valid"].as_bool(), "Value should be true")


fn test_parse_safe_failure():
    """Test parse_safe with invalid JSON."""
    var result = parse_safe('{"invalid": }')
    var is_ok = result.get[2, Bool]()
    assert_false(is_ok, "Should fail")

    if not is_ok:
        var error = result.get[1, JsonParseError]()
        assert_true(len(error.message) > 0, "Should have error message")


# ============================================================
# Serializer tests
# ============================================================


fn test_serialize_primitives():
    """Test serializing primitive values."""
    assert_equal(serialize(JsonValue.null()), "null")
    assert_equal(serialize(JsonValue.from_bool(True)), "true")
    assert_equal(serialize(JsonValue.from_bool(False)), "false")
    assert_equal(serialize(JsonValue.from_int(42)), "42")
    assert_equal(serialize(JsonValue.from_string("hello")), '"hello"')


fn test_serialize_array():
    """Test serializing arrays."""
    var arr = List[JsonValue]()
    arr.append(JsonValue.from_int(1))
    arr.append(JsonValue.from_int(2))
    arr.append(JsonValue.from_int(3))

    var value = JsonValue.from_array(arr)
    assert_equal(serialize(value), "[1,2,3]")


fn test_serialize_object():
    """Test serializing objects."""
    var obj = Dict[String, JsonValue]()
    obj["key"] = JsonValue.from_string("value")

    var value = JsonValue.from_object(obj)
    assert_equal(serialize(value), '{"key":"value"}')


fn test_serialize_escape_strings():
    """Test that strings are properly escaped."""
    var with_quote = JsonValue.from_string('say "hello"')
    assert_equal(serialize(with_quote), '"say \\"hello\\""')

    var with_newline = JsonValue.from_string("line1\nline2")
    assert_equal(serialize(with_newline), '"line1\\nline2"')


fn test_serialize_pretty():
    """Test pretty-printed serialization."""
    var obj = Dict[String, JsonValue]()
    obj["name"] = JsonValue.from_string("Test")

    var value = JsonValue.from_object(obj)
    var pretty = serialize_pretty(value, "  ")

    # Should contain newlines and indentation
    assert_true(len(pretty) > len(serialize(value)), "Pretty should be longer")


fn test_roundtrip() raises:
    """Test that parse followed by serialize preserves value."""
    var original = '{"name":"Alice","age":30,"active":true}'
    var value = parse(original)
    var serialized = serialize(value)

    # Parse again and compare
    var reparsed = parse(serialized)
    assert_equal(value["name"].as_string(), reparsed["name"].as_string())
    assert_equal(value["age"].as_int(), reparsed["age"].as_int())
    assert_equal(value["active"].as_bool(), reparsed["active"].as_bool())


# ============================================================
# Error handling tests
# ============================================================


fn test_error_format():
    """Test error formatting."""
    var error = JsonParseError("Test error", 10, 2, 5)
    var formatted = error.format()

    assert_true("line 2" in formatted, "Should include line number")
    assert_true("column 5" in formatted, "Should include column number")
    assert_true("Test error" in formatted, "Should include message")


# ============================================================
# Main test runner
# ============================================================


fn main() raises:
    """Run all tests."""
    print("Running mojo-json tests...\n")

    # JsonValue tests
    print("JsonValue tests:")
    test_null_value()
    print("  [OK] test_null_value")

    test_bool_value()
    print("  [OK] test_bool_value")

    test_int_value()
    print("  [OK] test_int_value")

    test_float_value()
    print("  [OK] test_float_value")

    test_string_value()
    print("  [OK] test_string_value")

    test_array_value()
    print("  [OK] test_array_value")

    test_object_value()
    print("  [OK] test_object_value")

    # Parser tests
    print("\nParser tests:")
    test_parse_null()
    print("  [OK] test_parse_null")

    test_parse_bool()
    print("  [OK] test_parse_bool")

    test_parse_integers()
    print("  [OK] test_parse_integers")

    test_parse_floats()
    print("  [OK] test_parse_floats")

    test_parse_strings()
    print("  [OK] test_parse_strings")

    test_parse_escape_sequences()
    print("  [OK] test_parse_escape_sequences")

    test_parse_unicode_escape()
    print("  [OK] test_parse_unicode_escape")

    test_parse_array()
    print("  [OK] test_parse_array")

    test_parse_object()
    print("  [OK] test_parse_object")

    test_parse_nested()
    print("  [OK] test_parse_nested")

    test_parse_whitespace()
    print("  [OK] test_parse_whitespace")

    test_parse_safe_success()
    print("  [OK] test_parse_safe_success")

    test_parse_safe_failure()
    print("  [OK] test_parse_safe_failure")

    # Serializer tests
    print("\nSerializer tests:")
    test_serialize_primitives()
    print("  [OK] test_serialize_primitives")

    test_serialize_array()
    print("  [OK] test_serialize_array")

    test_serialize_object()
    print("  [OK] test_serialize_object")

    test_serialize_escape_strings()
    print("  [OK] test_serialize_escape_strings")

    test_serialize_pretty()
    print("  [OK] test_serialize_pretty")

    test_roundtrip()
    print("  [OK] test_roundtrip")

    # Error tests
    print("\nError handling tests:")
    test_error_format()
    print("  [OK] test_error_format")

    print("\n" + "=" * 40)
    print("All mojo-json tests passed!")
    print("=" * 40)
