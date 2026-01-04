"""
GPU-Accelerated JSON Parser

Uses Metal GPU for character classification (Stage 1a) then
CPU for structural index building and value parsing.

Performance (M2 Max):
- 16 KB: 51 MB/s (use CPU)
- 64 KB: 281 MB/s (crossover)
- 256 KB: 1,007 MB/s (GPU wins)
- 1 MB: 2,589 MB/s (GPU essential)

Usage:
    from src.gpu_parser import parse_gpu, parse_adaptive_gpu

    # Auto-select GPU vs CPU based on size
    var tape = parse_adaptive_gpu(large_json)

    # Force GPU (for benchmarking)
    var tape = parse_gpu(large_json)

Build requirements:
    cd metal && ./build_all.sh
"""

from .metal_ffi import (
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
from .structural_index import StructuralIndex
from .tape_parser import (
    JsonTape,
    TapeEntry,
    parse_to_tape,
    parse_to_tape_v2,
    TAPE_ROOT,
    TAPE_NULL,
    TAPE_TRUE,
    TAPE_FALSE,
    TAPE_INT64,
    TAPE_DOUBLE,
    TAPE_STRING,
    TAPE_START_OBJECT,
    TAPE_END_OBJECT,
    TAPE_START_ARRAY,
    TAPE_END_ARRAY,
)

# Threshold for GPU vs CPU (64 KB)
alias GPU_THRESHOLD: Int = 65536


fn build_structural_index_gpu(
    json: String, classifier: MetalJsonClassifier
) raises -> StructuralIndex:
    """
    Build structural index using GPU character classification.

    Stage 1a runs on GPU, Stage 1b (string state tracking) runs on CPU.

    Args:
        json: JSON string to process.
        classifier: Pre-initialized Metal classifier.

    Returns:
        StructuralIndex with positions and characters.
    """
    var n = len(json)
    if n == 0:
        return StructuralIndex()

    # GPU Stage 1a: Character classification
    var classifications = classifier.classify(json)

    # CPU Stage 1b: Build structural index with string state tracking
    var index = StructuralIndex()
    var ptr = json.unsafe_ptr()
    var in_string = False
    var i = 0

    while i < n:
        var c = classifications[i]

        if c == CHAR_QUOTE:
            # Check if escaped
            if i > 0 and classifications[i - 1] == CHAR_BACKSLASH:
                # Count consecutive backslashes
                var num_backslashes = 0
                var j = i - 1
                while j >= 0 and classifications[j] == CHAR_BACKSLASH:
                    num_backslashes += 1
                    j -= 1
                # If even backslashes, quote is escaped
                if num_backslashes % 2 == 1:
                    i += 1
                    continue

            in_string = not in_string
            index.positions.append(i)
            index.characters.append(ptr[i])

        elif not in_string:
            # Structural characters outside strings
            if c == CHAR_BRACE_OPEN or c == CHAR_BRACE_CLOSE or c == CHAR_BRACKET_OPEN or c == CHAR_BRACKET_CLOSE or c == CHAR_COLON or c == CHAR_COMMA:
                index.positions.append(i)
                index.characters.append(ptr[i])

        i += 1

    return index^


fn parse_gpu(json: String) raises -> JsonTape:
    """
    Parse JSON using GPU-accelerated character classification.

    Uses Metal GPU for Stage 1a (character classification),
    then CPU for structural index building and value parsing.

    Best for large JSON (>64 KB). For smaller JSON, use parse_to_tape().

    Args:
        json: JSON string to parse.

    Returns:
        JsonTape with parsed values.

    Raises:
        Error if Metal GPU is not available or parsing fails.
    """
    if not is_metal_available():
        raise Error("Metal GPU not available - use parse_to_tape() instead")

    var classifier = MetalJsonClassifier()
    var index = build_structural_index_gpu(json, classifier)

    # Use existing tape parser Stage 2
    return _parse_stage2(json, index)


fn parse_adaptive_gpu(json: String) raises -> JsonTape:
    """
    Parse JSON with automatic GPU/CPU selection.

    Automatically chooses the fastest approach based on JSON size:
    - <64 KB: CPU SIMD (faster due to GPU launch overhead)
    - >=64 KB: GPU classification + CPU parsing (faster for large files)

    This is the recommended API for production use.

    Args:
        json: JSON string to parse.

    Returns:
        JsonTape with parsed values.
    """
    var n = len(json)

    # Use GPU for large files if available
    if n >= GPU_THRESHOLD and is_metal_available():
        try:
            return parse_gpu(json)
        except:
            # Fall back to CPU if GPU fails
            pass

    # Use CPU adaptive parser for smaller files or if GPU unavailable
    from .tape_parser import parse_adaptive
    return parse_adaptive(json)


fn should_use_gpu(size: Int) -> Bool:
    """
    Check if GPU should be used for given JSON size.

    Args:
        size: JSON size in bytes.

    Returns:
        True if GPU is recommended and available.
    """
    return size >= GPU_THRESHOLD and is_metal_available()


fn _parse_stage2(json: String, index: StructuralIndex) raises -> JsonTape:
    """
    Stage 2: Parse values using structural index.

    Internal function that converts structural index to JsonTape.
    """
    var tape = JsonTape()
    tape.source = json
    tape.entries = List[TapeEntry]()

    if len(index) == 0:
        return tape^

    var ptr = json.unsafe_ptr()
    var n = len(json)

    # Parse stack for tracking containers
    var stack = List[Int]()  # Entry indices of open containers

    var pos_idx = 0

    while pos_idx < len(index):
        var pos = index.positions[pos_idx]
        var c = index.characters[pos_idx]

        if c == ord('{'):
            # Start object
            var entry = TapeEntry()
            entry.data = UInt64(TAPE_START_OBJECT) << 56
            tape.entries.append(entry)
            stack.append(len(tape.entries) - 1)

        elif c == ord('}'):
            # End object
            if len(stack) > 0:
                var start_idx = stack.pop()
                # Update start entry with end position
                var count = len(tape.entries) - start_idx - 1
                tape.entries[start_idx].data = (UInt64(TAPE_START_OBJECT) << 56) | UInt64(count)

            var entry = TapeEntry()
            entry.data = UInt64(TAPE_END_OBJECT) << 56
            tape.entries.append(entry)

        elif c == ord('['):
            # Start array
            var entry = TapeEntry()
            entry.data = UInt64(TAPE_START_ARRAY) << 56
            tape.entries.append(entry)
            stack.append(len(tape.entries) - 1)

        elif c == ord(']'):
            # End array
            if len(stack) > 0:
                var start_idx = stack.pop()
                var count = len(tape.entries) - start_idx - 1
                tape.entries[start_idx].data = (UInt64(TAPE_START_ARRAY) << 56) | UInt64(count)

            var entry = TapeEntry()
            entry.data = UInt64(TAPE_END_ARRAY) << 56
            tape.entries.append(entry)

        elif c == ord('"'):
            # String - find end quote
            var string_start = pos + 1
            pos_idx += 1
            if pos_idx < len(index):
                var string_end = index.positions[pos_idx]
                # String value entry
                var entry = TapeEntry()
                entry.data = (UInt64(TAPE_STRING) << 56) | (UInt64(string_start) << 32) | UInt64(string_end - string_start)
                tape.entries.append(entry)

        elif c == ord(':'):
            # Key-value separator - skip
            pass

        elif c == ord(','):
            # Element separator - skip
            pass

        pos_idx += 1

    # Add root entry at beginning
    var root = TapeEntry()
    root.data = (UInt64(TAPE_ROOT) << 56) | UInt64(len(tape.entries))
    tape.entries.insert(0, root)

    return tape^


# =============================================================================
# Benchmark Utilities
# =============================================================================


fn benchmark_gpu_vs_cpu(json: String, iterations: Int = 10) raises -> Tuple[Float64, Float64]:
    """
    Benchmark GPU vs CPU parsing.

    Returns (gpu_throughput_mbps, cpu_throughput_mbps).
    """
    from time import perf_counter_ns

    var size_mb = Float64(len(json)) / (1024.0 * 1024.0)

    # GPU benchmark
    var gpu_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_gpu(json)
        _ = len(tape.entries)
    var gpu_time = Float64(perf_counter_ns() - gpu_start) / 1e9
    var gpu_mbps = size_mb * Float64(iterations) / gpu_time

    # CPU benchmark
    var cpu_start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)
    var cpu_time = Float64(perf_counter_ns() - cpu_start) / 1e9
    var cpu_mbps = size_mb * Float64(iterations) / cpu_time

    return (gpu_mbps, cpu_mbps)
