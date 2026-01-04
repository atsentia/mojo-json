# mojo-json

A high-performance JSON library for Mojo with GPU acceleration. Pure Mojo, no external dependencies.

## Performance Highlights (Apple M2 Max)

| Configuration | Throughput | Use Case |
|--------------|------------|----------|
| **GPU (Metal)** | **2,589 MB/s** | Large JSON (>64KB) |
| Adaptive Parser | 500-800 MB/s | Auto-selects best parser |
| NDJSON Zero-Copy | 1,900+ MB/s | Line extraction |
| On-Demand | 600+ MB/s | Sparse field access |

### GPU Acceleration (M2 Max)

GPU character classification via Metal FFI - **no Mojo Metal compiler needed**:

| JSON Size | GPU | CPU SIMD | Winner |
|-----------|-----|----------|--------|
| 16 KB | 51 MB/s | 500 MB/s | CPU |
| 64 KB | 281 MB/s | 500 MB/s | Crossover |
| 256 KB | **1,007 MB/s** | 500 MB/s | GPU 2x |
| 1 MB | **2,589 MB/s** | 500 MB/s | GPU 5x |

```mojo
from src.gpu_parser import parse_adaptive_gpu

# Auto-selects GPU (>64KB) or CPU (<64KB)
var tape = parse_adaptive_gpu(large_json)
```

Build GPU support: `cd metal && ./build_all.sh`

### Standard Benchmark Results (M2 Max)

| File | Size | V1 | V4 | Adaptive | Best For |
|------|------|----|----|----------|----------|
| twitter.json | 617 KB | **523 MB/s** | 469 MB/s | V1 | Web API payloads |
| canada.json | 2.2 MB | 336 MB/s | **446 MB/s** | V4 | GeoJSON (coordinates) |
| citm_catalog.json | 1.7 MB | **814 MB/s** | 748 MB/s | V1 | Nested structures |

### NDJSON Processing (M2 Max)

| Operation | Throughput | Speedup |
|-----------|------------|---------|
| Zero-copy extraction | 1,900 MB/s | **13.6x** vs copying |
| Traditional extraction | 140 MB/s | Baseline |
| Full parsing | 60-65 MB/s | Parsing dominates |

## Features

- **GPU Acceleration** - Metal compute shaders via FFI (2.5 GB/s for 1MB+)
- **Adaptive Parser** - Auto-selects V1/V2/V4 based on content analysis (83-100% optimal)
- **Zero-Copy NDJSON** - StringSlice extraction at 1.9 GB/s (13x faster)
- **SIMD Optimized** - Vectorized structural scanning (500+ MB/s)
- **On-Demand Parsing** - Parse-on-access for sparse field access (2x speedup)
- **Full JSON Spec** - RFC 8259 compliant parser
- **JsonValue Variant** - Type-safe representation of all JSON types
- **Unicode Support** - Full handling including surrogate pairs
- **Detailed Errors** - Parse errors with line/column information

## Installation

Add to your `pixi.toml`:

```toml
[dependencies]
mojo-json = { path = "../mojo-json" }
```

## Quick Start

### Parsing JSON

```mojo
from mojo_json import parse, JsonValue

# Parse a JSON string
var value = parse('{"name": "Alice", "age": 30, "active": true}')

# Access values
print(value["name"].as_string())  # Alice
print(value["age"].as_int())      # 30
print(value["active"].as_bool())  # True

# Check types before accessing
if value["name"].is_string():
    print("Name is a string!")
```

### Creating JSON Values

```mojo
from mojo_json import JsonValue, JsonObject, JsonArray

# Primitives
var null_val = JsonValue.null()
var bool_val = JsonValue.from_bool(True)
var int_val = JsonValue.from_int(42)
var float_val = JsonValue.from_float(3.14159)
var str_val = JsonValue.from_string("hello")

# Arrays
var arr = JsonArray()
arr.append(JsonValue.from_int(1))
arr.append(JsonValue.from_int(2))
arr.append(JsonValue.from_int(3))
var arr_val = JsonValue.from_array(arr)

# Objects
var obj = JsonObject()
obj["name"] = JsonValue.from_string("Bob")
obj["age"] = JsonValue.from_int(25)
obj["scores"] = arr_val
var obj_val = JsonValue.from_object(obj)
```

