"""Tests for JSON Pointer (RFC 6901) support."""

from testing import assert_equal, assert_true
from src.tape_parser import (
    parse_to_tape_v2,
    tape_get_pointer,
    tape_get_pointer_string,
    tape_get_pointer_int,
    tape_get_pointer_float,
    tape_get_pointer_bool,
)


fn test_pointer_root() raises:
    """Test empty pointer returns root."""
    var tape = parse_to_tape_v2('{"name": "Alice"}')
    var idx = tape_get_pointer(tape, "")
    assert_equal(idx, 1, "Empty pointer should return root (index 1)")


fn test_pointer_simple_object() raises:
    """Test simple object key lookup."""
    var tape = parse_to_tape_v2('{"name": "Alice", "age": 30}')

    var name = tape_get_pointer_string(tape, "/name")
    assert_equal(name, "Alice")

    var age = tape_get_pointer_int(tape, "/age")
    assert_equal(age, 30)


fn test_pointer_nested_object() raises:
    """Test nested object navigation."""
    var json = '{"user": {"profile": {"name": "Bob", "active": true}}}'
    var tape = parse_to_tape_v2(json)

    var name = tape_get_pointer_string(tape, "/user/profile/name")
    assert_equal(name, "Bob")

    var active = tape_get_pointer_bool(tape, "/user/profile/active")
    assert_true(active, "Should be true")


fn test_pointer_array_index() raises:
    """Test array index access."""
    var tape = parse_to_tape_v2('[10, 20, 30, 40]')

    assert_equal(tape_get_pointer_int(tape, "/0"), 10)
    assert_equal(tape_get_pointer_int(tape, "/1"), 20)
    assert_equal(tape_get_pointer_int(tape, "/2"), 30)
    assert_equal(tape_get_pointer_int(tape, "/3"), 40)


fn test_pointer_nested_array() raises:
    """Test nested array access."""
    var json = '{"users": [{"name": "Alice"}, {"name": "Bob"}]}'
    var tape = parse_to_tape_v2(json)

    assert_equal(tape_get_pointer_string(tape, "/users/0/name"), "Alice")
    assert_equal(tape_get_pointer_string(tape, "/users/1/name"), "Bob")


fn test_pointer_escaped_tilde() raises:
    """Test ~0 escape sequence (represents ~)."""
    var json = '{"a~b": 42}'
    var tape = parse_to_tape_v2(json)

    # ~0 in pointer means literal ~
    var value = tape_get_pointer_int(tape, "/a~0b")
    assert_equal(value, 42)


fn test_pointer_escaped_slash() raises:
    """Test ~1 escape sequence (represents /)."""
    var json = '{"a/b": 99}'
    var tape = parse_to_tape_v2(json)

    # ~1 in pointer means literal /
    var value = tape_get_pointer_int(tape, "/a~1b")
    assert_equal(value, 99)


fn test_pointer_float_value() raises:
    """Test float value retrieval."""
    var tape = parse_to_tape_v2('{"pi": 3.14159}')

    var pi = tape_get_pointer_float(tape, "/pi")
    var diff = pi - 3.14159
    if diff < 0:
        diff = -diff
    assert_true(diff < 0.00001, "Float should match")


fn test_pointer_not_found() raises:
    """Test that missing keys return 0 index."""
    var tape = parse_to_tape_v2('{"name": "Alice"}')

    var idx = tape_get_pointer(tape, "/missing")
    assert_equal(idx, 0, "Missing key should return 0")

    var idx2 = tape_get_pointer(tape, "/name/nested")
    assert_equal(idx2, 0, "Cannot navigate into string")


fn test_pointer_invalid_array_index() raises:
    """Test invalid array indices."""
    var tape = parse_to_tape_v2('[1, 2, 3]')

    # Out of bounds
    var idx = tape_get_pointer(tape, "/10")
    assert_equal(idx, 0, "Out of bounds index should return 0")

    # Leading zero not allowed (except "0")
    var idx2 = tape_get_pointer(tape, "/01")
    assert_equal(idx2, 0, "Leading zero should be invalid")


fn test_pointer_invalid_format() raises:
    """Test invalid pointer format."""
    var tape = parse_to_tape_v2('{"name": "Alice"}')

    # Must start with /
    var idx = tape_get_pointer(tape, "name")
    assert_equal(idx, 0, "Pointer without leading / should return 0")


fn test_pointer_complex_example() raises:
    """Test complex JSON structure from RFC 6901."""
    var json = """
    {
        "foo": ["bar", "baz"],
        "": 0,
        "a/b": 1,
        "c%d": 2,
        "e^f": 3,
        "g|h": 4,
        "i\\\\j": 5,
        "k\\"l": 6,
        " ": 7,
        "m~n": 8
    }
    """
    var tape = parse_to_tape_v2(json)

    # /foo -> ["bar", "baz"]
    var foo_idx = tape_get_pointer(tape, "/foo")
    assert_true(foo_idx > 0, "Should find /foo")

    # /foo/0 -> "bar"
    assert_equal(tape_get_pointer_string(tape, "/foo/0"), "bar")

    # /foo/1 -> "baz"
    assert_equal(tape_get_pointer_string(tape, "/foo/1"), "baz")

    # / -> 0 (empty string key)
    assert_equal(tape_get_pointer_int(tape, "/"), 0)

    # /a~1b -> 1 (key "a/b", ~1 = /)
    assert_equal(tape_get_pointer_int(tape, "/a~1b"), 1)

    # /m~0n -> 8 (key "m~n", ~0 = ~)
    assert_equal(tape_get_pointer_int(tape, "/m~0n"), 8)


fn main() raises:
    """Run all JSON Pointer tests."""
    print("Running JSON Pointer (RFC 6901) tests...\n")

    test_pointer_root()
    print("  [OK] test_pointer_root")

    test_pointer_simple_object()
    print("  [OK] test_pointer_simple_object")

    test_pointer_nested_object()
    print("  [OK] test_pointer_nested_object")

    test_pointer_array_index()
    print("  [OK] test_pointer_array_index")

    test_pointer_nested_array()
    print("  [OK] test_pointer_nested_array")

    test_pointer_escaped_tilde()
    print("  [OK] test_pointer_escaped_tilde")

    test_pointer_escaped_slash()
    print("  [OK] test_pointer_escaped_slash")

    test_pointer_float_value()
    print("  [OK] test_pointer_float_value")

    test_pointer_not_found()
    print("  [OK] test_pointer_not_found")

    test_pointer_invalid_array_index()
    print("  [OK] test_pointer_invalid_array_index")

    test_pointer_invalid_format()
    print("  [OK] test_pointer_invalid_format")

    test_pointer_complex_example()
    print("  [OK] test_pointer_complex_example")

    print("\n" + "=" * 40)
    print("All JSON Pointer tests passed!")
    print("=" * 40)
