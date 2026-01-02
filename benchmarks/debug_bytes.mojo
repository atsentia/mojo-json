"""Debug raw byte access in Mojo strings."""


fn main() raises:
    print("=" * 70)
    print("Debugging Raw Byte Access in Mojo")
    print("=" * 70)

    # Test using as_bytes() if available
    var test_str = "a前b"
    print("\nString:", test_str)
    print("Length:", len(test_str))

    # Try getting raw bytes using ord() on each position
    print("\nUsing ord() on string index:")
    for i in range(len(test_str)):
        try:
            var c = test_str[i]
            var o = ord(c)
            print("  [", i, "] ord:", o, "hex:", hex(o))
        except:
            print("  [", i, "] ERROR")

    # Test with as_bytes_slice if available
    print("\nAttempting unsafe_ptr access...")
    var ptr = test_str.unsafe_ptr()
    print("Got pointer, reading bytes:")
    for i in range(len(test_str)):
        var byte = ptr[i]
        print("  [", i, "] byte:", Int(byte), "hex:", hex(Int(byte)))


fn hex(n: Int) -> String:
    """Convert to hex string."""
    var digits = "0123456789ABCDEF"
    var result = "0x"
    if n >= 256:
        result += digits[(n >> 12) & 0xF]
        result += digits[(n >> 8) & 0xF]
    if n >= 16:
        result += digits[(n >> 4) & 0xF]
    result += digits[n & 0xF]
    return result