### Serializing JSON

```mojo
from mojo_json import serialize, serialize_pretty

var obj = JsonObject()
obj["message"] = JsonValue.from_string("Hello, World!")
obj["count"] = JsonValue.from_int(42)
var value = JsonValue.from_object(obj)

# Compact output (default)
print(serialize(value))
# {"message":"Hello, World!","count":42}

# Pretty-printed output
print(serialize_pretty(value))
# {
#   "message": "Hello, World!",
#   "count": 42
# }

# Custom indentation
print(serialize_pretty(value, "    "))  # 4 spaces
```

### Error Handling

```mojo
from mojo_json import parse_safe, JsonParseError

# Safe parsing (no exceptions)
var result = parse_safe('{"invalid": }')
if result.get[2, Bool]():
    var value = result.get[0, JsonValue]()
    # Use value
else:
    var error = result.get[1, JsonParseError]()
    print(error.format())
    # JSON parse error at line 1, column 13: Expected value

# With try/except
try:
    var value = parse('{"invalid": }')
except e:
    print("Parse error:", e)
```

### Adaptive Parser (Auto-Select Best Parser)

```mojo
from mojo_json import parse_adaptive, analyze_json_content

# Automatically selects V1, V2, or V4 based on content
var tape = parse_adaptive(large_json)

# Analyze content to see what parser will be selected
var profile = analyze_json_content(json_string)
print(profile)
# JsonContentProfile(quotes=8%, digits=0%, structural=5%, recommended=V1)

# Decision logic:
# - >20% digits → V4 (number-heavy, like GeoJSON coordinates)
# - >3% quotes  → V1 (string-heavy, like API responses)
# - Otherwise   → V2 (balanced default)
```

### NDJSON Zero-Copy Processing

```mojo
from mojo_json import (
    extract_line_slices,  # Zero-copy (recommended)
    extract_lines,        # With copying
    parse_to_tape,
    StringSlice,
    SliceList,
)

var ndjson = """
{"name": "Alice", "age": 30}
{"name": "Bob", "age": 25}
{"name": "Charlie", "age": 35}
"""

# Zero-copy extraction (13x faster) - recommended
var slices = extract_line_slices(ndjson)
for i in range(len(slices)):
    var line = slices[i]  # StringSlice - no allocation
    # Only allocate string when actually parsing
    var tape = parse_to_tape(line.to_string())
    # Process tape...

# Traditional extraction (slower, copies each line)
var lines = extract_lines(ndjson)
for i in range(len(lines)):
    var tape = parse_to_tape(lines[i])
```

### On-Demand Parsing (Sparse Access)

```mojo
from mojo_json import parse_on_demand

# Only builds structural index - values parsed on access
var doc = parse_on_demand(huge_json)

# Access specific fields (only these get parsed)
var name = doc.root()["user"]["name"].get_string()
var age = doc.root()["user"]["age"].get_int()

# 50+ other fields in the JSON are never parsed
```

## API Reference

### JsonValue

The core type representing any JSON value.

#### Constructors

| Method | Description |
|--------|-------------|
| `JsonValue.null()` | Create null value |
| `JsonValue.from_bool(Bool)` | Create boolean value |
| `JsonValue.from_int(Int64)` | Create integer value |
| `JsonValue.from_int(Int)` | Create integer value |
| `JsonValue.from_float(Float64)` | Create float value |
| `JsonValue.from_string(String)` | Create string value |
| `JsonValue.from_array(JsonArray)` | Create array value |
| `JsonValue.from_object(JsonObject)` | Create object value |

#### Type Checking

| Method | Returns |
|--------|---------|
| `is_null()` | `Bool` |
| `is_bool()` | `Bool` |
| `is_int()` | `Bool` |
| `is_float()` | `Bool` |
| `is_number()` | `Bool` (int or float) |
| `is_string()` | `Bool` |
| `is_array()` | `Bool` |
| `is_object()` | `Bool` |
| `type_name()` | `String` |

#### Value Access

