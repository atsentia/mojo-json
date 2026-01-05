#!/bin/bash
# Build script for JSON classification Metal library
#
# Usage: ./build_metallib.sh
#
# Outputs: json_classify.metallib
#
# Kernels included:
#   - json_classify_contiguous, json_classify_vec4, json_classify_lookup, json_classify_lookup_vec8
#   - create_quote_bitmap, create_string_mask, extract_structural_positions, find_newlines

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building JSON classification Metal library..."

# Ensure Metal Toolchain is available (downloads if needed)
if ! xcrun -sdk macosx metal --version &>/dev/null; then
    echo "Metal Toolchain not found. Downloading via xcodebuild..."
    xcodebuild -downloadComponent MetalToolchain
fi

# Metal compiler flags (same as MLX uses)
METAL_FLAGS="-Wall -Wextra -fno-fast-math"

# Get macOS deployment target if set
if [ -n "$MACOSX_DEPLOYMENT_TARGET" ]; then
    METAL_FLAGS="$METAL_FLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
fi

# Step 1: Compile .metal to .air (intermediate representation)
echo "Step 1: Compiling json_classify.metal -> json_classify.air"
xcrun -sdk macosx metal $METAL_FLAGS -c json_classify.metal -o json_classify.air

# Step 2: Link .air to .metallib
echo "Step 2: Linking json_classify.air -> json_classify.metallib"
xcrun -sdk macosx metallib json_classify.air -o json_classify.metallib

# Clean up intermediate file
rm -f json_classify.air

echo ""
echo "Success! Created: json_classify.metallib"
echo ""

# Show kernel functions
echo "Kernel functions exported:"
strings json_classify.metallib | grep -E "^(json_classify|create_|extract_|find_)[a-z_]+$" | sort -u
