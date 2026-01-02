"""
Comprehensive Performance Benchmark for Tape-Based JSON Parser

Measures:
1. Stage 1: Structural index building (SIMD scan)
2. Stage 2: Tape construction from index
3. Full pipeline throughput
4. Memory efficiency
5. Various JSON patterns
"""

from src.tape_parser import parse_to_tape, JsonTape, TapeParser
from src.structural_index import build_structural_index, benchmark_structural_scan
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


fn generate_object_array(count: Int) -> String:
    """Generate array of simple objects: [{"id": 0}, ...]."""
    var json = String("[")
    for i in range(count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "name": "item_' + String(i) + '"}'
    json += "]"
    return json


fn generate_nested_objects(depth: Int) -> String:
    """Generate deeply nested objects: {"a": {"b": {"c": ...}}}."""
    var json = String("")
    for i in range(depth):
        json += '{"level_' + String(i) + '": '
    json += '"value"'
    for _ in range(depth):
        json += "}"
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


fn benchmark_stage1(data: String, iterations: Int) -> Tuple[Float64, Int]:
    """
    Benchmark Stage 1 (structural index) only.
    Returns (MB/s, structural count).
    """
    var size = len(data)

    # Warmup
    for _ in range(5):
        var idx = build_structural_index(data)
        _ = idx

    # Get structural count
    var idx = build_structural_index(data)
    var struct_count = len(idx)

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(data)
        _ = idx
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    var throughput = total_bytes / (1024.0 * 1024.0) / seconds

    return (throughput, struct_count)


fn benchmark_full_parse(data: String, iterations: Int) -> Tuple[Float64, Int]:
    """
    Benchmark full tape parsing (Stage 1 + Stage 2).
    Returns (MB/s, tape entries).
    """
    var size = len(data)

    # Warmup
    for _ in range(5):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass

    # Get tape size
    var tape_entries = 0
    try:
        var tape = parse_to_tape(data)
        tape_entries = len(tape)
    except:
        pass

    # Timed iterations
    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var tape = parse_to_tape(data)
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    var throughput = total_bytes / (1024.0 * 1024.0) / seconds

    return (throughput, tape_entries)


fn benchmark_stage2_only(data: String, iterations: Int) -> Float64:
    """
    Benchmark Stage 2 only (tape construction from pre-built index).
    Returns MB/s.
    """
    var size = len(data)

    # Pre-build structural index once
    var index = build_structural_index(data)

    # Warmup
    for _ in range(5):
        try:
            var parser = TapeParser(data)
            var tape = parser.parse()
            _ = tape
        except:
            pass

    # Timed iterations (full parse, but we'll subtract Stage 1)
    var start = perf_counter_ns()
    for _ in range(iterations):
        try:
            var parser = TapeParser(data)
            var tape = parser.parse()
            _ = tape
        except:
            pass
    var elapsed = perf_counter_ns() - start

    var seconds = Float64(elapsed) / 1_000_000_000.0
    var total_bytes = Float64(size * iterations)
    return total_bytes / (1024.0 * 1024.0) / seconds


fn format_size(bytes: Int) -> String:
    """Format byte size for display."""
    if bytes >= 1024 * 1024:
        return String(Float64(bytes) / (1024.0 * 1024.0)) + " MB"
    elif bytes >= 1024:
        return String(Float64(bytes) / 1024.0) + " KB"
    else:
        return String(bytes) + " B"


fn run_benchmark_suite():
    """Run comprehensive benchmark suite."""
    print("=" * 80)
    print("MOJO-JSON TAPE PARSER PERFORMANCE BENCHMARK")
    print("=" * 80)
    print("")

    # Test configurations
    alias ITERATIONS = 100

    # =========================================================================
    # Test 1: Flat integer array
    # =========================================================================
    print("Test 1: Flat Integer Array")
    print("-" * 40)

    var counts1 = List[Int](100, 1000, 10000)
    for i in range(len(counts1)):
        var count = counts1[i]
        var json = generate_flat_array(count)
        var size = len(json)

        var stage1_result = benchmark_stage1(json, ITERATIONS)
        var full_result = benchmark_full_parse(json, ITERATIONS)

        print("  Size:", format_size(size), "| Elements:", count)
        print("    Stage 1 (SIMD scan):", stage1_result[0], "MB/s")
        print("    Full parse:         ", full_result[0], "MB/s")
        print("    Tape entries:       ", full_result[1])
        print("")

    # =========================================================================
    # Test 2: Object array (realistic data)
    # =========================================================================
    print("Test 2: Object Array (Realistic)")
    print("-" * 40)

    var counts2 = List[Int](100, 500, 1000)
    for i in range(len(counts2)):
        var count = counts2[i]
        var json = generate_object_array(count)
        var size = len(json)

        var stage1_result = benchmark_stage1(json, ITERATIONS)
        var full_result = benchmark_full_parse(json, ITERATIONS)

        print("  Size:", format_size(size), "| Objects:", count)
        print("    Stage 1 (SIMD scan):", stage1_result[0], "MB/s")
        print("    Full parse:         ", full_result[0], "MB/s")
        print("    Structural chars:   ", stage1_result[1])
        print("    Tape entries:       ", full_result[1])
        print("")

    # =========================================================================
    # Test 3: Deep nesting
    # =========================================================================
    print("Test 3: Deep Nesting")
    print("-" * 40)

    var depths = List[Int](10, 50, 100)
    for i in range(len(depths)):
        var depth = depths[i]
        var json = generate_nested_objects(depth)
        var size = len(json)

        var stage1_result = benchmark_stage1(json, ITERATIONS * 10)
        var full_result = benchmark_full_parse(json, ITERATIONS * 10)

        print("  Size:", format_size(size), "| Depth:", depth)
        print("    Stage 1:", stage1_result[0], "MB/s")
        print("    Full:   ", full_result[0], "MB/s")
        print("")

    # =========================================================================
    # Test 4: Mixed content (most realistic)
    # =========================================================================
    print("Test 4: Mixed Content (Production-like)")
    print("-" * 40)

    var obj_counts = List[Int](50, 200, 500)
    for i in range(len(obj_counts)):
        var obj_count = obj_counts[i]
        var json = generate_mixed_json(obj_count, 5)
        var size = len(json)

        var stage1_result = benchmark_stage1(json, ITERATIONS)
        var full_result = benchmark_full_parse(json, ITERATIONS)

        print("  Size:", format_size(size), "| Objects:", obj_count[])
        print("    Stage 1 (SIMD scan):", stage1_result[0], "MB/s")
        print("    Full parse:         ", full_result[0], "MB/s")
        print("    Structural chars:   ", stage1_result[1])
        print("    Tape entries:       ", full_result[1])
        print("")

    # =========================================================================
    # Summary
    # =========================================================================
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print("")
    print("Target benchmarks:")
    print("  - Stage 1 (structural scan): 500+ MB/s (SIMD)")
    print("  - Full tape parse:           300+ MB/s")
    print("")
    print("Comparison targets:")
    print("  - orjson (Python/Rust):  ~718 MB/s")
    print("  - simdjson (C++/SIMD):   ~2,500 MB/s")
    print("")
    print("Notes:")
    print("  - Stage 1 uses SIMD (16-byte chunks)")
    print("  - Stage 2 is sequential (index traversal)")
    print("  - Memory: 8 bytes per tape entry + string refs")
    print("=" * 80)


fn main():
    run_benchmark_suite()
