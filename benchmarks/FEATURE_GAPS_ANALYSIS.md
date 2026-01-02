# mojo-json Feature Gaps Analysis

Deep analysis of missing features, performance implications, and solutions.

## Feature Gap Summary

| Gap | Severity | Performance Impact | simdjson Solution | GPU Potential |
|-----|----------|-------------------|-------------------|---------------|
| No streaming parser | High | Memory bound | Streaming API | ❌ No |
| No lazy/on-demand parsing | High | 2-10x overhead | On-demand API | ❌ No |
| No zero-copy strings | Medium | 20-50% overhead | View types | ⚠️ Maybe |
| O(n²) key sorting | Low | Slow for many keys | Merge/Quick sort | ✅ Yes |
| No BigInt support | Low | Precision loss | String fallback | ❌ No |
| No duplicate key detection | Low | Data loss | Hash-based check | ✅ Yes |
| No JSON Path/Pointer | Low | Missing feature | Query API | ⚠️ Maybe |

## Detailed Analysis

### 1. No Streaming Parser (HIGH PRIORITY)

**Current Limitation:**
```mojo
# Current: Must load entire file into memory
var content = read_file("huge.json")  # 1GB in memory
var result = parse(content)            # Another 1GB for AST
# Peak memory: ~2GB for 1GB file
```

**Problem:**
- Cannot process files larger than available memory
- Inefficient for large files where only part is needed
- No backpressure for network streams

**simdjson Solution:**
```cpp
// simdjson: Iterate through documents in a stream
for (auto doc : parser.iterate_many(json_stream)) {
    // Process each top-level document
}
```

**Proposed Solution:**

```mojo
# Streaming parser API
struct JsonStreamParser:
    """Parse JSON from any byte source incrementally."""

    var buffer: List[UInt8]
    var buffer_size: Int
    var state: ParserState  # Track partial parse state

    fn __init__(out self, buffer_size: Int = 64 * 1024):
        """Initialize with buffer size (default 64KB)."""
        self.buffer = List[UInt8](capacity=buffer_size)
        self.buffer_size = buffer_size
        self.state = ParserState()

    fn feed(inout self, data: Span[UInt8]) -> List[JsonValue]:
        """Feed data and return any complete values parsed."""
        var results = List[JsonValue]()

        # Append to buffer
        self.buffer.extend(data)

        # Try to parse complete values
        while True:
            var parse_result = self._try_parse_value()
            if parse_result.is_complete:
                results.append(parse_result.value)
                self._consume(parse_result.bytes_consumed)
            else:
                break  # Need more data

        return results

    fn flush(inout self) raises -> List[JsonValue]:
        """Flush remaining data and return final values."""
        if len(self.buffer) > 0:
            # Attempt final parse
            return self._parse_remaining()
        return List[JsonValue]()
```

**Performance Characteristics:**
- Memory: O(buffer_size) instead of O(file_size)
- Latency: Can start processing immediately
- Throughput: Slight overhead from buffer management (~5-10%)

**GPU Potential:** ❌ No benefit. Streaming is inherently sequential at the document level.

---

### 2. No Lazy/On-Demand Parsing (HIGH PRIORITY)

**Current Limitation:**
```mojo
# Current: Full AST materialization
var result = parse('{"users": [...1000 items...], "metadata": {...}}')
# ALL users are parsed even if we only need metadata
var meta = result["metadata"]  # 1000 items parsed for nothing
```

**Problem:**
- Parses entire document even when only accessing subset
- Allocates memory for all values
- simdjson's on-demand API is 2-5x faster for partial access

**simdjson Solution:**
```cpp
// simdjson: On-demand (lazy) parsing
auto doc = parser.iterate(json);
auto metadata = doc["metadata"];  // Only parses path to metadata
// "users" array is NEVER parsed
```

**Proposed Solution:**

