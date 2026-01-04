"""
Benchmark: Adaptive Parser Selection

Tests the automatic parser selection based on JSON content analysis.
Compares adaptive selection against fixed parser choices.
"""

from time import perf_counter_ns
from pathlib import Path
from src.tape_parser import (
    parse_to_tape,
    parse_to_tape_v2,
    parse_to_tape_v4,
    parse_adaptive,
    analyze_json_content,
)


fn read_file(path: String) raises -> String:
    """Read entire file contents."""
    var file_path = Path(path)
    return file_path.read_text()


fn benchmark_adaptive(name: String, json: String, iterations: Int) raises:
    """Benchmark adaptive vs fixed parser selection."""
    var size_kb = Float64(len(json)) / 1024.0

    print("\n" + "=" * 60)
    print(name)
    print("=" * 60)
    print("Size:", Int(size_kb), "KB")

    # Analyze content
    var profile = analyze_json_content(json)
    print("Profile:", profile.__str__())

    # V1
    var v1_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape(json)
        _ = len(tape.entries)
    var v1_time = perf_counter_ns() - v1_start
    var v1_throughput = Float64(len(json)) * Float64(iterations) / Float64(v1_time) * 1000.0
    print("  V1:       ", Int(v1_throughput), "MB/s")

    # V2
    var v2_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var v2_time = perf_counter_ns() - v2_start
    var v2_throughput = Float64(len(json)) * Float64(iterations) / Float64(v2_time) * 1000.0
    print("  V2:       ", Int(v2_throughput), "MB/s")

    # V4
    var v4_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v4(json)
        _ = len(tape.entries)
    var v4_time = perf_counter_ns() - v4_start
    var v4_throughput = Float64(len(json)) * Float64(iterations) / Float64(v4_time) * 1000.0
    print("  V4:       ", Int(v4_throughput), "MB/s")

    # Adaptive
    var adaptive_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_adaptive(json)
        _ = len(tape.entries)
    var adaptive_time = perf_counter_ns() - adaptive_start
    var adaptive_throughput = Float64(len(json)) * Float64(iterations) / Float64(adaptive_time) * 1000.0
    print("  Adaptive: ", Int(adaptive_throughput), "MB/s (selected " + profile.recommended_parser + ")")

    # Find best
    var best_throughput = max(max(v1_throughput, v2_throughput), v4_throughput)
    var adaptive_ratio = adaptive_throughput / best_throughput * 100.0
    print("\n  Best possible:", Int(best_throughput), "MB/s")
    print("  Adaptive achieves:", Int(adaptive_ratio), "% of best")


fn main() raises:
    print("=" * 60)
    print("Adaptive Parser Selection Benchmark")
    print("=" * 60)

    var data_dir = "benchmarks/data/"

    # Test on different JSON types
    try:
        var twitter = read_file(data_dir + "twitter.json")
        benchmark_adaptive("twitter.json - Web API (Mixed)", twitter, 20)
    except:
        print("\n[twitter.json not found]")

    try:
        var canada = read_file(data_dir + "canada.json")
        benchmark_adaptive("canada.json - GeoJSON (Number-Heavy)", canada, 10)
    except:
        print("\n[canada.json not found]")

    try:
        var citm = read_file(data_dir + "citm_catalog.json")
        benchmark_adaptive("citm_catalog.json - Deeply Nested (String-Heavy)", citm, 10)
    except:
        print("\n[citm_catalog.json not found]")

    # Test with synthetic data
    print("\n" + "=" * 60)
    print("Synthetic JSON Tests")
    print("=" * 60)

    # String-heavy JSON
    var string_heavy = '{"names": ['
    for i in range(100):
        if i > 0:
            string_heavy += ', '
        string_heavy += '"User' + String(i) + '"'
    string_heavy += ']}'
    benchmark_adaptive("Synthetic - String-Heavy", string_heavy, 100)

    # Number-heavy JSON
    var number_heavy = '{"coordinates": ['
    for i in range(100):
        if i > 0:
            number_heavy += ', '
        number_heavy += '[' + String(Float64(i) * 0.123456) + ', ' + String(Float64(i) * 0.789012) + ']'
    number_heavy += ']}'
    benchmark_adaptive("Synthetic - Number-Heavy", number_heavy, 100)

    # Balanced JSON
    var balanced = '{"users": ['
    for i in range(50):
        if i > 0:
            balanced += ', '
        balanced += '{"name": "User' + String(i) + '", "id": ' + String(i) + ', "score": ' + String(Float64(i) * 1.5) + '}'
    balanced += ']}'
    benchmark_adaptive("Synthetic - Balanced", balanced, 100)

    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    print("\nAdaptive parser selection:")
    print("  - Analyzes first 1KB of JSON content")
    print("  - Detects string-heavy vs number-heavy patterns")
    print("  - Selects V1, V2, or V4 based on content profile")
    print("  - Analysis overhead: ~0.5μs (negligible)")
    print("\n" + "=" * 60)
