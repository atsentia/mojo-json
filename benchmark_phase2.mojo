"""
Phase 2 Performance Benchmark: Value Position Indexing

Compares v1 (original) vs v2 (value-indexed) tape parsers.

Key optimization: v2 pre-computes number/literal positions during
structural scanning, eliminating re-scanning in Stage 2.

Expected improvements:
- Flat integer arrays: 3-5x faster
- Mixed content: 1.5-2x faster
- String-heavy content: Similar or slightly faster

Run:
    cd mojo-json
    mojo run benchmark_phase2.mojo
"""

from src.tape_parser import parse_to_tape, parse_to_tape_v2
from src.structural_index import build_structural_index, build_structural_index_v2
from time import perf_counter_ns


# =============================================================================
# Test Data Generators
# =============================================================================


fn generate_flat_array(count: Int) -> String:
    """Generate flat array of integers: [1, 2, 3, ...]."""
    var json = String("[")
    for i in range(count):
        if i > 0:
            json += ", "
        json += String(i)
    json += "]"
    return json


fn generate_float_array(count: Int) -> String:
    """Generate array of floats: [1.1, 2.2, 3.3, ...]."""
    var json = String("[")
    for i in range(count):
        if i > 0:
            json += ", "
        json += String(Float64(i) + 0.1)
    json += "]"
    return json


fn generate_object_array(count: Int) -> String:
    """Generate array of objects with numeric values."""
    var json = String("[")
    for i in range(count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "score": ' + String(i * 10) + ', "active": true}'
    json += "]"
    return json


fn generate_mixed_json(obj_count: Int, arr_size: Int) -> String:
    """Generate realistic JSON with mixed content."""
    var json = String('{"data": [')
    for i in range(obj_count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i)
        json += ', "name": "User ' + String(i) + '"'
        json += ', "active": true'
        json += ', "score": ' + String(i * 10)
        json += ', "tags": ['
        for j in range(arr_size):
            if j > 0:
                json += ", "
            json += '"tag_' + String(j) + '"'
        json += ']}'
    json += '], "count": ' + String(obj_count)
    json += ', "success": true}'
    return json


# =============================================================================
# Benchmark Functions
# =============================================================================


fn benchmark_v1(data: String, iterations: Int) -> Float64:
    """Benchmark original parser. Returns MB/s."""
    var size = len(data)

    # Warmup
    for _ in range(5):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass

    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    return Float64(size * iterations) / (1024.0 * 1024.0) / seconds


fn benchmark_v2(data: String, iterations: Int) -> Float64:
    """Benchmark v2 parser with value indexing. Returns MB/s."""
    var size = len(data)

    # Warmup
    for _ in range(5):
        try:
            var tape = parse_to_tape_v2(data)
            _ = tape
        except:
            pass

    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape_v2(data)
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    return Float64(size * iterations) / (1024.0 * 1024.0) / seconds


fn benchmark_stage1_v1(data: String, iterations: Int) -> Float64:
    """Benchmark original structural index. Returns MB/s."""
    var size = len(data)

    for _ in range(5):
        var idx = build_structural_index(data)
        _ = idx

    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    return Float64(size * iterations) / (1024.0 * 1024.0) / seconds


