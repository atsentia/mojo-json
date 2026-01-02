"""
GPU-Accelerated Structural Scanner for JSON

Uses Metal GPU for parallel character classification:
- Stage 1a (GPU): Classify characters in fixed-size chunks
- Stage 1b (CPU): Build structural index from classification

Performance characteristics:
- GPU launch overhead: ~15μs per chunk
- Crossover point: GPU faster for JSON > 64KB
- Best for: Large JSON files, batch processing

Requires: macOS 15+, Apple Silicon (M1-M5), Mojo 25.6+
"""

from gpu.host import DeviceContext
from gpu import block_idx, block_dim, thread_idx
from layout import Layout, LayoutTensor

from .structural_index import StructuralIndex, QUOTE, COLON, COMMA, LBRACE, RBRACE, LBRACKET, RBRACKET, BACKSLASH

# Character type classifications
alias CHAR_WHITESPACE: UInt8 = 0
alias CHAR_BRACE_OPEN: UInt8 = 1   # {
alias CHAR_BRACE_CLOSE: UInt8 = 2  # }
alias CHAR_BRACKET_OPEN: UInt8 = 3  # [
alias CHAR_BRACKET_CLOSE: UInt8 = 4  # ]
alias CHAR_QUOTE: UInt8 = 5         # "
alias CHAR_COLON: UInt8 = 6         # :
alias CHAR_COMMA: UInt8 = 7         # ,
alias CHAR_BACKSLASH: UInt8 = 8     # \
alias CHAR_OTHER: UInt8 = 9

# GPU configuration
alias GPU_BLOCK_SIZE: Int = 256
alias GPU_CHUNK_SIZE: Int = 65536  # 64KB chunks for GPU processing

# Fixed-size layout for GPU chunks
alias chunk_layout = Layout.row_major(GPU_CHUNK_SIZE)


@always_inline
fn classify_char(ch: UInt8) -> UInt8:
    """Classify a single character."""
    if ch == ord('{'):
        return CHAR_BRACE_OPEN
    elif ch == ord('}'):
        return CHAR_BRACE_CLOSE
    elif ch == ord('['):
        return CHAR_BRACKET_OPEN
    elif ch == ord(']'):
        return CHAR_BRACKET_CLOSE
    elif ch == ord('"'):
        return CHAR_QUOTE
    elif ch == ord(':'):
        return CHAR_COLON
    elif ch == ord(','):
        return CHAR_COMMA
    elif ch == ord('\\'):
        return CHAR_BACKSLASH
    elif ch == ord(' ') or ch == ord('\t') or ch == ord('\n') or ch == ord('\r'):
        return CHAR_WHITESPACE
    else:
        return CHAR_OTHER


