# Adaptive JSON Parsing Design

**Goal**: Automatically select the optimal parsing strategy (CPU SIMD vs GPU) based on input characteristics.

## Executive Summary

The key insight is that **GPU has fixed overhead (~15-25μs)** while **CPU SIMD scales linearly**. This creates a crossover point where GPU becomes beneficial.

```
Performance
    ^
    |          GPU (parallel structural discovery)
    |         /
    |        /
    |       /  Crossover (~100KB)
    |      / /
    |     / /
    |    / /  CPU SIMD (sequential but no overhead)
    |   / /
    |  //
    | //
    |//________________> File Size
    0   50KB  100KB  1MB  10MB
```

## Adaptive Strategy

### Decision Matrix

| File Size | Approach | Reason |
|-----------|----------|--------|
| < 16 KB | CPU Scalar | SIMD overhead not worth it |
| 16 KB - 100 KB | CPU SIMD | No GPU launch overhead |
| 100 KB - 1 MB | GPU Stage 1 + CPU Stage 2 | GPU structural discovery beneficial |
| > 1 MB | Full GPU Pipeline | Maximum parallelism |

### Additional Heuristics

Beyond file size, these factors influence the decision:

| Factor | Prefer CPU | Prefer GPU |
|--------|-----------|------------|
| **Latency-sensitive** | ✅ | |
| **Throughput-optimized** | | ✅ |
| **String-heavy JSON** | ✅ (escape handling) | |
| **Number-heavy JSON** | | ✅ (parallel float parsing) |
| **Deep nesting** | ✅ (sequential dependency) | |
| **Wide arrays** | | ✅ (parallel element discovery) |
| **Batch processing** | | ✅ (amortize launch overhead) |

## API Design

### Simple API (Auto-Selection)

```mojo
from mojo_json import parse, ParseConfig

# Default: Auto-selects optimal path
var result = parse(json_string)

# Explicit configuration
var config = ParseConfig(
    strategy = ParseStrategy.AUTO,  # AUTO, CPU, GPU
    gpu_threshold = 100 * 1024,     # Crossover point in bytes
    prefer_latency = True,          # Optimize for latency vs throughput
)
var result = parse(json_string, config)
```

### Batch API (GPU-Optimized)

```mojo
from mojo_json import parse_batch

# Parse multiple JSON strings in parallel
# GPU overhead amortized across all inputs
var jsons = List[String]()
jsons.append('{"a": 1}')
jsons.append('{"b": 2}')
jsons.append('{"c": 3}')

var results = parse_batch(jsons)  # Single GPU dispatch
```

### Streaming API (Memory-Efficient)

```mojo
from mojo_json import JsonStreamParser

# For files larger than available memory
var parser = JsonStreamParser(buffer_size=64 * 1024)

# Feed chunks as they arrive
while chunk := read_chunk(file):
    var values = parser.feed(chunk)
    for value in values:
        process(value)

# Flush remaining
var final = parser.flush()
```

## Implementation Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     AdaptiveJsonParser                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌─────────────────┐    ┌───────────────┐  │
│  │ SizeAnalyzer │───►│ StrategySelector│───►│ ParserDispatch│  │
│  └──────────────┘    └─────────────────┘    └───────────────┘  │
│         │                    │                      │           │
│         ▼                    ▼                      ▼           │
│  ┌──────────────┐    ┌─────────────────┐    ┌───────────────┐  │
│  │ Quick Stats  │    │ Heuristic Engine│    │ CPU Path      │  │
│  │ - byte count │    │ - size thresholds   │ - SIMD stage1 │  │
│  │ - sample scan│    │ - content hints │    │ - scalar stage2  │
│  └──────────────┘    └─────────────────┘    └───────────────┘  │
│                                                     │           │
│                                              ┌──────┴──────┐    │
│                                              │ GPU Path    │    │
│                                              │ - Metal     │    │
│                                              │   kernels   │    │
│                                              └─────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Strategy Selector

