"""Optimized JSON Parser Benchmark.

Uses efficient SIMD patterns for Mojo 0.25.7.

Usage:
    cd mojo-json/benchmarks
    mojo run bench_optimized.mojo
"""

from time import perf_counter_ns
from collections import List

# SIMD width
alias SIMD_WIDTH: Int = 16

# Character codes
alias SPACE: UInt8 = 0x20
alias TAB: UInt8 = 0x09
alias NEWLINE: UInt8 = 0x0A
alias CR: UInt8 = 0x0D
alias QUOTE: UInt8 = 0x22
alias LBRACE: UInt8 = 0x7B
alias RBRACE: UInt8 = 0x7D
alias LBRACKET: UInt8 = 0x5B
alias RBRACKET: UInt8 = 0x5D
alias COLON: UInt8 = 0x3A
alias COMMA: UInt8 = 0x2C


@always_inline
fn create_ws_mask(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create whitespace mask using SIMD. Returns 1 for whitespace, 0 otherwise."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH]()

    @parameter
    for i in range(SIMD_WIDTH):
        var c = chunk[i]
        mask[i] = 1 if (c == SPACE or c == TAB or c == NEWLINE or c == CR) else 0

    return mask


@always_inline
fn create_structural_mask(chunk: SIMD[DType.uint8, SIMD_WIDTH]) -> SIMD[DType.uint8, SIMD_WIDTH]:
    """Create structural character mask using SIMD."""
    var mask = SIMD[DType.uint8, SIMD_WIDTH]()

    @parameter
    for i in range(SIMD_WIDTH):
        var c = chunk[i]
        mask[i] = 1 if (c == QUOTE or c == LBRACE or c == RBRACE or
                        c == LBRACKET or c == RBRACKET or c == COLON or c == COMMA) else 0

    return mask


@always_inline
fn find_first_one(mask: SIMD[DType.uint8, SIMD_WIDTH]) -> Int:
    """Find index of first 1 in mask. Returns SIMD_WIDTH if none found."""
    @parameter
    for i in range(SIMD_WIDTH):
        if mask[i] == 1:
            return i
    return SIMD_WIDTH


@always_inline
fn find_first_zero(mask: SIMD[DType.uint8, SIMD_WIDTH]) -> Int:
    """Find index of first 0 in mask. Returns SIMD_WIDTH if none found."""
    @parameter
    for i in range(SIMD_WIDTH):
        if mask[i] == 0:
            return i
    return SIMD_WIDTH


fn skip_whitespace_fast(data: String, start: Int) -> Int:
    """Fast whitespace skipping using SIMD reduce_add for quick checks."""
    var pos = start
    var n = len(data)

    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Create whitespace mask
        var ws_mask = create_ws_mask(chunk)

        # Quick check: are ALL bytes whitespace?
        if ws_mask.reduce_add() == SIMD_WIDTH:
            pos += SIMD_WIDTH
            continue

        # Find first non-whitespace
        var first_non_ws = find_first_zero(ws_mask)
        return pos + first_non_ws

    # Scalar tail
    while pos < n:
        var c = ord(data[pos])
        if c != Int(SPACE) and c != Int(TAB) and c != Int(NEWLINE) and c != Int(CR):
            break
        pos += 1

    return pos


fn find_structural_fast(data: String, start: Int) -> Tuple[Int, UInt8]:
    """Find next structural character using optimized SIMD."""
    var pos = start
    var n = len(data)

    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Create structural mask
        var struct_mask = create_structural_mask(chunk)

        # Quick check: any structural chars?
        if struct_mask.reduce_add() > 0:
            # Find first structural character
            @parameter
            for i in range(SIMD_WIDTH):
                if struct_mask[i] == 1:
                    return (pos + i, chunk[i])

        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        var c = UInt8(ord(data[pos]))
        if (c == QUOTE or c == LBRACE or c == RBRACE or
            c == LBRACKET or c == RBRACKET or c == COLON or c == COMMA):
            return (pos, c)
        pos += 1

    return (n, UInt8(0))


fn count_structural_fast(data: String) -> Int:
    """Count structural characters with optimized SIMD."""
    var count = 0
    var pos = 0
    var n = len(data)

    while pos + SIMD_WIDTH <= n:
        # Load 16 bytes
        var chunk = SIMD[DType.uint8, SIMD_WIDTH]()

        @parameter
        for i in range(SIMD_WIDTH):
            chunk[i] = ord(data[pos + i])

        # Create structural mask and count
        var struct_mask = create_structural_mask(chunk)
        count += Int(struct_mask.reduce_add())
        pos += SIMD_WIDTH

    # Scalar tail
    while pos < n:
        var c = UInt8(ord(data[pos]))
        if (c == QUOTE or c == LBRACE or c == RBRACE or
            c == LBRACKET or c == RBRACKET or c == COLON or c == COMMA):
            count += 1
        pos += 1

    return count


fn benchmark_structural_count(data: String, iterations: Int) -> Tuple[Float64, Int]:
    """Benchmark structural character counting. Returns (time_ms, count)."""
    var total_ns: Int = 0
    var result_count = 0

    for _ in range(iterations):
        var start = perf_counter_ns()
        result_count = count_structural_fast(data)
        var end = perf_counter_ns()
        total_ns += Int(end - start)

    var time_ms = Float64(total_ns) / Float64(iterations) / 1_000_000.0
    return (time_ms, result_count)


fn read_file(path: String) raises -> String:
    """Read file contents."""
    with open(path, "r") as f:
        return f.read()


fn main() raises:
    print("=" * 75)
    print("mojo-json Optimized SIMD Benchmark")
    print("=" * 75)
    print("Mojo version: 0.25.7 | SIMD width: 16 bytes")
    print()

    alias ITERATIONS = 100

    var files = List[String]()
    files.append("data/api_response_1kb.json")
    files.append("data/api_response_10kb.json")
    files.append("data/api_response_100kb.json")
    files.append("data/api_response_1mb.json")
    files.append("data/twitter.json")
    files.append("data/canada.json")
    files.append("data/citm_catalog.json")

    print("Structural Character Counting (Stage 1 Simulation)")
    print("-" * 75)
    print("File                               Size         Time        Throughput")
    print("-" * 75)

    var total_throughput: Float64 = 0.0
    var file_count = 0

    for i in range(len(files)):
        var filepath = files[i]
        try:
            var content = read_file(filepath)
            var size = len(content)

            # Warmup
            for _ in range(5):
                _ = count_structural_fast(content)

            # Benchmark
            var result = benchmark_structural_count(content, ITERATIONS)
            var time_ms = result[0]
            var struct_count = result[1]

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

            var time_str = String(time_ms)
            if len(time_str) > 6:
                time_str = time_str[:6]

            print(
                filepath.ljust(35),
                size_str.ljust(13),
                (time_str + " ms").ljust(12),
                String(Int(mbps)) + " MB/s"
            )

            total_throughput += mbps
            file_count += 1

        except:
            print(filepath.ljust(35), "SKIPPED")

    print("-" * 75)

    if file_count > 0:
        var avg = total_throughput / Float64(file_count)
        print()
        print("RESULTS:")
        print("  Files tested:", file_count)
        print("  Average throughput:", Int(avg), "MB/s")
        print()

        # Performance analysis
        print("PERFORMANCE ANALYSIS:")
        print("-" * 75)
        var simdjson_avg = 3500.0  # MB/s
        var orjson_avg = 900.0     # MB/s

        print("  vs simdjson (C++):  ", end="")
        if avg >= simdjson_avg:
            print(String(Int(avg / simdjson_avg * 100)) + "% (FASTER)")
        else:
            print(String(Int(avg / simdjson_avg * 100)) + "% (", String(Int(simdjson_avg / avg)), "x slower)")

        print("  vs orjson (Rust):   ", end="")
        if avg >= orjson_avg:
            print(String(Int(avg / orjson_avg * 100)) + "% (FASTER)")
        else:
            print(String(Int(avg / orjson_avg * 100)) + "% (", String(Int(orjson_avg / avg)), "x slower)")

    print()
    print("=" * 75)
    print("Reference throughputs:")
    print("  simdjson: 2,500 - 5,000 MB/s (true SIMD parallel)")
    print("  orjson:     700 - 1,800 MB/s")
    print("  ujson:      300 -   900 MB/s")
    print("  python:     100 -   400 MB/s")
    print("=" * 75)
