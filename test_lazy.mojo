"""Test LazyJsonValue functional API with SIMD string matching."""

from src.tape_parser import (
    parse_to_tape_v2,
    tape_get_object_value,
    tape_get_array_element,
    tape_get_string_value,
    tape_get_int_value,
    tape_is_object,
    tape_is_array,
    tape_is_string,
    tape_skip_value,
    tape_array_len,
    tape_array_iter_start,
    tape_array_iter_end,
    tape_array_iter_has_next,
    TAPE_END_ARRAY,
)
from time import perf_counter_ns


fn test_functional_api():
    """Test the low-level functional API."""
    print("Testing functional tape API...")
    var json = '{"name": "Alice", "age": 30, "city": "New York"}'
    try:
        var tape = parse_to_tape_v2(json)
        print("  Tape size:", len(tape))

        # Use functional API
        var is_obj = tape_is_object(tape, 1)
        print("  Is object:", is_obj)

        var name_idx = tape_get_object_value(tape, 1, "name")
        print("  name index:", name_idx)
        if name_idx > 0:
            var name = tape_get_string_value(tape, name_idx)
            print("  name:", name)

        var age_idx = tape_get_object_value(tape, 1, "age")
        print("  age index:", age_idx)
        if age_idx > 0:
            var age = tape_get_int_value(tape, age_idx)
            print("  age:", age)

        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn test_object_access():
    print("\nTesting object access via functional API...")
    var json = '{"name": "Alice", "age": 30, "city": "New York", "active": true}'
    try:
        var tape = parse_to_tape_v2(json)
        print("  Is object:", tape_is_object(tape, 1))

        var name_idx = tape_get_object_value(tape, 1, "name")
        if name_idx > 0:
            print("  name:", tape_get_string_value(tape, name_idx))

        var age_idx = tape_get_object_value(tape, 1, "age")
        if age_idx > 0:
            print("  age:", tape_get_int_value(tape, age_idx))

        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn test_array_access():
    print("\nTesting array access...")
    var json = "[1, 2, 3, 4, 5]"
    try:
        var tape = parse_to_tape_v2(json)
        print("  Is array:", tape_is_array(tape, 1))

        var first_idx = tape_get_array_element(tape, 1, 0)
        if first_idx > 0:
            print("  First:", tape_get_int_value(tape, first_idx))

        var last_idx = tape_get_array_element(tape, 1, 4)
        if last_idx > 0:
            print("  Last:", tape_get_int_value(tape, last_idx))

        print("  Array length:", tape_array_len(tape, 1))
        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn test_array_iteration():
    print("\nTesting array iteration...")
    var json = "[10, 20, 30]"
    try:
        var tape = parse_to_tape_v2(json)
        print("  Iterating:")

        var pos = tape_array_iter_start(tape, 1)
        var end_idx = tape_array_iter_end(tape, 1)
        var count = 0

        while tape_array_iter_has_next(tape, pos, end_idx):
            var value = tape_get_int_value(tape, pos)
            print("    Item:", value)
            pos = tape_skip_value(tape, pos)
            count += 1

        print("  Total items:", count)
        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn test_nested_access():
    print("\nTesting nested access...")
    var json = '{"users": [{"name": "Alice"}, {"name": "Bob"}], "count": 2}'
    try:
        var tape = parse_to_tape_v2(json)

        # Get users array
        var users_idx = tape_get_object_value(tape, 1, "users")
        print("  users is array:", tape_is_array(tape, users_idx))

        # Get first user
        var first_user_idx = tape_get_array_element(tape, users_idx, 0)

        # Get first user's name
        var first_name_idx = tape_get_object_value(tape, first_user_idx, "name")
        print("  First user name:", tape_get_string_value(tape, first_name_idx))

        # Get count
        var count_idx = tape_get_object_value(tape, 1, "count")
        print("  count:", tape_get_int_value(tape, count_idx))

        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn test_simd_string_comparison():
    """Test SIMD string matching with various key lengths."""
    print("\nTesting SIMD string matching performance...")
    var json = '{"short": 1, "medium_length_key": 2, "very_long_key_name_that_exceeds_16_bytes": 3}'
    try:
        var tape = parse_to_tape_v2(json)

        # Short key (< 16 bytes, scalar path)
        var short_idx = tape_get_object_value(tape, 1, "short")
        print("  short key found:", short_idx > 0)

        # Medium key (around 16 bytes, one SIMD chunk)
        var medium_idx = tape_get_object_value(tape, 1, "medium_length_key")
        print("  medium key found:", medium_idx > 0)

        # Long key (> 16 bytes, multiple SIMD chunks)
        var long_idx = tape_get_object_value(tape, 1, "very_long_key_name_that_exceeds_16_bytes")
        print("  long key found:", long_idx > 0)

        print("  PASSED")
    except e:
        print("  FAILED:", e)


fn benchmark_key_lookup():
    """Benchmark key lookup performance with SIMD."""
    print("\nBenchmarking key lookup performance...")
    var json = '{"key1": 1, "key2": 2, "key3": 3, "key4": 4, "key5": 5, "key6": 6, "key7": 7, "key8": 8, "key9": 9, "key10": 10}'
    try:
        var tape = parse_to_tape_v2(json)
        alias ITERATIONS = 100000

        var start = perf_counter_ns()
        for _ in range(ITERATIONS):
            var idx = tape_get_object_value(tape, 1, "key10")
            _ = idx
        var elapsed = perf_counter_ns() - start

        var ns_per_op = Float64(elapsed) / Float64(ITERATIONS)
        print("  Lookups:", ITERATIONS)
        print("  Time per lookup:", ns_per_op, "ns")
        print("  Lookups per second:", Int(1_000_000_000.0 / ns_per_op))
    except e:
        print("  FAILED:", e)


fn main():
    print("=" * 60)
    print("Lazy JSON Functional API Test Suite (M2 Max)")
    print("=" * 60)
    test_functional_api()
    test_object_access()
    test_array_access()
    test_array_iteration()
    test_nested_access()
    test_simd_string_comparison()
    benchmark_key_lookup()
    print("\nAll tests complete")
