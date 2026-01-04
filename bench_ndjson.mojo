"""
Benchmark: NDJSON Processing with Zero-Copy Optimization

Compares zero-copy StringSlice extraction vs traditional string copying.
Zero-copy extraction should be ~10x faster for line extraction.
"""

from time import perf_counter_ns
from src.ndjson import (
    parse_ndjson_parallel,
    extract_lines,
    extract_lines_simd,
    extract_line_slices,
    extract_line_slices_simd,
    find_line_boundaries,
    find_line_boundaries_simd,
    ndjson_stats,
    NdjsonIterator,
)
from src.string_slice import StringSlice, SliceList
from src.tape_parser import parse_to_tape


fn generate_ndjson(num_lines: Int) -> String:
    """Generate synthetic NDJSON data."""
    var result = String("")

    for i in range(num_lines):
        if i > 0:
            result += "\n"
        result += '{"id": ' + String(i)
        result += ', "name": "User' + String(i) + '"'
        result += ', "value": ' + String(Float64(i) * 1.5)
        result += ', "active": ' + ('true' if i % 2 == 0 else 'false')
        result += ', "tags": ["tag1", "tag2", "tag3"]'
        result += '}'

    return result


fn generate_complex_ndjson(num_lines: Int) -> String:
    """Generate more complex NDJSON with nested objects."""
    var result = String("")

    for i in range(num_lines):
        if i > 0:
            result += "\n"
        result += '{"id": ' + String(i)
        result += ', "user": {"name": "User' + String(i) + '", "email": "user' + String(i) + '@test.com"}'
        result += ', "metrics": {"views": ' + String(i * 100) + ', "clicks": ' + String(i * 10) + '}'
        result += ', "coords": [' + String(Float64(i) * 0.1) + ', ' + String(Float64(i) * 0.2) + ']'
        result += '}'

    return result


fn benchmark_line_detection(ndjson: String, name: String):
    """Benchmark line boundary detection."""
    var iterations = 100

    print("\n" + name + " - Line Detection")
    print("  Size:", Int(Float64(len(ndjson)) / 1024.0), "KB")

    # Scalar
    var scalar_start = perf_counter_ns()
    for _ in range(iterations):
        var lines = find_line_boundaries(ndjson)
        _ = len(lines)
    var scalar_time = perf_counter_ns() - scalar_start
    var scalar_throughput = Float64(len(ndjson)) * Float64(iterations) / Float64(scalar_time) * 1000.0
    print("  Scalar:    ", Int(scalar_throughput), "MB/s")

    # SIMD
    var simd_start = perf_counter_ns()
    for _ in range(iterations):
        var lines = find_line_boundaries_simd(ndjson)
        _ = len(lines)
    var simd_time = perf_counter_ns() - simd_start
    var simd_throughput = Float64(len(ndjson)) * Float64(iterations) / Float64(simd_time) * 1000.0
    print("  SIMD:      ", Int(simd_throughput), "MB/s")

    var speedup = simd_throughput / scalar_throughput
    print("  Speedup:   ", String(speedup)[:4] + "x")


fn benchmark_extraction(ndjson: String, name: String, iterations: Int):
    """Benchmark line extraction: zero-copy vs copying."""
    var stats = ndjson_stats(ndjson)
    var num_lines = stats[0]
    var total_bytes = stats[1]

    print("\n" + name + " - Line Extraction (Zero-Copy vs Copying)")
    print("  Lines:", num_lines, "  Size:", Int(Float64(total_bytes) / 1024.0), "KB")

    # Zero-copy extraction (StringSlice)
    var zerocopy_start = perf_counter_ns()
    for _ in range(iterations):
        var slices = extract_line_slices(ndjson)
        _ = len(slices)
    var zerocopy_time = perf_counter_ns() - zerocopy_start
    var zerocopy_throughput = Float64(total_bytes) * Float64(iterations) / Float64(zerocopy_time) * 1000.0
    print("  Zero-copy: ", Int(zerocopy_throughput), "MB/s")

    # Copying extraction (String)
    var copy_start = perf_counter_ns()
    for _ in range(iterations):
        var lines = extract_lines(ndjson)
        _ = len(lines)
    var copy_time = perf_counter_ns() - copy_start
    var copy_throughput = Float64(total_bytes) * Float64(iterations) / Float64(copy_time) * 1000.0
    print("  Copying:   ", Int(copy_throughput), "MB/s")

    var speedup = zerocopy_throughput / copy_throughput
    print("  Speedup:   " + String(speedup)[:4] + "x faster with zero-copy")


fn benchmark_zerocopy_parsing(ndjson: String, name: String, iterations: Int) raises:
    """Benchmark full parsing using zero-copy extraction."""
    var stats = ndjson_stats(ndjson)
    var num_lines = stats[0]
    var total_bytes = stats[1]

    print("\n" + name + " - Full Parsing (Zero-Copy vs Copying)")
    print("  Lines:", num_lines, "  Size:", Int(Float64(total_bytes) / 1024.0), "KB")

    # Zero-copy extraction + parse_to_tape
    var zerocopy_start = perf_counter_ns()
    for _ in range(iterations):
        var slices = extract_line_slices(ndjson)
        for i in range(len(slices)):
            var line = slices[i].to_string()  # Convert when parsing
            var tape = parse_to_tape(line)
            _ = len(tape.entries)
    var zerocopy_time = perf_counter_ns() - zerocopy_start
    var zerocopy_throughput = Float64(total_bytes) * Float64(iterations) / Float64(zerocopy_time) * 1000.0
    print("  Zero-copy: ", Int(zerocopy_throughput), "MB/s")

    # Copying extraction + parse_to_tape
    var copy_start = perf_counter_ns()
    for _ in range(iterations):
        var lines = extract_lines(ndjson)
        for i in range(len(lines)):
            var tape = parse_to_tape(lines[i])
            _ = len(tape.entries)
    var copy_time = perf_counter_ns() - copy_start
    var copy_throughput = Float64(total_bytes) * Float64(iterations) / Float64(copy_time) * 1000.0
    print("  Copying:   ", Int(copy_throughput), "MB/s")

    var speedup = zerocopy_throughput / copy_throughput
    if speedup > 1.0:
        print("  Speedup:   " + String(speedup)[:4] + "x faster with zero-copy")
    else:
        print("  Ratio:     " + String(speedup)[:4] + "x (similar - parsing dominates)")


