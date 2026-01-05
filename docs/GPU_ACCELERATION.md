# GPU Acceleration for mojo-json (Experimental)

GPU-accelerated structural scanning using Apple Metal via Mojo's GPU support.

## Status: Experimental (Mojo GPU Compiler Issue)

The GPU acceleration module is implemented but **currently blocked by Mojo Metal compiler**:

```
Metal Compiler failed to compile metallib. Please submit a bug report.
```

**Requirements when Mojo GPU support matures:**
- macOS 15+ (Sequoia)
- Apple Silicon (M1-M5)
- Mojo 25.6+ with working Metal compiler

**Current workaround:** Use CPU SIMD implementation which achieves 1,000+ MB/s.

**Alternative approach:** Consider using MLX or raw Metal shaders via FFI when Mojo
Metal compilation is fixed.

## Architecture

```
JSON String (>64KB)
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  GPU Stage 1a: Character Classification                 │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 64KB chunks processed in parallel               │   │
│  │ Each thread classifies one character:           │   │
│  │   { } [ ] " : , \ whitespace other              │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
    │ Classification array
    ▼
┌─────────────────────────────────────────────────────────┐
│  CPU Stage 1b: Build Structural Index                   │
│  - Track string state (in_string / not in_string)      │
│  - Handle escaped quotes                                │
│  - Build positions/characters arrays                    │
└─────────────────────────────────────────────────────────┘
    │
    ▼
StructuralIndex (same as CPU-only version)
```

## API

### Adaptive Selection

```mojo
from src.gpu_structural_scan import build_structural_index_adaptive

fn main() raises:
    var json = load_large_json()  # >64KB

    # Automatically uses GPU for large JSON, CPU for small
    var index = build_structural_index_adaptive(json)
```

### Force GPU

```mojo
from src.gpu_structural_scan import build_structural_index_gpu

fn main() raises:
    var json = load_large_json()
    var index = build_structural_index_gpu(json)
```

### Check Threshold

```mojo
from src.gpu_structural_scan import should_use_gpu

if should_use_gpu(len(json)):
    print("GPU recommended for this JSON size")
```

## Performance Characteristics

| JSON Size | Recommended | Reason |
|-----------|-------------|--------|
| < 16 KB | CPU (SIMD) | GPU launch overhead dominates |
| 16-64 KB | CPU (SIMD) | GPU and CPU similar |
| 64-256 KB | GPU | GPU classification faster |
| > 256 KB | GPU | GPU significantly faster |

### GPU Launch Overhead

- ~15 microseconds per kernel launch
- 64KB chunks amortize this overhead
- For 256KB JSON: 4 kernel launches = ~60μs overhead

### Expected Speedups (Large JSON)

| Operation | CPU SIMD | GPU Hybrid | Speedup |
|-----------|----------|------------|---------|
| 100 KB classification | 100 μs | 80 μs | 1.25x |
| 500 KB classification | 500 μs | 200 μs | 2.5x |
| 1 MB classification | 1000 μs | 350 μs | 2.9x |

Note: Full structural index building includes CPU Stage 1b, so overall speedup is lower.

## Implementation Details

### GPU Kernel

```mojo
fn classify_kernel(
    input_tensor: LayoutTensor[DType.uint8, chunk_layout, MutAnyOrigin],
    output_tensor: LayoutTensor[DType.uint8, chunk_layout, MutAnyOrigin],
):
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < GPU_CHUNK_SIZE:
        var ch = input_tensor[tid]
        # Classify character...
        output_tensor[tid] = classification
```

### Character Classifications

