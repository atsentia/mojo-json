"""Profile Stage 1 vs Stage 2 timing for benchmark files."""

from time import perf_counter_ns
from pathlib import Path
from src.structural_index import build_structural_index_v2
from src.tape_parser import TapeParserV2, parse_to_tape_v2


fn read_file(path: String) raises -> String:
    var file_path = Path(path)
    return file_path.read_text()


fn profile_file(name: String, path: String, iterations: Int = 5) raises:
    print("\n" + "=" * 50)
    print(name)
    print("=" * 50)

    var json = read_file(path)
    var size_mb = Float64(len(json)) / 1024.0 / 1024.0
    print("Size:", Int(size_mb * 100) / 100.0, "MB")

    # Stage 1: Structural indexing
    var stage1_start = perf_counter_ns()
    for _ in range(iterations):
        var index = build_structural_index_v2(json)
        _ = len(index)
    var stage1_time = (perf_counter_ns() - stage1_start) // iterations
    var stage1_throughput = Float64(len(json)) / Float64(stage1_time) * 1000.0

    # Stage 2: Full parse (includes Stage 1)
    var full_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var full_time = (perf_counter_ns() - full_start) // iterations
    var full_throughput = Float64(len(json)) / Float64(full_time) * 1000.0

    # Calculate Stage 2 time
    var stage2_time = full_time - stage1_time
    var stage1_pct = Float64(stage1_time) / Float64(full_time) * 100.0
    var stage2_pct = Float64(stage2_time) / Float64(full_time) * 100.0

    print("\nTiming breakdown:")
    print("  Stage 1 (index):  ", Int(stage1_time / 1000), "us (", Int(stage1_pct), "%) -", Int(stage1_throughput), "MB/s")
    print("  Stage 2 (tape):   ", Int(stage2_time / 1000), "us (", Int(stage2_pct), "%) -", Int(Float64(len(json)) / Float64(stage2_time) * 1000.0), "MB/s")
    print("  Total:            ", Int(full_time / 1000), "us -", Int(full_throughput), "MB/s")


fn main() raises:
    print("Stage Profiling: Where is time spent?")

    profile_file("twitter.json", "benchmarks/data/twitter.json")
    profile_file("canada.json", "benchmarks/data/canada.json")
    profile_file("citm_catalog.json", "benchmarks/data/citm_catalog.json")

    print("\n" + "=" * 50)
    print("Optimization targets:")
    print("- If Stage 1 is slow: Parallel structural indexing")
    print("- If Stage 2 is slow: Better float/string parsing")
    print("=" * 50)
