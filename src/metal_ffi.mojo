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


# =============================================================================
# GpJSON Full Stage 1 Pipeline
# =============================================================================

# Function type aliases for GpJSON C bridge
alias HasGpjsonFnType = fn (Int) -> Int32  # (ctx) -> int
alias FullStage1FnType = fn (Int, Int, UInt32, Int, Int, Int) -> Int32


struct GpJsonStage1Result(Sized):
    """Result from full GPU Stage 1 pipeline."""

    var positions: List[UInt32]
    var chars: List[UInt8]

    fn __init__(out self):
        self.positions = List[UInt32]()
        self.chars = List[UInt8]()

    fn __moveinit__(out self, deinit existing: Self):
        self.positions = existing.positions^
        self.chars = existing.chars^

    fn __len__(self) -> Int:
        return len(self.positions)


struct MetalGpJsonPipeline:
    """
    Full GPU Stage 1 pipeline using GpJSON-inspired algorithms.

    Implements:
    1. Quote bitmap creation (64 bytes → 1 uint64)
    2. Prefix-XOR string mask (simdjson algorithm)
    3. Structural character extraction with string filtering
    """

    var _lib: OwnedDLHandle
    var _handle: Int

    fn __init__(out self, lib_path: String = DEFAULT_LIB_PATH) raises:
        """Initialize GpJSON pipeline."""
        var dylib_path = lib_path + "/libmetal_bridge.dylib"
        self._lib = OwnedDLHandle(dylib_path)
        self._handle = 0

        var init_fn = self._lib.get_function[InitFnType]("metal_json_init")
        var metallib_path = lib_path + "/json_classify.metallib"
        var path_ptr = metallib_path.unsafe_cstr_ptr()
        var handle = init_fn(Int(path_ptr))

        if handle == 0:
            raise Error("Failed to initialize Metal context")

        self._handle = handle

        # Check if GpJSON kernels are available
        var has_gpjson = self._lib.get_function[HasGpjsonFnType]("metal_json_has_gpjson_pipeline")
        if has_gpjson(self._handle) == 0:
            raise Error("GpJSON kernels not available in metallib")

    fn __del__(deinit self):
        if self._handle != 0:
            var free_fn = self._lib.get_function[FreeFnType]("metal_json_free")
            free_fn(self._handle)

    fn run_stage1(self, data: String) raises -> GpJsonStage1Result:
        """
        Run full GPU Stage 1: quote bitmap → string mask → structural extraction.

        Args:
            data: Input JSON string

        Returns:
            GpJsonStage1Result with positions and characters of structural tokens
        """
        var n = len(data)
        if n == 0:
            return GpJsonStage1Result()

        # Allocate output buffers (worst case: every byte is structural)
        var positions = List[UInt32](capacity=n)
        positions.resize(n, 0)
        var chars = List[UInt8](capacity=n)
        chars.resize(n, 0)
        var count = List[UInt32](capacity=1)
        count.resize(1, 0)

        var stage1_fn = self._lib.get_function[FullStage1FnType]("metal_json_full_stage1")

        var status = stage1_fn(
            self._handle,
            Int(data.unsafe_ptr()),
            UInt32(n),
            Int(positions.unsafe_ptr()),
            Int(chars.unsafe_ptr()),
            Int(count.unsafe_ptr()),
        )

        if status != 0:
            raise Error("Metal GPU Stage 1 failed")

        # Trim to actual count
        var actual_count = Int(count[0])
        var result = GpJsonStage1Result()
        result.positions = List[UInt32](capacity=actual_count)
        result.chars = List[UInt8](capacity=actual_count)

        for i in range(actual_count):
            result.positions.append(positions[i])
            result.chars.append(chars[i])

        return result^


fn has_gpjson_pipeline() -> Bool:
    """Check if GpJSON GPU pipeline is available."""
    try:
        var lib = OwnedDLHandle(DEFAULT_LIB_PATH + "/libmetal_bridge.dylib")

        # First check Metal is available
        var check_fn = lib.get_function[IsAvailableFnType]("metal_json_is_available")
        if check_fn() == 0:
            return False

        # Initialize context to check for GpJSON kernels
        var init_fn = lib.get_function[InitFnType]("metal_json_init")
        var metallib_path = DEFAULT_LIB_PATH + "/json_classify.metallib"
        var path_ptr = metallib_path.unsafe_cstr_ptr()
        var handle = init_fn(Int(path_ptr))

        if handle == 0:
            return False

        var has_gpjson = lib.get_function[HasGpjsonFnType]("metal_json_has_gpjson_pipeline")
        var result = has_gpjson(handle) != 0

        var free_fn = lib.get_function[FreeFnType]("metal_json_free")
        free_fn(handle)

        return result
    except:
        return False


# =============================================================================
# Fused Kernel (Single-Pass) - Kernel Fusion Optimization
# =============================================================================

alias FusedExtractFnType = fn (Int, Int, UInt32, Int, Int, Int) -> Int32


struct MetalFusedPipeline:
    """
    Fused single-pass GPU structural extraction.

    Combines quote bitmap + prefix-XOR + extraction into ONE kernel.
    Eliminates 2 kernel dispatches and memory round-trips.
    """

    var _lib: OwnedDLHandle
    var _handle: Int

    fn __init__(out self, lib_path: String = DEFAULT_LIB_PATH) raises:
        """Initialize fused pipeline."""
        var dylib_path = lib_path + "/libmetal_bridge.dylib"
        self._lib = OwnedDLHandle(dylib_path)
        self._handle = 0

        var init_fn = self._lib.get_function[InitFnType]("metal_json_init")
        var metallib_path = lib_path + "/json_classify.metallib"
        var path_ptr = metallib_path.unsafe_cstr_ptr()
        var handle = init_fn(Int(path_ptr))

        if handle == 0:
            raise Error("Failed to initialize Metal context")

        self._handle = handle

    fn __del__(deinit self):
        if self._handle != 0:
            var free_fn = self._lib.get_function[FreeFnType]("metal_json_free")
            free_fn(self._handle)

    fn extract(self, data: String) raises -> GpJsonStage1Result:
        """
        Run fused single-pass structural extraction.

        Args:
            data: Input JSON string

        Returns:
            GpJsonStage1Result with structural positions and characters
        """
        var n = len(data)
        if n == 0:
            return GpJsonStage1Result()

        # Allocate output buffers
        var positions = List[UInt32](capacity=n)
        positions.resize(n, 0)
        var chars = List[UInt8](capacity=n)
        chars.resize(n, 0)
        var count = List[UInt32](capacity=1)
        count.resize(1, 0)

        var fused_fn = self._lib.get_function[FusedExtractFnType]("metal_json_fused_extract")

        var status = fused_fn(
            self._handle,
            Int(data.unsafe_ptr()),
            UInt32(n),
            Int(positions.unsafe_ptr()),
            Int(chars.unsafe_ptr()),
            Int(count.unsafe_ptr()),
        )

        if status != 0:
            raise Error("Fused GPU extraction failed")

        # Trim to actual count
        var actual_count = Int(count[0])
        var result = GpJsonStage1Result()
        result.positions = List[UInt32](capacity=actual_count)
        result.chars = List[UInt8](capacity=actual_count)

        for i in range(actual_count):
            result.positions.append(positions[i])
            result.chars.append(chars[i])

        return result^
