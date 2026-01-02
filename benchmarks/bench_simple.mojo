"""Simple JSON Parser Benchmark.

Self-contained benchmark to measure mojo-json parsing patterns.
Compatible with Mojo 0.25.7.

Usage:
    cd mojo-json/benchmarks
    mojo run bench_simple.mojo
"""

from time import perf_counter_ns
from collections import List

# SIMD width for character processing
alias SIMD_WIDTH: Int = 16

# Character codes
alias SPACE: UInt8 = 0x20
alias TAB: UInt8 = 0x09
alias NEWLINE: UInt8 = 0x0A
alias CR: UInt8 = 0x0D
alias QUOTE: UInt8 = 0x22
alias BACKSLASH: UInt8 = 0x5C
alias DIGIT_0: UInt8 = 0x30
alias DIGIT_9: UInt8 = 0x39

# Structural characters
alias LBRACE: UInt8 = 0x7B   # {
alias RBRACE: UInt8 = 0x7D   # }
alias LBRACKET: UInt8 = 0x5B # [
alias RBRACKET: UInt8 = 0x5D # ]
alias COLON: UInt8 = 0x3A    # :
alias COMMA: UInt8 = 0x2C    # ,


@always_inline
fn is_whitespace(c: UInt8) -> Bool:
    """Check if byte is JSON whitespace."""
    return c == SPACE or c == TAB or c == NEWLINE or c == CR


@always_inline
fn is_structural(c: UInt8) -> Bool:
    """Check if byte is a JSON structural character."""
    return (c == QUOTE or c == LBRACE or c == RBRACE or
            c == LBRACKET or c == RBRACKET or c == COLON or c == COMMA)


fn skip_whitespace_simd(data: String, start: Int) -> Int:
    """SIMD-accelerated whitespace skipping.

    Loads 16 bytes at a time and checks each for whitespace.
    """
    var pos = start
    var n = len(data)

    # Process 16-byte chunks
    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Check if ALL bytes are whitespace (element-by-element)
        var all_ws = True
        var first_non_ws = -1

        @parameter
        for i in range(SIMD_WIDTH):
            var c = chunk[i]
            if not is_whitespace(c):
                if first_non_ws < 0:
                    first_non_ws = i
                all_ws = False

        if all_ws:
            pos += SIMD_WIDTH
        else:
            return pos + first_non_ws

    # Scalar tail
    while pos < n:
        if not is_whitespace(ord(data[pos])):
            break
        pos += 1

    return pos


fn find_structural_simd(data: String, start: Int) -> Tuple[Int, UInt8]:
    """Find next structural character using SIMD."""
    var pos = start
    var n = len(data)

    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Find first structural character
        @parameter
        for i in range(SIMD_WIDTH):
            var c = chunk[i]
            if is_structural(c):
                return (pos + i, c)

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        var c = ord(data[pos])
        if is_structural(c):
            return (pos, c)
        pos += 1

    return (n, UInt8(0))


fn count_structural_chars(data: String) -> Int:
    """Count structural characters (simulates Stage 1 parsing)."""
    var count = 0
    var pos = 0
    var n = len(data)

    while pos < n:
        var result = find_structural_simd(data, pos)
        var new_pos = result[0]
        if new_pos >= n:
            break
        count += 1
        pos = new_pos + 1

    return count


fn count_digits_simd(data: String, start: Int) -> Int:
    """SIMD-accelerated digit counting."""
    var pos = start
    var n = len(data)
    var count = 0

    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Count consecutive digits
        var all_digits = True
        var first_non_digit = -1

        @parameter
        for i in range(SIMD_WIDTH):
            var c = chunk[i]
            var is_digit = c >= DIGIT_0 and c <= DIGIT_9
            if not is_digit:
                if first_non_digit < 0:
                    first_non_digit = i
                all_digits = False

        if all_digits:
            count += SIMD_WIDTH
            pos += SIMD_WIDTH
        else:
            count += first_non_digit
            return count

    # Scalar tail
    while pos < n:
        var c = UInt8(ord(data[pos]))
        if c >= DIGIT_0 and c <= DIGIT_9:
            count += 1
            pos += 1
        else:
            break

    return count


fn benchmark_structural_scan(data: String, iterations: Int) -> Float64:
    """Benchmark structural character scanning."""
    var total_ns: Int = 0

    for _ in range(iterations):
        var start = perf_counter_ns()
        var count = count_structural_chars(data)
        var end = perf_counter_ns()
        total_ns += Int(end - start)
        _ = count

    return Float64(total_ns) / Float64(iterations) / 1_000_000.0


fn read_file(path: String) raises -> String:
    """Read file contents."""
    with open(path, "r") as f:
        return f.read()


fn main() raises:
    print("=" * 70)
    print("mojo-json SIMD Performance Benchmark")
    print("=" * 70)
    print("Mojo version: 0.25.7")
    print()

    alias ITERATIONS = 100

    # Test files
    var files = List[String]()
    files.append("data/api_response_1kb.json")
    files.append("data/api_response_10kb.json")
    files.append("data/api_response_100kb.json")
    files.append("data/twitter.json")
    files.append("data/canada.json")
    files.append("data/citm_catalog.json")

    print("Testing SIMD structural scanning (Stage 1 simulation)")
    print("-" * 70)
    print("File                               Size         Time (ms)      MB/s")
    print("-" * 70)

    var total_throughput: Float64 = 0.0
    var file_count = 0

    for i in range(len(files)):
        var filepath = files[i]
        try:
            var content = read_file(filepath)
            var size = len(content)

            # Warmup
            for _ in range(3):
                _ = count_structural_chars(content)

            # Benchmark
            var time_ms = benchmark_structural_scan(content, ITERATIONS)

            # Calculate throughput
            var mb = Float64(size) / (1024.0 * 1024.0)
            var seconds = time_ms / 1000.0
            var mbps = mb / seconds

            var size_str: String
            if size < 1024:
                size_str = String(size) + " B"
            elif size < 1024 * 1024:
                size_str = String(size // 1024) + " KB"
            else:
                size_str = String(size // 1024 // 1024) + " MB"

            # Format time nicely
            var time_str = String(time_ms)
            if len(time_str) > 8:
                time_str = time_str[:8]

            print(
                filepath.ljust(35),
                size_str.ljust(13),
                (time_str + " ms").ljust(15),
                String(Int(mbps)) + " MB/s"
            )

            total_throughput += mbps
            file_count += 1

        except:
            print(filepath.ljust(35), "SKIPPED (file not found)")

    print("-" * 70)

    if file_count > 0:
        var avg = total_throughput / Float64(file_count)
        print()
        print("Average throughput:", Int(avg), "MB/s")

    print()
    print("=" * 70)
    print("Comparison with competitors:")
    print("-" * 70)
    print("  simdjson (C++):    2,500 - 5,000 MB/s (NEON SIMD, 2-stage)")
    print("  orjson (Rust):       700 - 1,800 MB/s")
    print("  ujson (C):           300 -   900 MB/s")
    print("  json (Python):       100 -   400 MB/s")
    print("=" * 70)
