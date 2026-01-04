"""Benchmark parallel Stage 1 structural indexing."""

from time import perf_counter_ns
from pathlib import Path
from src.structural_index import (
    build_structural_index,
    build_structural_index_v2,
    build_structural_index_parallel,
)


fn read_file(path: String) raises -> String:
    var file_path = Path(path)
    return file_path.read_text()


fn benchmark_indexer(name: String, json: String, iterations: Int) raises:
    print("\n" + "=" * 50)
    print(name)
    print("=" * 50)

    var size_mb = Float64(len(json)) / 1024.0 / 1024.0
    print("Size:", Int(size_mb * 100) / 100.0, "MB")

    # Benchmark V1 (simple)
    var v1_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index(json)
        _ = len(idx)
    var v1_time = perf_counter_ns() - v1_start
    var v1_throughput = Float64(len(json)) * Float64(iterations) / Float64(v1_time) * 1000.0

    # Benchmark V2 (with value spans)
    var v2_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_v2(json)
        _ = len(idx)
    var v2_time = perf_counter_ns() - v2_start
    var v2_throughput = Float64(len(json)) * Float64(iterations) / Float64(v2_time) * 1000.0

    # Benchmark Parallel
    var par_start = perf_counter_ns()
    for _ in range(iterations):
        var idx = build_structural_index_parallel(json, num_threads=4)
        _ = len(idx)
    var par_time = perf_counter_ns() - par_start
    var par_throughput = Float64(len(json)) * Float64(iterations) / Float64(par_time) * 1000.0

    print("\nThroughput:")
    print("  V1 (simple):  ", Int(v1_throughput), "MB/s")
    print("  V2 (spans):   ", Int(v2_throughput), "MB/s")
    print("  Parallel:     ", Int(par_throughput), "MB/s")

    var speedup = par_throughput / v2_throughput
    if speedup > 1.0:
        print("  Parallel speedup:", Int(speedup * 100 - 100), "% faster than V2")
    else:
        print("  Parallel overhead:", Int((1.0 - speedup) * 100), "% slower than V2")

    # Verify correctness
    var idx_v1 = build_structural_index(json)
    var idx_par = build_structural_index_parallel(json, num_threads=4)
    if len(idx_v1) == len(idx_par):
        print("  Correctness: OK (", len(idx_v1), "entries)")
    else:
        print("  Correctness: MISMATCH (V1:", len(idx_v1), "Parallel:", len(idx_par), ")")


fn main() raises:
    print("=" * 50)
    print("Parallel Stage 1 Benchmark")
    print("=" * 50)

    var data_dir = "benchmarks/data/"

    benchmark_indexer("twitter.json", read_file(data_dir + "twitter.json"), 20)
    benchmark_indexer("canada.json", read_file(data_dir + "canada.json"), 10)
    benchmark_indexer("citm_catalog.json", read_file(data_dir + "citm_catalog.json"), 10)

    print("\n" + "=" * 50)
    print("Note: Parallel is best for files > 500KB")
    print("=" * 50)
