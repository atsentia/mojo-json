# mojo-json Performance Analysis

**Date**: January 2026
**Hardware**: Apple M3 Ultra, 96GB RAM
**Benchmarks**: Standard simdjson test suite + generated data

## Benchmark Results Summary

### Parse Throughput (MB/s) - Higher is Better

| Library | Average | Peak | Notes |
|---------|---------|------|-------|
| **simdjson (C++)** | 2,500-5,000 | 12,000+ | NEON SIMD, On-demand API |
| **simdjson DOM** | 1,500-2,500 | 5,000 | Full materialization |
| **orjson (Rust)** | 718 | 1,816 | Best Python option |
| **ujson (C)** | 380 | 887 | Good but dated |
| **json (Python)** | 307 | 804 | Baseline |
| **mojo-json (current)** | TBD | TBD | To be measured |

### Key File Results

| File | Size | simdjson DOM | orjson | Ratio |
|------|------|--------------|--------|-------|
| twitter.json | 617 KB | 3,532 MB/s | 909 MB/s | **3.9x** |
| canada.json | 2.1 MB | 1,294 MB/s | 467 MB/s | **2.8x** |
| citm_catalog.json | 1.6 MB | 4,032 MB/s | 963 MB/s | **4.2x** |
| strings_1mb.json | 944 KB | 5,032 MB/s | 1,453 MB/s | **3.5x** |
| numbers_1mb.json | 911 KB | 1,148 MB/s | 377 MB/s | **3.0x** |

**simdjson is consistently 3-4x faster than orjson, which is already the fastest Python library.**

## Performance Gap Analysis

### Where simdjson Wins

1. **Structural Discovery (Stage 1)**
   - Uses SIMD to find `"`, `{`, `}`, `[`, `]`, `:`, `,` in parallel
   - Processes 32-64 bytes per SIMD instruction (NEON/AVX2)
   - mojo-json currently scans character-by-character for most operations

2. **UTF-8 Validation**
   - simdjson validates UTF-8 in parallel during Stage 1
   - Uses lookup tables + SIMD shuffles
   - mojo-json relies on Mojo's String type (implicit validation)

3. **Whitespace Skipping**
   - simdjson identifies all whitespace in Stage 1 (no separate skip)
   - mojo-json has SIMD whitespace skip but still per-character for some paths

4. **Number Parsing**
   - simdjson uses optimized float parsing (Lemire's algorithm)
   - mojo-json uses `atof()` which is slower

### Current mojo-json SIMD Coverage

| Operation | SIMD? | Speedup | Notes |
|-----------|-------|---------|-------|
| Whitespace skip | ✅ | 4-8x | 16-byte chunks |
| String boundary | ✅ | 3-6x | Find `"` and `\` |
| Digit counting | ✅ | 2-4x | For number parsing |
| Structural chars | ❌ | - | **Missing** |
| UTF-8 validation | ❌ | - | Implicit only |
| Float parsing | ❌ | - | Uses stdlib |

## Optimization Roadmap

### Phase 1: Enhanced SIMD (CPU) - Expected 2-3x improvement

1. **SIMD Structural Character Detection**
   ```mojo
   # Find all structural chars in 16 bytes at once
   fn find_structurals(data: SIMD[uint8, 16]) -> UInt16:
       var quotes = (data == ord('"'))
       var lbrace = (data == ord('{'))
       var rbrace = (data == ord('}'))
       var lbracket = (data == ord('['))
       var rbracket = (data == ord(']'))
       var colon = (data == ord(':'))
       var comma = (data == ord(','))
       return (quotes | lbrace | rbrace | lbracket | rbracket | colon | comma).to_bitmask()
   ```

2. **Two-Stage Parsing Architecture**
   ```
   Stage 1: Build structural index (SIMD)
   - Scan entire input with SIMD
   - Build array of structural char positions
   - Validate UTF-8 in same pass

   Stage 2: Value extraction (scalar)
   - Use index to jump between values
   - No character-by-character scanning
   ```

3. **Fast Float Parsing (Lemire's algorithm)**
   - Use integer operations for mantissa
   - Lookup table for powers of 10
   - Avoid `atof()` overhead

### Phase 2: GPU Acceleration (mojo-metal) - Experimental

**Potential GPU Use Cases:**

1. **Stage 1 Structural Discovery**
   - Each GPU thread processes a chunk (e.g., 256 bytes)
   - Find structural characters in parallel
   - Merge results to build index
   - **Challenge**: Handling strings that span chunks

2. **Parallel String Unescaping**
   - For JSON with many strings (API responses)
   - Each thread handles one string
   - **Challenge**: Variable-length output

3. **Batch Number Parsing**
   - Parse multiple numbers in parallel
   - Good for number-heavy data (sensor readings)
   - **Challenge**: Launch overhead for small files

**GPU Crossover Analysis:**

| Operation | CPU Time | GPU Overhead | Crossover Size |
|-----------|----------|--------------|----------------|
| Structural scan | O(n) | ~15μs | >50 KB |
| String unescape | O(n) | ~15μs | >100 strings |
| Number parsing | O(digits) | ~15μs | >1000 numbers |

**Recommendation**: GPU acceleration is only beneficial for:
- Large files (>1MB)
- Batch processing (many files at once)
- Specific workloads (number-heavy, string-heavy)

For typical API responses (<100KB), enhanced CPU SIMD will be faster.

## Implementation Priority

### High Impact, Medium Effort
1. **SIMD structural character detection** - Biggest single improvement
2. **Two-stage parsing** - Eliminates repeated scanning
3. **Fast float parsing** - Helps number-heavy data

### Medium Impact, Low Effort
4. **Expand SIMD width** - Use 32/64-byte SIMD where available
5. **String pooling** - Reduce allocation overhead
6. **Key interning** - Cache common object keys

### Low Impact, High Effort (Future)
7. **GPU structural discovery** - Only for very large files
8. **GPU batch processing** - For specialized workloads
9. **On-demand API** - Lazy parsing like simdjson

## Target Performance

| Metric | Current | Target | simdjson |
|--------|---------|--------|----------|
| Throughput (avg) | ~200 MB/s* | 1,000+ MB/s | 2,500 MB/s |
| vs orjson | 0.3x* | 1.5x | 3.5x |
| vs stdlib json | 0.7x* | 3.3x | 8x |

*Estimated based on typical Mojo performance vs Python

## Next Steps

1. [ ] Measure current mojo-json performance with same test files
2. [ ] Implement SIMD structural character detection
3. [ ] Implement two-stage parsing architecture
4. [ ] Implement fast float parsing
5. [ ] Re-benchmark and compare
6. [ ] Evaluate GPU acceleration for large files

## References

- [simdjson paper](https://arxiv.org/abs/1902.08318) - Parsing Gigabytes of JSON per Second
- [Lemire's fast float parsing](https://github.com/lemire/fast_float)
- [simdjson source](https://github.com/simdjson/simdjson/tree/master/src/generic/stage1)
- [orjson optimization notes](https://github.com/ijl/orjson#performance)
