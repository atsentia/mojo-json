"""Test Unicode parsing in mojo-json.

Tests various Unicode cases:
1. Direct UTF-8 characters (Japanese, emojis)
2. Unicode escapes (backslash uXXXX)
3. Surrogate pairs for emoji
4. Mixed content
"""

from mojo_json import parse


fn test_direct_utf8() raises -> Bool:
    """Test direct UTF-8 characters in JSON strings."""
    print("Testing direct UTF-8...")

    # Simple ASCII
    var ascii_json = '{"text": "hello"}'
    var ascii_result = parse(ascii_json)
    var ascii_text = ascii_result["text"].as_string()
    if ascii_text != "hello":
        print("  FAIL: ASCII - got:", ascii_text)
        return False
    print("  OK: ASCII")

    # Japanese characters (3-byte UTF-8)
    var jp_json = '{"name": "前田あゆみ"}'
    try:
        var jp_result = parse(jp_json)
        var jp_name = jp_result["name"].as_string()
        print("  OK: Japanese - got:", jp_name)
    except e:
        print("  FAIL: Japanese -", String(e))
        return False

    # Emoji (4-byte UTF-8)
    var emoji_json = '{"emoji": "😊"}'
    try:
        var emoji_result = parse(emoji_json)
        var emoji_text = emoji_result["emoji"].as_string()
        print("  OK: Emoji - got length:", len(emoji_text))
    except e:
        print("  FAIL: Emoji -", String(e))
        return False

    return True


fn test_unicode_escapes() raises -> Bool:
    """Test backslash uXXXX escape sequences."""
    print("\nTesting Unicode escapes...")

    # Basic Latin (U+0041 = 'A')
    var latin_json = '{"char": "\\u0041"}'
    try:
        var result = parse(latin_json)
        var text = result["char"].as_string()
        if text != "A":
            print("  FAIL: Latin - got:", text)
            return False
        print("  OK: Latin u0041 = A")
    except e:
        print("  FAIL: Latin -", String(e))
        return False

    # BMP character (U+3042 = 'あ')
    var bmp_json = '{"char": "\\u3042"}'
    try:
        var result = parse(bmp_json)
        var text = result["char"].as_string()
        print("  OK: BMP u3042 - got length:", len(text))
    except e:
        print("  FAIL: BMP -", String(e))
        return False

    # Copyright symbol (U+00A9 = '©')
    var copyright_json = '{"symbol": "\\u00A9"}'
    try:
        var result = parse(copyright_json)
        var text = result["symbol"].as_string()
        print("  OK: Copyright u00A9 - got length:", len(text))
    except e:
        print("  FAIL: Copyright -", String(e))
        return False

    return True


fn test_surrogate_pairs() raises -> Bool:
    """Test surrogate pair handling for characters outside BMP."""
    print("\nTesting surrogate pairs...")

    # Smiley = U+1F60A = surrogate pair
    var emoji_json = '{"emoji": "\\uD83D\\uDE0A"}'
    try:
        var result = parse(emoji_json)
        var text = result["emoji"].as_string()
        print("  OK: Surrogate pair uD83D uDE0A - got length:", len(text))
    except e:
        print("  FAIL: Surrogate pair -", String(e))
        return False

    # Party popper = U+1F389
    var party_json = '{"emoji": "\\uD83C\\uDF89"}'
    try:
        var result = parse(party_json)
        var text = result["emoji"].as_string()
        print("  OK: Surrogate pair uD83C uDF89 - got length:", len(text))
    except e:
        print("  FAIL: Surrogate pair 2 -", String(e))
        return False

    return True


fn test_mixed_content() raises -> Bool:
    """Test mixed ASCII, UTF-8, and escapes."""
    print("\nTesting mixed content...")

    # Mix of everything
    var mixed_json = '{"text": "Hello \\u0041 world"}'
    try:
        var result = parse(mixed_json)
        var text = result["text"].as_string()
        print("  OK: Mixed - got:", text)
    except e:
        print("  FAIL: Mixed -", String(e))
        return False

    return True


fn test_twitter_sample() raises -> Bool:
    """Test actual sample from twitter.json."""
    print("\nTesting Twitter sample...")

    var twitter_sample = '{"text": "名前:前田あゆみ"}'
    try:
        var result = parse(twitter_sample)
        var text = result["text"].as_string()
        print("  OK: Twitter sample parsed")
        print("  Text:", text)
    except e:
        print("  FAIL: Twitter sample -", String(e))
        return False

    return True


fn test_escape_sequences() raises -> Bool:
    """Test standard escape sequences."""
    print("\nTesting escape sequences...")

    # Newline, tab, etc.
    var escape_json = '{"text": "line1\\nline2\\ttab"}'
    try:
        var result = parse(escape_json)
        var text = result["text"].as_string()
        if "line1" not in text or "line2" not in text:
            print("  FAIL: Escape sequences - missing content")
            return False
        print("  OK: Escape sequences parsed")
    except e:
        print("  FAIL: Escape sequences -", String(e))
        return False

    return True


fn main() raises:
    print("=" * 70)
    print("Unicode Parsing Tests")
    print("=" * 70)

    var all_passed = True

    all_passed = test_direct_utf8() and all_passed
    all_passed = test_unicode_escapes() and all_passed
    all_passed = test_surrogate_pairs() and all_passed
    all_passed = test_mixed_content() and all_passed
    all_passed = test_twitter_sample() and all_passed
    all_passed = test_escape_sequences() and all_passed

    print("\n" + "=" * 70)
    if all_passed:
        print("All Unicode tests PASSED")
    else:
        print("Some Unicode tests FAILED")
    print("=" * 70)
