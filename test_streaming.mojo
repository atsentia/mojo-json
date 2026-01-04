"""Tests for streaming JSON parser."""

from testing import assert_equal, assert_true
from src.streaming import (
    JsonEventType,
    JsonEvent,
    StreamingParser,
    parse_streaming,
    count_elements,
    find_keys_at_depth,
)


fn test_parse_simple_object() raises:
    """Test parsing a simple object."""
    var events = parse_streaming('{"name": "Alice", "age": 30}')

    # Expected events: OBJECT_START, KEY, STRING, KEY, INT, OBJECT_END
    assert_true(len(events) >= 6, "Should have at least 6 events")

    var e0 = events[0].copy()
    assert_true(e0.type == JsonEventType.OBJECT_START, "First should be OBJECT_START")

    var e1 = events[1].copy()
    assert_true(e1.type == JsonEventType.KEY, "Second should be KEY")
    assert_equal(e1.string_value, "name")

    var e2 = events[2].copy()
    assert_true(e2.type == JsonEventType.STRING, "Third should be STRING")
    assert_equal(e2.string_value, "Alice")

    var e3 = events[3].copy()
    assert_true(e3.type == JsonEventType.KEY, "Fourth should be KEY")
    assert_equal(e3.string_value, "age")

    var e4 = events[4].copy()
    assert_true(e4.type == JsonEventType.INT, "Fifth should be INT")
    assert_equal(e4.int_value, 30)


fn test_parse_simple_array() raises:
    """Test parsing a simple array."""
    var events = parse_streaming("[1, 2, 3]")

    # Expected: ARRAY_START, INT, INT, INT, ARRAY_END
    assert_true(len(events) >= 5, "Should have at least 5 events")

    var e0 = events[0].copy()
    assert_true(e0.type == JsonEventType.ARRAY_START, "First should be ARRAY_START")

    var e1 = events[1].copy()
    assert_true(e1.type == JsonEventType.INT, "Second should be INT")
    assert_equal(e1.int_value, 1)

    var e4 = events[4].copy()
    assert_true(e4.type == JsonEventType.ARRAY_END, "Last should be ARRAY_END")


fn test_parse_nested() raises:
    """Test parsing nested structures."""
    var events = parse_streaming('{"user": {"name": "Bob"}}')

    var e0 = events[0].copy()
    assert_true(e0.type == JsonEventType.OBJECT_START, "First should be OBJECT_START")
    assert_equal(e0.depth, 0)

    var e2 = events[2].copy()
    assert_true(e2.type == JsonEventType.OBJECT_START, "Third should be nested OBJECT_START")
    assert_equal(e2.depth, 1)


fn test_parse_booleans() raises:
    """Test parsing boolean values."""
    var events = parse_streaming('[true, false]')

    var e1 = events[1].copy()
    assert_true(e1.type == JsonEventType.BOOL_TRUE, "Second should be BOOL_TRUE")

    var e2 = events[2].copy()
    assert_true(e2.type == JsonEventType.BOOL_FALSE, "Third should be BOOL_FALSE")


fn test_parse_null() raises:
    """Test parsing null value."""
    var events = parse_streaming('[null]')

    var e1 = events[1].copy()
    assert_true(e1.type == JsonEventType.NULL, "Second should be NULL")


fn test_parse_floats() raises:
    """Test parsing float values."""
    var events = parse_streaming('[3.14, 1e10, -2.5e-3]')

    var e1 = events[1].copy()
    assert_true(e1.type == JsonEventType.FLOAT, "First number should be FLOAT")

    var e2 = events[2].copy()
    assert_true(e2.type == JsonEventType.FLOAT, "Second number should be FLOAT")

    var e3 = events[3].copy()
    assert_true(e3.type == JsonEventType.FLOAT, "Third number should be FLOAT")


fn test_parse_escape_sequences() raises:
    """Test parsing strings with escape sequences."""
    var events = parse_streaming('["line1\\nline2", "tab\\there"]')

    var e1 = events[1].copy()
    assert_equal(e1.string_value, "line1\nline2")

    var e2 = events[2].copy()
    assert_equal(e2.string_value, "tab\there")


fn test_count_elements() raises:
    """Test counting elements."""
    var count = count_elements('[1, 2, 3, {"a": 1}]')
    # Elements: ARRAY_START(1) + 3 INTs + OBJECT_START(1) + STRING(1) + ARRAY_END(1) + OBJECT_END(1) = 8
    # But KEY is excluded, so: 1 + 3 + 1 + 1 + 1 + 1 = 8
    assert_true(count >= 6, "Should count multiple elements")


fn test_find_keys_at_depth() raises:
    """Test finding keys at specific depth."""
    var json = '{"name": "Alice", "address": {"city": "NYC", "zip": "10001"}}'
    var keys_0 = find_keys_at_depth(json, 1)  # depth 1 = inside root object
    var keys_1 = find_keys_at_depth(json, 2)  # depth 2 = inside address object

    assert_true(len(keys_0) >= 2, "Should find keys at depth 1")
    assert_true(len(keys_1) >= 2, "Should find keys at depth 2")


fn test_chunked_parsing() raises:
    """Test parsing in chunks (simulates streaming)."""
    var parser = StreamingParser()

    # Parse in chunks
    var events1 = parser.feed('{"name":')
    var events2 = parser.feed(' "Al')
    var events3 = parser.feed('ice"}')

    # Combine all events
    var total = len(events1) + len(events2) + len(events3)
    assert_true(total >= 4, "Should parse across chunks")


fn main() raises:
    """Run all streaming parser tests."""
    print("Running streaming parser tests...\n")

    test_parse_simple_object()
    print("  [OK] test_parse_simple_object")

    test_parse_simple_array()
    print("  [OK] test_parse_simple_array")

    test_parse_nested()
    print("  [OK] test_parse_nested")

    test_parse_booleans()
    print("  [OK] test_parse_booleans")

    test_parse_null()
    print("  [OK] test_parse_null")

    test_parse_floats()
    print("  [OK] test_parse_floats")

    test_parse_escape_sequences()
    print("  [OK] test_parse_escape_sequences")

    test_count_elements()
    print("  [OK] test_count_elements")

    test_find_keys_at_depth()
    print("  [OK] test_find_keys_at_depth")

    test_chunked_parsing()
    print("  [OK] test_chunked_parsing")

    print("\n" + "=" * 40)
    print("All streaming parser tests passed!")
    print("=" * 40)