| Code | Character | Description |
|------|-----------|-------------|
| 0 | ` ` `\t` `\n` `\r` | Whitespace |
| 1 | `{` | Object open |
| 2 | `}` | Object close |
| 3 | `[` | Array open |
| 4 | `]` | Array close |
| 5 | `"` | Quote |
| 6 | `:` | Colon |
| 7 | `,` | Comma |
| 8 | `\` | Backslash |
| 9 | other | Non-structural |

## Limitations

1. **String State Tracking**: Must be done on CPU (sequential dependency)
2. **Escape Sequences**: Handled in CPU pass
3. **Chunk Boundaries**: Processed correctly by reusing buffers

## Files

| File | Purpose |
|------|---------|
| `src/gpu_structural_scan.mojo` | GPU kernel and hybrid implementation |
| `test_gpu_structural_scan.mojo` | Tests and benchmarks |

## Future Work

1. **Batch Processing**: Process multiple JSON documents in one GPU call
2. **Full GPU Pipeline**: GPU-native string state tracking with prefix scan
3. **Multi-GPU**: Distribute large files across GPU cores

---

## GpJSON Analysis (2026-01)

Analyzed [GpJSON](https://github.com/koesie10/gpjson), a CUDA-based JSON parser achieving 15-25 GB/s on NVIDIA GPUs.

### Architecture: Multi-Pass GPU Pipeline

```
Pass 1: create_escape_index      → 64-bit bitmap of escaped chars
Pass 2: create_quote_index       → 64-bit bitmap of unescaped quotes
Pass 3: create_string_index      → Prefix-XOR for in-string tracking
Pass 4: create_leveled_bitmaps   → Structural chars by nesting level
Pass 5: find_value               → Query execution using indexes
```

### Key Algorithm: Prefix-XOR String Tracking

GpJSON uses the same algorithm as simdjson for tracking which characters are inside strings:

```c
// Converts quote bit positions to contiguous in-string mask
quotes ^= quotes << 1;
quotes ^= quotes << 2;
quotes ^= quotes << 4;
quotes ^= quotes << 8;
quotes ^= quotes << 16;
quotes ^= quotes << 32;
```

This transforms isolated quote bits into a mask where all characters inside strings have bit=1.

### Carry Propagation

Each kernel stores carry state for the next thread:
- **Escape carry**: Was the last char a backslash?
- **Quote count parity**: Odd/even quote count determines string state
- **Nesting level**: Current depth for leveled bitmaps

### NDJSON Optimization

GpJSON is optimized for **newline-delimited JSON** where each line is independent:
- One JSON record per GPU thread (embarrassingly parallel)
- No cross-line state dependencies
- Ideal for log processing and streaming analytics

For single large JSON documents, parallelization is more complex due to state dependencies across the entire file.

### Applicability to mojo-json

| GpJSON Feature | Mojo Applicability | Notes |
|----------------|-------------------|-------|
| 64-bit bitmaps | ✅ Direct port | Use UInt64 for masks |
| Prefix-XOR | ✅ Direct port | Pure arithmetic |
| Carry propagation | ✅ With threads | Need parallel prefix sum |
| Leveled bitmaps | ✅ Useful | Speeds up depth navigation |
| NDJSON parallel | ✅ High value | Easy parallelism |
| CUDA kernels | ❌ Not yet | Mojo lacks CUDA support |

### Recommended Implementation Path

1. **Short-term**: Add prefix-XOR string tracking to CPU Stage 1
2. **Medium-term**: Add NDJSON parallel processing mode
3. **Long-term**: Port full pipeline when Mojo GPU matures

---

## GpJSON-Inspired Full GPU Stage 1 (2026-01)

After analyzing GpJSON, we've implemented advanced kernels for full GPU Stage 1:

### New Kernel Pipeline

```
Pass 1: create_quote_bitmap      → 64-bit bitmap of quote positions
Pass 2: create_string_mask       → Prefix-XOR for in-string tracking
Pass 3: extract_structural_positions → Filter by string mask
Pass 4 (NDJSON): find_newlines   → Line boundary detection
```

### Key Algorithm: Prefix-XOR String Tracking

From simdjson/GpJSON - transforms quote positions to in-string mask:

```metal
// Input:  0b00100100 (quotes at positions 2 and 5)
// Output: 0b00111100 (inside string from 2-5)

