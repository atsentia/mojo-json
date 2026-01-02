"""Test Metal FFI for GPU-accelerated JSON classification."""

from src.metal_ffi import (
    MetalJsonClassifier,
    is_metal_available,
    CHAR_WHITESPACE,
    CHAR_BRACE_OPEN,
    CHAR_BRACE_CLOSE,
    CHAR_BRACKET_OPEN,
    CHAR_BRACKET_CLOSE,
    CHAR_QUOTE,
    CHAR_COLON,
    CHAR_COMMA,
    CHAR_BACKSLASH,
    CHAR_OTHER,
)

# Kernel variant constants
alias KERNEL_CONTIGUOUS: Int32 = 0
alias KERNEL_VEC4: Int32 = 1
alias KERNEL_LOOKUP: Int32 = 2
alias KERNEL_LOOKUP_VEC8: Int32 = 3
from time import perf_counter_ns


fn classification_name(code: UInt8) -> String:
    """Get human-readable name for classification code."""
    if code == CHAR_WHITESPACE:
        return "WS"
    elif code == CHAR_BRACE_OPEN:
        return "{"
    elif code == CHAR_BRACE_CLOSE:
        return "}"
    elif code == CHAR_BRACKET_OPEN:
        return "["
    elif code == CHAR_BRACKET_CLOSE:
        return "]"
    elif code == CHAR_QUOTE:
        return '"'
    elif code == CHAR_COLON:
        return ":"
    elif code == CHAR_COMMA:
        return ","
    elif code == CHAR_BACKSLASH:
        return "\\"
    else:
        return "."


fn test_basic_classification() raises -> Bool:
    """Test basic character classification."""
    print("Testing basic classification...")

    var classifier = MetalJsonClassifier()
    print("  GPU device:", classifier.device_name())

    var json = '{"a": 1}'
    var result = classifier.classify(json)

    print("  Input:", json)
    print("  Output:", end="")
    for i in range(len(result)):
        print(" ", classification_name(result[i]), end="")
    print()

    # Verify key characters
    # { at 0
    if result[0] != CHAR_BRACE_OPEN:
        print("  FAIL: Expected { at pos 0")
        return False

    # " at 1
    if result[1] != CHAR_QUOTE:
        print("  FAIL: Expected \" at pos 1")
        return False

    # : at 4
    if result[4] != CHAR_COLON:
        print("  FAIL: Expected : at pos 4")
        return False

    # } at 7
    if result[7] != CHAR_BRACE_CLOSE:
        print("  FAIL: Expected } at pos 7")
        return False

    print("  OK")
    return True


fn test_all_structural_chars() raises -> Bool:
    """Test all JSON structural characters."""
    print("\nTesting all structural characters...")

    var classifier = MetalJsonClassifier()
    var json = '{"arr": [1, 2], "obj": {"k": "v\\n"}}'
    var result = classifier.classify(json)

    print("  Input:", json)

    # Check for various structural chars
    var found_brace_open = False
    var found_brace_close = False
    var found_bracket_open = False
    var found_bracket_close = False
    var found_quote = False
    var found_colon = False
    var found_comma = False
    var found_backslash = False

    for i in range(len(result)):
        var c = result[i]
        if c == CHAR_BRACE_OPEN:
            found_brace_open = True
        elif c == CHAR_BRACE_CLOSE:
            found_brace_close = True
        elif c == CHAR_BRACKET_OPEN:
            found_bracket_open = True
        elif c == CHAR_BRACKET_CLOSE:
            found_bracket_close = True
        elif c == CHAR_QUOTE:
            found_quote = True
        elif c == CHAR_COLON:
            found_colon = True
        elif c == CHAR_COMMA:
            found_comma = True
        elif c == CHAR_BACKSLASH:
            found_backslash = True

    var all_found = (
        found_brace_open
        and found_brace_close
        and found_bracket_open
        and found_bracket_close
        and found_quote
        and found_colon
        and found_comma
        and found_backslash
    )

    if all_found:
        print("  Found all structural characters")
        print("  OK")
        return True
    else:
        print("  FAIL: Missing some structural characters")
        return False


