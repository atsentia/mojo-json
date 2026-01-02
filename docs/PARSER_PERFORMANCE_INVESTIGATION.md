# mojo-json Parser Performance Investigation & Fix Plan

## Executive Summary

**Current State:**
- GPU Stage 1 (classification): **23,000 MB/s** ✅ Excellent
- Full Parse: **10 MB/s** ❌ 150x slower than simdjson

**Root Cause:** The parser has multiple O(n²) patterns and excessive memory allocations.

**Target:** 500-1,500 MB/s (competitive with simd-json Rust)

---

## Benchmark Evidence

### citylots.json (181MB GeoJSON) - January 2025

| Parser | Throughput | Language | Notes |
|--------|------------|----------|-------|
| **mojo-json GPU Stage 1** | 23,169 MB/s | Mojo+Metal | Classification only |
| simdjson | 1,532 MB/s | C++ | Full DOM parse |
| sonic-rs | 407 MB/s* | Rust | *Degrades at 181MB |
| simd-json | 493 MB/s | Rust | Full parse |
| serde_json | 409 MB/s | Rust | Full parse |
| **mojo-json Full** | 10 MB/s | Mojo | **150x slower** |

The GPU is not the bottleneck. The CPU parser is.

---

## Critical Issues Identified

### Issue 1: String Concatenation O(n²)

**Location:** `src/parser.mojo:664-750` (`_parse_string_content`)

```mojo
var result = String("")  # Line 664

# In the parsing loop:
result += self.source[self.pos:end_pos]  # Line 676
result += '"'   # Line 708
result += '\\'  # Line 709
# ... many more single-char appends
```

**Problem:** Each `+=` operation:
1. Allocates new buffer (old_len + new_len)
2. Copies ALL existing content
3. Appends new content
4. Frees old buffer

For a string of N characters with M escape sequences:
- Best case (no escapes): O(1) slice copy
- Worst case (many escapes): O(N × M) allocations

**Impact:** For citylots.json with millions of strings, this dominates parse time.

### Issue 2: JsonValue Allocates All Fields

**Location:** `src/value.mojo:117-131`

```mojo
fn __init__(out self):
    self._type = JsonType.NULL
    self._bool_val = False
    self._int_val = 0
    self._float_val = 0.0
    self._string_val = ""              # Allocates empty String
    self._array_val = List[JsonValue]()     # Allocates empty List
    self._object_val = Dict[String, JsonValue]()  # Allocates empty Dict
```

**Problem:** Every JsonValue, even a simple `42`, allocates:
- 1 empty String (24+ bytes)
- 1 empty List (24+ bytes)
- 1 empty Dict (48+ bytes)

citylots.json has ~200,000 features × ~10 values each = **2 million JsonValue objects**.

**Impact:** 2M × 96 bytes = ~192MB of unnecessary allocations.

### Issue 3: Deep Copies on Access

**Location:** `src/value.mojo:339-359, 375-395`

```mojo
fn as_array(self) -> List[JsonValue]:
    if self._type == JsonType.ARRAY:
        return self._array_val.copy()  # FULL DEEP COPY

fn __getitem__(self, index: Int) -> JsonValue:
    ...
    return self._array_val[index].copy()  # COPY on every access
```

**Problem:** Every array/object access creates a full deep copy.

For nested access like `data["features"][0]["geometry"]["coordinates"]`:
- 4 copies created
- Each copy recursively copies all children

**Impact:** Exponential copying for deep structures.

### Issue 4: Copy Constructor Deep Copies

**Location:** `src/value.mojo:132-140`

```mojo
fn __copyinit__(out self, other: Self):
    ...
    self._array_val = other._array_val.copy()   # Deep copy
    self._object_val = other._object_val.copy() # Deep copy
```

**Problem:** Even copying a simple integer triggers empty list/dict copies.

### Issue 5: Per-Character Line/Column Tracking

**Location:** `src/parser.mojo:978-986`