```mojo
struct JsonDocument:
    """Lazy JSON document - parses on access."""

    var source: String           # Keep original source
    var structural_index: List[Int32]  # Positions of structural chars
    var _root: Optional[LazyValue]

    fn __init__(out self, source: String):
        """Build structural index without parsing values."""
        self.source = source
        self.structural_index = _build_structural_index(source)
        self._root = None

    fn root(inout self) -> LazyValue:
        """Get lazy root value."""
        if self._root is None:
            self._root = LazyValue(self, 0)
        return self._root.value()

    fn __getitem__(inout self, key: String) -> LazyValue:
        """Direct access to object key (lazy)."""
        return self.root()[key]


struct LazyValue:
    """A lazily-parsed JSON value - only materializes on access."""

    var doc: Pointer[JsonDocument]
    var start_pos: Int
    var _type: Optional[JsonType]
    var _materialized: Optional[JsonValue]

    fn type(inout self) -> JsonType:
        """Get type without full parse (fast)."""
        if self._type is None:
            self._type = _detect_type(self.doc, self.start_pos)
        return self._type.value()

    fn as_int(inout self) raises -> Int64:
        """Parse as integer (materializes value)."""
        if self.type() != JsonType.INT:
            raise Error("Not an integer")
        if self._materialized is None:
            self._materialized = _parse_number(self.doc, self.start_pos)
        return self._materialized.value().as_int()

    fn __getitem__(inout self, key: String) raises -> LazyValue:
        """Object key access (lazy - doesn't parse siblings)."""
        if self.type() != JsonType.OBJECT:
            raise Error("Not an object")
        # Use structural index to find key without parsing other keys
        var key_pos = _find_key_in_object(self.doc, self.start_pos, key)
        return LazyValue(self.doc, key_pos)

    fn __getitem__(inout self, index: Int) raises -> LazyValue:
        """Array index access (lazy)."""
        if self.type() != JsonType.ARRAY:
            raise Error("Not an array")
        var elem_pos = _find_array_element(self.doc, self.start_pos, index)
        return LazyValue(self.doc, elem_pos)

    fn materialize(inout self) -> JsonValue:
        """Force full materialization (for iteration, etc.)."""
        if self._materialized is None:
            self._materialized = _parse_value(self.doc, self.start_pos)
        return self._materialized.value()
```

**Performance Characteristics:**
- Partial access: 2-10x faster (no wasted parsing)
- Full access: ~same as current (materialization deferred)
- Memory: Only allocates what's accessed

**GPU Potential:** ⚠️ Structural index building can be GPU-accelerated (see earlier design).

---

### 3. No Zero-Copy Strings (MEDIUM PRIORITY)

**Current Limitation:**
```mojo
# Current: Every string is copied
var result = parse('{"name": "Alice", "city": "NYC"}')
var name = result["name"].as_string()  # Creates new String allocation
```

**Problem:**
- String allocation is expensive
- For read-only access, copying is unnecessary
- orjson avoids this with Rust lifetimes

**Proposed Solution:**

```mojo
struct JsonStringView:
    """A view into the original JSON source (no copy)."""

    var source: Pointer[String]  # Reference to source
    var start: Int
    var length: Int
    var needs_unescape: Bool     # True if contains \n, \t, etc.

    fn as_string(self) -> String:
        """Materialize to owned String (copies)."""
        if self.needs_unescape:
            return _unescape_string(self.source, self.start, self.length)
        else:
            return self.source[]slice(self.start, self.start + self.length)

    fn __eq__(self, other: String) -> Bool:
        """Compare without allocation."""
        if self.needs_unescape:
            # Must materialize for accurate comparison
            return self.as_string() == other
        # Direct comparison against source
        return _compare_slice(self.source, self.start, self.length, other)

    fn __hash__(self) -> Int:
        """Hash without allocation."""
        # Hash the source slice directly
        return _hash_slice(self.source, self.start, self.length)
```

**Performance Characteristics:**
- No-copy path: 20-50% faster for string-heavy JSON
- With escapes: Falls back to copy (same as current)
- Memory: Significant reduction for large string-heavy docs

**GPU Potential:** ⚠️ String hashing could be GPU-accelerated for many keys.

---

### 4. O(n²) Key Sorting (LOW PRIORITY)

**Current Limitation:**
```mojo
# In serializer.mojo - bubble sort for key sorting
fn _sort_keys(keys: List[String]) -> List[String]:
    # O(n²) bubble sort
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            if keys[j] < keys[i]:
                swap(keys[i], keys[j])
```

**Problem:**
- O(n²) becomes slow for objects with many keys
- 1000 keys = 1 million comparisons

**Proposed Solution:**

```mojo
# Option 1: Mojo stdlib sort (likely O(n log n))
fn _sort_keys_fast(inout keys: List[String]):
    sort(keys)  # Use stdlib sort

# Option 2: GPU-accelerated sort (for very large key sets)
fn _sort_keys_gpu(device: MetalDevice, keys: List[String]) -> List[String]:
    """GPU bitonic sort for large key sets."""
    if len(keys) < 1000:
        return _sort_keys_fast(keys)  # CPU faster for small sets

    # Convert to sortable representation
    var key_hashes = _compute_key_hashes_gpu(device, keys)
    var sorted_indices = _bitonic_sort_gpu(device, key_hashes)
    return _gather_by_indices(keys, sorted_indices)
```

**Performance Characteristics:**
- Current: O(n²) - 1000 keys = 1M comparisons
- With stdlib sort: O(n log n) - 1000 keys = 10K comparisons
- GPU sort: O(n log² n) parallel - beneficial for >10K keys

**GPU Potential:** ✅ Yes - Bitonic sort is GPU-friendly, but only for very large key sets.

---

### 5. No BigInt Support (LOW PRIORITY)