fn benchmark_full_parsing(ndjson: String, name: String, iterations: Int) raises:
    """Benchmark full NDJSON parsing (extraction + parse_to_tape)."""
    var stats = ndjson_stats(ndjson)
    var num_lines = stats[0]
    var total_bytes = stats[1]

    print("\n" + name + " - Full Parsing")
    print("  Lines:", num_lines, "  Size:", Int(Float64(total_bytes) / 1024.0), "KB")

    # Full parsing with SIMD extraction
    var start = perf_counter_ns()
    for _ in range(iterations):
        var lines = extract_lines_simd(ndjson)
        for i in range(len(lines)):
            var tape = parse_to_tape(lines[i])
            _ = len(tape.entries)
    var elapsed = perf_counter_ns() - start
    var throughput = Float64(total_bytes) * Float64(iterations) / Float64(elapsed) * 1000.0
    print("  Throughput:", Int(throughput), "MB/s")


fn test_correctness() raises:
    """Verify NDJSON parser produces correct results."""
    print("\n" + "=" * 60)
    print("Correctness Test")
    print("=" * 60)

    var ndjson = """{"a": 1}
{"b": 2}
{"c": 3}
{"d": 4}
{"e": 5}"""

    # Extract lines
    var lines = parse_ndjson_parallel(ndjson)

    print("  Lines extracted:", len(lines))

    # Verify each line parses correctly
    var valid = 0
    for i in range(len(lines)):
        try:
            var tape = parse_to_tape(lines[i])
            if len(tape.entries) > 0:
                valid += 1
        except:
            pass

    print("  Valid JSON lines:", valid)

    if valid == 5:
        print("  Status: PASS")
    else:
        print("  Status: FAIL")


fn main() raises:
    print("=" * 60)
    print("NDJSON Processing Benchmark")
    print("=" * 60)

    # Test correctness first
    test_correctness()

    # Generate test data
    var small_ndjson = generate_ndjson(100)
    var medium_ndjson = generate_ndjson(1000)
    var large_ndjson = generate_ndjson(10000)
    var complex_ndjson = generate_complex_ndjson(1000)

    # Benchmark line detection
    print("\n" + "=" * 60)
    print("Line Detection Benchmarks (Scalar vs SIMD)")
    print("=" * 60)

    benchmark_line_detection(small_ndjson, "Small (100 lines)")
    benchmark_line_detection(medium_ndjson, "Medium (1000 lines)")
    benchmark_line_detection(large_ndjson, "Large (10000 lines)")

    # Benchmark line extraction (Zero-Copy vs Copying)
    print("\n" + "=" * 60)
    print("Line Extraction: Zero-Copy vs Copying")
    print("=" * 60)

    benchmark_extraction(small_ndjson, "Small (100 lines)", 50)
    benchmark_extraction(medium_ndjson, "Medium (1000 lines)", 20)
    benchmark_extraction(large_ndjson, "Large (10000 lines)", 5)

    # Benchmark full parsing with zero-copy
    print("\n" + "=" * 60)
    print("Full Parsing: Zero-Copy vs Copying")
    print("=" * 60)

    benchmark_zerocopy_parsing(small_ndjson, "Small (100 lines)", 20)
    benchmark_zerocopy_parsing(medium_ndjson, "Medium (1000 lines)", 10)
    benchmark_zerocopy_parsing(large_ndjson, "Large (10000 lines)", 3)

    # Benchmark raw full parsing
    print("\n" + "=" * 60)
    print("Raw Parsing Throughput")
    print("=" * 60)

    benchmark_full_parsing(small_ndjson, "Small (100 lines)", 20)
    benchmark_full_parsing(medium_ndjson, "Medium (1000 lines)", 10)
    benchmark_full_parsing(complex_ndjson, "Complex (1000 lines)", 10)

    # Statistics
    print("\n" + "=" * 60)
    print("NDJSON Statistics")
    print("=" * 60)

    var stats = ndjson_stats(medium_ndjson)
    print("  Medium NDJSON:")
    print("    Lines:", stats[0])
    print("    Total bytes:", stats[1])
    print("    Avg bytes/line:", stats[2])

    # Iterator test
    print("\n" + "=" * 60)
    print("Iterator Test")
    print("=" * 60)

    var iter = NdjsonIterator(small_ndjson)
    print("  Total lines:", iter.line_count())

    var count = 0
    while iter.has_next():
        var tape = iter.next()
        _ = tape
        count += 1
        if count >= 5:
            break

    print("  Iterated:", count, "lines")

    # Summary
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    print("")
    print("NDJSON processing uses SIMD for line detection:")
    print("  - Scans 16 bytes at a time for newlines")
    print("  - ~2-3x faster for large files")
    print("  - Lines can be parsed in parallel in user code")
    print("")
    print("Usage example:")
    print("  var lines = parse_ndjson_parallel(ndjson)")
    print("  parallelize[parse_line](len(lines))")
    print("")
    print("=" * 60)
