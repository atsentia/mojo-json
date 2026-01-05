"""NEON SIMD FFI Benchmark.

Compares NEON SIMD (via FFI) vs CPU structural scanning performance.
Target: 3-4 GB/s on Apple Silicon.

Usage:
    cd mojo-json
    mojo run -I . benchmarks/bench_neon.mojo
"""

from time import perf_counter_ns
from src.neon_ffi import NeonJsonIndexer, neon_is_available
from src.structural_index import build_structural_index


alias WARMUP = 5
alias ITERATIONS = 50


fn generate_json(size_kb: Int) -> String:
    """Generate JSON of approximately the given size in KB."""
    var target_size = size_kb * 1024

    # Template: {"key0": "value0", "key1": "value1", ...}
    var result = String("{")
    var i = 0

    while len(result) < target_size:
        if i > 0:
            result += ", "
        result += '"key' + String(i) + '": "value' + String(i) + '"'
        i += 1

    result += "}"
    return result


fn generate_json_with_escapes(size_kb: Int) -> String:
    """Generate JSON with escaped strings (harder to parse)."""
    var target_size = size_kb * 1024
    var result = String("{")
    var i = 0

    while len(result) < target_size:
        if i > 0:
            result += ", "
        # Include escaped characters to test escape handling
        result += '"key' + String(i) + '": "value\\"with\\\\escapes\\n' + String(i) + '"'
        i += 1

    result += "}"
    return result


fn benchmark_cpu_simd(json: String) -> Float64:
    """Benchmark CPU SIMD structural index."""
    # Warmup
    for _ in range(WARMUP):
        var idx = build_structural_index(json)
        _ = len(idx)

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var idx = build_structural_index(json)
        _ = len(idx)
    var elapsed = perf_counter_ns() - start

    var bytes_processed = len(json) * ITERATIONS
    var seconds = Float64(elapsed) / 1e9
    return Float64(bytes_processed) / seconds / 1e6  # MB/s


fn benchmark_neon_structural(neon: NeonJsonIndexer, json: String) raises -> Float64:
    """Benchmark NEON SIMD structural extraction."""
    # Warmup
    for _ in range(WARMUP):
        var result = neon.find_structural(json)
        _ = result.count

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var result = neon.find_structural(json)
        _ = result.count
    var elapsed = perf_counter_ns() - start

    var bytes_processed = len(json) * ITERATIONS
    var seconds = Float64(elapsed) / 1e9
    return Float64(bytes_processed) / seconds / 1e6  # MB/s


fn benchmark_neon_classify(neon: NeonJsonIndexer, json: String) raises -> Float64:
    """Benchmark NEON SIMD simple classification (no string filtering)."""
    # Warmup
    for _ in range(WARMUP):
        var result = neon.classify(json)
        _ = len(result)

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var result = neon.classify(json)
        _ = len(result)
    var elapsed = perf_counter_ns() - start

    var bytes_processed = len(json) * ITERATIONS
    var seconds = Float64(elapsed) / 1e9
    return Float64(bytes_processed) / seconds / 1e6  # MB/s


fn main() raises:
    print("=" * 80)
    print("NEON SIMD FFI Benchmark")
    print("=" * 80)
    print()

    print("NEON Available:", neon_is_available())

    var neon = NeonJsonIndexer()
    print("Theoretical Throughput:", Int(neon.throughput_estimate()), "MB/s")
    print()

    # Test correctness first
    print("Testing correctness...")
    var test_json = '{"name": "test", "value": 42, "nested": {"a": "b\\nc"}}'
    var result = neon.find_structural(test_json)
    print("  Test JSON:", len(test_json), "bytes")
    print("  Structural chars found:", result.count)
    print("  Result:", result)
    print()

    # Simple JSON benchmark
    print("-" * 80)
    print("Simple JSON (no escapes)")
    print("-" * 80)
    print(
        "Size".ljust(10),
        "CPU SIMD".rjust(12),
        "NEON Full".rjust(12),
        "NEON Class".rjust(12),
        "Speedup".rjust(10),
    )
    print("-" * 80)

    for size_kb in List(4, 16, 64, 256, 1024, 4096):
        var json = generate_json(size_kb)
        var actual_size = len(json)

        var cpu_mbs = benchmark_cpu_simd(json)
        var neon_mbs = benchmark_neon_structural(neon, json)
        var neon_class_mbs = benchmark_neon_classify(neon, json)
        var speedup = neon_mbs / cpu_mbs

        var size_str = String(actual_size // 1024) + " KB"
        print(
            size_str.ljust(10),
            String(Int(cpu_mbs)).rjust(8) + " MB/s",
            String(Int(neon_mbs)).rjust(8) + " MB/s",
            String(Int(neon_class_mbs)).rjust(8) + " MB/s",
            String(speedup)[:4].rjust(6) + "x",
        )

    print()

    # JSON with escapes benchmark
    print("-" * 80)
    print("JSON with escapes (harder)")
    print("-" * 80)
    print(
        "Size".ljust(10),
        "CPU SIMD".rjust(12),
        "NEON Full".rjust(12),
        "NEON Class".rjust(12),
        "Speedup".rjust(10),
    )
    print("-" * 80)

    for size_kb in List(4, 16, 64, 256, 1024):
        var json = generate_json_with_escapes(size_kb)
        var actual_size = len(json)

        var cpu_mbs = benchmark_cpu_simd(json)
        var neon_mbs = benchmark_neon_structural(neon, json)
        var neon_class_mbs = benchmark_neon_classify(neon, json)
        var speedup = neon_mbs / cpu_mbs

        var size_str = String(actual_size // 1024) + " KB"
        print(
            size_str.ljust(10),
            String(Int(cpu_mbs)).rjust(8) + " MB/s",
            String(Int(neon_mbs)).rjust(8) + " MB/s",
            String(Int(neon_class_mbs)).rjust(8) + " MB/s",
            String(speedup)[:4].rjust(6) + "x",
        )

    print()
    print("=" * 80)
    print("Summary")
    print("=" * 80)
    print()
    print("NEON Full = Complete structural extraction (with string filtering)")
    print("NEON Class = Simple classification only (no string filtering)")
    print("Speedup = NEON Full / CPU SIMD")
    print()
    print("Target: 3-4 GB/s (3000-4000 MB/s) on Apple Silicon")