quotes ^= quotes << 1;
quotes ^= quotes << 2;
quotes ^= quotes << 4;
quotes ^= quotes << 8;
quotes ^= quotes << 16;
quotes ^= quotes << 32;
```

### 64-bit Bitmap Architecture

Each thread processes 64 bytes into a single `uint64_t`:
- **Memory efficient**: 64x compression vs per-byte classification
- **Parallel friendly**: Each chunk is independent (with carry)
- **Cache optimal**: Coalesced memory access patterns

### Carry Propagation

Handles cross-chunk string state:
```metal
// If previous chunk ended inside string, invert our mask
if (index > 0 && quote_carry[index - 1] == 1) {
    quotes = ~quotes;
}
```

### Kernel Files

New kernels in `metal/json_classify.metal`:
- `create_quote_bitmap` - Build 64-bit quote bitmaps with carry
- `create_string_mask` - Prefix-XOR transformation
- `extract_structural_positions` - Atomic extraction with string filtering
- `find_newlines` - NDJSON line detection

### Build Requirements

```bash
# 1. Install Metal toolchain first (one-time)
xcodebuild -downloadComponent MetalToolchain

# 2. Compile Metal shaders to .metallib
cd metal
xcrun metal -c json_classify.metal -o json_classify.air
xcrun metallib json_classify.air -o json_classify.metallib

# 3. Build C bridge library (already done)
clang -shared -fobjc-arc metal_bridge.m -o libmetal_bridge.dylib \
    -framework Metal -framework Foundation
```

### C API Functions (metal_bridge.h)

The C bridge exposes both simple character classification and full GpJSON pipeline:

**Simple Classification (working now)**:
- `metal_json_init()` - Initialize Metal context
- `metal_json_classify()` - GPU character classification at 2.5 GB/s
- `metal_json_free()` - Cleanup

**Full GpJSON Pipeline (requires metallib rebuild)**:
- `metal_json_has_gpjson_pipeline()` - Check if GpJSON kernels available
- `metal_json_create_quote_bitmap()` - 64-bit quote bitmaps
- `metal_json_create_string_mask()` - Prefix-XOR transformation
- `metal_json_extract_structural()` - Filter by string mask
- `metal_json_find_newlines()` - NDJSON line detection
- `metal_json_full_stage1()` - Combined 3-pass pipeline

### Expected Performance (when compiled)

| Operation | Current | With Full GPU Stage 1 |
|-----------|---------|----------------------|
| Stage 1a (classification) | 2.5 GB/s | ~3-4 GB/s |
| Stage 1b (string tracking) | Sequential | Parallel |
| Overall | 2.5 GB/s | ~4-6 GB/s (est.) |

---

## Comprehensive Hardware Acceleration Analysis (2026-01)

Deep analysis of all Apple Silicon acceleration options for JSON parsing.

### 1. mojo-metal (GPU via Metal) ✅ RECOMMENDED

**Location**: `/Users/amund/mojo-metal`

**Status**: Working GPU kernels using Mojo's native `DeviceContext` API.

**Architecture**:
```mojo
from gpu.host import DeviceContext
from gpu import block_idx, block_dim, thread_idx
from layout import Layout, LayoutTensor

fn classify_kernel(
    input: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    output: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
):
    var tid = block_idx.x * block_dim.x + thread_idx.x
    if tid < size:
        output[tid] = classify_char(input[tid])
```

**Key Capabilities**:
- Unary/binary/reduce GPU kernels implemented
- Device abstraction via `MetalDevice` struct
- 8-14x speedup for large tensors (>64K elements)
- ~15μs kernel launch overhead
- Supports M1-M5 with NAX detection for M3+

**JSON Parsing Fit**: EXCELLENT
- Character classification: embarrassingly parallel
- Each thread processes 1-4 bytes
- Can leverage MLX-style prefix scan for string tracking

### 2. MLX Metal Kernels Reference

**Key Files Analyzed**:
- `mlx/backend/metal/kernels/scan.h` - Prefix scan implementation
- `mlx/backend/metal/kernels/scan.metal` - Kernel instantiations

**Critical Finding: GPU Prefix Scan**

MLX implements hardware-accelerated prefix scans using Metal's SIMD primitives:

```metal
// MLX scan.h - Three-level parallel prefix scan
U simd_scan_impl(U x) {
    return simd_prefix_inclusive_sum(x);  // Hardware instruction!
}

