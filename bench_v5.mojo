"""
Benchmark: V5 Prefix-XOR String Tracking

Tests the simdjson-inspired prefix-XOR algorithm for string boundary detection.
"""

from time import perf_counter_ns
from src.structural_index import (
    build_structural_index,
    build_structural_index_v2,
    build_structural_index_v5,
)


fn run_benchmark(name: String, data: String):
    """Run all benchmarks on given data."""
    var size_kb = len(data) / 1024.0

    print("\n" + "=" * 60)
    print("File:", name, "(" + String(Int(size_kb)) + " KB)")
    print("=" * 60)

    var iterations = 100
    if len(data) > 100000:
        iterations = 50
    if len(data) > 500000:
        iterations = 20

    # V1 (baseline)
    var v1_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(data)
        _ = idx
    var v1_elapsed = Float64(perf_counter_ns() - v1_start) / 1_000_000_000.0
    var v1_mbps = Float64(len(data) * iterations) / (1024.0 * 1024.0) / v1_elapsed
    print("V1 (baseline):    " + String(Int(v1_mbps)) + " MB/s")

    # V2
    var v2_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v2(data)
        _ = idx
    var v2_elapsed = Float64(perf_counter_ns() - v2_start) / 1_000_000_000.0
    var v2_mbps = Float64(len(data) * iterations) / (1024.0 * 1024.0) / v2_elapsed
    print("V2 (value spans): " + String(Int(v2_mbps)) + " MB/s")

    # V5 (prefix-XOR)
    var v5_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v5(data)
        _ = idx
    var v5_elapsed = Float64(perf_counter_ns() - v5_start) / 1_000_000_000.0
    var v5_mbps = Float64(len(data) * iterations) / (1024.0 * 1024.0) / v5_elapsed
    print("V5 (prefix-XOR):  " + String(Int(v5_mbps)) + " MB/s")

    # Speedup
    var speedup = v5_mbps / v1_mbps
    print("\nV5 vs V1: " + String(speedup)[:4] + "x")


fn main() raises:
    print("=" * 60)
    print("Structural Index V5 (Prefix-XOR) Benchmark")
    print("=" * 60)
    print("\nTesting simdjson-inspired prefix-XOR string tracking")

    # Test with sample JSON
    var sample_json = """
    {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "id": "1",
                "properties": {"name": "Alaska", "density": 1.264},
                "geometry": {"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 1]]]}
            },
            {
                "type": "Feature",
                "id": "2",
                "properties": {"name": "California", "density": 251.3},
                "geometry": {"type": "Polygon", "coordinates": [[[2, 0], [3, 0], [3, 1], [2, 1]]]}
            }
        ],
        "metadata": {
            "source": "census",
            "year": 2023,
            "version": "1.0.0"
        }
    }
    """

    run_benchmark("sample.json", sample_json)

    # Try to load benchmark files
    try:
        var f1 = open("benchmarks/data/canada.json", "r")
        var canada = f1.read()
        f1.close()
        run_benchmark("canada.json", canada)
    except:
        print("\n[canada.json not found]")

    try:
        var f2 = open("benchmarks/data/twitter.json", "r")
        var twitter = f2.read()
        f2.close()
        run_benchmark("twitter.json", twitter)
    except:
        print("\n[twitter.json not found]")

    print("\n" + "=" * 60)
    print("Benchmark Complete")
    print("=" * 60)
