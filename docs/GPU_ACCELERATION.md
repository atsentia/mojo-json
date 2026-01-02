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
