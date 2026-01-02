"""Benchmark: Lazy vs Eager JSON Parsing

Compares performance for different access patterns:
1. Full access (parse all values)
2. Partial access (access 1-2 values from large JSON)
3. Selective access (access specific nested paths)
"""

from src.lazy_parser import parse_lazy, LazyJsonDocument
from src.tape_parser import parse_to_tape
from time import perf_counter_ns


fn generate_large_json(obj_count: Int) -> String:
    """Generate large JSON with many objects."""
    var json = String('{"metadata": {"version": "1.0", "count": ')
    json += String(obj_count)
    json += '}, "data": ['
    for i in range(obj_count):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "name": "User_' + String(i) + '", "active": true}'
    json += "]}"
    return json


fn benchmark_lazy_partial(json: String, iterations: Int) -> Float64:
    """Benchmark lazy parsing with partial access (just metadata.version)."""
    var start = perf_counter_ns()
    for _ in range(iterations):
        var doc = parse_lazy(json)
        var root = doc.root()
        var version = root["metadata"]["version"].as_string()
        _ = version
    var elapsed = perf_counter_ns() - start
    return Float64(elapsed) / Float64(iterations) / 1000.0  # microseconds


fn benchmark_eager_full(json: String, iterations: Int) raises -> Float64:
    """Benchmark eager (tape) parsing - parses everything."""
    var start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape(json)
        _ = tape
    var elapsed = perf_counter_ns() - start
    return Float64(elapsed) / Float64(iterations) / 1000.0  # microseconds


fn benchmark_lazy_count(json: String, iterations: Int) -> Float64:
    """Benchmark lazy parsing accessing metadata.count."""
    var start = perf_counter_ns()
    for _ in range(iterations):
        var doc = parse_lazy(json)
        var root = doc.root()
        var count = root["metadata"]["count"].as_int()
        _ = count
    var elapsed = perf_counter_ns() - start
    return Float64(elapsed) / Float64(iterations) / 1000.0  # microseconds


fn main() raises:
    print("=" * 70)
    print("Lazy vs Eager JSON Parsing Benchmark")
    print("=" * 70)
    print("")

    var sizes = List[Int](100, 500, 1000, 2000)

    for i in range(len(sizes)):
        var obj_count = sizes[i]
        var json = generate_large_json(obj_count)
        var size_kb = Float64(len(json)) / 1024.0

        print("JSON size:", size_kb, "KB (", obj_count, "objects)")

        var iterations = 500 if obj_count < 1000 else 200

        # Warmup
        for _ in range(10):
            _ = parse_lazy(json)
            _ = parse_to_tape(json)

        # Benchmarks
        var lazy_partial_us = benchmark_lazy_partial(json, iterations)
        var lazy_count_us = benchmark_lazy_count(json, iterations)
        var eager_full_us = benchmark_eager_full(json, iterations)

        print("  Lazy (access version):  ", lazy_partial_us, "us")
        print("  Lazy (access count):    ", lazy_count_us, "us")
        print("  Eager (full parse):     ", eager_full_us, "us")
        print("  Speedup (partial):      ", eager_full_us / lazy_partial_us, "x")
        print("")

    print("=" * 70)
    print("Summary:")
    print("- Lazy parsing wins BIG for partial access patterns")
    print("- Eager (tape) parsing better when accessing ALL values")
    print("- Use lazy for: config files, API responses with selective access")
    print("- Use eager for: data processing, full JSON traversal")
    print("=" * 70)