| Method | Returns |
|--------|---------|
| `as_bool()` | `Bool` |
| `as_int()` | `Int64` |
| `as_float()` | `Float64` |
| `as_string()` | `String` |
| `as_array()` | `JsonArray` |
| `as_object()` | `JsonObject` |

#### Array/Object Operations

| Method | Description |
|--------|-------------|
| `len()` | Get length of array or object |
| `[index]` | Get array element by index |
| `[key]` | Get object value by key |
| `contains(key)` | Check if object contains key |
| `keys()` | Get all object keys |

### Parser

#### Functions

```mojo
# Parse JSON string (raises on error)
fn parse(source: String) raises -> JsonValue

# Parse without exceptions
fn parse_safe(source: String) -> Tuple[JsonValue, JsonParseError, Bool]

# Parse with custom configuration
fn parse_with_config(source: String, config: ParserConfig) raises -> JsonValue
```

#### ParserConfig

```mojo
var config = ParserConfig(
    max_depth=1000,           # Maximum nesting depth
    allow_trailing_comma=False,  # Allow trailing commas (non-standard)
    allow_comments=False,     # Allow // and /* */ comments (non-standard)
)
```

### Serializer

#### Functions

```mojo
# Compact serialization
fn serialize(value: JsonValue) -> String

# Pretty-printed serialization
fn serialize_pretty(value: JsonValue, indent: String = "  ") -> String

# Serialize with custom configuration
fn serialize_with_config(value: JsonValue, config: SerializerConfig) -> String

# Alias for serialize
fn to_json(value: JsonValue) -> String
```

#### SerializerConfig

```mojo
var config = SerializerConfig(
    indent="  ",              # Indentation string (empty for compact)
    sort_keys=False,          # Sort object keys alphabetically
    escape_unicode=False,     # Escape non-ASCII as \uXXXX
    escape_forward_slash=False,  # Escape / for HTML embedding
)
```

### JsonParseError

```mojo
struct JsonParseError:
    var message: String      # Error description
    var position: Int        # Byte offset in source
    var line: Int           # Line number (1-indexed)
    var column: Int         # Column number (1-indexed)

    fn format() -> String   # Human-readable error message
    fn format_with_context(source: String, context_chars: Int = 20) -> String
```

## Type Aliases

```mojo
alias JsonArray = List[JsonValue]
alias JsonObject = Dict[String, JsonValue]
```

## Escape Sequences

The parser handles all standard JSON escape sequences:

| Escape | Character |
|--------|-----------|
| `\"` | Double quote |
| `\\` | Backslash |
| `\/` | Forward slash |
| `\b` | Backspace |
| `\f` | Form feed |
| `\n` | Newline |
| `\r` | Carriage return |
| `\t` | Tab |
| `\uXXXX` | Unicode code point |

Unicode surrogate pairs (`\uD800`-`\uDFFF`) are properly combined.

## Performance Notes

- Single-pass parser with no backtracking
- O(n) time complexity for parsing
- Minimal memory allocations
- No regex or external dependencies

## GPU Acceleration

For large JSON files (>64KB), GPU acceleration provides massive throughput improvements.

### Build Metal Library

```bash
cd metal
./build_all.sh
```

This compiles:
- `json_classify.metallib` - GPU compute kernels
- `libmetal_bridge.dylib` - C bridge for Mojo FFI

### Usage

```mojo
from src.metal_ffi import MetalJsonClassifier, is_metal_available

fn main() raises:
    if not is_metal_available():
        print("Metal GPU not available")
        return

    var classifier = MetalJsonClassifier()
    print("GPU:", classifier.device_name())

    # Classify JSON characters on GPU
    var json = '{"name": "test", "values": [1, 2, 3]}'
    var classifications = classifier.classify(json)

    # Classifications: 0=whitespace, 1={, 2=}, 3=[, 4=], 5=", 6=:, 7=,
```

### Benchmark Results (Apple M3 Ultra)

| JSON Size | GPU Throughput | Notes |
|-----------|---------------|-------|
| 16 KB | 46 MB/s | GPU overhead dominates |
| 64 KB | 358 MB/s | Crossover point |
| 256 KB | 1,357 MB/s | GPU significantly faster |
| 1 MB | **4,352 MB/s** | Full GPU utilization |

