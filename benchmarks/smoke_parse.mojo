"""Focused parsing smoke test.

Tests parsing with different JSON patterns to isolate bottlenecks.
"""

from time import perf_counter_ns
from mojo_json import parse


alias ITERATIONS = 1000


fn main() raises:
    print("=" * 70)
    print("JSON Parsing Pattern Analysis")
    print("=" * 70)
    print("Iterations:", ITERATIONS)
    print()

    # Test 1: Simple values
    print("1. Simple Values (no nesting):")
    print("-" * 70)

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("null")
        _ = r
    var null_time = perf_counter_ns() - start
    print("  null:              ", Float64(null_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("true")
        _ = r
    var bool_time = perf_counter_ns() - start
    print("  true:              ", Float64(bool_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("12345")
        _ = r
    var int_time = perf_counter_ns() - start
    print("  12345 (int):       ", Float64(int_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("123.456")
        _ = r
    var float_time = perf_counter_ns() - start
    print("  123.456 (float):   ", Float64(float_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse('"hello world"')
        _ = r
    var str_time = perf_counter_ns() - start
    print("  \"hello world\":     ", Float64(str_time) / Float64(ITERATIONS) / 1000, "μs")

    # Test 2: Simple containers
    print("\n2. Simple Containers:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("[]")
        _ = r
    var empty_arr_time = perf_counter_ns() - start
    print("  []:                ", Float64(empty_arr_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("{}")
        _ = r
    var empty_obj_time = perf_counter_ns() - start
    print("  {}:                ", Float64(empty_obj_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse("[1,2,3,4,5]")
        _ = r
    var arr5_time = perf_counter_ns() - start
    print("  [1,2,3,4,5]:       ", Float64(arr5_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse('{"a":1}')
        _ = r
    var obj1_time = perf_counter_ns() - start
    print("  {\"a\":1}:           ", Float64(obj1_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse('{"a":1,"b":2,"c":3}')
        _ = r
    var obj3_time = perf_counter_ns() - start
    print("  {\"a\":1,\"b\":2,\"c\":3}:", Float64(obj3_time) / Float64(ITERATIONS) / 1000, "μs")

    # Test 3: Nesting
    print("\n3. Nested Structures:")
    print("-" * 70)

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse('{"a":{"b":{"c":1}}}')
        _ = r
    var nested3_time = perf_counter_ns() - start
    print("  3-level nesting:   ", Float64(nested3_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse('[[[1]]]')
        _ = r
    var arr_nested3 = perf_counter_ns() - start
    print("  [[[1]]]:           ", Float64(arr_nested3) / Float64(ITERATIONS) / 1000, "μs")

    # Test 4: Strings with content
    print("\n4. String Sizes:")
    print("-" * 70)

    var short_str = '"' + "x" * 10 + '"'
    var medium_str = '"' + "x" * 100 + '"'
    var long_str = '"' + "x" * 1000 + '"'

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse(short_str)
        _ = r
    var short_time = perf_counter_ns() - start
    print("  10-char string:    ", Float64(short_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse(medium_str)
        _ = r
    var medium_time = perf_counter_ns() - start
    print("  100-char string:   ", Float64(medium_time) / Float64(ITERATIONS) / 1000, "μs")

    start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var r = parse(long_str)
        _ = r
    var long_time = perf_counter_ns() - start
    print("  1000-char string:  ", Float64(long_time) / Float64(ITERATIONS) / 1000, "μs")

    # Analysis
    print("\n" + "=" * 70)
    print("COST ANALYSIS:")
    print("=" * 70)

    var base_cost = Float64(null_time) / Float64(ITERATIONS) / 1000
    print("Base parsing cost (null):", base_cost, "μs")
    print()

    print("Incremental costs:")
    print("  Bool vs null:     +", (Float64(bool_time) - Float64(null_time)) / Float64(ITERATIONS) / 1000, "μs")
    print("  Int vs null:      +", (Float64(int_time) - Float64(null_time)) / Float64(ITERATIONS) / 1000, "μs")
    print("  Float vs int:     +", (Float64(float_time) - Float64(int_time)) / Float64(ITERATIONS) / 1000, "μs")
    print("  String vs null:   +", (Float64(str_time) - Float64(null_time)) / Float64(ITERATIONS) / 1000, "μs")
    print("  Empty obj vs null:+", (Float64(empty_obj_time) - Float64(null_time)) / Float64(ITERATIONS) / 1000, "μs")
    print("  Per key in obj:   +", (Float64(obj3_time) - Float64(obj1_time)) / 2 / Float64(ITERATIONS) / 1000, "μs")
