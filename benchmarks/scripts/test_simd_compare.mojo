"""Test SIMD comparison operations in Mojo 0.25.7."""

fn main():
    # Test SIMD comparison operations
    var v = SIMD[DType.uint8, 16](1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
    print("v:", v)

    # Try direct element-wise comparison that returns SIMD
    # In some versions, comparing with broadcast should work
    var target = SIMD[DType.uint8, 16](5)
    print("target:", target)

    # Element-wise equality should return SIMD[DType.bool, 16]
    # But in 0.25.7 it might return scalar Bool

    # Alternative: Use arithmetic to create mask
    # (v == 5) as integer: if equal, result is 0; if not, result is non-zero
    var diff = v - target
    print("diff:", diff)

    # Count zeros (matches)
    var match_count = 0
    for i in range(16):
        if diff[i] == 0:
            match_count += 1
    print("matches:", match_count)

    # Test: Create mask using subtraction and comparison
    # For whitespace detection: check if c is 0x20, 0x09, 0x0A, or 0x0D
    var test = SIMD[DType.uint8, 16](0x20, 0x09, 0x0A, 0x0D, 0x41, 0x42, 0x43, 0x44,
                                      0x20, 0x20, 0x20, 0x20, 0x45, 0x46, 0x47, 0x48)

    # Check for space (0x20)
    var is_space = SIMD[DType.uint8, 16]()
    for i in range(16):
        is_space[i] = 1 if test[i] == 0x20 else 0
    print("is_space:", is_space)
    print("space count:", is_space.reduce_add())

    # Check for any whitespace
    var is_ws = SIMD[DType.uint8, 16]()
    for i in range(16):
        var c = test[i]
        is_ws[i] = 1 if (c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D) else 0
    print("is_ws:", is_ws)
    print("ws count:", is_ws.reduce_add())

    # Using reduce_add to check all/any
    print("all ws:", is_ws.reduce_add() == 16)
    print("any ws:", is_ws.reduce_add() > 0)

    # Find first non-ws
    var first_non_ws = 16  # default: all are ws
    for i in range(16):
        if is_ws[i] == 0:
            first_non_ws = i
            break
    print("first non-ws index:", first_non_ws)
