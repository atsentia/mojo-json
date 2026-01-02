"""Baseline Benchmark for mojo-json.

Measures full parsing performance with various JSON file sizes.
Run: cd mojo-json && mojo run benchmarks/bench_baseline.mojo
"""

from time import perf_counter_ns
from collections import List

# Import from the mojo_json package
from mojo_json import parse, serialize, JsonValue


alias WARMUP = 3
alias ITERATIONS = 10


fn read_file(path: String) raises -> String:
    """Read file contents."""
    with open(path, "r") as f:
        return f.read()


fn benchmark_parse(content: String, iterations: Int) raises -> Float64:
    """Benchmark parsing. Returns average time in ms."""
    var total_ns: Int = 0

    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse(content)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result

    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn main() raises:
    print("=" * 70)
    print("mojo-json Baseline Benchmark")
    print("=" * 70)
    print("Iterations:", ITERATIONS, "| Warmup:", WARMUP)
    print()

    # Test files in order of size
    var files = List[String]()
    files.append("benchmarks/data/api_response_1kb.json")
    files.append("benchmarks/data/api_response_10kb.json")
    files.append("benchmarks/data/api_response_100kb.json")
    files.append("benchmarks/data/api_response_1mb.json")

    print("Full Parse Benchmark")
    print("-" * 70)
    print("File                              Size         Time        Throughput")
    print("-" * 70)

    var total_throughput: Float64 = 0.0
    var file_count = 0

    for i in range(len(files)):
        var filepath = files[i]
        try:
            var content = read_file(filepath)
            var size = len(content)

            # Warmup
            for _ in range(WARMUP):
                var w = parse(content)
                _ = w

            # Benchmark
            var parse_ms = benchmark_parse(content, ITERATIONS)

            # Calculate throughput
            var mb = Float64(size) / (1024.0 * 1024.0)
            var mbps = mb / (parse_ms / 1000.0)

            # Format size
            var size_str: String
            if size < 1024:
                size_str = String(size) + " B"
            elif size < 1024 * 1024:
                size_str = String(size // 1024) + " KB"
            else:
                size_str = String(size // 1024 // 1024) + " MB"

            # Format time
            var time_str = String(parse_ms)
            if len(time_str) > 8:
                time_str = time_str[:8]

            # Get filename only
            var parts = filepath.split("/")
            var filename = parts[len(parts) - 1]

            print(
                filename.ljust(34),
                size_str.ljust(13),
                (time_str + " ms").ljust(12),
                String(Int(mbps)) + " MB/s"
            )

            total_throughput += mbps
            file_count += 1

        except e:
            print(filepath.ljust(34), "ERROR:", String(e)[:30])

    print("-" * 70)

    if file_count > 0:
        var avg = total_throughput / Float64(file_count)

        print()
        print("RESULTS:")
        print("  Files tested:", file_count)
        print("  Average throughput:", Int(avg), "MB/s")
        print()
        print("COMPARISON:")
        print("-" * 70)
        print("  simdjson (C++):   3,500 MB/s  (reference)")
        print("  orjson (Rust):      900 MB/s  (reference)")
        print("  ujson (C):          380 MB/s  (reference)")
        print("  python json:        307 MB/s  (reference)")
        print("  mojo-json:       ", Int(avg), "MB/s  (this benchmark)")
        print()

        # Calculate comparisons
        if avg >= 380:
            print("  Status: FASTER than ujson! ✓")
        elif avg >= 307:
            print("  Status: Between Python json and ujson")
        else:
            print("  Status: Slower than Python json (needs optimization)")

    print()
    print("=" * 70)
