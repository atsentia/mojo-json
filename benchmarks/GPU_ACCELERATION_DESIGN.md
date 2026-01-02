# GPU Acceleration Design for mojo-json

**Goal**: Leverage mojo-metal to accelerate JSON parsing on Apple Silicon GPUs.

## Executive Summary

GPU acceleration for JSON parsing is **situationally beneficial**:
- ✅ **Good for**: Large files (>1MB), batch processing, number-heavy data
- ❌ **Not good for**: Small files (<100KB), single-file parsing, typical API responses

The key insight is that **simdjson's two-stage architecture** is CPU-optimal but GPU-adaptable. Stage 1 (structural discovery) is embarrassingly parallel and a good GPU candidate.

## Architecture Overview

```
                    CPU Path (default)           GPU Path (large files)
                    ─────────────────           ─────────────────────
Input JSON ──────► [Stage 1: Structural] ──────► [Stage 1: GPU Parallel]
                          │                              │
                          ▼                              ▼
                   Structural Index               Structural Index
                          │                              │
                          ▼                              ▼
                   [Stage 2: Extract] ◄─────────────────┘
                          │              (always CPU)
                          ▼
                      JsonValue
```

## GPU Kernels Design

### Kernel 1: Parallel Structural Discovery

**Purpose**: Find all structural characters (`"`, `{`, `}`, `[`, `]`, `:`, `,`) in parallel.

```mojo
# GPU Kernel: Find structural characters
fn structural_discovery_kernel[
    dtype: DType,
    layout: Layout,
](
    input: LayoutTensor[dtype, layout, MutableAnyOrigin],
    output_mask: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    size: Int,
):
    """Each thread processes one byte, outputs 1 if structural, 0 otherwise."""
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < size:
        var c = input[tid]
        var is_structural = (
            (c == ord('"')) or
            (c == ord('{')) or (c == ord('}')) or
            (c == ord('[')) or (c == ord(']')) or
            (c == ord(':')) or (c == ord(','))
        )
        output_mask[tid] = UInt8(1) if is_structural else UInt8(0)
```

**Optimized Version**: Process 4 bytes per thread

```mojo
fn structural_discovery_kernel_v4[
    layout: Layout,
](
    input: LayoutTensor[DType.uint32, layout, MutableAnyOrigin],
    output_mask: LayoutTensor[DType.uint32, layout, MutableAnyOrigin],
    size: Int,
):
    """Process 4 bytes per thread using vectorized comparison."""
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < size:
        var word = input[tid]  # 4 bytes packed as uint32

        # Extract individual bytes
        var b0 = (word >> 0) & 0xFF
        var b1 = (word >> 8) & 0xFF
        var b2 = (word >> 16) & 0xFF
        var b3 = (word >> 24) & 0xFF

        # Check each byte (lookup table would be faster)
        var m0 = is_structural_char(b0)
        var m1 = is_structural_char(b1)
        var m2 = is_structural_char(b2)
        var m3 = is_structural_char(b3)

        # Pack results
        output_mask[tid] = (m0 << 0) | (m1 << 8) | (m2 << 16) | (m3 << 24)
```

### Kernel 2: Quote/Escape Detection

**Purpose**: Identify quoted strings (accounting for escapes).

```mojo
fn quote_detection_kernel[
    layout: Layout,
](
    input: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    quote_mask: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    escape_mask: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    size: Int,
):
    """Mark quotes and escape characters."""
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < size:
        var c = input[tid]
        quote_mask[tid] = UInt8(1) if c == ord('"') else UInt8(0)
        escape_mask[tid] = UInt8(1) if c == ord('\\') else UInt8(0)
```

**Challenge**: A `"` after `\` is not a real quote. This requires sequential dependency resolution:

```mojo
# Second pass: Resolve escaped quotes (must be sequential or use prefix scan)
fn resolve_escaped_quotes(
    quote_mask: List[UInt8],
    escape_mask: List[UInt8],
) -> List[UInt8]:
    """Mark only unescaped quotes."""
    var result = List[UInt8](len(quote_mask))
    var i = 0
    while i < len(quote_mask):
        if escape_mask[i] == 1:
            # This is an escape, skip next char
            result[i] = 0
            if i + 1 < len(quote_mask):
                result[i + 1] = 0  # Escaped char is not a quote
            i += 2
        else:
            result[i] = quote_mask[i]
            i += 1
    return result
```

### Kernel 3: Parallel Number Parsing

**Purpose**: Parse multiple numbers in parallel (for number-heavy JSON).

```mojo
fn parallel_float_parse_kernel[
    layout: Layout,
](
    input: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    number_starts: LayoutTensor[DType.int32, layout, MutableAnyOrigin],
    number_ends: LayoutTensor[DType.int32, layout, MutableAnyOrigin],
    output: LayoutTensor[DType.float64, layout, MutableAnyOrigin],
    count: Int,
):
    """Each thread parses one number."""
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < count:
        var start = number_starts[tid]
        var end = number_ends[tid]

        # Parse number (simplified)
        var result = Float64(0)
        var negative = False
        var pos = start

        # Check sign
        if input[pos] == ord('-'):
            negative = True
            pos += 1

        # Parse integer part
        while pos < end and input[pos] >= ord('0') and input[pos] <= ord('9'):
            result = result * 10 + Float64(input[pos] - ord('0'))
            pos += 1

        # TODO: Parse decimal and exponent parts

        output[tid] = -result if negative else result
