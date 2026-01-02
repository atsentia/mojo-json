"""Mojo JSON Parser Benchmark.

Benchmarks mojo-json parsing and serialization performance.

Usage:
    cd mojo-json
    mojo benchmarks/bench_mojo.mojo
"""

from time import perf_counter_ns
from pathlib import Path
from collections import List

# Import mojo-json
from src import parse, serialize, serialize_pretty, JsonValue


alias WARMUP_ITERATIONS: Int = 3
alias BENCH_ITERATIONS: Int = 10


@value
struct BenchResult:
    """Result of a single benchmark."""
    var file: String
    var file_size: Int
    var parse_time_ms: Float64
    var serialize_time_ms: Float64
    var throughput_mb_s: Float64

    fn __init__(out self, file: String, file_size: Int, parse_ms: Float64, ser_ms: Float64):
        self.file = file
        self.file_size = file_size
        self.parse_time_ms = parse_ms
        self.serialize_time_ms = ser_ms
        # Throughput in MB/s = size_in_mb / time_in_seconds
        if parse_ms > 0:
            self.throughput_mb_s = (Float64(file_size) / 1024.0 / 1024.0) / (parse_ms / 1000.0)
        else:
            self.throughput_mb_s = 0


fn read_file(path: String) raises -> String:
    """Read entire file content as string."""
    with open(path, "r") as f:
        return f.read()


fn benchmark_parse(content: String, iterations: Int) raises -> Float64:
    """Benchmark parsing, return average time in milliseconds."""
    var total_time: Int = 0

    for i in range(iterations):
        var start = perf_counter_ns()
        var result = parse(content)
        var end = perf_counter_ns()
        total_time += end - start
        _ = result  # Prevent optimization

    # Convert nanoseconds to milliseconds
    return Float64(total_time) / Float64(iterations) / 1_000_000.0


fn benchmark_serialize(value: JsonValue, iterations: Int) raises -> Float64:
    """Benchmark serialization, return average time in milliseconds."""
    var total_time: Int = 0

    for i in range(iterations):
        var start = perf_counter_ns()
        var result = serialize(value)
        var end = perf_counter_ns()
        total_time += end - start
        _ = result

    return Float64(total_time) / Float64(iterations) / 1_000_000.0


fn format_size(size: Int) -> String:
    """Format file size as human-readable string."""
    if size < 1024:
        return String(size) + " B"
    elif size < 1024 * 1024:
        return String(size // 1024) + " KB"
    else:
        return String(size // 1024 // 1024) + " MB"


fn main() raises:
    print("=" * 70)
    print("Mojo JSON Parser Benchmark")
    print("=" * 70)
    print("Library: mojo-json (with SIMD optimizations)")
    print("Iterations:", BENCH_ITERATIONS, "(warmup:", WARMUP_ITERATIONS, ")")
    print()

    # List of test files to benchmark
    var test_files = List[String]()
    test_files.append("api_response_1kb.json")
    test_files.append("api_response_10kb.json")
    test_files.append("api_response_100kb.json")
    test_files.append("numbers_1kb.json")
    test_files.append("numbers_10kb.json")
    test_files.append("numbers_100kb.json")
    test_files.append("strings_1kb.json")
    test_files.append("strings_10kb.json")
    test_files.append("strings_100kb.json")
    test_files.append("nested_1kb.json")
    test_files.append("nested_10kb.json")
    # Standard benchmark datasets
    test_files.append("twitter.json")
    test_files.append("canada.json")
    test_files.append("citm_catalog.json")
    # Edge cases
    test_files.append("unicode_heavy.json")
    test_files.append("escape_heavy.json")
    test_files.append("many_keys.json")

    print("=" * 85)
    print(
        "File".ljust(30),
        "Size".ljust(12),
        "Parse (ms)".ljust(14),
        "Serialize".ljust(14),
        "MB/s"
    )
    print("=" * 85)

    var results = List[BenchResult]()
    var total_parse_throughput: Float64 = 0
    var file_count = 0

    for i in range(len(test_files)):
        var filename = test_files[i]
        var filepath = "benchmarks/data/" + filename

        try:
            var content = read_file(filepath)
            var file_size = len(content)

            # Warmup
            for w in range(WARMUP_ITERATIONS):
                var warmup_result = parse(content)
                _ = warmup_result

            # Parse once for serialization benchmark
            var parsed = parse(content)

            # Benchmark parsing
            var parse_time = benchmark_parse(content, BENCH_ITERATIONS)

            # Benchmark serialization
            var serialize_time = benchmark_serialize(parsed, BENCH_ITERATIONS)

            var result = BenchResult(filename, file_size, parse_time, serialize_time)
            results.append(result)

            var size_str = format_size(file_size)

            # Format output
            var throughput_str = String(int(result.throughput_mb_s))
            if result.throughput_mb_s >= 1000:
                throughput_str = String(int(result.throughput_mb_s / 1000)) + "," + String(int(result.throughput_mb_s) % 1000)

            print(
                filename.ljust(30),
                size_str.ljust(12),
                (String(round(parse_time, 3)) + " ms").ljust(14),
                (String(round(serialize_time, 3)) + " ms").ljust(14),
                throughput_str
            )

            total_parse_throughput += result.throughput_mb_s
            file_count += 1

        except e:
            print(filename.ljust(30), "SKIPPED (file not found)")

    print("-" * 85)

    # Summary
    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)

    if file_count > 0:
        var avg_throughput = total_parse_throughput / Float64(file_count)
        print("  Average parse throughput:", int(avg_throughput), "MB/s")
        print("  Files benchmarked:", file_count)

    # Write CSV results
    print()
    print("Writing results to: benchmarks/results/mojo_benchmarks.csv")

    try:
        with open("benchmarks/results/mojo_benchmarks.csv", "w") as f:
            _ = f.write("file,file_size,parse_time_ms,serialize_time_ms,throughput_mb_s\n")
            for i in range(len(results)):
                var r = results[i]
                var line = (
                    r.file + "," +
                    String(r.file_size) + "," +
                    String(r.parse_time_ms) + "," +
                    String(r.serialize_time_ms) + "," +
                    String(r.throughput_mb_s) + "\n"
                )
                _ = f.write(line)
        print("Done!")
    except e:
        print("Warning: Could not write CSV file:", e)
