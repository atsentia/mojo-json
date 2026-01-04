"""Tests for compressed tape parser with string interning."""

from src.tape_parser import (
    parse_to_tape_compressed,
    parse_to_tape_v2,
    CompressedJsonTape,
    tape_get_string_value,
    TAPE_STRING,
    TAPE_START_OBJECT,
    TAPE_START_ARRAY,
)


fn test_string_interning() raises:
    """Test that repeated strings are interned."""
    # JSON with repeated keys (common pattern)
    var json = '[{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}, {"id": 3, "name": "Carol"}]'

    var tape = parse_to_tape_compressed(json)

    print("String interning test:")
    print("  Strings interned:", tape.strings_interned)
    print("  Bytes saved:", tape.bytes_saved)
    print("  " + tape.compression_stats())

    # Should intern "id" and "name" (used 3 times each, so 2+2 = 4 interned)
    if tape.strings_interned > 0:
        print("  [OK] Strings were interned")
    else:
        print("  [WARN] No strings were interned")


fn test_no_duplicates() raises:
    """Test JSON without duplicate strings."""
    var json = '{"a": "x", "b": "y", "c": "z"}'

    var tape = parse_to_tape_compressed(json)

    print("\nNo duplicates test:")
    print("  Strings interned:", tape.strings_interned)
    print("  " + tape.compression_stats())

    if tape.strings_interned == 0:
        print("  [OK] No strings interned (expected)")
    else:
        print("  [INFO] Some strings matched")


fn test_large_repeated_data() raises:
    """Test with many repeated strings for maximum savings."""
    # Build JSON with 100 objects with same keys
    var json = String("[")
    for i in range(100):
        if i > 0:
            json += ","
        json += '{"id":' + String(i) + ',"type":"user","status":"active","role":"member"}'
    json += "]"

    var compressed_tape = parse_to_tape_compressed(json)
    var regular_tape = parse_to_tape_v2(json)

    print("\nLarge repeated data test:")
    print("  JSON size:", len(json), "bytes")
    print("  Regular tape memory:", regular_tape.memory_usage(), "bytes")
    print("  Compressed tape memory:", compressed_tape.memory_usage(), "bytes")
    print("  Strings interned:", compressed_tape.strings_interned)
    print("  Bytes saved:", compressed_tape.bytes_saved)
    print("  Compression ratio:", Int(compressed_tape.compression_ratio() * 100), "%")

    if compressed_tape.bytes_saved > 0:
        print("  [OK] Compression achieved savings")
    else:
        print("  [WARN] No savings achieved")


fn test_correctness() raises:
    """Test that compressed tape produces correct values."""
    var json = '{"name": "Alice", "age": 30}'

    var tape = parse_to_tape_compressed(json)

    print("\nCorrectness test:")
    print("  Tape entries:", len(tape.entries))

    # Verify structure
    var root_entry = tape.get_entry(0)
    var first_entry = tape.get_entry(1)

    if first_entry.type_tag() == TAPE_START_OBJECT:
        print("  [OK] First entry is OBJECT_START")
    else:
        print("  [FAIL] Expected OBJECT_START")

    # Try to read a string
    # Entry 2 should be the key "name"
    var entry2 = tape.get_entry(2)
    if entry2.type_tag() == TAPE_STRING:
        var name_key = tape.get_string(entry2.payload())
        print("  First key:", name_key)
        if name_key == "name":
            print("  [OK] String value correct")
        else:
            print("  [FAIL] Expected 'name', got:", name_key)


fn bench_compression_overhead() raises:
    """Benchmark to measure overhead of string interning."""
    from time import perf_counter_ns

    # Build test JSON
    var json = String("[")
    for i in range(1000):
        if i > 0:
            json += ","
        json += '{"id":' + String(i) + ',"type":"user","status":"active"}'
    json += "]"

    print("\nCompression overhead benchmark:")
    print("  JSON size:", len(json), "bytes")

    # Warm up
    var _ = parse_to_tape_v2(json)
    var __ = parse_to_tape_compressed(json)

    # Benchmark regular parsing
    var iterations = 50
    var start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_v2(json)
        _ = len(tape.entries)  # prevent optimization
    var regular_time = perf_counter_ns() - start

    # Benchmark compressed parsing
    start = perf_counter_ns()
    for _ in range(iterations):
        var tape = parse_to_tape_compressed(json)
        _ = len(tape.entries)
    var compressed_time = perf_counter_ns() - start

    var regular_ms = Float64(regular_time) / 1_000_000.0
    var compressed_ms = Float64(compressed_time) / 1_000_000.0

    print("  Regular parsing:", regular_ms, "ms (", iterations, "iterations)")
    print("  Compressed parsing:", compressed_ms, "ms (", iterations, "iterations)")
    print("  Overhead:", Int((compressed_ms / regular_ms - 1.0) * 100), "%")

    # Final comparison
    var final_regular = parse_to_tape_v2(json)
    var final_compressed = parse_to_tape_compressed(json)

    print("  Regular memory:", final_regular.memory_usage(), "bytes")
    print("  Compressed memory:", final_compressed.memory_usage(), "bytes")
    print("  Memory saved:", final_compressed.bytes_saved, "bytes")


fn main() raises:
    """Run all compressed tape tests."""
    print("=" * 60)
    print("Compressed Tape Parser Tests")
    print("=" * 60)

    test_string_interning()
    test_no_duplicates()
    test_large_repeated_data()
    test_correctness()
    bench_compression_overhead()

    print("\n" + "=" * 60)
    print("All compressed tape tests completed!")
    print("=" * 60)