```mojo
@value
struct StrategySelector:
    """Selects optimal parsing strategy based on input characteristics."""

    var gpu_threshold: Int          # Bytes above which GPU is preferred
    var simd_threshold: Int         # Bytes above which SIMD is used
    var prefer_latency: Bool        # True = minimize first-byte time
    var gpu_available: Bool         # Is GPU device present?

    fn __init__(out self):
        self.gpu_threshold = 100 * 1024   # 100 KB default
        self.simd_threshold = 16 * 1024   # 16 KB default
        self.prefer_latency = True
        self.gpu_available = _check_gpu_available()

    fn select(self, input_size: Int, hints: ContentHints) -> ParseStrategy:
        """Select optimal strategy based on size and content hints."""

        # Too small for any optimization
        if input_size < self.simd_threshold:
            return ParseStrategy.CPU_SCALAR

        # No GPU available
        if not self.gpu_available:
            return ParseStrategy.CPU_SIMD

        # Latency-sensitive: avoid GPU launch overhead
        if self.prefer_latency and input_size < self.gpu_threshold:
            return ParseStrategy.CPU_SIMD

        # String-heavy content: CPU better for escape handling
        if hints.string_ratio > 0.7:
            return ParseStrategy.CPU_SIMD

        # Large file: GPU beneficial
        if input_size >= self.gpu_threshold:
            return ParseStrategy.GPU_HYBRID

        return ParseStrategy.CPU_SIMD


@value
struct ContentHints:
    """Quick content analysis without full parsing."""

    var string_ratio: Float32    # Estimated ratio of string content
    var number_ratio: Float32    # Estimated ratio of numeric content
    var nesting_depth: Int       # Estimated maximum nesting
    var array_heavy: Bool        # Contains large arrays

    @staticmethod
    fn quick_analyze(data: Span[UInt8], sample_size: Int = 1024) -> ContentHints:
        """Sample-based content analysis (fast, O(sample_size))."""
        var hints = ContentHints(0.0, 0.0, 0, False)

        var quote_count = 0
        var digit_count = 0
        var bracket_depth = 0
        var max_depth = 0
        var array_count = 0

        var limit = min(len(data), sample_size)
        for i in range(limit):
            var c = data[i]
            if c == ord('"'):
                quote_count += 1
            elif c >= ord('0') and c <= ord('9'):
                digit_count += 1
            elif c == ord('['):
                bracket_depth += 1
                array_count += 1
                max_depth = max(max_depth, bracket_depth)
            elif c == ord(']'):
                bracket_depth -= 1

        hints.string_ratio = Float32(quote_count) / Float32(limit)
        hints.number_ratio = Float32(digit_count) / Float32(limit)
        hints.nesting_depth = max_depth
        hints.array_heavy = array_count > 10

        return hints
```

### Parse Strategy Enum

```mojo
@value
struct ParseStrategy:
    """Parsing strategy selection."""

    alias CPU_SCALAR: Int = 0   # Simple character-by-character
    alias CPU_SIMD: Int = 1     # SIMD-accelerated two-stage
    alias GPU_HYBRID: Int = 2   # GPU stage1 + CPU stage2
    alias GPU_FULL: Int = 3     # Full GPU pipeline (batch mode)
    alias AUTO: Int = -1        # Auto-select based on heuristics

    var value: Int
```

## GPU Integration with mojo-metal

### Structural Discovery Kernel

```mojo
# In mojo-metal: kernels/json_structural.mojo

from gpu import block_dim, block_idx, thread_idx
from gpu.host import DeviceContext, HostBuffer, DeviceBuffer
from layout import LayoutTensor, Layout

fn structural_discovery_kernel[
    layout: Layout,
](
    input: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    structural_mask: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    quote_mask: LayoutTensor[DType.uint8, layout, MutableAnyOrigin],
    size: Int,
):
    """GPU kernel to find structural characters in parallel.

    Each thread processes 4 bytes (vectorized for efficiency).
    Structural chars: " { } [ ] : ,
    """
    var tid = block_idx.x * block_dim.x + thread_idx.x
    var byte_offset = tid * 4

    if byte_offset + 3 < size:
        # Load 4 bytes
        var b0 = input[byte_offset]
        var b1 = input[byte_offset + 1]
        var b2 = input[byte_offset + 2]
        var b3 = input[byte_offset + 3]

        # Check structural characters
        structural_mask[byte_offset] = _is_structural(b0)
        structural_mask[byte_offset + 1] = _is_structural(b1)
        structural_mask[byte_offset + 2] = _is_structural(b2)
        structural_mask[byte_offset + 3] = _is_structural(b3)

        # Check quotes
        quote_mask[byte_offset] = UInt8(1) if b0 == ord('"') else UInt8(0)
        quote_mask[byte_offset + 1] = UInt8(1) if b1 == ord('"') else UInt8(0)
        quote_mask[byte_offset + 2] = UInt8(1) if b2 == ord('"') else UInt8(0)
        quote_mask[byte_offset + 3] = UInt8(1) if b3 == ord('"') else UInt8(0)


fn _is_structural(c: UInt8) -> UInt8:
    """Check if byte is a JSON structural character."""
    return UInt8(1) if (
        c == ord('"') or
        c == ord('{') or c == ord('}') or
        c == ord('[') or c == ord(']') or
        c == ord(':') or c == ord(',')
    ) else UInt8(0)
```

