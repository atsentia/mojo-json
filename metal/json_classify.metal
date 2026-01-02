/**
 * GPU-accelerated JSON character classification kernel
 *
 * Classifies each byte in a JSON string into structural character types.
 * This is Stage 1a of the two-stage JSON parsing pipeline.
 *
 * Classification codes:
 *   0 = whitespace (space, tab, newline, carriage return)
 *   1 = { (object open)
 *   2 = } (object close)
 *   3 = [ (array open)
 *   4 = ] (array close)
 *   5 = " (quote)
 *   6 = : (colon)
 *   7 = , (comma)
 *   8 = \ (backslash - escape)
 *   9 = other (non-structural)
 */

#include <metal_stdlib>
using namespace metal;

// Character classification constants
constant uint8_t CHAR_WHITESPACE = 0;
constant uint8_t CHAR_BRACE_OPEN = 1;
constant uint8_t CHAR_BRACE_CLOSE = 2;
constant uint8_t CHAR_BRACKET_OPEN = 3;
constant uint8_t CHAR_BRACKET_CLOSE = 4;
constant uint8_t CHAR_QUOTE = 5;
constant uint8_t CHAR_COLON = 6;
constant uint8_t CHAR_COMMA = 7;
constant uint8_t CHAR_BACKSLASH = 8;
constant uint8_t CHAR_OTHER = 9;

/**
 * Classify a single character.
 * Branchless implementation using select for better GPU performance.
 */
inline uint8_t classify_char(uint8_t ch) {
    // Structural characters (most common first for branch prediction)
    if (ch == '"') return CHAR_QUOTE;
    if (ch == '{') return CHAR_BRACE_OPEN;
    if (ch == '}') return CHAR_BRACE_CLOSE;
    if (ch == '[') return CHAR_BRACKET_OPEN;
    if (ch == ']') return CHAR_BRACKET_CLOSE;
    if (ch == ':') return CHAR_COLON;
    if (ch == ',') return CHAR_COMMA;
    if (ch == '\\') return CHAR_BACKSLASH;

    // Whitespace
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        return CHAR_WHITESPACE;
    }

    return CHAR_OTHER;
}

/**
 * Main classification kernel - processes contiguous memory.
 * Each thread classifies one byte.
 *
 * @param input  Input buffer (JSON bytes)
 * @param output Output buffer (classification codes)
 * @param size   Number of bytes to process
 * @param index  Thread position in grid
 */
[[kernel]] void json_classify_contiguous(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index < size) {
        output[index] = classify_char(input[index]);
    }
}

/**
 * Vectorized classification kernel - processes 4 bytes per thread.
 * More efficient for large buffers by reducing thread count.
 *
 * @param input  Input buffer (JSON bytes)
 * @param output Output buffer (classification codes)
 * @param size   Number of bytes to process (should be multiple of 4)
 * @param index  Thread position in grid (each thread handles 4 bytes)
 */
[[kernel]] void json_classify_vec4(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint base = index * 4;

    // Process 4 bytes per thread
    if (base + 3 < size) {
        output[base]     = classify_char(input[base]);
        output[base + 1] = classify_char(input[base + 1]);
        output[base + 2] = classify_char(input[base + 2]);
        output[base + 3] = classify_char(input[base + 3]);
    } else {
        // Handle tail bytes
        for (uint i = base; i < size && i < base + 4; i++) {
            output[i] = classify_char(input[i]);
        }
    }
}

/**
 * SIMD-style classification using lookup table in constant memory.
 * Fastest for uniform memory access patterns.
 */
constant uint8_t CHAR_LOOKUP[256] = {
    // 0x00-0x0F: Control characters (only tab=0x09, LF=0x0A, CR=0x0D are whitespace)
    9, 9, 9, 9, 9, 9, 9, 9, 9, 0, 0, 9, 9, 0, 9, 9,
    // 0x10-0x1F: More control characters
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    // 0x20-0x2F: space ! " # $ % & ' ( ) * + , - . /
    0, 9, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9,
    // 0x30-0x3F: 0-9 : ; < = > ?
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 6, 9, 9, 9, 9, 9,
    // 0x40-0x4F: @ A-O
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    // 0x50-0x5F: P-Z [ \ ] ^ _
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 3, 8, 4, 9, 9,
    // 0x60-0x6F: ` a-o
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    // 0x70-0x7F: p-z { | } ~ DEL
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 9, 2, 9, 9,
    // 0x80-0xFF: Extended ASCII (all other)
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9
};

[[kernel]] void json_classify_lookup(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index < size) {
        output[index] = CHAR_LOOKUP[input[index]];
    }
}

/**
 * Vectorized lookup table version - fastest implementation.
 * Processes 8 bytes per thread using lookup table.
 */
[[kernel]] void json_classify_lookup_vec8(
    device const uint8_t* input [[buffer(0)]],
    device uint8_t* output [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint base = index * 8;

    if (base + 7 < size) {
        // Fully unrolled for 8 bytes
        output[base]     = CHAR_LOOKUP[input[base]];
        output[base + 1] = CHAR_LOOKUP[input[base + 1]];
        output[base + 2] = CHAR_LOOKUP[input[base + 2]];
        output[base + 3] = CHAR_LOOKUP[input[base + 3]];
        output[base + 4] = CHAR_LOOKUP[input[base + 4]];
        output[base + 5] = CHAR_LOOKUP[input[base + 5]];
        output[base + 6] = CHAR_LOOKUP[input[base + 6]];
        output[base + 7] = CHAR_LOOKUP[input[base + 7]];
    } else {
        // Handle tail
        for (uint i = base; i < size && i < base + 8; i++) {
            output[i] = CHAR_LOOKUP[input[i]];
        }
    }
}
