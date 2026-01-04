"""Benchmark for parallel tape parser."""

from time import perf_counter_ns
from src.tape_parser import (
    parse_to_tape_v2,
    parse_to_tape_parallel,
    tape_get_float_value,
    tape_get_int_value,
    TAPE_DOUBLE,
    TAPE_INT64,
)


fn generate_number_heavy_json(num_items: Int) -> String:
    """Generate JSON with many numbers (sensor data pattern)."""
    var json = String("[")
    for i in range(num_items):
        if i > 0:
            json += ","
        var temp = 20.5 + Float64(i % 100) * 0.1
        var humidity = 45.0 + Float64(i % 50) * 0.5
        json += '{"id":' + String(i)
        json += ',"temp":' + String(temp)
        json += ',"humidity":' + String(humidity)
        json += ',"pressure":' + String(1013 + i % 20)
        json += ',"voltage":' + String(3.3 + Float64(i % 10) * 0.01)
        json += "}"
    json += "]"
    return json


fn generate_string_heavy_json(num_items: Int) -> String:
    """Generate JSON with mostly strings."""
    var json = String("[")
    for i in range(num_items):
        if i > 0:
            json += ","
        json += '{"name":"User' + String(i) + '"'
        json += ',"email":"user' + String(i) + '@example.com"'
        json += ',"city":"City' + String(i % 100) + '"'
        json += ',"country":"Country' + String(i % 50) + '"'
        json += "}"
    json += "]"
    return json


fn benchmark_parser(
    name: String,
    json: String,
    iterations: Int
) raises:
    """Benchmark regular vs parallel parser."""
    var size_kb = Float64(len(json)) / 1024.0
    print("\n" + name)
    print("  Size:", Int(size_kb), "KB")

    # Warm up
    var _ = parse_to_tape_v2(json)
    var __ = parse_to_tape_parallel(json)

    # Benchmark regular parser
    var start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var regular_ns = perf_counter_ns() - start
    var regular_ms = Float64(regular_ns) / 1_000_000.0
    var regular_throughput = Float64(len(json)) * Float64(iterations) / Float64(regular_ns) * 1000.0

    # Benchmark parallel parser
    start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_parallel(json)
        _ = len(tape.entries)
    var parallel_ns = perf_counter_ns() - start
    var parallel_ms = Float64(parallel_ns) / 1_000_000.0
    var parallel_throughput = Float64(len(json)) * Float64(iterations) / Float64(parallel_ns) * 1000.0

    # Results
    print("  Regular:  ", Int(regular_ms), "ms,", Int(regular_throughput), "MB/s")
    print("  Parallel: ", Int(parallel_ms), "ms,", Int(parallel_throughput), "MB/s")

    var speedup = regular_ms / parallel_ms
    if speedup > 1.0:
        print("  Speedup:  ", Int(speedup * 100 - 100), "% faster")
    else:
        print("  Overhead: ", Int((1.0 / speedup - 1.0) * 100), "% slower")


fn test_correctness() raises:
    """Verify parallel parser produces correct results."""
    print("\nCorrectness test:")

    var json = '[{"x": 1.5, "y": 2.5}, {"x": 3.5, "y": 4.5}]'

    var tape1 = parse_to_tape_v2(json)
    var tape2 = parse_to_tape_parallel(json)

    # Compare entry counts
    if len(tape1.entries) != len(tape2.entries):
        print("  [FAIL] Entry count mismatch:", len(tape1.entries), "vs", len(tape2.entries))
        return

    # Compare values
    var mismatch = False
    for i in range(len(tape1.entries)):
        var e1 = tape1.entries[i]
        var e2 = tape2.entries[i]

        if e1.type_tag() != e2.type_tag():
            print("  [FAIL] Type mismatch at", i)
            mismatch = True
            break

        # For numbers, check payload
        if e1.type_tag() == TAPE_INT64 or e1.type_tag() == TAPE_DOUBLE:
            if e1.data != e2.data:
                print("  [FAIL] Value mismatch at", i)
                mismatch = True
                break

    if not mismatch:
        print("  [OK] All", len(tape1.entries), "entries match")


fn main() raises:
    print("=" * 60)
    print("Parallel Tape Parser Benchmark")
    print("=" * 60)

    test_correctness()

    # Number-heavy JSON (best case for parallel)
    var number_json_small = generate_number_heavy_json(100)
    var number_json_medium = generate_number_heavy_json(1000)
    var number_json_large = generate_number_heavy_json(10000)

    benchmark_parser("Number-heavy (100 items)", number_json_small, 100)
    benchmark_parser("Number-heavy (1000 items)", number_json_medium, 50)
    benchmark_parser("Number-heavy (10000 items)", number_json_large, 10)

    # String-heavy JSON (parallel should have minimal benefit)
    var string_json = generate_string_heavy_json(1000)
    benchmark_parser("String-heavy (1000 items)", string_json, 50)

    # Count numbers in each JSON type
    print("\nNumber density analysis:")

    var tape_num = parse_to_tape_v2(number_json_medium)
    var num_count = 0
    for i in range(len(tape_num.entries)):
        var t = tape_num.entries[i].type_tag()
        if t == TAPE_INT64 or t == TAPE_DOUBLE:
            num_count += 1
    print("  Number-heavy (1000 items):", num_count, "numbers")

    var tape_str = parse_to_tape_v2(string_json)
    num_count = 0
    for i in range(len(tape_str.entries)):
        var t = tape_str.entries[i].type_tag()
        if t == TAPE_INT64 or t == TAPE_DOUBLE:
            num_count += 1
    print("  String-heavy (1000 items):", num_count, "numbers")

    print("\n" + "=" * 60)
    print("Benchmark complete!")
    print("=" * 60)
