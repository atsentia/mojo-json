"""Smoke tests to identify performance bottlenecks.

Isolates different operations to find where time is spent.
"""

from time import perf_counter_ns
from collections import Dict, List


alias ITERATIONS = 10000


fn benchmark[func: fn() -> None](name: String, iterations: Int):
    """Benchmark a function."""
    var start = perf_counter_ns()
    for _ in range(iterations):
        func()
    var end = perf_counter_ns()
    var total_ms = Float64(end - start) / 1_000_000.0
    var per_iter = total_ms / Float64(iterations) * 1000  # microseconds
    print(name.ljust(40), total_ms, "ms total,", per_iter, "μs/iter")


fn main() raises:
    print("=" * 70)
    print("Smoke Tests: Isolating Performance Bottlenecks")
    print("=" * 70)
    print("Iterations:", ITERATIONS)
    print()

    # Test data
    var test_string = "hello world this is a test string with some content"
    var n = len(test_string)

    # Test 1: String slicing (should be fast)
    print("\n1. String Operations:")
    print("-" * 70)

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var s = test_string[0:10]
        _ = s
    var slice_time = perf_counter_ns() - start
    print("  Slice [0:10]:", Float64(slice_time) / 1_000_000.0, "ms")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var s = test_string + test_string
        _ = s
    var concat_time = perf_counter_ns() - start
    print("  Concat 2x50:", Float64(concat_time) / 1_000_000.0, "ms")

    # Test 2: Dict operations (potential bottleneck)
    print("\n2. Dict Operations:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var d = Dict[String, Int]()
        d["key1"] = 1
        d["key2"] = 2
        d["key3"] = 3
        _ = d
    var dict_create = perf_counter_ns() - start
    print("  Create + 3 inserts:", Float64(dict_create) / 1_000_000.0, "ms")

    var lookup_dict = Dict[String, Int]()
    lookup_dict["key1"] = 1
    lookup_dict["key2"] = 2
    lookup_dict["key3"] = 3

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var v = lookup_dict["key1"]
        _ = v
    var dict_lookup = perf_counter_ns() - start
    print("  Lookup:", Float64(dict_lookup) / 1_000_000.0, "ms")

    # Test 3: List operations
    print("\n3. List Operations:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var lst = List[Int]()
        for i in range(10):
            lst.append(i)
        _ = lst
    var list_create = perf_counter_ns() - start
    print("  Create + 10 appends:", Float64(list_create) / 1_000_000.0, "ms")

    # Test 4: Character access
    print("\n4. Character Access:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var c = test_string[25]
        _ = c
    var char_access = perf_counter_ns() - start
    print("  Single char access:", Float64(char_access) / 1_000_000.0, "ms")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var c = ord(test_string[25])
        _ = c
    var ord_time = perf_counter_ns() - start
    print("  ord() call:", Float64(ord_time) / 1_000_000.0, "ms")

    # Test 5: Comparison operations
    print("\n5. Comparison Operations:")
    print("-" * 70)

    var char = test_string[0]
    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var eq = char == 'h'
        _ = eq
    var char_cmp = perf_counter_ns() - start
    print("  Char equality:", Float64(char_cmp) / 1_000_000.0, "ms")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var eq = test_string == "hello"
        _ = eq
    var str_cmp = perf_counter_ns() - start
    print("  String equality:", Float64(str_cmp) / 1_000_000.0, "ms")

    # Test 6: Int/Float parsing
    print("\n6. Number Parsing:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var i = atol("12345")
        _ = i
    var atol_time = perf_counter_ns() - start
    print("  atol('12345'):", Float64(atol_time) / 1_000_000.0, "ms")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var f = atof("123.456")
        _ = f
    var atof_time = perf_counter_ns() - start
    print("  atof('123.456'):", Float64(atof_time) / 1_000_000.0, "ms")

    # Test 7: Loop overhead
    print("\n7. Loop & Function Overhead:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS * 100):
        pass
    var loop_time = perf_counter_ns() - start
    print("  Empty loop (100x):", Float64(loop_time) / 1_000_000.0, "ms")

    print("\n" + "=" * 70)
    print("ANALYSIS:")
    print("=" * 70)

    # Calculate estimated parsing cost for 1KB file (~1000 chars)
    var per_char_ms = Float64(char_access) / Float64(ITERATIONS) / 1_000.0
    var per_ord_ms = Float64(ord_time) / Float64(ITERATIONS) / 1_000.0
    var per_dict_ms = Float64(dict_create) / Float64(ITERATIONS) / 1_000.0

    print("Per operation (estimated for 1KB = ~1000 chars):")
    print("  Char access:", per_char_ms * 1000, "ms")
    print("  ord() calls:", per_ord_ms * 1000, "ms")
    print("  Dict creates:", per_dict_ms * 10, "ms (10 objects)")

    # If parsing 1KB takes 0.2ms at 3MB/s actual, breakdown:
    var actual_1kb_ms = 0.2422  # From benchmark
    print()
    print("Actual 1KB parse time:", actual_1kb_ms, "ms")
    print("Expected time breakdown:")
    print("  Character scan:", per_char_ms * 1000, "ms")
    print("  Remaining (overhead):", actual_1kb_ms - per_char_ms * 1000, "ms")
