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
    parse_to_tape_v2,
    parse_to_tape_parallel,
    parse_to_tape_compressed,
    tape_get_string_value,
    tape_get_float_value,
    TAPE_STRING,
    TAPE_INT64,
    TAPE_DOUBLE,
    TAPE_START_OBJECT,
    TAPE_START_ARRAY,
)
from src.parser import parse


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


struct BenchmarkResult:
    var name: String
    var size_bytes: Int
    var time_ns: Int
    var throughput_mbs: Float64
    var iterations: Int

    fn __init__(out self, name: String, size: Int, time: Int, iters: Int):
        self.name = name
        self.size_bytes = size
        self.time_ns = time
        self.iterations = iters
        self.throughput_mbs = Float64(size) * Float64(iters) / Float64(time) * 1000.0


fn benchmark_parser[
    parser_fn: fn(String) raises -> _
](name: String, json: String, warmup: Int = 3, iterations: Int = 10) raises -> BenchmarkResult:
    """Benchmark a parser function."""
    # Warmup
    for _ in range(warmup):
        var _ = parser_fn(json)

    # Benchmark
    var start = perf_counter_ns()
    for _ in range(iterations):
        var result = parser_fn(json)
        _ = result  # Prevent optimization
    var elapsed = perf_counter_ns() - start

    return BenchmarkResult(name, len(json), elapsed, iterations)


fn run_tape_v2(json: String) raises -> Int:
    """Wrapper for tape v2 parser."""
    var tape = parse_to_tape_v2(json)
    return len(tape.entries)


fn run_tape_parallel(json: String) raises -> Int:
    """Wrapper for parallel tape parser."""
    var tape = parse_to_tape_parallel(json)
    return len(tape.entries)


fn run_tape_compressed(json: String) raises -> Int:
    """Wrapper for compressed tape parser."""
    var tape = parse_to_tape_compressed(json)
    return len(tape.entries)


fn run_dom_parser(json: String) raises -> Int:
    """Wrapper for DOM parser."""
    var value = parse(json)
    return 1


fn print_result(result: BenchmarkResult):
    """Print benchmark result."""
    var size_kb = Float64(result.size_bytes) / 1024.0
    print("    ", result.name + ":", Int(result.throughput_mbs), "MB/s")


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
    print("Content: ", counts[0], "strings,", counts[1], "ints,", counts[2], "floats,", counts[3], "containers")

    print("\nThroughput:")

    # Tape V2 (baseline)
    var tape_v2_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var tape_v2_time = perf_counter_ns() - tape_v2_start
    var tape_v2_throughput = Float64(len(json)) * Float64(iterations) / Float64(tape_v2_time) * 1000.0
    print("    Tape V2:        ", Int(tape_v2_throughput), "MB/s (baseline)")

    # Parallel (for comparison)
    var parallel_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_parallel(json)
        _ = len(tape.entries)
    var parallel_time = perf_counter_ns() - parallel_start
    var parallel_throughput = Float64(len(json)) * Float64(iterations) / Float64(parallel_time) * 1000.0
    var parallel_ratio = parallel_throughput / tape_v2_throughput
    print("    Parallel:       ", Int(parallel_throughput), "MB/s (", Int(parallel_ratio * 100), "% of baseline)")

    # Compressed (memory-optimized)
    var compressed_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_compressed(json)
        _ = len(tape.entries)
    var compressed_time = perf_counter_ns() - compressed_start
    var compressed_throughput = Float64(len(json)) * Float64(iterations) / Float64(compressed_time) * 1000.0
    var compressed_ratio = compressed_throughput / tape_v2_throughput
    print("    Compressed:     ", Int(compressed_throughput), "MB/s (", Int(compressed_ratio * 100), "% of baseline)")

    # Memory analysis for compressed
    var tape_regular = parse_to_tape_v2(json)
    var tape_comp = parse_to_tape_compressed(json)
    var mem_regular = tape_regular.memory_usage()
    var mem_comp = tape_comp.memory_usage()
    var mem_saved = tape_comp.bytes_saved
    var mem_ratio = Float64(mem_comp) / Float64(mem_regular) * 100.0
    print("\nMemory:")
    print("    Regular tape:  ", mem_regular, "bytes")
    print("    Compressed:    ", mem_comp, "bytes (", Int(mem_ratio), "% of regular)")
    print("    Bytes saved:   ", mem_saved, "bytes")
    print("    Strings interned:", tape_comp.strings_interned)


fn main() raises:
    print("=" * 60)
    print("Standard JSON Parser Benchmark Suite")
    print("=" * 60)
    print("\nBenchmark files from simdjson/serde-json test suite")
    print("Testing: Tape V2, Parallel, and Compressed parsers")

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
    print("\nKey observations:")
    print("- Tape V2 is the fastest for general use")
    print("- Parallel parser has overhead for files < 1MB")
    print("- Compressed parser saves memory for repeated strings")
    print("\nComparison targets:")
    print("- simdjson: 2,500-5,000 MB/s")
    print("- orjson:   700-1,800 MB/s")
    print("- serde:    300-600 MB/s")
    print("\n" + "=" * 60)