fn test_kernel_variants() raises -> Bool:
    """Test all kernel variants produce same results."""
    print("\nTesting kernel variants...")

    var classifier = MetalJsonClassifier()
    var json = '{"test": [1, 2, 3], "nested": {"a": "b"}}'

    var result_contiguous = classifier.classify_variant(json, KERNEL_CONTIGUOUS)
    var result_vec4 = classifier.classify_variant(json, KERNEL_VEC4)
    var result_lookup = classifier.classify_variant(json, KERNEL_LOOKUP)
    var result_lookup_vec8 = classifier.classify_variant(json, KERNEL_LOOKUP_VEC8)

    # All results should be identical
    for i in range(len(json)):
        if (
            result_contiguous[i] != result_vec4[i]
            or result_vec4[i] != result_lookup[i]
            or result_lookup[i] != result_lookup_vec8[i]
        ):
            print("  FAIL: Kernel variant mismatch at position", i)
            return False

    print("  All 4 kernel variants produce identical results")
    print("  OK")
    return True


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


fn benchmark_gpu() raises:
    """Benchmark GPU classification throughput."""
    print("\n" + "=" * 60)
    print("GPU Classification Benchmark")
    print("=" * 60)

    var classifier = MetalJsonClassifier()
    print("GPU:", classifier.device_name())
    print()

    var sizes_kb = List[Int](16, 64, 256, 1024)

    for i in range(len(sizes_kb)):
        var size_kb = sizes_kb[i]
        var json = generate_large_json(size_kb)
        var actual_size = len(json)
        var actual_kb = Float64(actual_size) / 1024.0

        # Warmup
        for _ in range(3):
            _ = classifier.classify(json)

        # Benchmark
        var iterations = 100 if size_kb < 256 else 50

        var start = perf_counter_ns()
        for _ in range(iterations):
            var result = classifier.classify(json)
            _ = result
        var elapsed = perf_counter_ns() - start

        var avg_ns = Float64(elapsed) / Float64(iterations)
        var avg_us = avg_ns / 1000.0
        var mbps = (actual_kb / 1024.0) / (avg_us / 1e6)

        print(
            "Size:",
            actual_kb,
            "KB | Time:",
            avg_us,
            "us | Throughput:",
            mbps,
            "MB/s",
        )


fn benchmark_kernel_variants() raises:
    """Compare performance of different kernel variants."""
    print("\n" + "=" * 60)
    print("Kernel Variant Comparison (256 KB)")
    print("=" * 60)

    var classifier = MetalJsonClassifier()
    var json = generate_large_json(256)
    var actual_kb = Float64(len(json)) / 1024.0
    var iterations = 50

    var variants = List[Int32](KERNEL_CONTIGUOUS, KERNEL_VEC4, KERNEL_LOOKUP, KERNEL_LOOKUP_VEC8)
    var names = List[String]("contiguous", "vec4", "lookup", "lookup_vec8")

    for v in range(len(variants)):
        var variant = variants[v]
        # Warmup
        for _ in range(3):
            _ = classifier.classify_variant(json, variant)

        # Benchmark
        var start = perf_counter_ns()
        for _ in range(iterations):
            var result = classifier.classify_variant(json, variant)
            _ = result
        var elapsed = perf_counter_ns() - start

        var avg_us = Float64(elapsed) / Float64(iterations) / 1000.0
        var mbps = (actual_kb / 1024.0) / (avg_us / 1e6)

        print(names[v], ":", avg_us, "us |", mbps, "MB/s")


fn main() raises:
    print("=" * 60)
    print("Metal FFI Tests")
    print("=" * 60)

    # Check availability
    if not is_metal_available():
        print("Metal GPU not available!")
        return

    print("Metal GPU: Available")
    print()

    var all_passed = True

    all_passed = test_basic_classification() and all_passed
    all_passed = test_all_structural_chars() and all_passed
    all_passed = test_kernel_variants() and all_passed

    benchmark_gpu()
    benchmark_kernel_variants()

    print("\n" + "=" * 60)
    if all_passed:
        print("All Metal FFI tests PASSED")
    else:
        print("Some tests FAILED")
    print("=" * 60)
