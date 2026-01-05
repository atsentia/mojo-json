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


// =============================================================================
// GpJSON-Inspired Kernels: 64-bit Bitmap Operations
// =============================================================================

/**
 * Create quote bitmap - each thread processes 64 chars into one uint64.
 * Based on GpJSON create_quote_index.cu
 *
 * @param input       Input JSON bytes
 * @param quote_bits  Output 64-bit quote bitmaps (1 bit per char)
 * @param quote_carry Quote count parity for cross-chunk carry (0 or 1)
 * @param size        Total input size in bytes
 * @param num_chunks  Number of 64-byte chunks
 */
[[kernel]] void create_quote_bitmap(
    device const uint8_t* input [[buffer(0)]],
    device uint64_t* quote_bits [[buffer(1)]],
    device uint8_t* quote_carry [[buffer(2)]],
    constant const uint32_t& size [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    uint64_t base = index * 64;
    if (base >= size) return;

    uint64_t bitmap = 0;
    uint8_t quote_count = 0;
    uint64_t end = min(base + 64, (uint64_t)size);

    // Build quote bitmap for this 64-byte chunk
    for (uint64_t i = base; i < end; i++) {
        uint8_t ch = input[i];
        uint64_t bit_pos = i - base;

        if (ch == '"') {
            // Check if escaped (previous char is backslash)
            // Note: For full escape handling, would need escape bitmap first
            bool escaped = (i > 0 && input[i - 1] == '\\');
            if (!escaped) {
                bitmap |= (1UL << bit_pos);
                quote_count++;
            }
        }
    }

    quote_bits[index] = bitmap;
    quote_carry[index] = quote_count & 1;  // Parity for carry propagation
}

/**
 * Prefix-XOR to convert quote bitmap to string mask.
 * Based on simdjson/GpJSON algorithm.
 *
 * After this: bit=1 means character is INSIDE a string.
 *
 * @param quote_bits     Input: quote position bitmaps
 * @param string_mask    Output: in-string mask (modified in place)
 * @param quote_carry    Quote parity from previous chunks
 * @param num_chunks     Number of 64-bit chunks
 */
[[kernel]] void create_string_mask(
    device uint64_t* quote_bits [[buffer(0)]],
    device const uint8_t* quote_carry [[buffer(1)]],
    constant const uint32_t& num_chunks [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= num_chunks) return;

    uint64_t quotes = quote_bits[index];

    // Prefix-XOR algorithm (from simdjson)
    // Transforms: 0b00100100 (quotes at pos 2,5)
    // Into:       0b00111100 (inside string from 2-5)
    quotes ^= quotes << 1;
    quotes ^= quotes << 2;
    quotes ^= quotes << 4;
    quotes ^= quotes << 8;
    quotes ^= quotes << 16;
    quotes ^= quotes << 32;

    // Handle carry from previous chunks
    // If previous chunk ended inside string, invert our mask
    if (index > 0 && quote_carry[index - 1] == 1) {
        quotes = ~quotes;
    }

    quote_bits[index] = quotes;  // Now contains string mask
}

/**
 * Extract structural character positions, filtering out those inside strings.
 *
 * @param input         Input JSON bytes
 * @param string_mask   64-bit string masks (bit=1 means inside string)
 * @param output_pos    Output: positions of structural chars
 * @param output_chars  Output: the structural characters
 * @param output_count  Atomic counter for output position
 * @param size          Input size
 */
[[kernel]] void extract_structural_positions(
    device const uint8_t* input [[buffer(0)]],
    device const uint64_t* string_mask [[buffer(1)]],
    device uint32_t* output_pos [[buffer(2)]],
    device uint8_t* output_chars [[buffer(3)]],
    device atomic_uint* output_count [[buffer(4)]],
    constant const uint32_t& size [[buffer(5)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= size) return;

    uint8_t ch = input[index];
    uint8_t cls = CHAR_LOOKUP[ch];

    // Skip non-structural characters
    if (cls == CHAR_WHITESPACE || cls == CHAR_OTHER || cls == CHAR_BACKSLASH) {
        return;
    }

    // Check if inside string using mask
    uint chunk_idx = index / 64;
    uint bit_pos = index % 64;
    uint64_t mask = string_mask[chunk_idx];
    bool in_string = (mask >> bit_pos) & 1;

    // Quotes mark string boundaries (always structural)
    // Other structural chars only if outside strings
    if (cls == CHAR_QUOTE || !in_string) {
        uint pos = atomic_fetch_add_explicit(output_count, 1, memory_order_relaxed);
        output_pos[pos] = index;
        output_chars[pos] = ch;
    }
}

/**
 * NDJSON line detection - find newline positions.
 * Each thread processes 64 bytes.
 *
 * @param input         Input bytes
 * @param newline_bits  Output: 64-bit newline bitmaps
 * @param size          Input size
 */
[[kernel]] void find_newlines(
    device const uint8_t* input [[buffer(0)]],
    device uint64_t* newline_bits [[buffer(1)]],
    constant const uint32_t& size [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    uint64_t base = index * 64;
    if (base >= size) return;

    uint64_t bitmap = 0;
    uint64_t end = min(base + 64, (uint64_t)size);

    for (uint64_t i = base; i < end; i++) {
        if (input[i] == '\n') {
            bitmap |= (1UL << (i - base));
        }
    }

    newline_bits[index] = bitmap;
}
