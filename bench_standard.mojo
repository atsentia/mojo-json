"""
Standard JSON Parser Benchmark Suite

Uses the industry-standard benchmark files:
- twitter.json (617KB): Web API payloads, mixed content
- canada.json (2.1MB): GeoJSON, float-heavy (lat/long coordinates)
- citm_catalog.json (1.6MB): Deeply nested structure

These are the same files used by simdjson, serde-json, orjson, etc.
"""

from time import perf_counter_ns
from pathlib import Path
from src.tape_parser import (
    parse_to_tape,
    parse_to_tape_v2,
    parse_to_tape_v3,
    parse_to_tape_v4,
    parse_to_tape_parallel,
    parse_to_tape_compressed,
    TAPE_STRING,
    TAPE_INT64,
    TAPE_DOUBLE,
    TAPE_START_OBJECT,
    TAPE_START_ARRAY,
)


fn read_file(path: String) raises -> String:
    """Read entire file contents."""
    var file_path = Path(path)
    return file_path.read_text()


fn count_tokens(json: String) raises -> Tuple[Int, Int, Int, Int]:
    """Count strings, ints, floats, and containers in JSON."""
    var tape = parse_to_tape_v2(json)
    var strings = 0
    var ints = 0
    var floats = 0
    var containers = 0

    for i in range(len(tape.entries)):
        var tag = tape.entries[i].type_tag()
        if tag == TAPE_STRING:
            strings += 1
        elif tag == TAPE_INT64:
            ints += 1
        elif tag == TAPE_DOUBLE:
            floats += 1
        elif tag == TAPE_START_OBJECT or tag == TAPE_START_ARRAY:
            containers += 1

    return (strings, ints, floats, containers)


fn benchmark_file(name: String, path: String, iterations: Int) raises:
    """Run all parser benchmarks on a file."""
    print("\n" + "=" * 60)
    print(name)
    print("=" * 60)

    var json = read_file(path)
    var size_kb = Float64(len(json)) / 1024.0
    var size_mb = size_kb / 1024.0

    print("Size:", Int(size_kb), "KB (", Int(size_mb * 100) / 100.0, "MB)")

    # Analyze content
    var counts = count_tokens(json)
    print("Content:", counts[0], "strings,", counts[1], "ints,", counts[2], "floats,", counts[3], "containers")

    print("\nThroughput:")

    # Tape V1 (simpler index)
    var tape_v1_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape(json)
        _ = len(tape.entries)
    var tape_v1_time = perf_counter_ns() - tape_v1_start
    var tape_v1_throughput = Float64(len(json)) * Float64(iterations) / Float64(tape_v1_time) * 1000.0
    print("    Tape V1:       ", Int(tape_v1_throughput), "MB/s")

    # Tape V2 (16-byte SIMD)
    var tape_v2_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var tape_v2_time = perf_counter_ns() - tape_v2_start
    var tape_v2_throughput = Float64(len(json)) * Float64(iterations) / Float64(tape_v2_time) * 1000.0
    var v1_vs_v2 = tape_v1_throughput / tape_v2_throughput
    print("    Tape V2:       ", Int(tape_v2_throughput), "MB/s (V1 is", Int(v1_vs_v2 * 100), "% of V2)")

    # Tape V3 (32-byte SIMD)
    var tape_v3_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v3(json)
        _ = len(tape.entries)
    var tape_v3_time = perf_counter_ns() - tape_v3_start
    var tape_v3_throughput = Float64(len(json)) * Float64(iterations) / Float64(tape_v3_time) * 1000.0
    var v3_vs_v2 = tape_v3_throughput / tape_v2_throughput
    print("    Tape V3:       ", Int(tape_v3_throughput), "MB/s (", Int(v3_vs_v2 * 100), "% of V2)")

    # Tape V4 (branchless character classification)
    var tape_v4_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v4(json)
        _ = len(tape.entries)
    var tape_v4_time = perf_counter_ns() - tape_v4_start
    var tape_v4_throughput = Float64(len(json)) * Float64(iterations) / Float64(tape_v4_time) * 1000.0
    var v4_vs_v2 = tape_v4_throughput / tape_v2_throughput
    print("    Tape V4:       ", Int(tape_v4_throughput), "MB/s (", Int(v4_vs_v2 * 100), "% of V2)")

    # Parallel (for comparison)
    var parallel_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_parallel(json)
        _ = len(tape.entries)
    var parallel_time = perf_counter_ns() - parallel_start
    var parallel_throughput = Float64(len(json)) * Float64(iterations) / Float64(parallel_time) * 1000.0
    var parallel_ratio = parallel_throughput / tape_v2_throughput
    print("    Parallel:      ", Int(parallel_throughput), "MB/s (", Int(parallel_ratio * 100), "%)")

    # Compressed (memory-optimized)
    var compressed_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_compressed(json)
        _ = len(tape.entries)
    var compressed_time = perf_counter_ns() - compressed_start
    var compressed_throughput = Float64(len(json)) * Float64(iterations) / Float64(compressed_time) * 1000.0
    var compressed_ratio = compressed_throughput / tape_v2_throughput
    print("    Compressed:    ", Int(compressed_throughput), "MB/s (", Int(compressed_ratio * 100), "%)")

    # Memory analysis for compressed
    var tape_regular = parse_to_tape_v2(json)
    var tape_comp = parse_to_tape_compressed(json)
    var mem_regular = tape_regular.memory_usage()
    var mem_comp = tape_comp.memory_usage()
    var mem_saved = tape_comp.bytes_saved
    var mem_ratio = Float64(mem_comp) / Float64(mem_regular) * 100.0
    print("\nMemory:")
    print("    Regular:       ", mem_regular, "bytes")
    print("    Compressed:    ", mem_comp, "bytes (", Int(mem_ratio), "%)")
    print("    Saved:         ", mem_saved, "bytes,", tape_comp.strings_interned, "strings interned")


fn main() raises:
    print("=" * 60)
    print("Standard JSON Parser Benchmark Suite")
    print("=" * 60)
    print("\nBenchmark files from simdjson/serde-json test suite")

    var data_dir = "benchmarks/data/"

    # Twitter - mixed web API content
    benchmark_file(
        "twitter.json - Web API Payload",
        data_dir + "twitter.json",
        iterations=20
    )

    # Canada - GeoJSON, float-heavy
    benchmark_file(
        "canada.json - GeoJSON (Float-Heavy)",
        data_dir + "canada.json",
        iterations=10
    )

    # CITM Catalog - deeply nested
    benchmark_file(
        "citm_catalog.json - Deeply Nested",
        data_dir + "citm_catalog.json",
        iterations=10
    )

    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    print("\nComparison targets:")
    print("- simdjson: 2,500-5,000 MB/s")
    print("- orjson:   700-1,800 MB/s")
    print("- serde:    300-600 MB/s")
    print("\n" + "=" * 60)
