#!/bin/bash
# Build script for JSON classification Metal library
#
# Usage: ./build_metallib.sh
#
# Outputs: json_classify.metallib

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building JSON classification Metal library..."

# Metal compiler flags (same as MLX uses)
METAL_FLAGS="-x metal -Wall -Wextra -fno-fast-math"

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

# Show metallib info
echo "Metal library info:"
xcrun -sdk macosx metal-nm json_classify.metallib 2>/dev/null || true

echo ""
echo "Kernel functions exported:"
strings json_classify.metallib | grep -E "^json_classify" || echo "  (use metal-nm to inspect)"
