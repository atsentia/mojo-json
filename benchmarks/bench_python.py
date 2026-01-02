#!/usr/bin/env python3
"""Python JSON parser benchmarks.

Compares:
- json (stdlib)
- orjson (Rust-based, fastest)
- ujson (C-based, fast)

Usage:
    pip install orjson ujson
    python bench_python.py
"""

import json
import time
import os
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Callable, Any

# Try to import fast JSON libraries
try:
    import orjson
    HAS_ORJSON = True
except ImportError:
    HAS_ORJSON = False
    print("Warning: orjson not installed. Run: pip install orjson")

try:
    import ujson
    HAS_UJSON = True
except ImportError:
    HAS_UJSON = False
    print("Warning: ujson not installed. Run: pip install ujson")

DATA_DIR = Path(__file__).parent / "data"
RESULTS_DIR = Path(__file__).parent / "results"

# Number of iterations for timing
WARMUP_ITERATIONS = 3
BENCH_ITERATIONS = 10


@dataclass
class BenchResult:
    """Result of a single benchmark."""
    library: str
    file: str
    file_size: int
    parse_time_ms: float
    serialize_time_ms: float
    throughput_mb_s: float


def time_function(func: Callable, iterations: int = BENCH_ITERATIONS) -> float:
    """Time a function over multiple iterations, return average time in ms."""
    times = []
    for _ in range(iterations):
        start = time.perf_counter()
        func()
        end = time.perf_counter()
        times.append((end - start) * 1000)  # Convert to ms
    return sum(times) / len(times)


def benchmark_json_stdlib(content: str, data: Any) -> tuple[float, float]:
    """Benchmark standard library json."""
    # Parse
    def parse():
        json.loads(content)

    # Serialize
    def serialize():
        json.dumps(data)

    # Warmup
    for _ in range(WARMUP_ITERATIONS):
        parse()
        serialize()

    parse_time = time_function(parse)
    serialize_time = time_function(serialize)

    return parse_time, serialize_time


def benchmark_orjson(content: bytes, data: Any) -> tuple[float, float]:
    """Benchmark orjson (Rust-based)."""
    if not HAS_ORJSON:
        return -1, -1

    def parse():
        orjson.loads(content)

    def serialize():
        orjson.dumps(data)

    for _ in range(WARMUP_ITERATIONS):
        parse()
        serialize()

    parse_time = time_function(parse)
    serialize_time = time_function(serialize)

    return parse_time, serialize_time


def benchmark_ujson(content: str, data: Any) -> tuple[float, float]:
    """Benchmark ujson (C-based)."""
    if not HAS_UJSON:
        return -1, -1

    def parse():
        ujson.loads(content)

    def serialize():
        ujson.dumps(data)

    for _ in range(WARMUP_ITERATIONS):
        parse()
        serialize()

    parse_time = time_function(parse)
    serialize_time = time_function(serialize)

    return parse_time, serialize_time


def run_benchmarks() -> list[BenchResult]:
    """Run all benchmarks on all test files."""
    results = []

    # Get all JSON test files
    json_files = sorted(DATA_DIR.glob("*.json"))

    if not json_files:
        print(f"Error: No JSON files found in {DATA_DIR}")
        print("Run: python generate_test_data.py")
        sys.exit(1)

    print(f"Found {len(json_files)} test files\n")
    print("=" * 80)
    print(f"{'File':<30} {'Size':>10} {'Library':<10} {'Parse':>10} {'Serialize':>10} {'MB/s':>10}")
    print("=" * 80)

    for json_file in json_files:
        file_size = json_file.stat().st_size
        file_name = json_file.name

        # Skip very large files for quick testing
        if file_size > 20 * 1024 * 1024:  # 20 MB
            print(f"{file_name:<30} {'SKIPPED (too large)':>50}")
            continue

        # Read file content
        with open(json_file, 'r') as f:
            content_str = f.read()
        content_bytes = content_str.encode('utf-8')

        # Parse once to get data for serialization tests
        data = json.loads(content_str)

        # Benchmark each library
        libraries = [
            ("json", lambda: benchmark_json_stdlib(content_str, data)),
            ("orjson", lambda: benchmark_orjson(content_bytes, data)),
            ("ujson", lambda: benchmark_ujson(content_str, data)),
        ]

        for lib_name, bench_func in libraries:
            try:
                parse_time, serialize_time = bench_func()
                if parse_time < 0:
                    continue  # Library not available

                throughput = (file_size / 1024 / 1024) / (parse_time / 1000) if parse_time > 0 else 0

                result = BenchResult(
                    library=lib_name,
                    file=file_name,
                    file_size=file_size,
                    parse_time_ms=parse_time,
                    serialize_time_ms=serialize_time,
                    throughput_mb_s=throughput
                )
                results.append(result)

                size_str = f"{file_size/1024:.1f}KB" if file_size < 1024*1024 else f"{file_size/1024/1024:.1f}MB"
                print(f"{file_name:<30} {size_str:>10} {lib_name:<10} {parse_time:>9.3f}ms {serialize_time:>9.3f}ms {throughput:>9.1f}")

            except Exception as e:
                print(f"{file_name:<30} {lib_name:<10} ERROR: {e}")

        print("-" * 80)

    return results


def save_results(results: list[BenchResult]):
    """Save results to CSV."""
    RESULTS_DIR.mkdir(exist_ok=True)
    output_file = RESULTS_DIR / "python_benchmarks.csv"

    with open(output_file, 'w') as f:
        f.write("library,file,file_size,parse_time_ms,serialize_time_ms,throughput_mb_s\n")
        for r in results:
            f.write(f"{r.library},{r.file},{r.file_size},{r.parse_time_ms:.3f},{r.serialize_time_ms:.3f},{r.throughput_mb_s:.1f}\n")

    print(f"\nResults saved to: {output_file}")


def print_summary(results: list[BenchResult]):
    """Print summary comparison."""
    print("\n" + "=" * 60)
    print("SUMMARY: Average Parse Throughput (MB/s)")
    print("=" * 60)

    # Group by library
    libs = {}
    for r in results:
        if r.library not in libs:
            libs[r.library] = []
        libs[r.library].append(r.throughput_mb_s)

    # Calculate averages
    for lib, throughputs in sorted(libs.items(), key=lambda x: -sum(x[1])/len(x[1])):
        avg = sum(throughputs) / len(throughputs)
        print(f"  {lib:<10}: {avg:>8.1f} MB/s")

    # Calculate speedups vs json stdlib
    if "json" in libs and "orjson" in libs:
        json_avg = sum(libs["json"]) / len(libs["json"])
        orjson_avg = sum(libs["orjson"]) / len(libs["orjson"])
        print(f"\n  orjson is {orjson_avg/json_avg:.1f}x faster than stdlib json")


def main():
    print("Python JSON Parser Benchmark")
    print("=" * 60)
    print(f"Libraries: json (stdlib){', orjson' if HAS_ORJSON else ''}{', ujson' if HAS_UJSON else ''}")
    print(f"Iterations: {BENCH_ITERATIONS} (warmup: {WARMUP_ITERATIONS})")
    print()

    results = run_benchmarks()
    save_results(results)
    print_summary(results)


if __name__ == "__main__":
    main()
