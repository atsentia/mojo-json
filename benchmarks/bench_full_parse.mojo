"""Full JSON Parsing Benchmark.

Tests complete JSON parsing (not just Stage 1 structural scan).
Uses the updated mojo-json with optimized SIMD.

Usage:
    cd mojo-json
    mojo run benchmarks/bench_full_parse.mojo
"""

from time import perf_counter_ns
from collections import List

# Import from the package
from src import parse, serialize, JsonValue


alias WARMUP = 5
alias ITERATIONS = 20


fn benchmark_parse(content: String, iterations: Int) raises -> Float64:
    """Benchmark full JSON parsing. Returns average time in ms."""
    var total_ns: Int = 0

    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse(content)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result

    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn benchmark_serialize(value: JsonValue, iterations: Int) raises -> Float64:
    """Benchmark JSON serialization. Returns average time in ms."""
    var total_ns: Int = 0

    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = serialize(value)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result

    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn read_file(path: String) raises -> String:
    """Read file contents."""
    with open(path, "r") as f:
        return f.read()


fn main() raises:
    print("=" * 80)
    print("mojo-json Full Parsing Benchmark")
    print("=" * 80)
    print("Mojo 0.25.7 | Optimized SIMD | Iterations:", ITERATIONS)
    print()

    var files = List[String]()
    files.append("benchmarks/data/api_response_1kb.json")
    files.append("benchmarks/data/api_response_10kb.json")
    files.append("benchmarks/data/api_response_100kb.json")
    files.append("benchmarks/data/twitter.json")
    files.append("benchmarks/data/canada.json")
    files.append("benchmarks/data/citm_catalog.json")

    print("Full Parse + Serialize Benchmark")
    print("-" * 80)
    print("File                                    Size      Parse      Serialize    Parse MB/s")
    print("-" * 80)

    var total_parse_throughput: Float64 = 0.0
    var total_serialize_throughput: Float64 = 0.0
    var file_count = 0

    for i in range(len(files)):
        var filepath = files[i]
        try:
            var content = read_file(filepath)
            var size = len(content)

            # Warmup parse
            for _ in range(WARMUP):
                var warmup = parse(content)
                _ = warmup

            # Parse once for serialization
            var parsed = parse(content)

            # Warmup serialize
            for _ in range(WARMUP):
                var warmup = serialize(parsed)
                _ = warmup

            # Benchmark parse
            var parse_ms = benchmark_parse(content, ITERATIONS)

            # Benchmark serialize
            var serialize_ms = benchmark_serialize(parsed, ITERATIONS)

            # Calculate throughputs
            var mb = Float64(size) / (1024.0 * 1024.0)
            var parse_mbps = mb / (parse_ms / 1000.0)
            var serialize_mbps = mb / (serialize_ms / 1000.0)

            var size_str: String
            if size < 1024:
                size_str = String(size) + " B"
            elif size < 1024 * 1024:
                size_str = String(size // 1024) + " KB"
            else:
                size_str = String(size // 1024 // 1024) + " MB"

            var parse_str = String(parse_ms)[:6] + " ms"
            var ser_str = String(serialize_ms)[:6] + " ms"

            # Get filename only
            var parts = filepath.split("/")
            var filename = parts[len(parts) - 1]

            print(
                filename.ljust(40),
                size_str.ljust(10),
                parse_str.ljust(11),
                ser_str.ljust(13),
                String(Int(parse_mbps)) + " MB/s"
            )

            total_parse_throughput += parse_mbps
            total_serialize_throughput += serialize_mbps
            file_count += 1

        except e:
            print(filepath.ljust(40), "ERROR:", String(e)[:40])

    print("-" * 80)

    if file_count > 0:
        var avg_parse = total_parse_throughput / Float64(file_count)
        var avg_serialize = total_serialize_throughput / Float64(file_count)

        print()
        print("SUMMARY:")
        print("  Files tested:", file_count)
        print("  Average parse throughput:", Int(avg_parse), "MB/s")
        print("  Average serialize throughput:", Int(avg_serialize), "MB/s")
        print()

        print("COMPARISON:")
        print("-" * 80)
        print("  Library             Parse       vs mojo-json")
        print("-" * 80)
        print("  simdjson (C++)      3,500 MB/s  ", String(Int(3500.0 / avg_parse)), "x faster")
        print("  orjson (Rust)         900 MB/s  ", String(Int(900.0 / avg_parse)), "x faster")
        print("  ujson (C)             380 MB/s  ", end="")
        if avg_parse >= 380:
            print("mojo-json is", String(Int(avg_parse / 380.0)), "x faster")
        else:
            print(String(Int(380.0 / avg_parse)), "x faster")
        print("  json (Python)         307 MB/s  ", end="")
        if avg_parse >= 307:
            print("mojo-json is", String(Int(avg_parse / 307.0)), "x faster")
        else:
            print(String(Int(307.0 / avg_parse)), "x faster")

    print()
    print("=" * 80)