### Adaptive Parser Implementation

```mojo
# In mojo-json: adaptive_parser.mojo

from mojo_metal.device import MetalDevice
from mojo_metal.kernels.json_structural import structural_discovery_kernel

struct AdaptiveJsonParser:
    """JSON parser that automatically selects CPU or GPU path."""

    var strategy_selector: StrategySelector
    var metal_device: Optional[MetalDevice]
    var cpu_parser: CpuSimdParser

    fn __init__(out self, config: ParseConfig = ParseConfig()):
        self.strategy_selector = StrategySelector()
        self.strategy_selector.gpu_threshold = config.gpu_threshold
        self.strategy_selector.prefer_latency = config.prefer_latency

        # Initialize GPU if available and wanted
        if config.strategy != ParseStrategy.CPU_SIMD:
            try:
                self.metal_device = MetalDevice()
            except:
                self.metal_device = None
        else:
            self.metal_device = None

        self.cpu_parser = CpuSimdParser()

    fn parse(self, source: String) raises -> JsonValue:
        """Parse JSON with automatic strategy selection."""
        var data = source.as_bytes()
        var size = len(data)

        # Quick content analysis (samples first 1KB)
        var hints = ContentHints.quick_analyze(data, sample_size=1024)

        # Select strategy
        var strategy = self.strategy_selector.select(size, hints)

        # Dispatch to appropriate path
        if strategy == ParseStrategy.CPU_SCALAR:
            return self._parse_scalar(data)
        elif strategy == ParseStrategy.CPU_SIMD:
            return self._parse_cpu_simd(data)
        elif strategy == ParseStrategy.GPU_HYBRID:
            return self._parse_gpu_hybrid(data)
        else:
            return self._parse_cpu_simd(data)  # Fallback

    fn _parse_cpu_simd(self, data: Span[UInt8]) raises -> JsonValue:
        """CPU SIMD two-stage parsing."""
        # Stage 1: SIMD structural discovery
        var structural_index = self.cpu_parser.build_structural_index(data)

        # Stage 2: Value extraction using index
        return self.cpu_parser.extract_values(data, structural_index)

    fn _parse_gpu_hybrid(self, data: Span[UInt8]) raises -> JsonValue:
        """GPU Stage 1 + CPU Stage 2."""
        if self.metal_device is None:
            return self._parse_cpu_simd(data)

        var device = self.metal_device.value()

        # Allocate GPU buffers
        var input_buf = device.allocate(len(data))
        var structural_buf = device.allocate(len(data))
        var quote_buf = device.allocate(len(data))

        # Copy input to GPU
        input_buf.copy_from_host(data)

        # Launch structural discovery kernel
        var blocks = (len(data) + 255) // 256
        device.dispatch(
            structural_discovery_kernel,
            blocks=blocks,
            threads=256,
            input_buf,
            structural_buf,
            quote_buf,
            len(data),
        )

        # Copy results back
        var structural_mask = List[UInt8](len(data))
        var quote_mask = List[UInt8](len(data))
        structural_buf.copy_to_host(structural_mask)
        quote_buf.copy_to_host(quote_mask)

        # Stage 2: CPU value extraction (sequential dependency)
        var structural_index = self._build_index_from_masks(
            structural_mask, quote_mask
        )
        return self.cpu_parser.extract_values(data, structural_index)
```

