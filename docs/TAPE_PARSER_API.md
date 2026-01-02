# mojo-json Tape Parser API

High-performance JSON parsing using the simdjson two-stage architecture.

## Performance

| JSON Type | Throughput | Notes |
|-----------|------------|-------|
| Mixed content | **340-350 MB/s** | Production-like data |
| Object arrays | 330-345 MB/s | Realistic workloads |
| Flat int arrays | 210-256 MB/s | SIMD-accelerated |
| Deep nesting | 300-320 MB/s | Recursive structures |

**Comparison**: ~48% of orjson (718 MB/s), ~14% of simdjson (2,500 MB/s)

## Quick Start

```mojo
from src.tape_parser import parse_to_tape

fn main() raises:
    var json = '{"name": "Alice", "age": 30}'
    var tape = parse_to_tape(json)

    print("Tape entries:", len(tape))
    print("Memory usage:", tape.memory_usage(), "bytes")
```

## API Reference

### `parse_to_tape(json: String) -> JsonTape`

Parse JSON string into tape representation.

**Returns**: `JsonTape` containing parsed data

**Raises**: On invalid JSON

### `JsonTape` Structure

The tape is a flat array of 64-bit entries:

```
[8-bit type tag | 56-bit payload]
```

**Type Tags**:
| Tag | Char | Description |
|-----|------|-------------|
| `TAPE_ROOT` | `r` | Root entry (payload = tape length) |
| `TAPE_START_OBJECT` | `{` | Object start (payload = end index) |
| `TAPE_END_OBJECT` | `}` | Object end (payload = start index) |
| `TAPE_START_ARRAY` | `[` | Array start (payload = end index) |
| `TAPE_END_ARRAY` | `]` | Array end (payload = start index) |
| `TAPE_STRING` | `"` | String (payload = buffer offset) |
| `TAPE_INT64` | `l` | Integer (next entry = raw value) |
| `TAPE_DOUBLE` | `d` | Float (next entry = raw bits) |
| `TAPE_TRUE` | `t` | Boolean true |
| `TAPE_FALSE` | `f` | Boolean false |
| `TAPE_NULL` | `n` | Null value |

### `JsonTape` Methods

```mojo
# Size and memory
fn __len__(self) -> Int
fn memory_usage(self) -> Int

# Reading entries
fn get_entry(self, idx: Int) -> TapeEntry
fn get_string(self, offset: Int) -> String
fn get_int64(self, idx: Int) -> Int64
fn get_double(self, idx: Int) -> Float64

# Navigation
fn skip_value(self, idx: Int) -> Int
```

### `TapeEntry` Methods

```mojo
fn type_tag(self) -> UInt8
fn payload(self) -> Int
fn raw_u64(self) -> UInt64

fn is_container_start(self) -> Bool
fn is_container_end(self) -> Bool
fn is_string(self) -> Bool
fn is_number(self) -> Bool
```

## Example: Traversing JSON

```mojo
from src.tape_parser import parse_to_tape, TAPE_STRING, TAPE_INT64

fn main() raises:
    var json = '{"users": [{"name": "Alice", "age": 30}]}'
    var tape = parse_to_tape(json)

    # Iterate through tape
    var i = 0
    while i < len(tape):
        var entry = tape.get_entry(i)
        var tag = entry.type_tag()

        if tag == TAPE_STRING:
            var s = tape.get_string(entry.payload())
            print("String:", s)
            i += 1
        elif tag == TAPE_INT64:
            var n = tape.get_int64(i)
            print("Int64:", n)
            i += 2  # Skip value entry too
        else:
            i += 1
```

## Architecture

The parser uses simdjson's two-stage architecture:

```
JSON String
    │
    ▼
┌─────────────────────────────────────┐
│ Stage 1: Structural Index (SIMD)    │  ~1,000 MB/s
│ - Find: { } [ ] " : ,               │
│ - Track string boundaries           │
│ - Output: positions + characters    │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Stage 2: Tape Construction          │  ~450 MB/s
│ - Walk structural index             │
│ - Parse literals/numbers            │
│ - Build flat tape entries           │
└─────────────────────────────────────┘
    │
    ▼
JsonTape (O(1) random access)
```

## Benchmarking

```mojo
from src.tape_parser import benchmark_tape_parse

fn main():
    var json = '...'  # Your JSON
    var throughput = benchmark_tape_parse(json, iterations=100)
    print("Throughput:", throughput, "MB/s")
```

## Files

| File | Purpose |
|------|---------|
| `src/tape_parser.mojo` | Main parser implementation |
| `src/structural_index.mojo` | SIMD structural scanning |
| `benchmark_tape.mojo` | Performance benchmarks |
| `profile_tape.mojo` | Stage timing analysis |
| `test_tape_parser.mojo` | Unit tests |

## Optimizations Applied

1. **SIMD Structural Scan**: 16-byte chunk processing
2. **Fast Integer Parser**: SIMD for 8+ digit numbers
3. **Pre-allocation**: Estimated tape size from structural count
4. **Zero-copy Strings**: Store references to source
5. **Inlined Functions**: Hot paths use `@always_inline`

## Limitations

- Numbers parsed as Int64 or Float64 (no arbitrary precision)
- Strings stored as references (source must remain valid)
- Sequential Stage 2 (GPU acceleration planned for Phase 3)
