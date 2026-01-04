"""
Zero-Copy String Slice

A lightweight view into a string without copying data.
Essential for high-performance JSON parsing where string
allocations are a major bottleneck.

Performance:
- Creation: O(1) - just stores offsets
- Comparison: O(n) - compares bytes directly
- to_string(): O(n) - only copies when explicitly needed

Usage:
    var source = '{"name": "Alice", "age": 30}'
    var slice = StringSlice(source, 9, 5)  # "Alice"

    # Zero-copy comparison
    if slice == "Alice":
        print("Match!")

    # Only allocate when needed
    var actual_string = slice.to_string()
"""


struct StringSlice(Stringable, Sized, EqualityComparable):
    """
    A zero-copy view into a string.

    Stores a reference to the source data plus start/length.
    No allocation until to_string() is called.

    WARNING: The source string must outlive this slice!
    """
    var _source: String
    var _start: Int
    var _length: Int

    # =========================================================================
    # Initialization
    # =========================================================================

    fn __init__(out self):
        """Create an empty slice."""
        self._source = String("")
        self._start = 0
        self._length = 0

    fn __init__(out self, source: String, start: Int, length: Int):
        """
        Create a slice from a string.

        Args:
            source: The source string.
            start: Start offset in bytes.
            length: Length in bytes.
        """
        self._source = source
        self._start = start
        self._length = length

    fn __copyinit__(out self, existing: Self):
        """Copy constructor - copies the reference, not the underlying data."""
        self._source = existing._source
        self._start = existing._start
        self._length = existing._length

    fn __moveinit__(out self, deinit existing: Self):
        """Move constructor."""
        self._source = existing._source^
        self._start = existing._start
        self._length = existing._length

    # =========================================================================
    # Properties
    # =========================================================================

    fn __len__(self) -> Int:
        """Return length of the slice."""
        return self._length

    fn is_empty(self) -> Bool:
        """Check if slice is empty."""
        return self._length == 0

    fn start(self) -> Int:
        """Return start offset."""
        return self._start

    fn end(self) -> Int:
        """Return end offset (exclusive)."""
        return self._start + self._length

    # =========================================================================
    # Access
    # =========================================================================

    @always_inline
    fn __getitem__(self, index: Int) -> UInt8:
        """Get byte at index."""
        return self._source.unsafe_ptr()[self._start + index]

    # =========================================================================
    # Conversion
    # =========================================================================

    fn to_string(self) -> String:
        """
        Convert slice to a new String (allocates).

        Only call this when you actually need an owned String.
        """
        if self._length == 0:
            return String("")

        var ptr = self._source.unsafe_ptr()
        var result = String("")
        for i in range(self._length):
            result += chr(Int(ptr[self._start + i]))
        return result

    fn __str__(self) -> String:
        """String representation for printing."""
        return self.to_string()

    # =========================================================================
    # Comparison
    # =========================================================================

    fn __eq__(self, other: Self) -> Bool:
        """Compare two slices."""
        if self._length != other._length:
            return False

        var ptr1 = self._source.unsafe_ptr()
        var ptr2 = other._source.unsafe_ptr()
        for i in range(self._length):
            if ptr1[self._start + i] != ptr2[other._start + i]:
                return False
        return True

    fn __ne__(self, other: Self) -> Bool:
        """Check inequality."""
        return not self.__eq__(other)

    fn __eq__(self, other: String) -> Bool:
        """Compare slice to string."""
        if self._length != len(other):
            return False

        var ptr = self._source.unsafe_ptr()
        var other_ptr = other.unsafe_ptr()
        for i in range(self._length):
            if ptr[self._start + i] != other_ptr[i]:
                return False
        return True

    fn __ne__(self, other: String) -> Bool:
        """Check inequality with string."""
        return not self.__eq__(other)

    # =========================================================================
    # Searching
    # =========================================================================

    fn contains(self, char: UInt8) -> Bool:
        """Check if slice contains a character."""
        var ptr = self._source.unsafe_ptr()
        for i in range(self._length):
            if ptr[self._start + i] == char:
                return True
        return False

    fn find(self, char: UInt8) -> Int:
        """Find first occurrence of character. Returns -1 if not found."""
        var ptr = self._source.unsafe_ptr()
        for i in range(self._length):
            if ptr[self._start + i] == char:
                return i
        return -1

    fn starts_with(self, prefix: String) -> Bool:
        """Check if slice starts with prefix."""
        if len(prefix) > self._length:
            return False

        var ptr = self._source.unsafe_ptr()
        var prefix_ptr = prefix.unsafe_ptr()
        for i in range(len(prefix)):
            if ptr[self._start + i] != prefix_ptr[i]:
                return False
        return True

    fn ends_with(self, suffix: String) -> Bool:
        """Check if slice ends with suffix."""
        if len(suffix) > self._length:
            return False

        var ptr = self._source.unsafe_ptr()
        var suffix_ptr = suffix.unsafe_ptr()
        var offset = self._length - len(suffix)
        for i in range(len(suffix)):
            if ptr[self._start + offset + i] != suffix_ptr[i]:
                return False
        return True

    # =========================================================================
    # Slicing
    # =========================================================================

    fn subslice(self, start: Int, length: Int) -> Self:
        """Create a sub-slice (still zero-copy)."""
        return StringSlice(self._source, self._start + start, length)

    fn trim_whitespace(self) -> Self:
        """Return slice with leading/trailing whitespace removed."""
        var ptr = self._source.unsafe_ptr()
        var start = 0
        var end = self._length

        # Skip leading whitespace
        while start < end:
            var c = ptr[self._start + start]
            if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                break
            start += 1

        # Skip trailing whitespace
        while end > start:
            var c = ptr[self._start + end - 1]
            if c != ord(' ') and c != ord('\t') and c != ord('\n') and c != ord('\r'):
                break
            end -= 1

        return StringSlice(self._source, self._start + start, end - start)

    # =========================================================================
    # Numeric Parsing (Zero-copy)
    # =========================================================================

    fn parse_int(self) -> Int64:
        """
        Parse slice as integer without allocating a String.

        Returns 0 for empty or invalid input.
        """
        if self._length == 0:
            return 0

        var ptr = self._source.unsafe_ptr()
        var result: Int64 = 0
        var negative = False
        var i = 0

        # Handle sign
        if ptr[self._start] == ord('-'):
            negative = True
            i = 1
        elif ptr[self._start] == ord('+'):
            i = 1

        # Parse digits
        while i < self._length:
            var c = ptr[self._start + i]
            if c < ord('0') or c > ord('9'):
                break
            result = result * 10 + Int64(c - ord('0'))
            i += 1

        return -result if negative else result

    fn parse_float(self) -> Float64:
        """
        Parse slice as float without allocating a String.

        Returns 0.0 for empty or invalid input.
        """
        if self._length == 0:
            return 0.0

        var ptr = self._source.unsafe_ptr()
        var integer_part: Float64 = 0.0
        var fraction_part: Float64 = 0.0
        var exponent: Int = 0
        var negative = False
        var exp_negative = False
        var i = 0

        # Handle sign
        if ptr[self._start] == ord('-'):
            negative = True
            i = 1
        elif ptr[self._start] == ord('+'):
            i = 1

        # Parse integer part
        while i < self._length:
            var c = ptr[self._start + i]
            if c < ord('0') or c > ord('9'):
                break
            integer_part = integer_part * 10.0 + Float64(c - ord('0'))
            i += 1

        # Parse fraction
        if i < self._length and ptr[self._start + i] == ord('.'):
            i += 1
            var divisor: Float64 = 10.0
            while i < self._length:
                var c = ptr[self._start + i]
                if c < ord('0') or c > ord('9'):
                    break
                fraction_part += Float64(c - ord('0')) / divisor
                divisor *= 10.0
                i += 1

        # Parse exponent
        if i < self._length and (ptr[self._start + i] == ord('e') or ptr[self._start + i] == ord('E')):
            i += 1
            if i < self._length and ptr[self._start + i] == ord('-'):
                exp_negative = True
                i += 1
            elif i < self._length and ptr[self._start + i] == ord('+'):
                i += 1

            while i < self._length:
                var c = ptr[self._start + i]
                if c < ord('0') or c > ord('9'):
                    break
                exponent = exponent * 10 + Int(c - ord('0'))
                i += 1

        var result = integer_part + fraction_part
        if negative:
            result = -result

        # Apply exponent
        if exponent > 0:
            var mult: Float64 = 1.0
            for _ in range(exponent):
                mult *= 10.0
            if exp_negative:
                result /= mult
            else:
                result *= mult

        return result

    # =========================================================================
    # Hashing
    # =========================================================================

    fn hash(self) -> Int:
        """Compute hash of slice content (FNV-1a)."""
        var ptr = self._source.unsafe_ptr()
        var h: Int = 0x811c9dc5  # FNV offset basis
        for i in range(self._length):
            h ^= Int(ptr[self._start + i])
            h *= 0x01000193  # FNV prime
        return h


