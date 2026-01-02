"""Debug Unicode handling in Mojo strings."""


fn main() raises:
    print("=" * 70)
    print("Debugging Unicode in Mojo")
    print("=" * 70)

    # Test 1: ASCII string indexing
    print("\n1. ASCII string:")
    var ascii_str = "hello"
    print("  String:", ascii_str)
    print("  Length:", len(ascii_str))
    for i in range(len(ascii_str)):
        var c = ascii_str[i]
        print("  [", i, "]:", c, "ord:", ord(c))

    # Test 2: Japanese string indexing
    print("\n2. Japanese string:")
    var jp_str = "前田"
    print("  String:", jp_str)
    print("  Length:", len(jp_str))
    for i in range(len(jp_str)):
        var c = jp_str[i]
        print("  [", i, "]:", c, "ord:", ord(c))

    # Test 3: Mixed string
    print("\n3. Mixed string (ASCII + Japanese):")
    var mixed_str = "a前b"
    print("  String:", mixed_str)
    print("  Length:", len(mixed_str))
    for i in range(len(mixed_str)):
        var c = mixed_str[i]
        print("  [", i, "]:", c, "ord:", ord(c))

    # Test 4: Check what bytes make up the Japanese character
    print("\n4. UTF-8 bytes of Japanese characters:")
    print("  前 = U+524D should be E5 89 8D in UTF-8")
    print("  田 = U+7530 should be E7 94 B0 in UTF-8")

    # Test 5: Check the specific JSON string
    print("\n5. JSON string indexing:")
    var json_str = '{"name": "前"}'
    print("  String:", json_str)
    print("  Length:", len(json_str))
    for i in range(len(json_str)):
        var c = json_str[i]
        var o = ord(c)
        if o < 32:
            print("  [", i, "]: CONTROL CHAR ord:", o)
        elif o > 127:
            print("  [", i, "]: HIGH BYTE ord:", o, "hex:", hex(o))
        else:
            print("  [", i, "]:", c, "ord:", o)


fn hex(n: Int) -> String:
    """Convert to hex string."""
    var digits = "0123456789ABCDEF"
    if n < 16:
        return "0x0" + digits[n]
    var high = n >> 4
    var low = n & 0xF
    return "0x" + digits[high] + digits[low]
