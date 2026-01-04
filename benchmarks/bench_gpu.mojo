"""GPU vs CPU Structural Scan Benchmark.

Compares GPU and CPU performance for structural character scanning.
Tests various file sizes to find GPU crossover point.

Usage:
    cd mojo-json
    mojo run -I . benchmarks/bench_gpu.mojo
"""

from time import perf_counter_ns
from src.gpu.structural_scan import (
    gpu_structural_scan,
    is_gpu_available,
    GPU_CROSSOVER_SIZE,
    _cpu_structural_scan,
)
from src.structural_index import build_structural_index


alias WARMUP = 3
alias ITERATIONS = 20


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


fn benchmark_gpu_scan(json: String) raises -> Float64:
    """Benchmark GPU structural scan."""
    # Warmup
    for _ in range(WARMUP):
        var result = gpu_structural_scan(json)
        _ = result.count

    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        var result = gpu_structural_scan(json)
        _ = result.count
    var elapsed = perf_counter_ns() - start

    var bytes_processed = len(json) * ITERATIONS
    var seconds = Float64(elapsed) / 1e9
    return Float64(bytes_processed) / seconds / 1e6  # MB/s


fn main() raises:
    print("=" * 70)
    print("GPU vs CPU Structural Scan Benchmark")
    print("=" * 70)
    print()

    print("GPU Available:", is_gpu_available())
    print("GPU Crossover Size:", GPU_CROSSOVER_SIZE // 1024, "KB")
    print()

    print("-" * 70)
    print("Size (KB)".ljust(12), "CPU SIMD".rjust(12), "GPU Scan".rjust(12), "Speedup".rjust(12))
    print("-" * 70)

    for size_kb in List(1, 4, 16, 64, 256, 1024):
        var json = generate_json(size_kb)
        var actual_size = len(json) // 1024

        var cpu_mbs = benchmark_cpu_simd(json)
        var gpu_mbs = benchmark_gpu_scan(json)
        var speedup = gpu_mbs / cpu_mbs

        print(
            String(actual_size).rjust(8), "KB".ljust(4),
            String(Int(cpu_mbs)).rjust(8), "MB/s".ljust(4),
            String(Int(gpu_mbs)).rjust(8), "MB/s".ljust(4),
            String(speedup)[:4] + "x"
        )

    print("-" * 70)
    print()
    print("NOTES:")
    print("  - GPU scan currently uses CPU fallback (kernel not yet implemented)")
    print("  - Expected GPU speedup: 2-4x for files > 64 KB")
    print("  - Target: 2,000+ MB/s for large files")
    print("=" * 70)