**Current Limitation:**
```mojo
# JSON spec allows arbitrary precision integers
# {"big": 9999999999999999999999999999999999}
# Current: Parsed as Int64, overflows or loses precision
```

**Proposed Solution:**

```mojo
struct JsonValue:
    # Add BigInt variant
    alias BIGINT: Int = 7  # New type

    var _bigint_val: String  # Store as string for arbitrary precision

    fn as_bigint(self) -> String:
        """Get arbitrary precision integer as string."""
        if self._type == JsonType.BIGINT:
            return self._bigint_val
        elif self._type == JsonType.INT:
            return str(self._int_val)
        raise Error("Not an integer")

# Parser modification
fn _parse_number(self) -> JsonValue:
    # Count digits
    var digit_count = _count_digits(self.source, self.pos)

    if digit_count > 18:  # Exceeds Int64 range
        # Store as BigInt (string)
        var bigint_str = self.source[start:end]
        return JsonValue.from_bigint(bigint_str)
    else:
        # Normal int/float parsing
        ...
```

**GPU Potential:** ❌ No benefit for BigInt.

---

### 6. No Duplicate Key Detection (LOW PRIORITY)

**Current Limitation:**
```mojo
# {"name": "Alice", "name": "Bob"}
# Result: {"name": "Bob"} - silently overwrites
```

**RFC 8259 says keys SHOULD be unique, but many parsers ignore duplicates.

**Proposed Solution:**

```mojo
struct ParserConfig:
    # Add option
    var detect_duplicate_keys: Bool = False

fn _parse_object(self) -> JsonValue:
    var obj = JsonObject()
    var seen_keys = Set[String]() if self.config.detect_duplicate_keys else None

    while ...:
        var key = self._parse_string()

        if seen_keys is not None:
            if key in seen_keys:
                self._error("Duplicate key: " + key)
            seen_keys.add(key)

        var value = self._parse_value()
        obj[key] = value

    return JsonValue.from_object(obj)
```

**GPU Potential:** ✅ Hash-based duplicate detection could use GPU for very large objects, but the overhead wouldn't be worth it for typical JSON.

---

### 7. No JSON Path/Pointer (LOW PRIORITY)

**Current Limitation:**
```mojo
# No query syntax for nested access
# Must manually navigate: result["users"][0]["address"]["city"]
```

**Proposed Solution:**

```mojo
fn query(value: JsonValue, path: String) -> JsonValue:
    """Query JSON using JSON Pointer (RFC 6901) syntax.

    Example:
        query(data, "/users/0/address/city")
    """
    var parts = path.split("/")
    var current = value

    for part in parts:
        if part == "":
            continue  # Skip leading slash

        if current.is_object():
            current = current[part]
        elif current.is_array():
            var index = int(part)
            current = current[index]
        else:
            return JsonValue.null()

    return current


fn query_all(value: JsonValue, pattern: String) -> List[JsonValue]:
    """Query JSON using JSONPath syntax.

    Example:
        query_all(data, "$.users[*].name")
    """
    # Implement JSONPath parser and evaluator
    ...
```

**GPU Potential:** ⚠️ Parallel query evaluation for multiple paths could benefit from GPU.

---

## Implementation Priority Matrix

| Feature | Effort | Impact | Priority |
|---------|--------|--------|----------|
| Lazy/On-demand parsing | High | Very High | **P0** |
| Streaming parser | Medium | High | **P1** |
| O(n log n) key sorting | Low | Medium | **P1** |
| Zero-copy strings | Medium | Medium | **P2** |
| Duplicate key detection | Low | Low | **P2** |
| BigInt support | Low | Low | **P3** |
| JSON Path/Pointer | Medium | Low | **P3** |

## Recommended Implementation Order

### Phase 1: Core Performance (P0-P1)
1. **Implement structural index** (foundation for lazy parsing)
2. **Add lazy/on-demand API** (2-10x speedup for partial access)
3. **Fix key sorting** (quick win, 10 minutes)
4. **Add streaming API** (memory efficiency)

### Phase 2: Efficiency (P2)
5. **Zero-copy string views** (reduce allocations)
6. **Duplicate key detection option** (correctness)

### Phase 3: Extended Features (P3)
7. **BigInt support** (precision)
8. **JSON Path/Pointer** (convenience)

## GPU Acceleration Summary

| Feature | GPU Benefit | Notes |
|---------|-------------|-------|
| Structural index | ✅ High | Parallel char detection |
| Lazy parsing | ⚠️ Index only | Value extraction is sequential |
| String views | ⚠️ Hashing only | For large key sets |
| Key sorting | ✅ For >10K keys | Bitonic sort |
| Duplicate detection | ⚠️ For large objects | Hash collision detection |
| Query evaluation | ⚠️ Multi-query | Parallel path evaluation |

**Overall GPU strategy**: Focus on structural index building, which benefits ALL subsequent operations.