// For types without hardware support, use shuffle pattern:
for (int i = 1; i <= 16; i *= 2) {
    val = operator()(val, simd_shuffle_and_fill_up(val, init, i));
}
```

**Algorithm Structure**:
1. Per-thread scan (N_READS elements)
2. Simdgroup-level exclusive scan via `simd_prefix_exclusive_sum`
3. Cross-simdgroup scan via shared memory
4. Combine prefix + simdgroup_sum + thread_sum

**JSON Application**: The prefix-XOR for string tracking CAN be implemented on GPU using this pattern, replacing `sum` with `xor`.

### 3. Apple Neural Engine (ANE) ❌ NOT SUITABLE

**Research Sources**:
- [hollance/neural-engine](https://github.com/hollance/neural-engine)
- [Apple ML Research](https://machinelearning.apple.com/research/neural-engine-transformers)

**Why ANE Won't Work for JSON Parsing**:

1. **No Public API**: ANE is only accessible via CoreML's automatic scheduling
2. **Custom Layers Can't Use ANE**: CoreML custom layers run on CPU/GPU only
3. **Wrong Operation Domain**: ANE optimized for:
   - Matrix multiply (INT8, FP16)
   - Convolutions
   - Activation functions
   - NOT byte-level comparisons or prefix scans

4. **Data Format Constraints**: ANE buffers must be 64-byte aligned on last axis, causing 32-64x memory overhead for byte operations

**Quote from Apple**:
> "Because there is no public API to program the ANE, custom layers cannot run on the ANE."

### 4. Apple AMX (Matrix Coprocessor) ⚠️ INDIRECT ACCESS ONLY

**Research Sources**:
- [corsix/amx](https://github.com/corsix/amx) - Reverse-engineered instruction set
- [Meekolab Research](https://research.meekolab.com/the-elusive-apple-matrix-coprocessor-amx)

**What AMX Is**:
- Undocumented matrix coprocessor in Apple Silicon
- 32x32 grid of 16-bit multiply-accumulate units
- ~1475 GFLOPS on M1 Max (vs 102 GFLOPS for NEON)
- 2x faster than NEON for matrix operations

**Access Methods**:
1. **Accelerate Framework** (Recommended): BLAS, vDSP automatically use AMX
2. **Direct Assembly** (Undocumented): Risk of breaking on future chips
3. **M4+**: ARM SME (Scalable Matrix Extension) provides documented access

**JSON Parsing Fit**: POOR
- AMX designed for dense matrix multiply
- JSON parsing is sparse (1-5% structural characters)
- Byte comparisons don't map to matrix ops
- Potential use: Batch float parsing (not the bottleneck)

### 5. Accelerate Framework (vDSP, BNNS)

**Available Operations**:
- `vDSP_vthres`: Threshold operations
- `vDSP_vcmprs`: Compress vectors by condition
- `BNNS`: Neural network primitives

**JSON Parsing Fit**: LIMITED
- Could use `vDSP_vthres` to find specific byte values
- Overhead of framework calls may exceed benefit
- Better to use direct SIMD (already implemented)

### 6. tinygrad Metal Backend Reference

**Key Implementation** (`ops_metal.py`):
- Uses `MTLCompileOptions` with fast-math
- Buffer management via `newBufferWithLength_options_` with shared storage
- Kernel dispatch via `MTLComputeCommandEncoder`
- 32-thread simdgroups (matching Apple GPU architecture)

**Relevance**: Shows how to build efficient Metal compute from Python/high-level language. Similar patterns applicable to Mojo.

### 7. llama.cpp Metal Reference

**Key File**: `ggml-metal.metal` (~15K lines)

**Optimization Patterns**:
- `#define N_SIMDWIDTH 32` - Consistent with Apple GPU
- Heavy use of `simd_shuffle` for cross-lane communication
- `FOR_UNROLL` pragma for loop unrolling
- Quantized operations (INT4, INT8, FP8)