## Performance Expectations

### M3 Ultra Performance Targets

| File Size | Strategy | Expected Throughput |
|-----------|----------|---------------------|
| 1 KB | CPU Scalar | 500 MB/s |
| 10 KB | CPU SIMD | 1,000 MB/s |
| 100 KB | CPU SIMD | 1,500 MB/s |
| 100 KB | GPU Hybrid | 1,200 MB/s (overhead) |
| 1 MB | GPU Hybrid | 2,500 MB/s |
| 10 MB | GPU Hybrid | 4,000 MB/s |

### Crossover Analysis for M3 Ultra

```
GPU overhead breakdown:
- Kernel launch: ~10 μs
- Memory copy to device: ~1 μs/KB (unified memory helps)
- Synchronization: ~5 μs
- Memory copy from device: ~1 μs/KB

Total overhead: ~20 μs + 2 μs/KB

For 100KB file:
- GPU overhead: 20 + 200 = 220 μs
- GPU compute: 100 μs (massively parallel)
- Total GPU: 320 μs

- CPU SIMD: 65 μs (1.5 GB/s)

Crossover: When GPU compute savings > overhead
- At 100KB: GPU overhead dominates
- At 500KB: GPU compute savings start winning
- At 1MB: GPU is clearly faster

Recommended crossover: 100-200 KB for M3 Ultra
```

### Batch Processing Advantage

For batch processing (many JSON files), GPU overhead is amortized:

```
Single file (100KB):
- CPU: 65 μs
- GPU: 320 μs (5x slower)

100 files (100KB each, batch):
- CPU: 6,500 μs (100 × 65)
- GPU: 220 + 10,000 = 10,220 μs (still slower)

100 files (1MB each, batch):
- CPU: 65,000 μs
- GPU: 220 + 25,000 = 25,220 μs (2.5x faster!)
```

## Configuration Recommendations

### Default Configuration (Latency-Optimized)

```mojo
var config = ParseConfig(
    strategy = ParseStrategy.AUTO,
    gpu_threshold = 200 * 1024,    # 200 KB (conservative)
    simd_threshold = 16 * 1024,    # 16 KB
    prefer_latency = True,
)
```

### Throughput-Optimized Configuration

```mojo
var config = ParseConfig(
    strategy = ParseStrategy.AUTO,
    gpu_threshold = 100 * 1024,    # 100 KB (aggressive)
    simd_threshold = 8 * 1024,     # 8 KB
    prefer_latency = False,
)
```

### Batch Processing Configuration

```mojo
var config = ParseConfig(
    strategy = ParseStrategy.GPU_FULL,  # Always use GPU
    batch_size = 100,                   # Process 100 files per dispatch
)
```

## Implementation Phases

### Phase 1: CPU SIMD Enhancement (P0)
1. Implement SIMD structural character detection
2. Implement two-stage parsing architecture
3. Add fast float parsing (Lemire's algorithm)
4. **Target: 1,500 MB/s for all file sizes**

### Phase 2: GPU Structural Discovery (P1)
1. Add json_structural.mojo kernel to mojo-metal
2. Implement GPU hybrid path in mojo-json
3. Add automatic crossover detection
4. **Target: 2,500 MB/s for files >1MB**

### Phase 3: Adaptive Tuning (P2)
1. Add content heuristics (string-heavy, number-heavy)
2. Implement batch processing API
3. Auto-tune crossover thresholds per device
4. **Target: Optimal path selection with <1% wrong decisions**

## Success Metrics

| Metric | Target |
|--------|--------|
| CPU SIMD throughput | >1,500 MB/s |
| GPU throughput (1MB+) | >2,500 MB/s |
| Strategy selection accuracy | >99% |
| API overhead | <5 μs |
| Memory efficiency | <1.5x input size |

## References

- [simdjson On-Demand API](https://github.com/simdjson/simdjson/blob/master/doc/ondemand.md)
- [GPU-Accelerated JSON Parsing](https://arxiv.org/abs/2007.14287)
- [mojo-metal GPU Kernels](/Users/amund/mojo-contrib-experimental/mojo-metal/src/kernels/)
- [Apple Metal Best Practices](https://developer.apple.com/documentation/metal/gpu_programming_techniques)