**Why the variation?** GPU kernel launches have ~15μs overhead. For small JSON, this
overhead dominates. At 64KB (the "crossover point"), GPU starts winning. At 1MB, the
GPU processes data so fast that we're approaching memory bandwidth limits - the M3 Ultra
has 800 GB/s unified memory bandwidth, and we're achieving 4.3 GB/s with read+write+FFI
overhead, which is excellent utilization for a classification workload.

**Practical guidance:**
- **< 64KB**: Use CPU SIMD (faster due to no GPU launch overhead)
- **64KB - 256KB**: GPU provides moderate speedup (2-3x)
- **> 256KB**: GPU provides significant speedup (4-8x vs CPU SIMD)
- **> 1MB**: GPU essential for real-time processing

### Kernel Variants

Four GPU kernel implementations optimized for different tradeoffs:

| Kernel | Throughput | Strategy |
|--------|-----------|----------|
| `lookup_vec8` | **1,401 MB/s** | Lookup table + 8 bytes/thread (default, fastest) |
| `lookup` | 1,365 MB/s | Lookup table + 1 byte/thread |
| `contiguous` | 1,294 MB/s | If-else branches per character |
| `vec4` | 1,262 MB/s | 4 bytes/thread with branches |

**Why lookup_vec8 wins:**
1. **Lookup table** - 256-byte table in GPU constant memory eliminates all branches
2. **8 bytes/thread** - Reduces thread dispatch overhead, better memory coalescing
3. **Unrolled loop** - 8 loads per thread amortizes instruction overhead

The lookup table approach converts character classification from branching code
(unpredictable on GPU) to simple array indexing (single memory read).

### Architecture

```
JSON String (>64KB)
    │
    ▼
┌─────────────────────────────────────────┐
│  GPU Stage 1a: Character Classification │
│  - Parallel: 1000s of threads           │
│  - Lookup table in constant memory      │
│  - 8 bytes per thread (vec8 kernel)     │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  CPU Stage 1b: Structural Index         │
│  - Sequential string state tracking     │
│  - Handle escape sequences              │
└─────────────────────────────────────────┘
    │
    ▼
StructuralIndex → Stage 2 Parsing
```

### Why FFI Instead of Mojo GPU?

Mojo 0.25.7's Metal compiler has a bug that crashes during metallib generation.
This implementation bypasses it by:

1. Pre-compiling Metal shaders with Apple's `xcrun metal` tools
2. Using a C/Objective-C bridge for Metal API calls
3. Calling from Mojo via `OwnedDLHandle` FFI

See `docs/GPU_ACCELERATION.md` for technical details.

## Examples

### Working with Nested Data

```mojo
var json = '''
{
    "users": [
        {"name": "Alice", "email": "alice@example.com"},
        {"name": "Bob", "email": "bob@example.com"}
    ],
    "total": 2
}
'''

var data = parse(json)

# Access nested values
for i in range(data["users"].len()):
    var user = data["users"][i]
    print(user["name"].as_string() + ": " + user["email"].as_string())
```

### Building Complex JSON

```mojo
# Build a response object
fn build_response(success: Bool, message: String, data: JsonValue) -> JsonValue:
    var obj = JsonObject()
    obj["success"] = JsonValue.from_bool(success)
    obj["message"] = JsonValue.from_string(message)
    obj["data"] = data
    obj["timestamp"] = JsonValue.from_int(get_current_timestamp())
    return JsonValue.from_object(obj)
```

### Validation Pattern

```mojo
fn validate_user(json: String) -> Bool:
    var result = parse_safe(json)
    if not result.get[2, Bool]():
        print("Invalid JSON:", result.get[1, JsonParseError]().format())
        return False

    var user = result.get[0, JsonValue]()

    if not user.is_object():
        print("Expected object")
        return False

    if not user.contains("name") or not user["name"].is_string():
        print("Missing or invalid 'name' field")
        return False

    if not user.contains("age") or not user["age"].is_int():
        print("Missing or invalid 'age' field")
        return False

    return True
```

## License

Apache 2.0 License

## Part of mojo-contrib

This library is part of [mojo-contrib](https://github.com/atsentia/mojo-contrib), a collection of pure Mojo libraries.
