"""Test GPU-accelerated structural scanning."""

from src.gpu_structural_scan import (
    build_structural_index_gpu,
    build_structural_index_adaptive,
    should_use_gpu,
    classify_char,
    CHAR_BRACE_OPEN,
    CHAR_BRACE_CLOSE,
    CHAR_QUOTE,
    CHAR_COLON,
    CHAR_COMMA,
)
from src.structural_index import build_structural_index
from time import perf_counter_ns


fn test_classify_char() -> Bool:
    """Test character classification function."""
    print("Testing character classification...")

    if classify_char(ord('{')) != CHAR_BRACE_OPEN:
        print("  FAIL: { not classified as BRACE_OPEN")
        return False

    if classify_char(ord('}')) != CHAR_BRACE_CLOSE:
        print("  FAIL: } not classified as BRACE_CLOSE")
        return False

    if classify_char(ord('"')) != CHAR_QUOTE:
        print("  FAIL: \" not classified as QUOTE")
        return False

    if classify_char(ord(':')) != CHAR_COLON:
        print("  FAIL: : not classified as COLON")
        return False

    if classify_char(ord(',')) != CHAR_COMMA:
        print("  FAIL: , not classified as COMMA")
        return False

    print("  OK")
    return True


fn test_gpu_structural_index() raises -> Bool:
    """Test GPU structural index building."""
    print("\nTesting GPU structural index...")

    var json = '{"name": "Alice", "age": 30}'

    # Build with GPU
    var gpu_index = build_structural_index_gpu(json)

    # Build with CPU for comparison
    var cpu_index = build_structural_index(json)

    print("  CPU index length:", len(cpu_index))
    print("  GPU index length:", len(gpu_index))

    if len(cpu_index) != len(gpu_index):
        print("  FAIL: Index lengths don't match")
        return False

    # Compare positions and characters
    for i in range(len(cpu_index)):
        var cpu_pos = cpu_index.get_position(i)
        var gpu_pos = gpu_index.get_position(i)
        var cpu_char = cpu_index.get_character(i)
        var gpu_char = gpu_index.get_character(i)

        if cpu_pos != gpu_pos or cpu_char != gpu_char:
            print("  FAIL: Mismatch at index", i)
            print("    CPU: pos=", cpu_pos, "char=", cpu_char)
            print("    GPU: pos=", gpu_pos, "char=", gpu_char)
            return False

    print("  All positions match!")
    print("  OK")
    return True


fn test_should_use_gpu():
    """Test GPU usage threshold."""
    print("\nTesting GPU usage threshold...")

    if should_use_gpu(1024):
        print("  FAIL: 1KB should use CPU")

    if should_use_gpu(32 * 1024):
        print("  FAIL: 32KB should use CPU")

    if not should_use_gpu(64 * 1024):
        print("  FAIL: 64KB should use GPU")

    if not should_use_gpu(128 * 1024):
        print("  FAIL: 128KB should use GPU")

    print("  OK")


fn generate_large_json(size_kb: Int) -> String:
    """Generate JSON of approximately specified size."""
    var json = String('{"data": [')
    var obj_count = 0
    while len(json) < size_kb * 1024:
        if obj_count > 0:
            json += ", "
        json += '{"id": ' + String(obj_count) + ', "name": "User_' + String(obj_count) + '"}'
        obj_count += 1
    json += "]}"
    return json


fn benchmark_cpu_vs_gpu() raises:
    """Benchmark CPU vs GPU structural scanning."""
    print("\n" + "=" * 60)
    print("CPU vs GPU Structural Scan Benchmark")
    print("=" * 60)

    var sizes_kb = List[Int](16, 32, 64, 128, 256)

    for i in range(len(sizes_kb)):
        var size_kb = sizes_kb[i]
        var json = generate_large_json(size_kb)
        var actual_kb = Float64(len(json)) / 1024.0

        print("\nJSON size:", actual_kb, "KB")

        var iterations = 100 if size_kb < 128 else 50

        # Warmup
        for _ in range(5):
            _ = build_structural_index(json)
            _ = build_structural_index_gpu(json)

        # Benchmark CPU
        var cpu_start = perf_counter_ns()
        for _ in range(iterations):
            var idx = build_structural_index(json)
            _ = idx
        var cpu_time = perf_counter_ns() - cpu_start
        var cpu_us = Float64(cpu_time) / Float64(iterations) / 1000.0

        # Benchmark GPU
        var gpu_start = perf_counter_ns()
        for _ in range(iterations):
            var idx = build_structural_index_gpu(json)
            _ = idx
        var gpu_time = perf_counter_ns() - gpu_start
        var gpu_us = Float64(gpu_time) / Float64(iterations) / 1000.0

        var cpu_mbps = actual_kb / 1024.0 / (cpu_us / 1e6)
        var gpu_mbps = actual_kb / 1024.0 / (gpu_us / 1e6)
        var speedup = cpu_us / gpu_us

        print("  CPU:", cpu_us, "us (", cpu_mbps, "MB/s)")
        print("  GPU:", gpu_us, "us (", gpu_mbps, "MB/s)")
        print("  Speedup:", speedup, "x")


fn main() raises:
    print("=" * 60)
    print("GPU Structural Scan Tests")
    print("=" * 60)

    var all_passed = True

    all_passed = test_classify_char() and all_passed
    all_passed = test_gpu_structural_index() and all_passed
    test_should_use_gpu()

    benchmark_cpu_vs_gpu()

    print("\n" + "=" * 60)
    if all_passed:
        print("All GPU tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 60)