# =============================================================================
# SliceList - Optimized for NDJSON
# =============================================================================


struct SliceList(Sized):
    """
    A list of line offsets into a shared source string.

    Optimized for NDJSON where all lines reference the same input.
    """
    var _source: String
    var _offsets: List[Tuple[Int, Int]]  # (start, length) pairs

    fn __init__(out self, source: String):
        """Create empty slice list referencing source."""
        self._source = source
        self._offsets = List[Tuple[Int, Int]]()

    fn __moveinit__(out self, owned existing: Self):
        """Move constructor."""
        self._source = existing._source^
        self._offsets = existing._offsets^

    fn __len__(self) -> Int:
        """Return number of slices."""
        return len(self._offsets)

    fn append(mut self, start: Int, length: Int):
        """Add a slice (zero-copy - just stores offsets)."""
        self._offsets.append((start, length))

    fn __getitem__(self, index: Int) -> StringSlice:
        """Get slice at index."""
        var offset = self._offsets[index]
        return StringSlice(self._source, offset[0], offset[1])

    fn get_string(self, index: Int) -> String:
        """Get string at index (allocates)."""
        return self[index].to_string()

    fn total_bytes(self) -> Int:
        """Return total bytes across all slices."""
        var total = 0
        for i in range(len(self._offsets)):
            total += self._offsets[i][1]
        return total


# =============================================================================
# Factory Functions
# =============================================================================


fn slice_from_string(s: String) -> StringSlice:
    """Create a slice covering the entire string."""
    return StringSlice(s, 0, len(s))


fn slice_between(source: String, start: Int, end: Int) -> StringSlice:
    """Create a slice from start to end (exclusive)."""
    return StringSlice(source, start, end - start)
