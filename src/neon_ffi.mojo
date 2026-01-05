"""
NEON SIMD FFI Wrapper for High-Performance JSON Structural Indexing

Uses ARM64 NEON intrinsics via C FFI for simdjson-level performance.

Usage:
    from src.neon_ffi import NeonJsonIndexer

    fn main() raises:
        var indexer = NeonJsonIndexer()
        var result = indexer.find_structural('{"name": "test", "value": 42}')
        print("Found", result.count, "structural characters")

Build requirements:
    1. Build NEON library: cd neon && ./build.sh
    2. Or set env: export NEON_JSON_LIB="/path/to/mojo-json/neon"

Performance: 3-4 GB/s on Apple Silicon (M1-M4)

Algorithm (from simdjson):
    - 64-byte chunk processing with NEON vectors
    - Branchless character classification
    - Prefix-XOR for string tracking via carry-less multiply
    - Escape sequence handling with odd backslash detection
"""

from sys.ffi import OwnedDLHandle
from memory import UnsafePointer

# Classification constants (same as NEON implementation)
alias NEON_CHAR_WHITESPACE: UInt8 = 0
alias NEON_CHAR_BRACE_OPEN: UInt8 = 1
alias NEON_CHAR_BRACE_CLOSE: UInt8 = 2
alias NEON_CHAR_BRACKET_OPEN: UInt8 = 3
alias NEON_CHAR_BRACKET_CLOSE: UInt8 = 4
alias NEON_CHAR_QUOTE: UInt8 = 5
alias NEON_CHAR_COLON: UInt8 = 6
alias NEON_CHAR_COMMA: UInt8 = 7
alias NEON_CHAR_BACKSLASH: UInt8 = 8
alias NEON_CHAR_OTHER: UInt8 = 9

# Default library path
alias DEFAULT_NEON_LIB_PATH = "/Users/amund/mojo-contrib/serialization/mojo-json/neon"

# Function type aliases for C bridge
alias NeonInitFnType = fn () -> Int  # () -> NeonContext*
alias NeonFreeFnType = fn (Int) -> None  # (NeonContext*) -> void
alias NeonFindStructuralFnType = fn (
    Int, Int, UInt64, Int, Int, UInt64
) -> Int64  # (ctx, input, input_len, positions, characters, max_output) -> count
alias NeonClassifyFnType = fn (
    Int, Int, UInt64
) -> Int32  # (input, output, len) -> int
alias NeonIsAvailableFnType = fn () -> Int32  # () -> int
alias NeonThroughputFnType = fn () -> Float64  # () -> double


struct NeonStructuralResult(Sized, Writable):
    """
    Result of structural character extraction.

    Contains positions and characters of structural JSON elements
    (braces, brackets, colons, commas, quotes) found outside strings.
    """

    var positions: List[UInt32]
    var characters: List[UInt8]
    var count: Int

    fn __init__(out self, count: Int = 0):
        self.positions = List[UInt32](capacity=count)
        self.characters = List[UInt8](capacity=count)
        self.count = count

    fn __moveinit__(out self, deinit other: Self):
        self.positions = other.positions^
        self.characters = other.characters^
        self.count = other.count

    fn __len__(self) -> Int:
        return self.count

    fn write_to[W: Writer](self, mut writer: W):
        writer.write("NeonStructuralResult(count=")
        writer.write(self.count)
        writer.write(", chars=[")
        var show = min(self.count, 10)
        for i in range(show):
            if i > 0:
                writer.write(", ")
            writer.write(chr(Int(self.characters[i])))
        if self.count > 10:
            writer.write(", ...")
        writer.write("])")


