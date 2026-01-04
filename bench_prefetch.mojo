"""Benchmark for prefetch optimization."""

from time import perf_counter_ns
from src.tape_parser import (
    parse_to_tape_v2,
    tape_get_int_value,
    tape_skip_value,
    tape_array_iter_start,
    tape_array_iter_end,
    tape_array_iter_has_next,
    tape_prefetch_entry,
    tape_prefetch_range,
    tape_prefetch_children,
    TAPE_END_ARRAY,
)


fn generate_int_array(size: Int) -> String:
    """Generate JSON array of integers."""
    var result = String("[")
    for i in range(size):
        if i > 0:
            result += ","
        result += String(i)
    result += "]"
    return result


fn bench_iterate_no_prefetch(tape_json: String, iterations: Int) raises -> Tuple[Int64, Int]:
    """Iterate through array without prefetch."""
    var tape = parse_to_tape_v2(tape_json)
    var sum: Int64 = 0

    var start = perf_counter_ns()
    for _ in range(iterations):
        var pos = tape_array_iter_start(tape, 1)  # Root is array
        var end_idx = tape_array_iter_end(tape, 1)

        while tape_array_iter_has_next(tape, pos, end_idx):
            sum += tape_get_int_value(tape, pos)
            pos = tape_skip_value(tape, pos)
    var end = perf_counter_ns()

    return (end - start, Int(sum))


fn bench_iterate_with_prefetch(tape_json: String, iterations: Int) raises -> Tuple[Int64, Int]:
    """Iterate through array with prefetch hints."""
    var tape = parse_to_tape_v2(tape_json)
    var sum: Int64 = 0

    var start = perf_counter_ns()
    for _ in range(iterations):
        var pos = tape_array_iter_start(tape, 1)  # Root is array
        var end_idx = tape_array_iter_end(tape, 1)

        # Prefetch children before iteration
        tape_prefetch_children(tape, 1)

        var prefetch_ahead = 16  # Prefetch 16 entries ahead
        while tape_array_iter_has_next(tape, pos, end_idx):
            # Prefetch ahead during iteration
            if pos + prefetch_ahead < end_idx:
                tape_prefetch_entry(tape, pos + prefetch_ahead)

            sum += tape_get_int_value(tape, pos)
            pos = tape_skip_value(tape, pos)
    var end = perf_counter_ns()

    return (end - start, Int(sum))


fn bench_random_access_no_prefetch(tape_json: String, iterations: Int) raises -> Tuple[Int64, Int]:
    """Random access without prefetch."""
    var tape = parse_to_tape_v2(tape_json)
    var sum: Int64 = 0
    var arr_size = tape.entries[1].payload() - 2  # Estimate array size

    var start = perf_counter_ns()
    for i in range(iterations):
        # Access elements in a scattered pattern
        var idx = ((i * 7) % arr_size) * 2 + 2  # *2 for int entries taking 2 slots
        if idx >= 2 and idx < len(tape.entries) - 1:
            sum += tape_get_int_value(tape, idx)
    var end = perf_counter_ns()

    return (end - start, Int(sum))


fn bench_random_access_with_prefetch(tape_json: String, iterations: Int) raises -> Tuple[Int64, Int]:
    """Random access with prefetch hints."""
    var tape = parse_to_tape_v2(tape_json)
    var sum: Int64 = 0
    var arr_size = tape.entries[1].payload() - 2  # Estimate array size

    var start = perf_counter_ns()
    for i in range(iterations):
        # Calculate next access and prefetch it
        var next_idx = (((i + 1) * 7) % arr_size) * 2 + 2
        if next_idx >= 2 and next_idx < len(tape.entries) - 1:
            tape_prefetch_entry(tape, next_idx)

        # Current access
        var idx = ((i * 7) % arr_size) * 2 + 2
        if idx >= 2 and idx < len(tape.entries) - 1:
            sum += tape_get_int_value(tape, idx)
    var end = perf_counter_ns()

    return (end - start, Int(sum))


fn main() raises:
    print("=" * 60)
    print("Prefetch Optimization Benchmark")
    print("=" * 60)

    # Test with different array sizes
    var sizes = List[Int]()
    sizes.append(100)
    sizes.append(1000)
    sizes.append(10000)

    for size_idx in range(len(sizes)):
        var size = sizes[size_idx]
        var json = generate_int_array(size)
        var iterations = 100000 // size  # Scale iterations with size
        if iterations < 10:
            iterations = 10

        print("\n--- Array size:", size, "elements ---")
        print("Iterations:", iterations)

        # Sequential iteration benchmark
        print("\nSequential iteration:")

        var result_no_pf = bench_iterate_no_prefetch(json, iterations)
        var time_no_pf = result_no_pf[0]
        print("  Without prefetch:", time_no_pf // 1000, "µs total,",
              time_no_pf // iterations // 1000, "µs/iteration")

        var result_with_pf = bench_iterate_with_prefetch(json, iterations)
        var time_with_pf = result_with_pf[0]
        print("  With prefetch:   ", time_with_pf // 1000, "µs total,",
              time_with_pf // iterations // 1000, "µs/iteration")

        if time_with_pf < time_no_pf:
            var speedup = Float64(time_no_pf) / Float64(time_with_pf)
            print("  Speedup:", speedup, "x")
        else:
            var slowdown = Float64(time_with_pf) / Float64(time_no_pf)
            print("  Slowdown:", slowdown, "x (prefetch overhead)")

        # Random access benchmark
        print("\nRandom access:")

        var rand_no_pf = bench_random_access_no_prefetch(json, iterations * size // 10)
        var rand_time_no_pf = rand_no_pf[0]
        print("  Without prefetch:", rand_time_no_pf // 1000, "µs")

        var rand_with_pf = bench_random_access_with_prefetch(json, iterations * size // 10)
        var rand_time_with_pf = rand_with_pf[0]
        print("  With prefetch:   ", rand_time_with_pf // 1000, "µs")

        if rand_time_with_pf < rand_time_no_pf:
            var speedup = Float64(rand_time_no_pf) / Float64(rand_time_with_pf)
            print("  Speedup:", speedup, "x")
        else:
            var slowdown = Float64(rand_time_with_pf) / Float64(rand_time_no_pf)
            print("  Slowdown:", slowdown, "x (prefetch overhead)")

    print("\n" + "=" * 60)
    print("Benchmark complete")
    print("=" * 60)
    print("\nNote: Prefetch is most effective for:")
    print("- Large data structures that don't fit in L1/L2 cache")
    print("- Predictable access patterns")
    print("- Memory-bound workloads")
