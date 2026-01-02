"""Debug flat array parsing."""

from src.tape_parser import parse_to_tape, TAPE_START_ARRAY, TAPE_END_ARRAY, TAPE_INT64
from src.structural_index import build_structural_index

fn main() raises:
    var json = "[1, 2, 3, 4, 5]"
    print("JSON:", json)
    print("Length:", len(json))

    # Check structural index
    var idx = build_structural_index(json)
    print("\nStructural index (", len(idx), " chars):")
    for i in range(len(idx)):
        var pos = idx.get_position(i)
        var char = idx.get_character(i)
        print("  [", i, "] pos=", pos, " char='", chr(Int(char)), "'")

    # Parse to tape
    var tape = parse_to_tape(json)
    print("\nTape entries:", len(tape))
    for i in range(len(tape)):
        var entry = tape.get_entry(i)
        var tag = entry.type_tag()
        print("  [", i, "] type='", chr(Int(tag)), "' payload=", entry.payload())
