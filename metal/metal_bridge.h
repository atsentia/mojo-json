/**
 * Metal Bridge for JSON Character Classification
 *
 * C API for GPU-accelerated JSON parsing via Metal.
 * Includes both simple character classification and full GpJSON-style Stage 1 pipeline.
 */

#ifndef METAL_BRIDGE_H
#define METAL_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context handle
typedef struct MetalContext MetalContext;

// =============================================================================
// Initialization and Cleanup
// =============================================================================

/**
 * Initialize Metal context with specified metallib path.
 *
 * @param metallib_path Path to pre-compiled .metallib file
 * @return Opaque context pointer, or NULL on failure
 */
MetalContext* metal_json_init(const char* metallib_path);

/**
 * Free Metal context and resources.
 */
void metal_json_free(MetalContext* ctx);

/**
 * Get GPU device name for diagnostics.
 */
const char* metal_json_device_name(MetalContext* ctx);

/**
 * Check if Metal GPU is available.
 */
int metal_json_is_available(void);

// =============================================================================
// Simple Character Classification (existing API)
// =============================================================================

/**
 * Classify JSON characters using GPU.
 * Uses the fastest available kernel (lookup_vec8 by default).
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
 *
 * @param ctx Context from metal_json_init
 * @param input Input byte array (JSON string)
 * @param output Output byte array (classifications)
 * @param size Number of bytes to process
 * @return 0 on success, -1 on failure
 */
int metal_json_classify(MetalContext* ctx,
                        const uint8_t* input,
                        uint8_t* output,
                        uint32_t size);

/**
 * Classify JSON characters with explicit kernel selection.
 *
 * @param ctx Context from metal_json_init
 * @param input Input byte array
 * @param output Output byte array
 * @param size Number of bytes
 * @param kernel_variant 0=contiguous, 1=vec4, 2=lookup, 3=lookup_vec8
 * @return 0 on success, -1 on failure
 */
int metal_json_classify_variant(MetalContext* ctx,
                                const uint8_t* input,
                                uint8_t* output,
                                uint32_t size,
                                int kernel_variant);

// =============================================================================
// GpJSON-Inspired Full Stage 1 Pipeline
// =============================================================================

/**
 * Check if GpJSON pipeline is available.
 * Requires metallib compiled with GpJSON kernels.
 */
int metal_json_has_gpjson_pipeline(MetalContext* ctx);

/**
 * Create quote bitmap - marks quote positions in 64-bit bitmaps.
 * Each GPU thread processes 64 bytes into one uint64.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param size Input size
 * @param quote_bits Output: 64-bit quote bitmaps (caller allocates (size+63)/64 uint64s)
 * @param quote_carry Output: Quote parity per chunk (caller allocates (size+63)/64 bytes)
 * @return 0 on success, -1 on failure
 */
int metal_json_create_quote_bitmap(MetalContext* ctx,
                                   const uint8_t* input,
                                   uint32_t size,
                                   uint64_t* quote_bits,
                                   uint8_t* quote_carry);

/**
 * Create string mask using prefix-XOR.
 * Converts quote bitmaps to in-string masks (bit=1 means inside string).
 * Based on simdjson/GpJSON algorithm.
 *
 * @param ctx Context
 * @param quote_bits In/Out: Quote bitmaps -> String masks
 * @param quote_carry Quote parity from create_quote_bitmap
 * @param num_chunks Number of 64-byte chunks
 * @return 0 on success, -1 on failure
 */
int metal_json_create_string_mask(MetalContext* ctx,
                                  uint64_t* quote_bits,
                                  const uint8_t* quote_carry,
                                  uint32_t num_chunks);

/**
 * Extract structural character positions, filtering out those inside strings.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param string_mask In-string masks from create_string_mask
 * @param size Input size
 * @param output_pos Output: Positions of structural characters (caller allocates)
 * @param output_chars Output: The structural characters themselves (caller allocates)
 * @param output_count Output: Number of structural characters found
 * @return 0 on success, -1 on failure
 */
int metal_json_extract_structural(MetalContext* ctx,
                                  const uint8_t* input,
                                  const uint64_t* string_mask,
                                  uint32_t size,
                                  uint32_t* output_pos,
                                  uint8_t* output_chars,
                                  uint32_t* output_count);

/**
 * Find newline positions for NDJSON processing.
 *
 * @param ctx Context
 * @param input Input bytes
 * @param size Input size
 * @param newline_bits Output: 64-bit newline bitmaps (caller allocates (size+63)/64 uint64s)
 * @return 0 on success, -1 on failure
 */
int metal_json_find_newlines(MetalContext* ctx,
                             const uint8_t* input,
                             uint32_t size,
                             uint64_t* newline_bits);

/**
 * Full GPU Stage 1: Run the complete GpJSON pipeline.
 *
 * This combines:
 * 1. create_quote_bitmap - Find quote positions
 * 2. create_string_mask - Prefix-XOR to mark string regions
 * 3. extract_structural_positions - Get structural chars outside strings
 *
 * More efficient than calling individual functions due to single command buffer.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param size Input size
 * @param output_pos Output: Positions of structural characters
 * @param output_chars Output: The structural characters
 * @param output_count Output: Number found
 * @return 0 on success, -1 on failure
 */
int metal_json_full_stage1(MetalContext* ctx,
                           const uint8_t* input,
                           uint32_t size,
                           uint32_t* output_pos,
                           uint8_t* output_chars,
                           uint32_t* output_count);

#ifdef __cplusplus
}
#endif

#endif /* METAL_BRIDGE_H */
