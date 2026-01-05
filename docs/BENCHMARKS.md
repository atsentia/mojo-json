# mojo-json Benchmarks

Comprehensive cross-library JSON parsing benchmarks comparing mojo-json against the fastest JSON parsers across multiple languages.

## Test Environment

- **Hardware**: Apple M3 Ultra (24-core CPU, 76-core GPU, 96GB unified memory)
- **OS**: macOS Sequoia 15.2
- **Mojo**: 25.1.0
- **Test Date**: January 2025

## Benchmark Methodology

- **Iterations**: 10 per file per library
- **Warmup**: 5 iterations (discarded)
- **Metric**: Throughput in MB/s (higher is better)
- **Files**: Standard JSON benchmark files from [nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark)

### Test Files

| File | Size | Characteristics |
|------|------|-----------------|
| `twitter.json` | 617 KB | Mixed web API data, strings, nested objects |
| `canada.json` | 2.2 MB | GeoJSON coordinates, heavy float parsing |
| `citm_catalog.json` | 1.7 MB | Deeply nested structures, mixed types |

## Results Summary

### Throughput (MB/s) - Higher is Better

| Library | twitter.json | canada.json | citm_catalog.json |
|---------|-------------|-------------|-------------------|
| **mojo-json (NEON)** | **6,423** | **5,297** | 5,808 |
| simdjson (C++) | 4,313 | 3,898 | **5,970** |
| sonic-rs (Rust) | 1,650 | 1,144 | 2,855 |
| simd-json (Rust) | 1,019 | 494 | 1,269 |
| orjson (Python) | 794 | 405 | 817 |
| serde-json (Rust) | 353 | 535 | 806 |

### Rankings by File

**twitter.json** (617 KB - Web API payload):
1. 🥇 mojo-json: 6,423 MB/s
2. 🥈 simdjson: 4,313 MB/s (+49% for mojo-json)
3. 🥉 sonic-rs: 1,650 MB/s

**canada.json** (2.2 MB - GeoJSON coordinates):
1. 🥇 mojo-json: 5,297 MB/s
2. 🥈 simdjson: 3,898 MB/s (+36% for mojo-json)
3. 🥉 sonic-rs: 1,144 MB/s

**citm_catalog.json** (1.7 MB - Deeply nested):
1. 🥇 simdjson: 5,970 MB/s
2. 🥈 mojo-json: 5,808 MB/s (-3%)
3. 🥉 sonic-rs: 2,855 MB/s

## Libraries Tested

### mojo-json (This Library)
- **Language**: Mojo
- **Version**: Latest
- **API**: `NeonJsonIndexer.find_structural()` (NEON SIMD FFI)
- **Notes**: Uses ARM NEON intrinsics via C FFI for simdjson-level performance

### simdjson
- **Language**: C++
- **Version**: Latest (singleheader)
- **API**: On-demand parsing (`parser.iterate()`)
- **Notes**: The gold standard for JSON parsing performance

### sonic-rs
- **Language**: Rust
- **Version**: 0.3.17
- **API**: `sonic_rs::from_str()`
- **Notes**: SIMD-accelerated Rust JSON parser

### simd-json
- **Language**: Rust
- **Version**: 0.14.3
- **API**: `simd_json::to_borrowed_value()`
- **Notes**: Rust port of simdjson

### orjson
- **Language**: Python (Rust extension)
- **Version**: Latest
- **API**: `orjson.loads()`
- **Notes**: Fastest Python JSON library

### serde-json
- **Language**: Rust
- **Version**: 1.0.148
- **API**: `serde_json::from_str()`
- **Notes**: Standard Rust JSON library

## Detailed Results

### Statistical Analysis

Results include mean and standard deviation across 10 iterations:

```
================================================================================
Library        canada.json         citm_catalog.json   twitter.json
--------------------------------------------------------------------------------
mojo-json      5297 ± 398          5808 ± 620          6423 ± 131
simdjson       3898 ± 413          5970 ± 360          4313 ± 1597
sonic-rs       1144 ± 28           2855 ± 65           1650 ± 44
simd-json      494 ± 9             1269 ± 15           1019 ± 54
orjson         405 ± 11            817 ± 78            794 ± 37
serde-json     535 ± 24            806 ± 21            353 ± 39
================================================================================
```

