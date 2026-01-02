"""Test lazy JSON parser."""

from src.lazy_parser import parse_lazy, LazyJsonDocument
from time import perf_counter_ns


fn test_object_access() raises -> Bool:
    """Test accessing object members."""
    print("Testing object access...")

    var json = '{"name": "Alice", "age": 30, "active": true}'
    var doc = parse_lazy(json)
    var root = doc.root()

    if not root.is_object():
        print("  FAIL: Root not detected as object")
        return False

    # Access name
    var name = root["name"].as_string()
    if name != "Alice":
        print("  FAIL: name =", name, "expected Alice")
        return False

    # Access age
    var age = root["age"].as_int()
    if age != 30:
        print("  FAIL: age =", age, "expected 30")
        return False

    # Access active
    var active = root["active"].as_bool()
    if not active:
        print("  FAIL: active should be true")
        return False

    print("  name =", name)
    print("  age =", age)
    print("  active =", active)
    print("  OK")
    return True


fn test_type_detection() raises -> Bool:
    """Test type detection without parsing."""
    print("\nTesting type detection...")

    var json = '{"str": "hello", "num": 42, "bool": true, "null": null, "arr": [], "obj": {}}'
    var doc = parse_lazy(json)
    var root = doc.root()

    print("  Root type:", root.type())

    if root.type() != "object":
        print("  FAIL: Expected object type")
        return False

    print("  OK")
    return True


fn test_lazy_vs_eager() raises -> Bool:
    """Compare lazy vs eager parsing for partial access."""
    print("\nComparing lazy vs eager parsing...")

    # Generate large JSON
    var json = String('{"data": [')
    for i in range(1000):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "name": "User_' + String(i) + '"}'
    json += '], "count": 1000}'

    print("  JSON size:", len(json), "bytes")

    # Lazy parse - just build structural index
    var lazy_start = perf_counter_ns()
    var doc = parse_lazy(json)
    var lazy_time = perf_counter_ns() - lazy_start

    # Access just one value
    var access_start = perf_counter_ns()
    var root = doc.root()
    var count = root["count"].as_int()
    var access_time = perf_counter_ns() - access_start

    print("  Lazy parse time:", lazy_time // 1000, "us")
    print("  Access 'count':", access_time // 1000, "us")
    print("  count =", count)

    if count != 1000:
        print("  FAIL: Expected count = 1000")
        return False

    print("  OK")
    return True


fn benchmark_lazy_partial():
    """Benchmark lazy parsing with partial access."""
    print("\nBenchmarking lazy parsing (partial access)...")

    # Generate JSON
    var json = String('{"metadata": {"version": "1.0"}, "data": [')
    for i in range(500):
        if i > 0:
            json += ", "
        json += '{"id": ' + String(i) + ', "values": [1, 2, 3, 4, 5]}'
    json += ']}'

    print("  JSON size:", len(json), "bytes")

    var iterations = 1000

    # Benchmark: parse + access one field
    var start = perf_counter_ns()
    for _ in range(iterations):
        var doc = parse_lazy(json)
        var root = doc.root()
        var version = root["metadata"]["version"].as_string()
        _ = version
    var elapsed = perf_counter_ns() - start

    var per_op_us = Float64(elapsed) / Float64(iterations) / 1000.0
    var throughput = Float64(len(json) * iterations) / (Float64(elapsed) / 1e9) / (1024.0 * 1024.0)

    print("  Time per parse+access:", per_op_us, "us")
    print("  Throughput:", throughput, "MB/s")


fn main() raises:
    print("=" * 60)
    print("Lazy JSON Parser Tests")
    print("=" * 60)

    var all_passed = True

    all_passed = test_object_access() and all_passed
    all_passed = test_type_detection() and all_passed
    all_passed = test_lazy_vs_eager() and all_passed

    benchmark_lazy_partial()

    print("\n" + "=" * 60)
    if all_passed:
        print("All lazy parser tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 60)
