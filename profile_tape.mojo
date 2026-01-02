"""
Profiling Analysis for Tape Parser

Breaks down time spent in each stage to identify optimization targets.
"""

from src.tape_parser import parse_to_tape, JsonTape, TapeParser
from src.structural_index import build_structural_index
from time import perf_counter_ns


fn generate_test_json(obj_count: Int) -> String:
    """Generate realistic JSON for profiling."""
    var json = String('{"data": [')
    for i in range(obj_count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i)
        json += ', "name": "User_' + String(i) + '"'
        json += ', "active": true'
        json += ', "score": ' + String(i * 10)
        json += ', "tags": ["a", "b", "c"]}'
    json += '], "total": ' + String(obj_count) + '}'
    return json


fn profile_stages(json: String, iterations: Int):
    """Profile each stage separately."""
    var size = len(json)

    print("\nJSON size:", size, "bytes")
    print("-" * 60)

    # Stage 1: Structural index building
    var stage1_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(json)
        _ = idx
    var stage1_time = perf_counter_ns() - stage1_start

    var idx = build_structural_index(json)
    var struct_count = len(idx)

    # Full parse timing
    var full_start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape(json)
            _ = tape
        except:
            pass
    var full_time = perf_counter_ns() - full_start

    # Stage 2 = Full - Stage 1
    var stage2_time = full_time - stage1_time

    # Calculate throughputs
    var total_mb = Float64(size * iterations) / (1024.0 * 1024.0)
    var stage1_s = Float64(stage1_time) / 1e9
    var stage2_s = Float64(stage2_time) / 1e9
    var full_s = Float64(full_time) / 1e9

    print("Iterations:", iterations)
    print("")
    print("Timing breakdown:")
    print("  Stage 1 (SIMD scan):     ", stage1_time // 1_000_000, "ms (", stage1_s / full_s * 100, "%)")
    print("  Stage 2 (tape build):    ", stage2_time // 1_000_000, "ms (", stage2_s / full_s * 100, "%)")
    print("  Total:                   ", full_time // 1_000_000, "ms")
    print("")
    print("Throughput:")
    print("  Stage 1:", total_mb / stage1_s, "MB/s")
    print("  Stage 2:", total_mb / stage2_s, "MB/s (estimated)")
    print("  Full:   ", total_mb / full_s, "MB/s")
    print("")
    print("Structural analysis:")
    print("  Structural chars found:", struct_count)
    print("  Bytes per struct char: ", Float64(size) / Float64(struct_count))
    print("  Processing cost:       ", Float64(stage1_time) / Float64(struct_count), "ns/char")


fn analyze_bottlenecks(json: String):
    """Analyze where Stage 2 spends time."""
    print("\nBottleneck Analysis")
    print("=" * 60)

    var size = len(json)
    var iterations = 100

    # Time different operations
    var idx = build_structural_index(json)

    # Measure index traversal only (no tape ops)
    var traverse_start = perf_counter_ns()
    for _ in range(iterations):
        var total = 0
        for i in range(len(idx)):
            total += idx.get_position(i)
            total += Int(idx.get_character(i))
        _ = total
    var traverse_time = perf_counter_ns() - traverse_start

    # Full parse
    var full_start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape(json)
            _ = tape
        except:
            pass
    var full_time = perf_counter_ns() - full_start

    print("Index traversal time: ", traverse_time // 1_000_000, "ms")
    print("Full parse time:      ", full_time // 1_000_000, "ms")
    print("Tape construction:    ", (full_time - traverse_time) // 1_000_000, "ms")
    print("")

    var traverse_pct = Float64(traverse_time) / Float64(full_time) * 100
    var tape_pct = 100 - traverse_pct

    print("Time distribution:")
    print("  Index traversal: ", traverse_pct, "%")
    print("  Tape building:   ", tape_pct, "%")


fn main():
    print("=" * 60)
    print("TAPE PARSER PROFILING ANALYSIS")
    print("=" * 60)

    # Small JSON
    print("\n[Small JSON - 50 objects]")
    var small = generate_test_json(50)
    profile_stages(small, 500)

    # Medium JSON
    print("\n[Medium JSON - 500 objects]")
    var medium = generate_test_json(500)
    profile_stages(medium, 100)

    # Large JSON
    print("\n[Large JSON - 2000 objects]")
    var large = generate_test_json(2000)
    profile_stages(large, 50)

    # Bottleneck analysis
    analyze_bottlenecks(medium)

    print("\n" + "=" * 60)
    print("OPTIMIZATION RECOMMENDATIONS")
    print("=" * 60)
    print("")
    print("Based on profiling:")
    print("1. If Stage 1 > 50%: Improve SIMD scan")
    print("   - Try wider SIMD (32/64 byte chunks)")
    print("   - Use lookup tables for char classification")
    print("")
    print("2. If Stage 2 > 50%: Improve tape construction")
    print("   - Pre-allocate tape entries")
    print("   - Batch string copies")
    print("   - Reduce function call overhead")
    print("")
    print("3. For GPU acceleration (Phase 3):")
    print("   - Stage 1 is embarrassingly parallel")
    print("   - Stage 2 needs careful dependency analysis")
    print("=" * 60)