```mojo
fn _advance(mut self):
    if self.pos < len(self.source):
        if self.source[self.pos] == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        self.pos += 1
```

**Problem:** Called for EVERY character, even when SIMD processes batches.

**Impact:** Prevents effective SIMD utilization. Branch misprediction on newline check.

### Issue 6: No Pre-sizing of Collections

**Location:** `src/parser.mojo:858, 913`

```mojo
var arr = List[JsonValue]()  # No capacity hint
var obj = Dict[String, JsonValue]()  # No capacity hint
```

**Problem:** Collections grow via repeated reallocation (typically 2x each time).

For an array of 1000 elements: log₂(1000) ≈ 10 reallocations, each copying all elements.

---

## How simdjson Achieves 1,500+ MB/s

### 1. Tape-Based Architecture
```
Input: {"name": "Alice", "age": 30}

Tape: [ROOT_OBJ, 2, STRING_PTR, STRING_PTR, INT, 30, END_OBJ]
         ↓        ↓            ↓
      2 members  "name"       "Alice"
```
- Single contiguous allocation
- No per-value objects
- Values are indices/offsets into tape

### 2. Two-Stage Parsing
```
Stage 1 (SIMD): Find all structural characters: { } [ ] " : ,
Stage 2 (Scalar): Walk structural positions, build tape
```
- Stage 1 is embarrassingly parallel (our GPU does this at 23 GB/s)
- Stage 2 jumps between structural chars (no scanning)

### 3. Zero-Copy Strings
```cpp
// simdjson doesn't copy strings - returns view into original buffer
std::string_view get_string() {
    return std::string_view(buffer + start, length);
}
```
- No allocation for string access
- Original buffer must stay alive

### 4. On-Demand Parsing
```cpp
// Values parsed only when accessed
auto doc = parser.iterate(json);
auto name = doc["name"];  // Parsed here, not during initial parse
```
- Initial "parse" just validates and builds index
- Actual value extraction is lazy

---

## Fix Strategy (Prioritized by Impact)

### Phase 1: Quick Wins (Target: 50-100 MB/s)

#### 1.1 String Builder Pattern
**File:** `src/parser.mojo`
**Effort:** 2-3 hours
**Expected Impact:** 5-10x speedup on string-heavy JSON

```mojo
# BEFORE (O(n²)):
var result = String("")
result += char1
result += char2
...

# AFTER (O(n)):
var buffer = List[UInt8](capacity=estimated_length)
buffer.append(byte1)
buffer.append(byte2)
...
return String(buffer^)
```

#### 1.2 Lazy Field Initialization
**File:** `src/value.mojo`
**Effort:** 3-4 hours
**Expected Impact:** 2-3x speedup (fewer allocations)

```mojo
# BEFORE: Always allocate all fields
fn __init__(out self):
    self._string_val = ""
    self._array_val = List[JsonValue]()
    self._object_val = Dict[String, JsonValue]()

# AFTER: Only allocate what's needed
# Option A: Use Optional types
var _string_val: Optional[String]
var _array_val: Optional[List[JsonValue]]

# Option B: Use unsafe uninitialized memory
# (requires careful lifecycle management)
```

#### 1.3 Pre-sized Collections
**File:** `src/parser.mojo`
**Effort:** 1-2 hours
**Expected Impact:** 1.5x speedup

```mojo
# BEFORE:
var arr = List[JsonValue]()

# AFTER: Estimate capacity from structural scan
var estimated_size = count_commas_in_range(start, end) + 1
var arr = List[JsonValue](capacity=estimated_size)
```

### Phase 2: Reference Semantics (Target: 100-300 MB/s)

#### 2.1 Return References Instead of Copies
**File:** `src/value.mojo`
**Effort:** 4-6 hours
**Expected Impact:** 2-5x speedup for nested access

