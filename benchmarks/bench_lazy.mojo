"""Lazy JSON Parsing Benchmark.

Compares different parsing strategies:
- parse()        : Full recursive descent (~14 MB/s)
- parse_fast()   : Tape + full JsonValue conversion (~15 MB/s)
- parse_lazy()   : Tape only, lazy access (~500 MB/s)
- parse_to_tape(): Pure tape (fastest, ~800 MB/s)

Usage:
    cd mojo-json
    mojo run benchmarks/bench_lazy.mojo
"""

from time import perf_counter_ns
from collections import List

# Import all parsing options
from src import parse, parse_fast, parse_lazy, parse_to_tape, JsonValue


alias WARMUP = 5
alias ITERATIONS = 50


fn benchmark_parse(content: String, iterations: Int) raises -> Float64:
    """Benchmark full recursive descent parsing."""
    var total_ns: Int = 0
    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse(content)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result
    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn benchmark_parse_fast(content: String, iterations: Int) raises -> Float64:
    """Benchmark tape + JsonValue conversion."""
    var total_ns: Int = 0
    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse_fast(content)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result
    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn benchmark_parse_lazy(content: String, iterations: Int) raises -> Float64:
    """Benchmark lazy parsing (tape only, no conversion)."""
    var total_ns: Int = 0
    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse_lazy(content)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = result
    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn benchmark_tape(content: String, iterations: Int) raises -> Float64:
    """Benchmark pure tape parsing (no value conversion)."""
    var total_ns: Int = 0
    for _ in range(iterations):
        var start = perf_counter_ns()
        var result = parse_to_tape(content)
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
    print("mojo-json Lazy Parsing Benchmark")
    print("=" * 80)
    print("Mojo 0.25.7 | Iterations:", ITERATIONS)
    print()

    var files = List[String]()
    files.append("benchmarks/data/api_response_1kb.json")
    files.append("benchmarks/data/api_response_10kb.json")
    files.append("benchmarks/data/api_response_100kb.json")
    files.append("benchmarks/data/twitter.json")
    files.append("benchmarks/data/canada.json")
    files.append("benchmarks/data/citm_catalog.json")

    print("Comparing Parser Options")
    print("-" * 100)
    print("File                                    Size      parse()    parse_fast() parse_lazy() parse_to_tape()")
    print("-" * 100)

    var total_parse = 0.0
    var total_fast = 0.0
    var total_lazy = 0.0
    var total_tape = 0.0
    var file_count = 0

    for i in range(len(files)):
        var filepath = files[i]
        try:
            var content = read_file(filepath)
            var size = len(content)

            # Warmup all parsers
            for _ in range(WARMUP):
                var w1 = parse(content)
                var w2 = parse_fast(content)
                var w3 = parse_lazy(content)
                var w4 = parse_to_tape(content)
                _ = w1
                _ = w2
                _ = w3
                _ = w4

            # Benchmark each
            var parse_ms = benchmark_parse(content, ITERATIONS)
            var fast_ms = benchmark_parse_fast(content, ITERATIONS)
            var lazy_ms = benchmark_parse_lazy(content, ITERATIONS)
            var tape_ms = benchmark_tape(content, ITERATIONS)

            # Calculate MB/s
            var mb = Float64(size) / (1024.0 * 1024.0)
            var parse_mbps = mb / (parse_ms / 1000.0)
            var fast_mbps = mb / (fast_ms / 1000.0)
            var lazy_mbps = mb / (lazy_ms / 1000.0)
            var tape_mbps = mb / (tape_ms / 1000.0)

            var size_str: String
            if size < 1024:
                size_str = String(size) + " B"
            elif size < 1024 * 1024:
                size_str = String(size // 1024) + " KB"
            else:
                size_str = String(size // 1024 // 1024) + " MB"

            # Get filename only
            var parts = filepath.split("/")
            var filename = parts[len(parts) - 1]

            print(
                filename.ljust(40),
                size_str.ljust(10),
                (String(Int(parse_mbps)) + " MB/s").ljust(11),
                (String(Int(fast_mbps)) + " MB/s").ljust(13),
                (String(Int(lazy_mbps)) + " MB/s").ljust(13),
                String(Int(tape_mbps)) + " MB/s"
            )

            total_parse += parse_mbps
            total_fast += fast_mbps
            total_lazy += lazy_mbps
            total_tape += tape_mbps
            file_count += 1

        except e:
            print(filepath.ljust(40), "ERROR:", String(e)[:40])

    print("-" * 100)

    if file_count > 0:
        var avg_parse = total_parse / Float64(file_count)
        var avg_fast = total_fast / Float64(file_count)
        var avg_lazy = total_lazy / Float64(file_count)
        var avg_tape = total_tape / Float64(file_count)

        print()
        print("SUMMARY:")
        print("-" * 60)
        print("  Parser            Average MB/s   Speedup vs parse()")
        print("-" * 60)
        print("  parse()          ", String(Int(avg_parse)).rjust(8), "MB/s      1.0x (baseline)")
        print("  parse_fast()     ", String(Int(avg_fast)).rjust(8), "MB/s     ", String(avg_fast / avg_parse)[:4] + "x")
        print("  parse_lazy()     ", String(Int(avg_lazy)).rjust(8), "MB/s     ", String(avg_lazy / avg_parse)[:4] + "x")
        print("  parse_to_tape()  ", String(Int(avg_tape)).rjust(8), "MB/s     ", String(avg_tape / avg_parse)[:4] + "x")
        print("-" * 60)

        print()
        print("RECOMMENDATIONS:")
        print("  - For small JSON or full tree access:  parse()")
        print("  - For selective value extraction:      parse_lazy()")
        print("  - For maximum performance:             parse_to_tape()")

    print()
    print("=" * 80)