fn benchmark_stage1_v2(data: String, iterations: Int) -> Float64:
    """Benchmark v2 structural index with value tracking. Returns MB/s."""
    var size = len(data)

    for _ in range(5):
        var idx = build_structural_index_v2(data)
        _ = idx

    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v2(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    return Float64(size * iterations) / (1024.0 * 1024.0) / seconds


fn format_size(bytes: Int) -> String:
    """Format byte size for display."""
    if bytes >= 1024 * 1024:
        return String(Float64(bytes) / (1024.0 * 1024.0))[:5] + " MB"
    elif bytes >= 1024:
        return String(Float64(bytes) / 1024.0)[:5] + " KB"
    else:
        return String(bytes) + " B"


fn main():
    print("=" * 80)
    print("PHASE 2 BENCHMARK: Value Position Indexing")
    print("=" * 80)
    print("Machine: Apple M2 Max (32GB RAM)")
    print("Date: 2026-01-04")
    print("")

    alias ITERATIONS = 100

    # =========================================================================
    # Test 1: Flat Integer Array (worst case for v1)
    # =========================================================================
    print("Test 1: Flat Integer Arrays")
    print("-" * 80)
    print("Size".ljust(15), "v1 Parse".ljust(12), "v2 Parse".ljust(12), "Speedup".ljust(10), "v1 Stage1".ljust(12), "v2 Stage1")
    print("-" * 80)

    var int_counts = List[Int](1000, 5000, 10000)
    for i in range(len(int_counts)):
        var count = int_counts[i]
        var json = generate_flat_array(count)
        var size_str = format_size(len(json))

        var v1 = benchmark_v1(json, ITERATIONS)
        var v2 = benchmark_v2(json, ITERATIONS)
        var s1_v1 = benchmark_stage1_v1(json, ITERATIONS)
        var s1_v2 = benchmark_stage1_v2(json, ITERATIONS)
        var speedup = v2 / v1

        print(
            size_str.ljust(15),
            (String(Int(v1)) + " MB/s").ljust(12),
            (String(Int(v2)) + " MB/s").ljust(12),
            (String(speedup)[:4] + "x").ljust(10),
            (String(Int(s1_v1)) + " MB/s").ljust(12),
            String(Int(s1_v2)) + " MB/s"
        )

    print("")

    # =========================================================================
    # Test 2: Float Array
    # =========================================================================
    print("Test 2: Float Arrays")
    print("-" * 80)

    var float_counts = List[Int](1000, 5000, 10000)
    for i in range(len(float_counts)):
        var count = float_counts[i]
        var json = generate_float_array(count)
        var size_str = format_size(len(json))

        var v1 = benchmark_v1(json, ITERATIONS)
        var v2 = benchmark_v2(json, ITERATIONS)
        var s1_v1 = benchmark_stage1_v1(json, ITERATIONS)
        var s1_v2 = benchmark_stage1_v2(json, ITERATIONS)
        var speedup = v2 / v1

        print(
            size_str.ljust(15),
            (String(Int(v1)) + " MB/s").ljust(12),
            (String(Int(v2)) + " MB/s").ljust(12),
            (String(speedup)[:4] + "x").ljust(10),
            (String(Int(s1_v1)) + " MB/s").ljust(12),
            String(Int(s1_v2)) + " MB/s"
        )

    print("")

    # =========================================================================
    # Test 3: Object Array (mixed numbers and strings)
    # =========================================================================
    print("Test 3: Object Arrays (numbers + strings)")
    print("-" * 80)

    var obj_counts = List[Int](500, 1000, 2000)
    for i in range(len(obj_counts)):
        var count = obj_counts[i]
        var json = generate_object_array(count)
        var size_str = format_size(len(json))

        var v1 = benchmark_v1(json, ITERATIONS)
        var v2 = benchmark_v2(json, ITERATIONS)
        var speedup = v2 / v1

        print(
            size_str.ljust(15),
            (String(Int(v1)) + " MB/s").ljust(12),
            (String(Int(v2)) + " MB/s").ljust(12),
            (String(speedup)[:4] + "x").ljust(10)
        )

    print("")

    # =========================================================================
    # Test 4: Mixed Content (production-like)
    # =========================================================================
    print("Test 4: Mixed Content (production-like)")
    print("-" * 80)

    var mixed_counts = List[Int](100, 300, 500)
    for i in range(len(mixed_counts)):
        var count = mixed_counts[i]
        var json = generate_mixed_json(count, 5)
        var size_str = format_size(len(json))

        var v1 = benchmark_v1(json, ITERATIONS)
        var v2 = benchmark_v2(json, ITERATIONS)
        var speedup = v2 / v1

        print(
            size_str.ljust(15),
            (String(Int(v1)) + " MB/s").ljust(12),
            (String(Int(v2)) + " MB/s").ljust(12),
            (String(speedup)[:4] + "x").ljust(10)
        )

    print("")

    # =========================================================================
    # Summary
    # =========================================================================
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print("")
    print("Phase 2 Optimization: Value Position Indexing")
    print("  - Pre-computes number/literal positions during Stage 1")
    print("  - Eliminates re-scanning in Stage 2")
    print("  - Greatest benefit for number-heavy JSON")
    print("")
    print("Targets:")
    print("  - Flat integer arrays: 3-5x improvement")
    print("  - Mixed content: 1.5-2x improvement")
    print("  - String-heavy: Minimal overhead")
    print("")
    print("Next phase: GPU acceleration for files > 100KB")
    print("=" * 80)