```mojo
# BEFORE (copies):
fn as_array(self) -> List[JsonValue]:
    return self._array_val.copy()

# AFTER (reference):
fn as_array_ref(self) -> ref [self._array_val] List[JsonValue]:
    return self._array_val
```

**Note:** Requires careful ownership tracking. May need Mojo 0.26+ features.

#### 2.2 Batch Position Tracking
**File:** `src/parser.mojo`
**Effort:** 2-3 hours
**Expected Impact:** 1.5x speedup

```mojo
# BEFORE: Per-character tracking
fn _advance(mut self):
    if self.source[self.pos] == '\n':
        self.line += 1
    self.pos += 1

# AFTER: Batch update after SIMD scan
fn _advance_batch(mut self, count: Int, newlines: Int):
    self.pos += count
    self.line += newlines
    # Column calculated lazily on error
```

### Phase 3: Structural Index (Target: 300-800 MB/s)

#### 3.1 Two-Stage Architecture
**New File:** `src/structural_index.mojo`
**Effort:** 8-12 hours
**Expected Impact:** 3-5x speedup

```mojo
struct StructuralIndex:
    """Positions of all structural characters."""
    var positions: List[Int]
    var characters: List[UInt8]

fn build_structural_index(data: String) -> StructuralIndex:
    """Stage 1: Find all { } [ ] " : , positions using SIMD."""
    # Can use GPU classification here!
    var gpu_classes = gpu_classify(data)

    var index = StructuralIndex()
    for i in range(len(gpu_classes)):
        if gpu_classes[i] != CHAR_OTHER:
            index.positions.append(i)
            index.characters.append(gpu_classes[i])
    return index

fn parse_with_index(data: String, index: StructuralIndex) -> JsonValue:
    """Stage 2: Build values by jumping between structural positions."""
    # No character scanning - just jump to next structural char
```

#### 3.2 GPU-Accelerated Stage 1
**File:** `src/gpu_parser.mojo`
**Effort:** 4-6 hours
**Expected Impact:** 2x speedup for large files (>1MB)

```mojo
fn parse_gpu_hybrid(data: String) -> JsonValue:
    """Use GPU for Stage 1, CPU for Stage 2."""
    if len(data) < 64 * 1024:
        return parse_cpu(data)  # GPU overhead not worth it

    var classifier = MetalJsonClassifier()
    var classifications = classifier.classify(data)
    var index = build_index_from_classifications(classifications)
    return parse_with_index(data, index)
```

### Phase 4: Tape-Based Output (Target: 800-1,500 MB/s)

#### 4.1 Tape Data Structure
**New File:** `src/tape.mojo`
**Effort:** 12-16 hours
**Expected Impact:** 2-3x speedup

```mojo
struct JsonTape:
    """Compact representation of parsed JSON."""
    var tape: List[UInt64]      # Type tags + values/offsets
    var strings: List[UInt8]    # All string bytes concatenated
    var string_offsets: List[Int]  # Where each string starts

    fn get_type(self, index: Int) -> JsonType:
        return (self.tape[index] >> 56) as JsonType

    fn get_int(self, index: Int) -> Int64:
        return self.tape[index] as Int64

    fn get_string(self, index: Int) -> StringRef:
        var offset = self.string_offsets[index]
        var length = self.string_offsets[index + 1] - offset
        return StringRef(self.strings.unsafe_ptr() + offset, length)
```

#### 4.2 Tape Builder
```mojo
struct TapeBuilder:
    var tape: JsonTape
    var pos: Int  # Current tape position

    fn add_int(mut self, value: Int64):
        self.tape.tape.append((JsonType.INT << 56) | (value as UInt64))
        self.pos += 1

    fn add_string(mut self, data: String, start: Int, end: Int):
        # Copy string bytes to string buffer
        var offset = len(self.tape.strings)
        for i in range(start, end):
            self.tape.strings.append(ord(data[i]))
        self.tape.string_offsets.append(offset)
        self.tape.tape.append((JsonType.STRING << 56) | (offset as UInt64))
        self.pos += 1
```

