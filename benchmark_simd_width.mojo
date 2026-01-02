"""Benchmark 16-byte vs 32-byte SIMD for structural indexing."""

from src.structural_index import (
    build_structural_index,
    build_structural_index_32,
)
from time import perf_counter_ns


fn generate_json(obj_count: Int) -> String:
    """Generate test JSON."""
    var json = String('{"data": [')
    for i in range(obj_count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "name": "User_' + String(i) + '"}'
    json += "]}"
    return json


fn benchmark_16(data: String, iterations: Int) -> Float64:
    """Benchmark 16-byte SIMD."""
    var size = len(data)

    # Warmup
    for _ in range(10):
        var idx = build_structural_index(data)
        _ = idx

    # Timed
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1e9
    var total_mb = Float64(size * iterations) / (1024.0 * 1024.0)
    return total_mb / seconds


fn benchmark_32(data: String, iterations: Int) -> Float64:
    """Benchmark 32-byte SIMD."""
    var size = len(data)

    # Warmup
    for _ in range(10):
        var idx = build_structural_index_32(data)
        _ = idx

    # Timed
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_32(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1e9
    var total_mb = Float64(size * iterations) / (1024.0 * 1024.0)
    return total_mb / seconds


fn main():
    print("=" * 70)
    print("SIMD Width Comparison: 16-byte vs 32-byte")
    print("=" * 70)
    print("")

    var sizes = List[Int](100, 500, 1000, 2000)

    for i in range(len(sizes)):
        var obj_count = sizes[i]
        var json = generate_json(obj_count)
        var size_kb = Float64(len(json)) / 1024.0

        print("JSON size:", size_kb, "KB (", obj_count, "objects)")

        # Verify both produce same results
        var idx_16 = build_structural_index(json)
        var idx_32 = build_structural_index_32(json)

        if len(idx_16) != len(idx_32):
            print("  ERROR: Different struct counts!", len(idx_16), "vs", len(idx_32))
            continue

        # Benchmark
        var iterations = 200 if obj_count < 1000 else 100

        var throughput_16 = benchmark_16(json, iterations)
        var throughput_32 = benchmark_32(json, iterations)

        var improvement = (throughput_32 / throughput_16 - 1.0) * 100

        print("  16-byte SIMD:", throughput_16, "MB/s")
        print("  32-byte SIMD:", throughput_32, "MB/s")
        print("  Improvement: ", improvement, "%")
        print("")

    print("=" * 70)
