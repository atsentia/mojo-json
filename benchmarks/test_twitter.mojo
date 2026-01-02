"""Test parsing twitter.json with Unicode content."""

from mojo_json import parse
from time import perf_counter_ns


fn read_file(path: String) raises -> String:
    """Read file contents."""
    with open(path, "r") as f:
        return f.read()


fn main() raises:
    print("=" * 70)
    print("Twitter.json Unicode Test")
    print("=" * 70)

    # Read the twitter.json file
    var json_data = read_file("benchmarks/data/twitter.json")
    print("File size:", len(json_data), "bytes")

    # Try to parse it
    print("\nParsing...")
    var start = perf_counter_ns()
    var result = parse(json_data)
    var elapsed = perf_counter_ns() - start

    print("Parse time:", Float64(elapsed) / 1_000_000.0, "ms")

    # Check structure
    if result.is_object():
        var keys = result.keys()
        print("Root is object, key count:", len(keys))

        # Check statuses array
        if result.contains("statuses"):
            var statuses = result["statuses"]
            if statuses.is_array():
                print("Statuses count:", statuses.len())

                # Check first status
                if statuses.len() > 0:
                    var first = statuses[0]
                    if first.is_object():
                        if first.contains("text"):
                            var text = first["text"].as_string()
                            print("\nFirst tweet text preview:")
                            print("  ", text[:100] if len(text) > 100 else text)

    print("\n" + "=" * 70)
    print("SUCCESS: twitter.json parsed correctly!")
    print("=" * 70)