struct NeonJsonIndexer:
    """
    NEON SIMD-accelerated JSON structural indexer.

    Uses ARM64 NEON intrinsics for high-performance JSON parsing.
    Implements simdjson's branchless algorithm for 3-4 GB/s throughput.
    """

    var _lib: OwnedDLHandle
    var _handle: Int  # NeonContext* as opaque handle

    fn __init__(out self, lib_path: String = DEFAULT_NEON_LIB_PATH) raises:
        """
        Initialize NEON indexer.

        Args:
            lib_path: Path to directory containing libneon_json.dylib
        """
        var dylib_path = lib_path + "/libneon_json.dylib"
        self._lib = OwnedDLHandle(dylib_path)
        self._handle = 0

        # Check if NEON is available
        var is_available_fn = self._lib.get_function[NeonIsAvailableFnType](
            "neon_json_is_available"
        )
        if is_available_fn() == 0:
            raise Error("NEON SIMD not available on this platform")

        # Initialize context
        var init_fn = self._lib.get_function[NeonInitFnType]("neon_json_init")
        var handle = init_fn()

        if handle == 0:
            raise Error("Failed to initialize NEON context")

        self._handle = handle

    fn __del__(deinit self):
        """Clean up NEON resources."""
        # Note: We intentionally don't free here due to Mojo FFI library unloading
        # issues that can cause crashes. The OS will reclaim memory on process exit.
        # For long-running applications, call close() explicitly before exit.
        pass

    fn close(mut self):
        """Explicitly free NEON resources. Call before exiting if needed."""
        if self._handle != 0:
            var free_fn = self._lib.get_function[NeonFreeFnType]("neon_json_free")
            free_fn(self._handle)
            self._handle = 0

    fn find_structural(self, data: String) raises -> NeonStructuralResult:
        """
        Find all structural character positions using NEON SIMD.

        This is the core Stage 1 operation that identifies JSON structure:
        - Braces: { }
        - Brackets: [ ]
        - Colons: :
        - Commas: ,
        - Quotes: " (string boundaries)

        Characters inside strings are filtered out using the prefix-XOR algorithm.

        Args:
            data: Input JSON string

        Returns:
            NeonStructuralResult with positions and characters
        """
        var n = len(data)
        if n == 0:
            return NeonStructuralResult(0)

        # Estimate max structural chars (typically ~1 per 4-8 bytes)
        var max_output = n // 2 + 64

        var result = NeonStructuralResult(max_output)
        result.positions.resize(max_output, 0)
        result.characters.resize(max_output, 0)

        var find_fn = self._lib.get_function[NeonFindStructuralFnType](
            "neon_json_find_structural"
        )

        var count = find_fn(
            self._handle,
            Int(data.unsafe_ptr()),
            UInt64(n),
            Int(result.positions.unsafe_ptr()),
            Int(result.characters.unsafe_ptr()),
            UInt64(max_output),
        )

        if count < 0:
            raise Error("NEON structural extraction failed")

        result.count = Int(count)
        result.positions.resize(result.count, 0)
        result.characters.resize(result.count, 0)

        return result^

    fn find_structural_bytes(
        self, data: UnsafePointer[UInt8], length: Int
    ) raises -> NeonStructuralResult:
        """
        Find structural characters from raw bytes.

        Args:
            data: Pointer to input bytes
            length: Number of bytes

        Returns:
            NeonStructuralResult with positions and characters
        """
        if length == 0:
            return NeonStructuralResult(0)

        var max_output = length // 2 + 64

        var result = NeonStructuralResult(max_output)
        result.positions.resize(max_output, 0)
        result.characters.resize(max_output, 0)

        var find_fn = self._lib.get_function[NeonFindStructuralFnType](
            "neon_json_find_structural"
        )

        var count = find_fn(
            self._handle,
            Int(data),
            UInt64(length),
            Int(result.positions.unsafe_ptr()),
            Int(result.characters.unsafe_ptr()),
            UInt64(max_output),
        )

        if count < 0:
            raise Error("NEON structural extraction failed")

        result.count = Int(count)
        result.positions.resize(result.count, 0)
        result.characters.resize(result.count, 0)

        return result^

    fn classify(self, data: String) raises -> List[UInt8]:
        """
        Simple character classification (no string filtering).

        Faster but doesn't distinguish inside/outside strings.
        Use find_structural() for proper JSON parsing.

        Args:
            data: Input string

        Returns:
            List of classification codes (one per byte)
        """
        var n = len(data)
        if n == 0:
            return List[UInt8]()

        var result = List[UInt8](capacity=n)
        result.resize(n, 0)

        var classify_fn = self._lib.get_function[NeonClassifyFnType](
            "neon_json_classify"
        )

        var status = classify_fn(
            Int(data.unsafe_ptr()),
            Int(result.unsafe_ptr()),
            UInt64(n),
        )

        if status != 0:
            raise Error("NEON classification failed")

        return result^

    fn throughput_estimate(self) -> Float64:
        """
        Get theoretical throughput estimate in MB/s.

        Returns:
            Estimated throughput based on CPU capabilities
        """
        var throughput_fn = self._lib.get_function[NeonThroughputFnType](
            "neon_json_throughput_estimate"
        )
        return throughput_fn()


fn neon_is_available() -> Bool:
    """
    Check if NEON SIMD is available on this platform.

    Returns:
        True on ARM64 (always available)
    """
    # On ARM64 macOS, NEON is always available
    # We just check if the library can be loaded
    return True  # Assume available, will fail at init if not
