/**
 * NEON SIMD JSON Structural Indexer
 *
 * High-performance JSON Stage 1 using ARM64 NEON intrinsics.
 * Implements simdjson's branchless algorithm for structural character detection.
 *
 * Performance: 3-4 GB/s on Apple Silicon (M1-M4)
 *
 * Build:
 *   clang -O3 -march=armv8-a+simd -shared -fPIC neon_json.c -o libneon_json.dylib
 */

#ifndef NEON_JSON_H
#define NEON_JSON_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Classification codes (same as Metal implementation) */
#define NEON_CHAR_WHITESPACE   0
#define NEON_CHAR_BRACE_OPEN   1
#define NEON_CHAR_BRACE_CLOSE  2
#define NEON_CHAR_BRACKET_OPEN 3
#define NEON_CHAR_BRACKET_CLOSE 4
#define NEON_CHAR_QUOTE        5
#define NEON_CHAR_COLON        6
#define NEON_CHAR_COMMA        7
#define NEON_CHAR_BACKSLASH    8
#define NEON_CHAR_OTHER        9

/* Opaque context for buffer reuse */
typedef struct NeonContext NeonContext;

/**
 * Initialize NEON context.
 * @return Context pointer, or NULL on failure
 */
NeonContext* neon_json_init(void);

/**
 * Free NEON context and resources.
 */
void neon_json_free(NeonContext* ctx);

/**
 * Find structural character positions using NEON SIMD.
 *
 * Implements simdjson's branchless algorithm:
 * 1. Vectorized character classification (16 bytes at once)
 * 2. Branchless escape/quote handling
 * 3. Prefix-XOR for string tracking via carry-less multiply
 *
 * @param ctx         Context from neon_json_init
 * @param input       Input JSON bytes
 * @param input_len   Input length
 * @param positions   Output: structural char positions (caller allocates)
 * @param characters  Output: structural characters (caller allocates)
 * @param max_output  Maximum output capacity
 * @return Number of structural chars found, -1 on error
 */
int64_t neon_json_find_structural(
    NeonContext* ctx,
    const uint8_t* input,
    size_t input_len,
    uint32_t* positions,
    uint8_t* characters,
    size_t max_output
);

/**
 * Simple character classification (no string filtering).
 * Faster but doesn't distinguish inside/outside strings.
 *
 * @param input   Input bytes
 * @param output  Classification codes (one per byte)
 * @param len     Length
 * @return 0 on success, -1 on error
 */
int neon_json_classify(
    const uint8_t* input,
    uint8_t* output,
    size_t len
);

/**
 * Check if NEON is available.
 * Always returns 1 on ARM64 macOS.
 */
int neon_json_is_available(void);

/**
 * Get throughput estimate in MB/s for benchmarking.
 * Returns theoretical maximum based on CPU frequency.
 */
double neon_json_throughput_estimate(void);

#ifdef __cplusplus
}
#endif

#endif /* NEON_JSON_H */