**JSON Parsing Relevance**: Limited - focused on matrix ops for LLM inference.

---

## Feasibility Summary

| Accelerator | Feasibility | Expected Speedup | JSON Fit |
|-------------|-------------|------------------|----------|
| **Metal GPU (mojo-metal)** | ✅ High | 2-5x for >100KB | Excellent |
| **MLX-style Prefix Scan** | ✅ High | Key enabler | Excellent |
| **ANE** | ❌ None | N/A | None |
| **AMX** | ⚠️ Indirect | Minor | Poor |
| **Accelerate vDSP** | ⚠️ Low | Minor | Limited |
| **Multi-core CPU** | ✅ High | 2-4x (8 cores) | Excellent |

---

## Recommended Implementation Strategy

### Phase 1: GPU Character Classification (mojo-metal)

Use existing mojo-metal infrastructure:

```mojo
from mojo_metal.device import MetalDevice

fn classify_chars_gpu(json: String) -> List[UInt8]:
    var device = MetalDevice()
    var size = len(json)

    # Allocate buffers
    var in_buf = device.create_buffer[DType.uint8](size)
    var out_buf = device.create_buffer[DType.uint8](size)

    # Launch kernel
    var num_blocks = (size + 255) // 256
    device.ctx.enqueue_function_checked[classify_kernel, classify_kernel](
        in_tensor, out_tensor, size,
        grid_dim=num_blocks, block_dim=256,
    )

    device.synchronize()
    return result
```

### Phase 2: GPU Prefix-XOR (Port from MLX)

Implement `CumXor` operation following MLX's scan pattern:

```metal
// Custom CumXor for string tracking (port to Mojo)
struct CumXor<U> {
    static constexpr constant U init = 0;

    U operator()(U a, U b) { return a ^ b; }

    U simd_scan(U x) {
        for (int i = 1; i <= 16; i *= 2) {
            x ^= simd_shuffle_and_fill_up(x, init, i);
        }
        return x;
    }
};
```

### Phase 3: Full GPU Pipeline

```
JSON Input
    │
    ▼
[GPU] Character Classification (embarrassingly parallel)
    │
    ▼
[GPU] Quote Bitmap (parallel comparison)
    │
    ▼
[GPU] String Index (prefix-XOR scan)
    │
    ▼
[GPU] Structural Character Extraction (parallel filter)
    │
    ▼
[CPU] Value Parsing (On-Demand API)
```

### Phase 4: NDJSON Parallel Processing

For newline-delimited JSON (logs, streaming data):

```mojo
fn parse_ndjson_parallel(data: String) -> List[JsonValue]:
    # Find newline positions (GPU or CPU)
    var lines = find_line_boundaries(data)

    # Process lines in parallel (one per thread/core)
    var results = List[JsonValue]()
    parallel_for(lines) fn(line_start, line_end):
        var line_json = data[line_start:line_end]
        results.append(parse_on_demand(line_json))

    return results
```

---

## References

- [mojo-metal](file:///Users/amund/mojo-metal) - Local GPU library
- [MLX](https://github.com/ml-explore/mlx) - Apple's ML framework
- [GpJSON](https://github.com/koesie10/gpjson) - CUDA JSON parser
- [llama.cpp](https://github.com/ggerganov/llama.cpp) - LLM inference with Metal
- [tinygrad](https://github.com/tinygrad/tinygrad) - ML framework with Metal backend
- [hollance/neural-engine](https://github.com/hollance/neural-engine) - ANE reverse engineering
- [corsix/amx](https://github.com/corsix/amx) - AMX instruction set
- [Apple Accelerate](https://developer.apple.com/documentation/accelerate) - SIMD/BLAS framework
