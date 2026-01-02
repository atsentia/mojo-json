# mojo-json Lazy Parser API

On-demand JSON parsing using simdjson-inspired architecture.

## Performance

| Access Pattern | Lazy Parser | Tape Parser | Speedup |
|----------------|-------------|-------------|---------|
| Access 1-2 fields from 100KB | 107 μs | 240 μs | **2.2x** |
| Access 1-2 fields from 48KB | 53 μs | 116 μs | **2.2x** |
| Full traversal | Similar | Similar | 1.0x |

**Best for:** Config files, API responses, selective field access

## Quick Start

```mojo
from src.lazy_parser import parse_lazy

fn main():
    var json = '{"name": "Alice", "age": 30, "active": true}'
    var doc = parse_lazy(json)
    var root = doc.root()

    # Values parsed only when accessed
    var name = root["name"].as_string()    # Parses "Alice" here
    var age = root["age"].as_int()         # Parses 30 here
    var active = root["active"].as_bool()  # Parses true here

    print("Name:", name)      # Alice
    print("Age:", age)        # 30
    print("Active:", active)  # True
```

## API Reference

### `parse_lazy(json: String) -> LazyJsonDocument`

Parse JSON lazily - builds structural index only, values parsed on access.

```mojo
var doc = parse_lazy('{"key": "value"}')
```

### `LazyJsonDocument`

Container for lazy JSON document.

```mojo
struct LazyJsonDocument:
    fn root(self) -> LazyValue
```

### `LazyValue`

Lazy JSON value - parses on access.

**Type Detection:**
```mojo
fn type(self) -> String      # "object", "array", "string", "number", "true", "false", "null"
fn is_object(self) -> Bool
fn is_array(self) -> Bool
fn is_string(self) -> Bool
fn is_null(self) -> Bool
```

**Value Extraction:**
```mojo
fn as_string(self) -> String
fn as_int(self) -> Int64
fn as_float(self) -> Float64
fn as_bool(self) -> Bool
```

**Object Access:**
```mojo
fn __getitem__(self, key: String) -> LazyValue
```

## Nested Access

```mojo
var json = '{"user": {"profile": {"name": "Bob"}}}'
var doc = parse_lazy(json)
var name = doc.root()["user"]["profile"]["name"].as_string()
print(name)  # Bob
```

## Architecture

```
JSON String
    │
    ▼
┌─────────────────────────────────────┐
│ Stage 1: Structural Index (SIMD)    │  ~1,000 MB/s
│ - Find: { } [ ] " : ,               │
│ - Build positions array             │
│ - NO value parsing                  │
└─────────────────────────────────────┘
    │
    ▼
LazyJsonDocument
    │ Access root["key"]
    ▼
┌─────────────────────────────────────┐
│ On-Demand Parsing                   │
│ - Navigate structural index         │
│ - Parse only requested value        │
│ - O(1) object key lookup (linear)   │
└─────────────────────────────────────┘
```

## When to Use

**Use Lazy Parser:**
- Accessing 1-5 fields from large JSON
- Config file parsing
- API response selective extraction
- Unknown JSON structure exploration

**Use Tape Parser:**
- Processing all values in JSON
- Data transformation pipelines
- JSON validation
- Full document traversal

## Comparison with Tape Parser

| Feature | Lazy Parser | Tape Parser |
|---------|-------------|-------------|
| Initial parse | Structural index only | Full parse to tape |
| Memory | Lower (index + source) | Higher (tape + strings) |
| Partial access | **2x faster** | Full cost upfront |
| Full access | Similar | Slightly faster |
| Random access | O(n) key search | O(1) tape index |

## Files

| File | Purpose |
|------|---------|
| `src/lazy_parser.mojo` | Lazy parser implementation |
| `src/structural_index.mojo` | SIMD structural scanning |
| `test_lazy_parser.mojo` | Unit tests |
| `benchmark_lazy_vs_eager.mojo` | Performance comparison |
