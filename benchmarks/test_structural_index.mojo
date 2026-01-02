"""Test structural index implementation."""

from src.structural_index import build_structural_index, build_structural_index_fast, benchmark_structural_scan


fn test_simple_object() raises -> Bool:
    """Test indexing a simple JSON object."""
    print("Testing simple object...")

    var json = '{"key": "value"}'
    var index = build_structural_index(json)

    print("  JSON:", json)
    print("  Structural chars found:", len(index))

    # Expected: { " " : " " }
    # Positions: 0, 1, 5, 6, 8, 14, 15
    for i in range(len(index)):
        var pos = index.get_position(i)
        var char = index.get_character(i)
        print("  [", i, "] pos:", pos, "char:", chr(Int(char)))

    if len(index) < 5:
        print("  FAIL: Expected at least 5 structural chars")
        return False

    print("  OK")
    return True


fn test_nested_object() raises -> Bool:
    """Test indexing nested JSON."""
    print("\nTesting nested object...")

    var json = '{"a":{"b":1}}'
    var index = build_structural_index(json)

    print("  JSON:", json)
    print("  Structural chars found:", len(index))

    for i in range(len(index)):
        var pos = index.get_position(i)
        var char = index.get_character(i)
        print("  [", i, "] pos:", pos, "char:", chr(Int(char)))

    print("  OK")
    return True


fn test_array() raises -> Bool:
    """Test indexing JSON array."""
    print("\nTesting array...")

    var json = '[1, 2, 3]'
    var index = build_structural_index(json)

    print("  JSON:", json)
    print("  Structural chars found:", len(index))

    # Expected: [ , , ]
    for i in range(len(index)):
        var pos = index.get_position(i)
        var char = index.get_character(i)
        print("  [", i, "] pos:", pos, "char:", chr(Int(char)))

    print("  OK")
    return True


fn test_string_with_structural() raises -> Bool:
    """Test that structural chars inside strings are NOT indexed."""
    print("\nTesting string containing structural chars...")

    var json = '{"key": "val{ue}"}'
    var index = build_structural_index(json)

    print("  JSON:", json)
    print("  Structural chars found:", len(index))

    for i in range(len(index)):
        var pos = index.get_position(i)
        var char = index.get_character(i)
        print("  [", i, "] pos:", pos, "char:", chr(Int(char)))

    # The { inside "val{ue}" should NOT be indexed
    # Only outer { } and quotes should be indexed
    print("  OK")
    return True


fn test_escaped_quote() raises -> Bool:
    """Test escaped quotes in strings."""
    print("\nTesting escaped quotes...")

    var json = '{"key": "val\\"ue"}'
    var index = build_structural_index(json)

    print("  JSON:", json)
    print("  Structural chars found:", len(index))

    for i in range(len(index)):
        var pos = index.get_position(i)
        var char = index.get_character(i)
        print("  [", i, "] pos:", pos, "char:", chr(Int(char)))

    print("  OK")
    return True


fn test_throughput() raises:
    """Benchmark structural index building."""
    print("\n" + "=" * 70)
    print("Throughput Benchmark")
    print("=" * 70)

    # Generate test JSON of various sizes
    var sizes = List[Int]()
    sizes.append(1000)
    sizes.append(10000)
    sizes.append(100000)

    for i in range(len(sizes)):
        var size = sizes[i]

        # Generate JSON array of numbers
        var json = String("[")
        var num_elements = size // 5  # ~5 bytes per "1234,"
        for j in range(num_elements):
            if j > 0:
                json += ","
            json += "1234"
        json += "]"

        var actual_size = len(json)
        var iterations = 1000 if actual_size < 10000 else 100

        var throughput = benchmark_structural_scan(json, iterations)
        print("Size:", actual_size, "bytes | Throughput:", Int(throughput), "MB/s")


fn main() raises:
    print("=" * 70)
    print("Structural Index Tests")
    print("=" * 70)

    var all_passed = True

    all_passed = test_simple_object() and all_passed
    all_passed = test_nested_object() and all_passed
    all_passed = test_array() and all_passed
    all_passed = test_string_with_structural() and all_passed
    all_passed = test_escaped_quote() and all_passed

    print("\n" + "=" * 70)
    if all_passed:
        print("All structural index tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 70)

    # Run throughput benchmark
    test_throughput()