fn classify_chars_gpu_impl(
    data: String,
) raises -> List[UInt8]:
    """
    Classify all characters in parallel on GPU.

    Processes data in GPU_CHUNK_SIZE chunks.
    Returns list of character types (one per input byte).
    """
    var n = len(data)
    if n == 0:
        return List[UInt8]()

    var ctx = DeviceContext()

    # Allocate GPU buffers (reusable across chunks)
    var input_host = ctx.enqueue_create_host_buffer[DType.uint8](GPU_CHUNK_SIZE)
    var output_host = ctx.enqueue_create_host_buffer[DType.uint8](GPU_CHUNK_SIZE)
    var input_dev = ctx.enqueue_create_buffer[DType.uint8](GPU_CHUNK_SIZE)
    var output_dev = ctx.enqueue_create_buffer[DType.uint8](GPU_CHUNK_SIZE)

    var result = List[UInt8](capacity=n)
    var ptr = data.unsafe_ptr()
    var pos = 0

    # Classification kernel
    fn classify_kernel(
        input_tensor: LayoutTensor[DType.uint8, chunk_layout, MutableAnyOrigin],
        output_tensor: LayoutTensor[DType.uint8, chunk_layout, MutableAnyOrigin],
    ):
        var tid = block_idx.x * block_dim.x + thread_idx.x
        if tid < GPU_CHUNK_SIZE:
            var ch = input_tensor[tid]
            if ch == ord('{'):
                output_tensor[tid] = CHAR_BRACE_OPEN
            elif ch == ord('}'):
                output_tensor[tid] = CHAR_BRACE_CLOSE
            elif ch == ord('['):
                output_tensor[tid] = CHAR_BRACKET_OPEN
            elif ch == ord(']'):
                output_tensor[tid] = CHAR_BRACKET_CLOSE
            elif ch == ord('"'):
                output_tensor[tid] = CHAR_QUOTE
            elif ch == ord(':'):
                output_tensor[tid] = CHAR_COLON
            elif ch == ord(','):
                output_tensor[tid] = CHAR_COMMA
            elif ch == ord('\\'):
                output_tensor[tid] = CHAR_BACKSLASH
            elif ch == ord(' ') or ch == ord('\t') or ch == ord('\n') or ch == ord('\r'):
                output_tensor[tid] = CHAR_WHITESPACE
            else:
                output_tensor[tid] = CHAR_OTHER

    alias num_blocks = (GPU_CHUNK_SIZE + GPU_BLOCK_SIZE - 1) // GPU_BLOCK_SIZE

    # Process full chunks
    while pos + GPU_CHUNK_SIZE <= n:
        # Copy data to host buffer
        for i in range(GPU_CHUNK_SIZE):
            input_host[i] = ptr[pos + i]

        # Copy to device
        ctx.enqueue_copy(dst_buf=input_dev, src_buf=input_host)

        # Create tensors and launch kernel
        var in_tensor = LayoutTensor[DType.uint8, chunk_layout](input_dev)
        var out_tensor = LayoutTensor[DType.uint8, chunk_layout](output_dev)

        ctx.enqueue_function_checked[classify_kernel, classify_kernel](
            in_tensor, out_tensor,
            grid_dim=num_blocks,
            block_dim=GPU_BLOCK_SIZE,
        )

        # Copy results back
        ctx.enqueue_copy(dst_buf=output_host, src_buf=output_dev)
        ctx.synchronize()

        # Append results
        for i in range(GPU_CHUNK_SIZE):
            result.append(output_host[i])

        pos += GPU_CHUNK_SIZE

    # Process remaining bytes on CPU (faster for small sizes)
    while pos < n:
        result.append(classify_char(ptr[pos]))
        pos += 1

    return result^


fn build_index_from_classifications(
    data: String,
    char_types: List[UInt8],
) -> StructuralIndex:
    """
    Build structural index from GPU classification results.

    CPU pass that handles string state tracking.
    """
    var n = len(data)
    var index = StructuralIndex(capacity=n // 4)
    var in_string = False

    for pos in range(n):
        var char_type = char_types[pos]

        if char_type == CHAR_QUOTE:
            # Check if escaped (look at previous char)
            var escaped = False
            if pos > 0 and char_types[pos - 1] == CHAR_BACKSLASH:
                escaped = True

            if not escaped:
                in_string = not in_string
                index.append(pos, QUOTE)

        elif not in_string:
            # Record structural characters outside strings
            if char_type == CHAR_BRACE_OPEN:
                index.append(pos, LBRACE)
            elif char_type == CHAR_BRACE_CLOSE:
                index.append(pos, RBRACE)
            elif char_type == CHAR_BRACKET_OPEN:
                index.append(pos, LBRACKET)
            elif char_type == CHAR_BRACKET_CLOSE:
                index.append(pos, RBRACKET)
            elif char_type == CHAR_COLON:
                index.append(pos, COLON)
            elif char_type == CHAR_COMMA:
                index.append(pos, COMMA)

    return index^


fn build_structural_index_gpu(data: String) raises -> StructuralIndex:
    """
    Build structural index using GPU acceleration.

    Hybrid approach:
    - GPU: Parallel character classification (64KB chunks)
    - CPU: Build index with string state tracking

    Best for JSON > 64KB. For smaller JSON, use CPU-only version.
    """
    # Step 1: GPU character classification
    var char_types = classify_chars_gpu_impl(data)

    # Step 2: CPU pass to build index
    return build_index_from_classifications(data, char_types)


fn should_use_gpu(data_size: Int) -> Bool:
    """
    Determine if GPU should be used based on data size.

    Returns True if data is large enough for GPU to be beneficial.
    Crossover point is approximately 64KB (GPU_CHUNK_SIZE).
    """
    return data_size >= GPU_CHUNK_SIZE


fn build_structural_index_adaptive(data: String) raises -> StructuralIndex:
    """
    Automatically choose CPU or GPU based on data size.

    - < 64KB: Use SIMD CPU implementation
    - >= 64KB: Use GPU acceleration
    """
    from .structural_index import build_structural_index

    if should_use_gpu(len(data)):
        return build_structural_index_gpu(data)
    else:
        return build_structural_index(data)
