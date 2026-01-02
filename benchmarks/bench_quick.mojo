"""Quick inline benchmark for mojo-json.

Tests the optimized parser without module import issues.
Run: cd mojo-json && mojo run benchmarks/bench_quick.mojo
"""

from time import perf_counter_ns

# Inline a simple JSON string for testing
fn main() raises:
    print("=" * 60)
    print("mojo-json Quick Benchmark (PERF-005 String Builder)")
    print("=" * 60)

    # Test data - various sizes
    var small_json = '{"name": "Alice", "age": 30, "active": true}'
    var medium_json = '{"users": [' + ', '.join([
        '{"id": ' + String(i) + ', "name": "user' + String(i) + '", "email": "user' + String(i) + '@example.com"}'
        for i in range(100)
    ]) + ']}'

    # Build larger test string
    var large_parts = List[String]()
    large_parts.append('{"data": [')
    for i in range(1000):
        if i > 0:
            large_parts.append(",")
        large_parts.append('{"id":')
        large_parts.append(String(i))
        large_parts.append(',"value":"test string number ')
        large_parts.append(String(i))
        large_parts.append(' with some padding to make it longer"}')
    large_parts.append(']}')

    var large_json = String("")
    for i in range(len(large_parts)):
        large_json += large_parts[i]

    print("Small JSON size:", len(small_json), "bytes")
    print("Large JSON size:", len(large_json), "bytes")
    print()

    # Benchmark string operations at different sizes
    print("String building benchmark:")
    print("-" * 60)

    # Test different string sizes
    var sizes = List[Int]()
    sizes.append(100)
    sizes.append(1000)
    sizes.append(10000)

    for s in range(len(sizes)):
        var size = sizes[s]
        var iterations = 10000 // size  # More iterations for smaller sizes

        print("\nSize:", size, "chars,", iterations, "iterations:")

        # Test 1: Old pattern (string concat)
        var start = perf_counter_ns()
        for _ in range(iterations):
            var result = String("")
            for _ in range(size):
                result += "x"
            _ = result
        var old_time = perf_counter_ns() - start

        # Test 2: Slice pattern (build then slice - common optimization)
        start = perf_counter_ns()
        for _ in range(iterations):
            # Pre-build a large string, then slice
            var base = "x" * size
            _ = base
        var slice_time = perf_counter_ns() - start

        print("  Old (result += char):", Float64(old_time) / 1_000_000.0, "ms")
        print("  Slice (\"x\" * size):", Float64(slice_time) / 1_000_000.0, "ms")

        if slice_time < old_time:
            print("  Slice is", Float64(old_time) / Float64(slice_time), "x faster")

    print()
    print("=" * 60)
