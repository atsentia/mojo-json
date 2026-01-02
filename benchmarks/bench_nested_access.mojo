"""Nested Access Benchmark.

Tests zero-copy nested access with LazyJsonValue.
Compares deep key access patterns between lazy and eager parsing.

Usage:
    cd mojo-json
    mojo run -I . benchmarks/bench_nested_access.mojo
"""

from time import perf_counter_ns
from src import parse, parse_lazy, JsonValue


alias WARMUP = 5
alias ITERATIONS = 1000


fn generate_deep_json(depth: Int) -> String:
    """Generate JSON with nested objects."""
    var result = String("")
    for i in range(depth):
        result += '{"level' + String(i) + '": '
    result += '"deepValue"'
    for _ in range(depth):
        result += "}"
    return result


fn generate_wide_json(width: Int) -> String:
    """Generate JSON with many keys but only one needed."""
    var result = String('{"target": "found"')
    for i in range(width):
        result += ', "key' + String(i) + '": "value' + String(i) + '"'
    result += "}"
    return result


fn main() raises:
    print("=" * 70)
    print("mojo-json Nested Access Benchmark")
    print("=" * 70)
    print()

    # Test 1: Deep nested access
    print("Test 1: Deep Nested Access")
    print("-" * 70)

    for depth in List(5, 10, 20, 50):
        var json = generate_deep_json(depth)

        # Warmup
        for _ in range(WARMUP):
            var lazy = parse_lazy(json)
            var v = lazy.copy()
            for i in range(depth):
                v = v["level" + String(i)]
            _ = v.as_string()

        # Benchmark lazy
        var lazy_start = perf_counter_ns()
        for _ in range(ITERATIONS):
            var lazy = parse_lazy(json)
            var v = lazy.copy()
            for i in range(depth):
                v = v["level" + String(i)]
            _ = v.as_string()
        var lazy_ns = perf_counter_ns() - lazy_start

        # Benchmark eager
        var eager_start = perf_counter_ns()
        for _ in range(ITERATIONS):
            var value = parse(json)
            var v = value.copy()
            for i in range(depth):
                v = v["level" + String(i)].copy()
            _ = v.as_string()
        var eager_ns = perf_counter_ns() - eager_start

        var lazy_us = Float64(lazy_ns) / Float64(ITERATIONS) / 1000.0
        var eager_us = Float64(eager_ns) / Float64(ITERATIONS) / 1000.0
        var speedup = eager_us / lazy_us

        print(
            "  Depth",
            String(depth).rjust(3),
            ":",
            "lazy",
            String(Int(lazy_us)).rjust(5),
            "µs, eager",
            String(Int(eager_us)).rjust(5),
            "µs, speedup",
            String(speedup)[:4] + "x"
        )

    print()

    # Test 2: Wide object, single key access
    print("Test 2: Wide Object, Single Key Access")
    print("-" * 70)

    for width in List(10, 100, 1000, 5000):
        var json = generate_wide_json(width)

        # Warmup
        for _ in range(WARMUP):
            var lazy = parse_lazy(json)
            _ = lazy["target"].as_string()

        # Benchmark lazy (early exit)
        var lazy_start = perf_counter_ns()
        for _ in range(ITERATIONS):
            var lazy = parse_lazy(json)
            _ = lazy["target"].as_string()
        var lazy_ns = perf_counter_ns() - lazy_start

        # Benchmark eager (must parse all)
        var eager_start = perf_counter_ns()
        for _ in range(ITERATIONS):
            var value = parse(json)
            _ = value["target"].as_string()
        var eager_ns = perf_counter_ns() - eager_start

        var lazy_us = Float64(lazy_ns) / Float64(ITERATIONS) / 1000.0
        var eager_us = Float64(eager_ns) / Float64(ITERATIONS) / 1000.0
        var speedup = eager_us / lazy_us

        print(
            "  Width",
            String(width).rjust(5),
            ":",
            "lazy",
            String(Int(lazy_us)).rjust(5),
            "µs, eager",
            String(Int(eager_us)).rjust(5),
            "µs, speedup",
            String(speedup)[:4] + "x"
        )

    print()
    print("=" * 70)
    print("SUMMARY:")
    print("  - Lazy parsing is faster for selective access patterns")
    print("  - Zero-copy nested access shares tape via ArcPointer")
    print("  - Best used when accessing subset of large JSON")
    print("=" * 70)
