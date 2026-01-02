"""Test tape-based JSON parser."""

from src.tape_parser import parse_to_tape, JsonTape, benchmark_tape_parse
from src.tape_parser import TAPE_ROOT, TAPE_START_OBJECT, TAPE_END_OBJECT
from src.tape_parser import TAPE_START_ARRAY, TAPE_END_ARRAY
from src.tape_parser import TAPE_STRING, TAPE_INT64, TAPE_TRUE, TAPE_FALSE, TAPE_NULL


fn test_simple_object() raises -> Bool:
    """Test parsing simple object."""
    print("Testing simple object...")

    var tape = parse_to_tape('{"name": "Alice", "age": 30}')

    print("  Tape length:", len(tape))
    print("  Memory usage:", tape.memory_usage(), "bytes")

    # Check structure
    if len(tape) < 6:
        print("  FAIL: Tape too short")
        return False

    # Entry 0 should be ROOT
    var root = tape.get_entry(0)
    if root.type_tag() != TAPE_ROOT:
        print("  FAIL: First entry not ROOT")
        return False

    # Entry 1 should be START_OBJECT
    var obj_start = tape.get_entry(1)
    if obj_start.type_tag() != TAPE_START_OBJECT:
        print("  FAIL: Expected START_OBJECT")
        return False

    print("  OK")
    return True


fn test_simple_array() raises -> Bool:
    """Test parsing simple array."""
    print("\nTesting simple array...")

    var tape = parse_to_tape("[1, 2, 3]")

    print("  Tape length:", len(tape))

    # Entry 0 = ROOT
    # Entry 1 = START_ARRAY
    var arr_start = tape.get_entry(1)
    if arr_start.type_tag() != TAPE_START_ARRAY:
        print("  FAIL: Expected START_ARRAY")
        return False

    print("  OK")
    return True


fn test_nested_structure() raises -> Bool:
    """Test parsing nested JSON."""
    print("\nTesting nested structure...")

    var json = '{"users": [{"name": "Alice"}, {"name": "Bob"}]}'
    var tape = parse_to_tape(json)

    print("  Tape length:", len(tape))

    # Should have outer object, array, and two inner objects
    if len(tape) < 10:
        print("  FAIL: Tape too short for nested structure")
        return False

    print("  OK")
    return True


fn test_literals() raises -> Bool:
    """Test parsing literals (true, false, null)."""
    print("\nTesting literals...")

    var tape = parse_to_tape('{"a": true, "b": false, "c": null}')

    print("  Tape length:", len(tape))

    # Find and verify literals
    var found_true = False
    var found_false = False
    var found_null = False

    for i in range(len(tape)):
        var entry = tape.get_entry(i)
        if entry.type_tag() == TAPE_TRUE:
            found_true = True
        elif entry.type_tag() == TAPE_FALSE:
            found_false = True
        elif entry.type_tag() == TAPE_NULL:
            found_null = True

    if not found_true:
        print("  FAIL: Missing true")
        return False
    if not found_false:
        print("  FAIL: Missing false")
        return False
    if not found_null:
        print("  FAIL: Missing null")
        return False

    print("  OK")
    return True


fn test_numbers() raises -> Bool:
    """Test parsing numbers."""
    print("\nTesting numbers...")

    var tape = parse_to_tape('{"int": 42, "float": 3.14}')

    print("  Tape length:", len(tape))

    # Find and verify numbers
    var found_int = False
    var found_float = False

    for i in range(len(tape)):
        var entry = tape.get_entry(i)
        if entry.type_tag() == TAPE_INT64:
            var val = tape.get_int64(i)
            if val == 42:
                found_int = True
                print("  Found int:", val)

    if not found_int:
        print("  FAIL: Missing integer 42")
        return False

    print("  OK")
    return True


fn test_string_extraction() raises -> Bool:
    """Test string extraction from tape."""
    print("\nTesting string extraction...")

    var tape = parse_to_tape('{"greeting": "Hello, World!"}')

    print("  Tape length:", len(tape))

    # Find strings
    for i in range(len(tape)):
        var entry = tape.get_entry(i)
        if entry.type_tag() == TAPE_STRING:
            var s = tape.get_string(entry.payload())
            print("  Found string:", s)

    print("  OK")
    return True


fn test_benchmark() raises -> Bool:
    """Benchmark tape parser throughput."""
    print("\nBenchmarking tape parser...")

    # Generate test JSON
    var json = String('{"data": [')
    for i in range(1000):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "name": "item_' + String(i) + '"}'
    json += "]}"

    print("  JSON size:", len(json), "bytes")

    # Run benchmark
    var throughput = benchmark_tape_parse(json, 100)
    print("  Throughput:", throughput, "MB/s")

    if throughput < 10.0:
        print("  WARNING: Throughput below 10 MB/s")

    print("  OK")
    return True


fn main() raises:
    print("=" * 70)
    print("Tape-Based JSON Parser Tests")
    print("=" * 70)

    var all_passed = True

    all_passed = test_simple_object() and all_passed
    all_passed = test_simple_array() and all_passed
    all_passed = test_nested_structure() and all_passed
    all_passed = test_literals() and all_passed
    all_passed = test_numbers() and all_passed
    all_passed = test_string_extraction() and all_passed
    all_passed = test_benchmark() and all_passed

    print("\n" + "=" * 70)
    if all_passed:
        print("All tape parser tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 70)