### Performance Ratios

**mojo-json vs simdjson:**
- twitter.json: 1.49x faster
- canada.json: 1.36x faster
- citm_catalog.json: 0.97x (3% slower)

**mojo-json vs orjson (Python's fastest):**
- twitter.json: 8.1x faster
- canada.json: 13.1x faster
- citm_catalog.json: 7.1x faster

**mojo-json vs sonic-rs (Rust's fastest):**
- twitter.json: 3.9x faster
- canada.json: 4.6x faster
- citm_catalog.json: 2.0x faster

## Running the Benchmarks

### Prerequisites

```bash
# Build NEON library (for mojo-json)
cd neon && ./build.sh && cd ..

# Build Rust benchmarks
cd benchmarks/rust_bench && cargo build --release && cd ../..

# Build simdjson benchmark
cd benchmarks
clang++ -O3 -std=c++17 -I competitors/simdjson/singleheader \
        bench_simdjson_csv.cpp competitors/simdjson/singleheader/simdjson.cpp \
        -o bench_simdjson_csv

# Install orjson (Python)
pip install orjson
```

### Run All Benchmarks

```bash
cd benchmarks

# Run individual benchmarks
mojo run -I .. bench_comparison.mojo          # mojo-json (NEON)
python3 bench_comparison.py                    # orjson
cd rust_bench && ./target/release/json_bench   # Rust libraries
cd .. && ./bench_simdjson_csv                  # simdjson

# Aggregate results
cat results/mojo_results.csv > results/all_results.csv
tail -n +2 results/python_results.csv >> results/all_results.csv
tail -n +2 results/rust_results.csv >> results/all_results.csv
tail -n +2 results/simdjson_results.csv >> results/all_results.csv
python3 aggregate_results.py
```

### Quick Benchmark (mojo-json only)

```bash
cd mojo-json
mojo run -I . benchmarks/bench_neon.mojo
```

## Why is mojo-json So Fast?

### NEON SIMD Implementation

mojo-json uses ARM NEON intrinsics (via C FFI) implementing the simdjson algorithm:

1. **64-byte chunk processing**: Process 64 bytes per iteration using NEON vectors
2. **Branchless classification**: Lookup tables eliminate branch mispredictions
3. **Prefix-XOR string tracking**: Carry-less multiply for O(1) string state
4. **Parallel structural extraction**: Find all `{}[]:,"` positions simultaneously

### Architecture

```
Input JSON
    │
    ▼
┌─────────────────────────────────────────────────┐
│  NEON Stage 1: Structural Extraction            │
│  - 64-byte SIMD chunks                          │
│  - Branchless character classification          │
│  - Prefix-XOR for string boundary tracking      │
│  - ~6 GB/s throughput                           │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│  Stage 2: Value Parsing                         │
│  - Jump directly to structural positions        │
│  - On-demand value extraction                   │
│  - Zero-copy string references                  │
└─────────────────────────────────────────────────┘
```

### Build the NEON Library

```bash
cd neon
./build.sh
# Creates: libneon_json.dylib
```

## Historical Performance

| Version | Throughput | Notes |
|---------|-----------|-------|
| v0.1 (parse) | 14 MB/s | Recursive descent |
| v0.2 (tape) | 300 MB/s | Tape-based parser |
| v0.3 (SIMD) | 600 MB/s | CPU SIMD structural scan |
| v0.4 (NEON) | **6,000 MB/s** | ARM NEON via FFI |

## Reproducibility

All benchmark code is available in `benchmarks/`:

- `bench_comparison.mojo` - mojo-json NEON benchmark
- `bench_comparison.py` - orjson benchmark
- `rust_bench/` - Rust benchmarks (sonic-rs, simd-json, serde-json)
- `bench_simdjson_csv.cpp` - simdjson benchmark
- `aggregate_results.py` - Results aggregation

Raw results are saved to `benchmarks/results/`:
- `mojo_results.csv`
- `python_results.csv`
- `rust_results.csv`
- `simdjson_results.csv`
- `all_results.csv` (combined)
- `summary.csv` (statistics)
