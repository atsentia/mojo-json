"""
Benchmark: On-Demand vs Tape Parsing

Compares performance of:
- parse_on_demand(): Stage 1 only, values parsed on access
- parse_to_tape_v2(): Full Stage 1 + Stage 2

Target: On-Demand should be 1.5-2x faster for sparse field access.
"""

from time import perf_counter_ns
from src.tape_parser import (
    parse_on_demand,
    parse_to_tape_v2,
    tape_get_pointer_string,
    tape_get_pointer_int,
    tape_get_pointer_float,
)


fn benchmark_on_demand(data: String, iterations: Int) -> Float64:
    """Benchmark on-demand parsing with sparse field access."""
    var size = len(data)

    # Warmup
    for _ in range(10):
        var doc = parse_on_demand(data)
        _ = doc

    # Timed iterations - parsing + sparse access
    var start = perf_counter_ns()
    for _ in range(iterations):
        var doc = parse_on_demand(data)
        # Sparse access: just a few fields
        var root = doc.root()
        if root.is_object():
            # Try to access a few fields
            var val1 = root["type"]
            var val2 = root["features"]
            if val2.is_array():
                var first = val2[0]
                _ = first
            _ = val1
        _ = doc

    var elapsed = perf_counter_ns() - start
    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


fn benchmark_tape_v2(data: String, iterations: Int) -> Float64:
    """Benchmark tape V2 parsing with same field access pattern."""
    var size = len(data)

    # Warmup
    for _ in range(10):
        try:
            var tape = parse_to_tape_v2(data)
            _ = tape
        except:
            pass

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape_v2(data)
            # Same access pattern via JSON Pointer
            var val1 = tape_get_pointer_string(tape, "/type")
            var val2 = tape_get_pointer_string(tape, "/features/0/type")
            _ = val1
            _ = val2
            _ = tape
        except:
            pass

    var elapsed = perf_counter_ns() - start
    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


fn benchmark_stage1_only(data: String, iterations: Int) -> Float64:
    """Benchmark Stage 1 only (structural index) for reference."""
    from src.structural_index import build_structural_index_v2

    var size = len(data)

    # Warmup
    for _ in range(10):
        var idx = build_structural_index_v2(data)
        _ = idx

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v2(data)
        _ = idx

    var elapsed = perf_counter_ns() - start
    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


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

    # Stage 1 only (reference)
    var stage1_mbps = benchmark_stage1_only(data, iterations)
    print("\nStage 1 only (reference): " + String(Int(stage1_mbps)) + " MB/s")

    # On-Demand
    var on_demand_mbps = benchmark_on_demand(data, iterations)
    print("On-Demand:                " + String(Int(on_demand_mbps)) + " MB/s")

    # Tape V2
    var tape_v2_mbps = benchmark_tape_v2(data, iterations)
    print("Tape V2:                  " + String(Int(tape_v2_mbps)) + " MB/s")

    # Speedup
    var speedup = on_demand_mbps / tape_v2_mbps
    print("\nOn-Demand vs Tape V2: " + String(speedup)[:4] + "x")


fn main() raises:
    print("=" * 60)
    print("On-Demand JSON Parser Benchmark")
    print("=" * 60)
    print("\nPhase 2 Optimization: Stage 1 only, values on access")
    print("Target: 1.5-2x faster than tape parsing for sparse access")

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

    try:
        var f3 = open("benchmarks/data/citm_catalog.json", "r")
        var citm = f3.read()
        f3.close()
        run_benchmark("citm_catalog.json", citm)
    except:
        print("\n[citm_catalog.json not found]")

    print("\n" + "=" * 60)
    print("Benchmark Complete")
    print("=" * 60)
