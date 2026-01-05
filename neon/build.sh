#!/bin/bash
# Build script for NEON SIMD JSON library
#
# Usage: ./build.sh [clean|debug|release]
#
# Produces: libneon_json.dylib

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Default to release build
BUILD_TYPE="${1:-release}"

# Compiler settings
CC="clang"
CFLAGS_COMMON="-Wall -Wextra -Wpedantic -fPIC -shared"
CFLAGS_COMMON="$CFLAGS_COMMON -march=armv8-a+simd+crypto"  # Enable NEON + crypto for vmull_p64

# Architecture-specific flags
if [[ $(uname -m) == "arm64" ]]; then
    CFLAGS_COMMON="$CFLAGS_COMMON -arch arm64"
fi

case "$BUILD_TYPE" in
    clean)
        echo "Cleaning build artifacts..."
        rm -f libneon_json.dylib libneon_json.a *.o
        echo "Done."
        exit 0
        ;;
    debug)
        CFLAGS="$CFLAGS_COMMON -O0 -g -DDEBUG"
        echo "Building debug configuration..."
        ;;
    release)
        CFLAGS="$CFLAGS_COMMON -O3 -DNDEBUG -flto"
        echo "Building release configuration..."
        ;;
    *)
        echo "Unknown build type: $BUILD_TYPE"
        echo "Usage: $0 [clean|debug|release]"
        exit 1
        ;;
esac

# Build shared library
echo "Compiling neon_json.c..."
$CC $CFLAGS \
    -o libneon_json.dylib \
    neon_json.c

# Verify the build
if [[ -f "libneon_json.dylib" ]]; then
    echo ""
    echo "Build successful!"
    echo "Output: $(pwd)/libneon_json.dylib"
    echo ""

    # Show library info
    echo "Library info:"
    file libneon_json.dylib
    echo ""

    # Show exported symbols
    echo "Exported symbols:"
    nm -g libneon_json.dylib | grep " T " | head -10
    echo ""

    # Show size
    ls -lh libneon_json.dylib
else
    echo "Build failed!"
    exit 1
fi
