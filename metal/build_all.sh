#!/bin/bash
# Build script for Metal JSON classification library
#
# Usage: ./build_all.sh
#
# Outputs:
#   - json_classify.metallib (GPU kernel library)
#   - libmetal_bridge.dylib (C bridge for Mojo FFI)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "Building Metal JSON Classification Library"
echo "=============================================="
echo ""

# Step 1: Build Metal shader library
echo "Step 1: Building Metal shader library..."
./build_metallib.sh

# Step 2: Build C bridge library
echo ""
echo "Step 2: Building C bridge library..."
echo "  Compiling metal_bridge.m -> libmetal_bridge.dylib"

clang -shared -fobjc-arc \
    -O3 \
    -framework Metal \
    -framework Foundation \
    metal_bridge.m \
    -o libmetal_bridge.dylib

echo ""
echo "=============================================="
echo "Build Complete!"
echo "=============================================="
echo ""
echo "Files created:"
echo "  - json_classify.metallib  (Metal kernel library)"
echo "  - libmetal_bridge.dylib   (C bridge for FFI)"
echo ""
echo "GPU device check:"
./check_gpu.sh 2>/dev/null || echo "  (run check_gpu.sh for GPU info)"
echo ""
echo "To use from Mojo:"
echo '  export METAL_JSON_LIB="'"$SCRIPT_DIR"'"'
echo ""