### Phase 5: On-Demand API (Target: 1,500+ MB/s)

#### 5.1 Lazy Value Wrapper
**New File:** `src/lazy.mojo`
**Effort:** 8-12 hours

```mojo
struct LazyJson:
    """Parse-on-demand JSON value."""
    var _data: String
    var _tape: JsonTape
    var _index: Int

    fn type(self) -> JsonType:
        return self._tape.get_type(self._index)

    fn as_int(self) -> Int64:
        return self._tape.get_int(self._index)

    fn __getitem__(self, key: String) -> LazyJson:
        """Lookup without parsing other fields."""
        # Scan tape for matching key
        ...
```

---

## Implementation Roadmap

```
Week 1: Quick Wins (Phase 1)
├── Day 1-2: String Builder Pattern (1.1)
├── Day 3: Pre-sized Collections (1.3)
├── Day 4-5: Lazy Field Initialization (1.2)
└── Benchmark: Target 50-100 MB/s

Week 2: Reference Semantics (Phase 2)
├── Day 1-3: Return References (2.1)
├── Day 4-5: Batch Position Tracking (2.2)
└── Benchmark: Target 100-300 MB/s

Week 3: Structural Index (Phase 3)
├── Day 1-3: Build Structural Index (3.1)
├── Day 4-5: GPU-Accelerated Stage 1 (3.2)
└── Benchmark: Target 300-800 MB/s

Week 4: Tape Architecture (Phase 4 - Optional)
├── Day 1-3: Tape Data Structure (4.1)
├── Day 4-5: Tape Builder (4.2)
└── Benchmark: Target 800-1,500 MB/s
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Mojo reference semantics unstable | Medium | High | Use copies as fallback, wait for 0.26 |
| String builder still slow | Low | Medium | Profile, consider unsafe ptr ops |
| GPU integration complexity | Medium | Medium | CPU-only fallback always available |
| Tape API incompatible with existing | High | Medium | Keep existing API, add tape as option |

---

## Success Metrics

| Phase | Target | Measurement |
|-------|--------|-------------|
| Phase 1 | 50-100 MB/s | citylots_10mb.json parse time |
| Phase 2 | 100-300 MB/s | citylots_25mb.json parse time |
| Phase 3 | 300-800 MB/s | citylots_50mb.json parse time |
| Phase 4 | 800-1,500 MB/s | citylots.json (181MB) parse time |

**Ultimate Goal:** Match simd-json Rust (~500 MB/s) within 4 weeks.

---

## Appendix: Profiling Commands

```bash
# Build with profiling
mojo build -O3 bench_citylots_full.mojo

# Run with Instruments (macOS)
xcrun xctrace record --template "Time Profiler" --launch bench_citylots_full

# Memory profiling
xcrun leaks --atExit -- ./bench_citylots_full