```

## Performance Estimates

### GPU Overhead
- Kernel launch: ~10-15 μs
- Memory copy to device: ~1-2 μs per KB (unified memory helps)
- Synchronization: ~5-10 μs

### Crossover Analysis

| File Size | CPU SIMD Time | GPU Time | Faster |
|-----------|---------------|----------|--------|
| 1 KB | 0.001 ms | 0.025 ms | CPU |
| 10 KB | 0.01 ms | 0.028 ms | CPU |
| 100 KB | 0.1 ms | 0.05 ms | **GPU** |
| 1 MB | 1.0 ms | 0.2 ms | **GPU** |
| 10 MB | 10 ms | 1.5 ms | **GPU** |

**Crossover point: ~50-100 KB**

### M3 Ultra GPU Capabilities
- GPU Cores: 60-76
- Memory Bandwidth: 800 GB/s (shared with CPU)
- Threads per Core: 1024
- Total Threads: ~60,000-80,000

At 4 bytes/thread, a single kernel launch can process ~240-320 KB in parallel.

## Integration with mojo-metal

### Required mojo-metal Updates

1. **Add general-purpose kernels** to mojo-metal:
   ```
   src/kernels/
   ├── unary_kernels.mojo      # exp, relu, etc. (existing)
   ├── binary_kernels.mojo     # add, mul, etc. (existing)
   ├── reduce_kernels.mojo     # sum, max, etc. (existing)
   ├── search_kernels.mojo     # NEW: find chars, patterns
   └── transform_kernels.mojo  # NEW: byte transforms
   ```

2. **Search kernels** for JSON parsing:
   ```mojo
   # mojo-metal/src/kernels/search_kernels.mojo
   fn find_bytes_kernel(...)      # Find specific byte values
   fn create_mask_kernel(...)     # Create bitmask for matching
   fn prefix_sum_kernel(...)      # For index building
   ```

3. **Byte transform kernels**:
   ```mojo
   # mojo-metal/src/kernels/transform_kernels.mojo
   fn pack_bitmask_kernel(...)    # Pack byte mask to bits
   fn scatter_kernel(...)         # Scatter values by index
   fn gather_kernel(...)          # Gather values by index
   ```

### API Design

```mojo
# mojo-json integration
from mojo_metal.device import MetalDevice
from mojo_metal.kernels.search import find_structural_chars, build_structural_index

fn parse_gpu(source: String) -> JsonValue:
    """Parse JSON using GPU acceleration for large files."""

    # Check if GPU beneficial
    if len(source) < GPU_CROSSOVER_SIZE:  # ~100KB
        return parse_cpu(source)  # Use CPU path

    var device = MetalDevice()

    # Stage 1: GPU structural discovery
    var structural_mask = find_structural_chars(device, source)
    var quote_mask = find_quotes(device, source)
    var structural_index = build_structural_index(device, structural_mask, quote_mask)

    # Stage 2: CPU value extraction (using index)
    return extract_values(source, structural_index)
```

## Implementation Plan

### Phase 1: CPU Two-Stage (No GPU)
1. Implement structural index building with CPU SIMD
2. Implement index-based value extraction
3. Benchmark improvement

### Phase 2: GPU Structural Discovery
1. Add search kernels to mojo-metal
2. Implement GPU structural discovery
3. Add automatic CPU/GPU selection
4. Benchmark crossover point

### Phase 3: GPU Optimizations
1. Implement prefix scan for index building
2. Optimize memory transfers
3. Add batch processing API
4. Profile and tune

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| GPU overhead dominates | Performance regression | CPU path for small files |
| String escapes break parallelism | Incorrect results | Hybrid GPU+CPU approach |
| Mojo GPU API changes | Code breaks | Abstract behind mojo-metal |
| Memory copies slow | Reduced speedup | Use unified memory |

## Success Criteria

1. **Correctness**: Pass all existing mojo-json tests
2. **Performance**:
   - 2x speedup for files >1MB
   - No regression for files <100KB
   - Competitive with orjson for all sizes
3. **Usability**:
   - Same API as CPU version
   - Automatic selection of optimal path

## References

- [GPU-Accelerated JSON Parsing](https://arxiv.org/abs/2007.14287) - ParPaRaw paper
- [simdjson Stage 1 Architecture](https://github.com/simdjson/simdjson/blob/master/doc/implementation-selection.md)
- [mojo-metal GPU Kernels](../../../mojo-contrib-experimental/mojo-metal/src/kernels/)
