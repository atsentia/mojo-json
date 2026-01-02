"""
Metal FFI Wrapper for GPU-Accelerated JSON Classification

Uses pre-compiled Metal shaders via C bridge to bypass Mojo's Metal compiler issues.

Usage:
    from src.metal_ffi import MetalJsonClassifier

    fn main() raises:
        var classifier = MetalJsonClassifier()
        var result = classifier.classify('{"name": "test"}')

Build requirements:
    1. Build Metal library: cd metal && ./build_all.sh
    2. Set env: export METAL_JSON_LIB="/path/to/mojo-json/metal"

Classification codes:
    0 = whitespace, 1 = {, 2 = }, 3 = [, 4 = ], 5 = quote
    6 = :, 7 = ,, 8 = backslash, 9 = other
"""

from sys.ffi import OwnedDLHandle

# Classification constants (same as Metal kernel)
alias CHAR_WHITESPACE: UInt8 = 0
alias CHAR_BRACE_OPEN: UInt8 = 1
alias CHAR_BRACE_CLOSE: UInt8 = 2
alias CHAR_BRACKET_OPEN: UInt8 = 3
alias CHAR_BRACKET_CLOSE: UInt8 = 4
alias CHAR_QUOTE: UInt8 = 5
alias CHAR_COLON: UInt8 = 6
alias CHAR_COMMA: UInt8 = 7
alias CHAR_BACKSLASH: UInt8 = 8
alias CHAR_OTHER: UInt8 = 9

# Kernel variants
alias KERNEL_CONTIGUOUS: Int32 = 0
alias KERNEL_VEC4: Int32 = 1
alias KERNEL_LOOKUP: Int32 = 2
alias KERNEL_LOOKUP_VEC8: Int32 = 3  # Default (fastest)

# Default library path
alias DEFAULT_LIB_PATH = "/Users/amund/mojo-contrib/serialization/mojo-json/metal"

# Function type aliases for C bridge
alias InitFnType = fn (Int) -> Int  # (const char* path) -> void*
alias FreeFnType = fn (Int) -> None  # (void* ctx) -> void
alias ClassifyFnType = fn (Int, Int, Int, UInt32) -> Int32  # (ctx, input, output, size) -> int
alias ClassifyVariantFnType = fn (Int, Int, Int, UInt32, Int32) -> Int32  # with kernel variant
alias IsAvailableFnType = fn () -> Int32  # () -> int




struct MetalJsonClassifier:
    """
    GPU-accelerated JSON character classifier.

    Uses Metal compute shaders via FFI for parallel classification.
    """

    var _lib: OwnedDLHandle
    var _handle: Int  # Store raw address as Int (opaque handle)

    fn __init__(out self, lib_path: String = DEFAULT_LIB_PATH) raises:
        """
        Initialize Metal classifier.

        Args:
            lib_path: Path to directory containing metallib and dylib
        """
        # Load the bridge library
        var dylib_path = lib_path + "/libmetal_bridge.dylib"
        self._lib = OwnedDLHandle(dylib_path)
        self._handle = 0

        # Get init function
        var init_fn = self._lib.get_function[InitFnType]("metal_json_init")

        # Initialize Metal context with metallib path
        var metallib_path = lib_path + "/json_classify.metallib"
        var path_ptr = metallib_path.unsafe_cstr_ptr()
        var handle = init_fn(Int(path_ptr))

        if handle == 0:
            raise Error("Failed to initialize Metal context")

        self._handle = handle

    fn __del__(deinit self):
        """Clean up Metal resources."""
        if self._handle != 0:
            var free_fn = self._lib.get_function[FreeFnType]("metal_json_free")
            free_fn(self._handle)

    fn classify(self, data: String) raises -> List[UInt8]:
        """
        Classify all characters in a JSON string using GPU.

        Args:
            data: Input JSON string

        Returns:
            List of classification codes (one per byte)
        """
        var n = len(data)
        if n == 0:
            return List[UInt8]()

        var result = List[UInt8](capacity=n)
        result.resize(n, 0)

        var classify_fn = self._lib.get_function[ClassifyFnType]("metal_json_classify")

        var status = classify_fn(
            self._handle,
            Int(data.unsafe_ptr()),
            Int(result.unsafe_ptr()),
            UInt32(n),
        )

        if status != 0:
            raise Error("Metal GPU classification failed")

        return result^

    fn classify_variant(self, data: String, kernel: Int32) raises -> List[UInt8]:
        """
        Classify using a specific kernel variant.

        Args:
            data: Input JSON string
            kernel: Kernel variant (0=contiguous, 1=vec4, 2=lookup, 3=lookup_vec8)

        Returns:
            List of classification codes
        """
        var n = len(data)
        if n == 0:
            return List[UInt8]()

        var result = List[UInt8](capacity=n)
        result.resize(n, 0)

        var classify_fn = self._lib.get_function[ClassifyVariantFnType]("metal_json_classify_variant")

        var status = classify_fn(
            self._handle,
            Int(data.unsafe_ptr()),
            Int(result.unsafe_ptr()),
            UInt32(n),
            kernel,
        )

        if status != 0:
            raise Error("Metal GPU classification failed")

        return result^

    fn device_name(self) -> String:
        """Get the name of the Metal GPU device.

        Note: Current Mojo FFI pointer-from-address APIs are evolving.
        The C bridge can return device name, but reading C strings
        requires low-level pointer manipulation. Returns fixed string
        since this module only works on macOS with Metal.
        """
        return "Apple M-series GPU (Metal)"


fn is_metal_available() -> Bool:
    """Check if Metal GPU is available on this system."""
    try:
        var lib = OwnedDLHandle(DEFAULT_LIB_PATH + "/libmetal_bridge.dylib")
        var check_fn = lib.get_function[IsAvailableFnType]("metal_json_is_available")
        return check_fn() != 0
    except:
        return False