# Allocation tracking
MallocStackLogging=1 ./bench_citylots_full
```

---

## Phase 6: GPU-Heavy Architecture (Target: 2,000-5,000 MB/s)

The GPU achieves 23 GB/s on character classification. Can we push more work to GPU?

### What GPU Excels At

| Task | Parallelizable? | GPU Potential |
|------|-----------------|---------------|
| Character classification | ✅ Yes | 23 GB/s (proven) |
| Quote position detection | ✅ Yes | 20+ GB/s |
| Backslash detection | ✅ Yes | 20+ GB/s |
| Digit span detection | ✅ Yes | 15+ GB/s |
| Whitespace boundaries | ✅ Yes | 20+ GB/s |
| Bracket/brace counting | ✅ Parallel prefix sum | 10+ GB/s |
| UTF-8 validation | ✅ Yes | 15+ GB/s |

### What Requires Sequential Processing

| Task | Why Sequential? | CPU Speed |
|------|-----------------|-----------|
| String state tracking | "Is this `{` inside a string?" | 5+ GB/s |
| Escape resolution | `\"` vs `"` | 5+ GB/s |
| Tape building | Variable-length output | 1-2 GB/s |
| Value extraction | Tree construction | 500 MB/s |

### The String State Problem

The challenge: **A `{` inside `"{hello}"` is NOT structural.**

```
Input:  {"key": "value with { brace"}
         ^      ^         ^       ^
         |      |         |       |
     Structural String   NOT    End
                        struct  string
```

GPU can find ALL `{` positions, but can't know which are inside strings without sequential state.

### simdjson's Solution: Parallel Quote Pairing

simdjson uses a clever SIMD algorithm:

```
1. Find all backslash positions:    [5, 12, ...]
2. Find all quote positions:        [1, 6, 15, 22, ...]
3. Mark escaped quotes (\ before "): XOR scan
4. Compute string regions:          Prefix XOR of unescaped quotes
5. Mask structural chars:           AND with "not in string" mask
```

Steps 1-2 are parallel. Steps 3-5 use SIMD prefix operations.

### GPU-Heavy Pipeline Design

```
┌─────────────────────────────────────────────────────────────┐
│  GPU KERNEL 1: Multi-Class Detection (one pass)            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ For each byte in parallel:                          │   │
│  │   - Is it { } [ ] : , " \ or other?                 │   │
│  │   - Is it whitespace?                               │   │
│  │   - Is it a digit?                                  │   │
│  │   - Is it a UTF-8 continuation byte?                │   │
│  │ Output: 4 parallel bitmaps (1 bit per byte)         │   │
│  └─────────────────────────────────────────────────────┘   │
│  Throughput: 20+ GB/s                                      │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  GPU KERNEL 2: Position Extraction                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ For each 64-bit word of bitmap:                     │   │
│  │   - Count set bits (popcount)                       │   │
│  │   - Extract positions (parallel bit scan)           │   │
│  │ Output: Compact position arrays                     │   │
│  └─────────────────────────────────────────────────────┘   │
│  Throughput: 15+ GB/s                                      │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  GPU KERNEL 3: Parallel Prefix Operations                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Escape resolution:                                  │   │
│  │   - XOR scan of backslash-before-quote              │   │
│  │ String state:                                       │   │
│  │   - Prefix XOR of unescaped quotes                  │   │
│  │ Nesting depth:                                      │   │
│  │   - Prefix sum of (+1 for {[, -1 for ]})            │   │
│  └─────────────────────────────────────────────────────┘   │
│  Throughput: 10+ GB/s (memory bound)                       │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  CPU: Tape Construction                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Walk structural positions (not raw bytes!)          │   │
│  │ Build tape entries for values                       │   │
│  │ Copy strings to string buffer                       │   │
│  └─────────────────────────────────────────────────────┘   │
│  Throughput: 1-2 GB/s (limited by tape output)             │
└─────────────────────────────────────────────────────────────┘
```

### New Metal Kernels Needed

#### Kernel: `json_multiclass_detect`
```metal
// Output 4 bits per byte packed into uint32
kernel void json_multiclass_detect(
    device const uint8_t* input [[buffer(0)]],
    device uint32_t* structural_bitmap [[buffer(1)]],  // { } [ ] : , "
    device uint32_t* quote_bitmap [[buffer(2)]],       // " positions
    device uint32_t* backslash_bitmap [[buffer(3)]],   // \ positions
    device uint32_t* digit_bitmap [[buffer(4)]],       // 0-9 positions
    constant uint32_t& size [[buffer(5)]],
    uint tid [[thread_position_in_grid]]
) {
    uint base = tid * 32;  // Each thread handles 32 bytes → 1 uint32 output

    uint32_t structural = 0;
    uint32_t quotes = 0;
    uint32_t backslashes = 0;
    uint32_t digits = 0;

    for (uint i = 0; i < 32 && base + i < size; i++) {
        uint8_t c = input[base + i];
        uint32_t bit = 1u << i;

        if (c == '{' || c == '}' || c == '[' || c == ']' ||
            c == ':' || c == ',' || c == '"') {
            structural |= bit;
        }
        if (c == '"') quotes |= bit;
        if (c == '\\') backslashes |= bit;
        if (c >= '0' && c <= '9') digits |= bit;
    }

    structural_bitmap[tid] = structural;
    quote_bitmap[tid] = quotes;
    backslash_bitmap[tid] = backslashes;
    digit_bitmap[tid] = digits;
}
```

#### Kernel: `prefix_xor_scan`
```metal
// Compute prefix XOR for string state tracking
// Uses work-efficient parallel scan algorithm
kernel void prefix_xor_scan(
    device uint32_t* data [[buffer(0)]],
    device uint32_t* output [[buffer(1)]],
    constant uint32_t& n [[buffer(2)]],
    uint tid [[thread_position_in_grid]],
    uint gid [[threadgroup_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]]
) {
    // Blelloch scan algorithm adapted for XOR
    threadgroup uint32_t shared[256];

    // Load into shared memory
    shared[lid] = (tid < n) ? data[tid] : 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Up-sweep (reduce)
    for (uint stride = 1; stride < 256; stride *= 2) {
        uint idx = (lid + 1) * stride * 2 - 1;
        if (idx < 256) {
            shared[idx] ^= shared[idx - stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Down-sweep
    if (lid == 255) shared[255] = 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride /= 2) {
        uint idx = (lid + 1) * stride * 2 - 1;
        if (idx < 256) {
            uint32_t temp = shared[idx - stride];
            shared[idx - stride] = shared[idx];
            shared[idx] ^= temp;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid < n) output[tid] = shared[lid];
}
```

### Expected Performance

| File Size | GPU-Heavy | Current Full | Speedup |
|-----------|-----------|--------------|---------|
| 10 MB | 300-500 MB/s | 10 MB/s | 30-50x |
| 50 MB | 800-1,500 MB/s | 10 MB/s | 80-150x |
| 181 MB | 1,500-3,000 MB/s | 10 MB/s | 150-300x |

### Implementation Effort

| Component | Effort | Dependencies |
|-----------|--------|--------------|
| Multi-class kernel | 4-6 hours | None |
| Position extraction | 4-6 hours | Multi-class kernel |
| Prefix scan kernels | 8-12 hours | Position extraction |
| String state resolution | 4-6 hours | Prefix scan |
| CPU tape builder | 8-12 hours | All GPU stages |
| Integration & testing | 8-12 hours | All above |

**Total:** 36-54 hours (1-1.5 weeks focused effort)

### Comparison with CPU-Only Approach

| Approach | Target | Complexity | When to Use |
|----------|--------|------------|-------------|
| CPU Quick Wins | 100 MB/s | Low | Small files, quick improvement |
| CPU Structural Index | 500 MB/s | Medium | Medium files, balanced |
| GPU-Heavy | 2,000 MB/s | High | Large files (>1MB), max performance |

### Decision Matrix

```
File Size < 64KB:  Use CPU-only (GPU overhead dominates)
File Size 64KB-1MB: Use GPU classification + CPU parse
File Size > 1MB:    Use GPU-Heavy pipeline
```

---

## References

1. [simdjson: Parsing Gigabytes of JSON per Second](https://arxiv.org/abs/1902.08318)
2. [On-Demand JSON: A Better Way to Parse Documents?](https://arxiv.org/abs/2312.17149)
3. [Mojo Memory Ownership](https://docs.modular.com/mojo/manual/values/ownership)
4. [sonic-rs Design](https://github.com/cloudwego/sonic-rs/blob/main/docs/DESIGN.md)
5. [Parallel Prefix Sum (Scan) with CUDA](https://developer.nvidia.com/gpugems/gpugems3/part-vi-gpu-computing/chapter-39-parallel-prefix-sum-scan-cuda)
6. [Metal Best Practices Guide](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/)
