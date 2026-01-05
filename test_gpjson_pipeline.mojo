"""Test GpJSON-inspired GPU Stage 1 pipeline."""

from src.metal_ffi import (
    MetalGpJsonPipeline,
    has_gpjson_pipeline,
    is_metal_available,
)
from time import perf_counter_ns


fn test_gpjson_available():
    """Test that GpJSON pipeline is available."""
    print("Testing GpJSON availability...")
    print("  Metal available:", is_metal_available())
    print("  GpJSON pipeline:", has_gpjson_pipeline())


fn test_simple_json() raises:
    """Test with simple JSON."""
    print("\nTesting simple JSON...")
    var json = '{"name": "Alice", "age": 30}'

    var pipeline = MetalGpJsonPipeline()
    var result = pipeline.run_stage1(json)

    print("  Input:", json)
    print("  Structural chars found:", len(result))
    print("  Positions:", end=" ")
    for i in range(len(result)):
        print(result.positions[i], end=" ")
    print()
    print("  Chars:", end=" ")
    for i in range(len(result)):
        print(chr(Int(result.chars[i])), end=" ")
    print()

    # Expected: { " : " , " : }
    # Positions: 0, 1, 6, 8, 15, 17, 22, 24, 27
    print("  Expected ~9 structural chars")


fn test_nested_json() raises:
    """Test with nested JSON."""
    print("\nTesting nested JSON...")
    var json = '{"user": {"name": "Bob", "items": [1, 2, 3]}}'

    var pipeline = MetalGpJsonPipeline()
    var result = pipeline.run_stage1(json)

    print("  Input:", json)
    print("  Structural chars found:", len(result))


fn test_string_with_special_chars() raises:
    """Test that structural chars inside strings are filtered."""
    print("\nTesting string filtering...")
    var json = '{"msg": "Hello, {world}!"}'  # { } inside string should be filtered

    var pipeline = MetalGpJsonPipeline()
    var result = pipeline.run_stage1(json)

    print("  Input:", json)
    print("  Structural chars found:", len(result))
    print("  Chars:", end=" ")
    for i in range(len(result)):
        print(chr(Int(result.chars[i])), end=" ")
    print()
    # Should NOT include { or } from inside the string
    print("  Expected: { \" : \" } (5 structural, not 7)")


fn benchmark_gpjson(size_kb: Int) raises:
    """Benchmark GpJSON pipeline."""
    print("\nBenchmarking GpJSON pipeline (" + String(size_kb) + " KB)...")

    # Generate test data
    var base = '{"id": 12345, "name": "test", "value": 99.99},'
    var builder = String("{\"items\": [")
    var target_size = size_kb * 1024
    while len(builder) < target_size:
        builder += base
    builder += "{}]}"
    var json = builder

    print("  Actual size:", len(json), "bytes")

    var pipeline = MetalGpJsonPipeline()

    # Warmup
    _ = pipeline.run_stage1(json)

    # Benchmark
    var iterations = 10
    var start = perf_counter_ns()
    for _ in range(iterations):
        var result = pipeline.run_stage1(json)
        _ = len(result)  # Prevent optimization
    var elapsed = perf_counter_ns() - start

    var total_bytes = len(json) * iterations
    var throughput_mbs = Float64(total_bytes) / Float64(elapsed) * 1000.0

    print("  Iterations:", iterations)
    print("  Total time:", Float64(elapsed) / 1_000_000.0, "ms")
    print("  Throughput:", throughput_mbs, "MB/s")


fn main() raises:
    print("=" * 60)
    print("GpJSON GPU Stage 1 Pipeline Test")
    print("=" * 60)

    test_gpjson_available()

    if not has_gpjson_pipeline():
        print("\nGpJSON pipeline not available. Skipping tests.")
        print("Rebuild metallib: cd metal && ./build_all.sh")
        return

    test_simple_json()
    test_nested_json()
    test_string_with_special_chars()

    # Benchmarks
    benchmark_gpjson(64)
    benchmark_gpjson(256)
    benchmark_gpjson(1024)

    print("\n" + "=" * 60)
    print("All tests completed!")
    print("=" * 60)
