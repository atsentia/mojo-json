/**
 * NEON SIMD JSON Structural Indexer
 *
 * Implements simdjson's branchless algorithm using ARM64 NEON intrinsics.
 * Processes 64 bytes at a time (4x 16-byte vectors).
 *
 * Key techniques:
 * - vceqq_u8: 16-byte parallel comparison
 * - vpaddq_u8: Convert 128-bit mask to 16-bit (ARM's PMOVMSKB workaround)
 * - vmull_p64: Carry-less multiply for prefix-XOR (string tracking)
 */

#include "neon_json.h"
#include <arm_neon.h>
#include <stdlib.h>
#include <string.h>

/* Context for reusable buffers */
struct NeonContext {
    uint64_t* quote_bits;      /* Quote position bitmaps */
    uint64_t* string_mask;     /* In-string mask */
    size_t buffer_capacity;    /* Allocated capacity in chunks */
};

NeonContext* neon_json_init(void) {
    NeonContext* ctx = calloc(1, sizeof(NeonContext));
    return ctx;
}

void neon_json_free(NeonContext* ctx) {
    if (ctx) {
        free(ctx->quote_bits);
        free(ctx->string_mask);
        free(ctx);
    }
}

/* Ensure buffers are allocated for given input size */
static void ensure_buffers(NeonContext* ctx, size_t input_len) {
    size_t num_chunks = (input_len + 63) / 64;
    if (ctx->buffer_capacity >= num_chunks) return;

    free(ctx->quote_bits);
    free(ctx->string_mask);

    ctx->quote_bits = malloc(num_chunks * sizeof(uint64_t));
    ctx->string_mask = malloc(num_chunks * sizeof(uint64_t));
    ctx->buffer_capacity = num_chunks;
}

/**
 * Convert 16-byte comparison result to 16-bit bitmask.
 * ARM doesn't have PMOVMSKB, so we use pairwise addition.
 *
 * Input: uint8x16_t with 0xFF or 0x00 per byte
 * Output: 16-bit mask where bit i = 1 if byte i was 0xFF
 */
static inline uint64_t neon_movemask_16(uint8x16_t v) {
    /* Shift each byte to get high bit into position */
    static const uint8_t shift_vals[16] = {
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
    };
    uint8x16_t shift_mask = vld1q_u8(shift_vals);

    /* AND with shift mask to get bit positions */
    uint8x16_t masked = vandq_u8(v, shift_mask);

    /* Pairwise add to combine bytes into 2 uint64s */
    uint8x16_t paired = vpaddq_u8(masked, masked);
    paired = vpaddq_u8(paired, paired);
    paired = vpaddq_u8(paired, paired);

    /* Extract lower 16 bits */
    return vgetq_lane_u16(vreinterpretq_u16_u8(paired), 0);
}

/**
 * Process 64 bytes and return structural/quote/backslash bitmasks.
 */
static inline void classify_chunk_64(
    const uint8_t* input,
    uint64_t* structural_out,
    uint64_t* quote_out,
    uint64_t* backslash_out
) {
    uint64_t structural = 0;
    uint64_t quotes = 0;
    uint64_t backslashes = 0;

    /* Constant vectors for comparison */
    uint8x16_t v_quote = vdupq_n_u8('"');
    uint8x16_t v_backslash = vdupq_n_u8('\\');
    uint8x16_t v_brace_open = vdupq_n_u8('{');
    uint8x16_t v_brace_close = vdupq_n_u8('}');
    uint8x16_t v_bracket_open = vdupq_n_u8('[');
    uint8x16_t v_bracket_close = vdupq_n_u8(']');
    uint8x16_t v_colon = vdupq_n_u8(':');
    uint8x16_t v_comma = vdupq_n_u8(',');

    /* Process 4x 16-byte chunks */
    for (int i = 0; i < 4; i++) {
        uint8x16_t chunk = vld1q_u8(input + i * 16);

        /* Character comparisons - each returns 0xFF or 0x00 per byte */
        uint8x16_t is_quote = vceqq_u8(chunk, v_quote);
        uint8x16_t is_backslash = vceqq_u8(chunk, v_backslash);
        uint8x16_t is_brace_o = vceqq_u8(chunk, v_brace_open);
        uint8x16_t is_brace_c = vceqq_u8(chunk, v_brace_close);
        uint8x16_t is_brack_o = vceqq_u8(chunk, v_bracket_open);
        uint8x16_t is_brack_c = vceqq_u8(chunk, v_bracket_close);
        uint8x16_t is_colon = vceqq_u8(chunk, v_colon);
        uint8x16_t is_comma = vceqq_u8(chunk, v_comma);

        /* Combine structural characters */
        uint8x16_t struct_mask = vorrq_u8(is_brace_o, is_brace_c);
        struct_mask = vorrq_u8(struct_mask, is_brack_o);
        struct_mask = vorrq_u8(struct_mask, is_brack_c);
        struct_mask = vorrq_u8(struct_mask, is_colon);
        struct_mask = vorrq_u8(struct_mask, is_comma);
        struct_mask = vorrq_u8(struct_mask, is_quote);

        /* Convert to bitmasks and place in correct position */
        structural |= (uint64_t)neon_movemask_16(struct_mask) << (i * 16);
        quotes |= (uint64_t)neon_movemask_16(is_quote) << (i * 16);
        backslashes |= (uint64_t)neon_movemask_16(is_backslash) << (i * 16);
    }

    *structural_out = structural;
    *quote_out = quotes;
    *backslash_out = backslashes;
}

/**
 * Prefix XOR using carry-less multiply (simdjson algorithm).
 *
 * Computes cumulative XOR of bits:
 * - Input:  0b00100100 (quotes at positions 2, 5)
 * - Output: 0b00111100 (inside string from 2-5)
 *
 * vmull_p64 with all-1s computes prefix XOR in one instruction.
 */
static inline uint64_t prefix_xor(uint64_t mask) {
    poly64x1_t a = vcreate_p64(mask);
    poly64x1_t b = vcreate_p64(0xFFFFFFFFFFFFFFFFULL);
    poly128_t result = vmull_p64(vget_lane_p64(a, 0), vget_lane_p64(b, 0));

    /* Lower 64 bits contain the prefix XOR result */
    return (uint64_t)result;
}

/**
 * Find positions where odd-length backslash sequences end.
 * These are the backslashes that actually escape the next character.
 *
 * Algorithm (from simdjson):
 * 1. Find starts of backslash sequences
 * 2. Find lengths by counting consecutive backslashes
 * 3. Odd-length sequences escape the following character
 */
static inline uint64_t find_odd_backslash_sequences(uint64_t backslashes) {
    if (backslashes == 0) return 0;

    /* Find sequence starts (backslash not preceded by backslash) */
    uint64_t starts = backslashes & ~(backslashes << 1);

    /* For each sequence, determine if odd or even length */
    /* This is the key insight: we can use arithmetic on the bits */

    /* Simplified approach: check if quote follows odd number of backslashes */
    /* Full simdjson uses a more complex carry-based approach */

    /* For now, use a reasonable approximation:
     * A backslash escapes if there's an odd number preceding a position */
    uint64_t odd_ends = 0;
    uint64_t seq = backslashes;
    while (seq) {
        int pos = __builtin_ctzll(seq);
        int count = 0;
        uint64_t temp = seq >> pos;
        while (temp & 1) {
            count++;
            temp >>= 1;
        }
        if (count & 1) {
            /* Odd-length sequence - the last backslash escapes next char */
            odd_ends |= (1ULL << (pos + count - 1));
        }
        seq &= seq - (1ULL << (pos + count - 1));
    }
    return odd_ends;
}

int64_t neon_json_find_structural(
    NeonContext* ctx,
    const uint8_t* input,
    size_t input_len,
    uint32_t* positions,
    uint8_t* characters,
    size_t max_output
) {
    if (!ctx || !input || input_len == 0 || !positions || !characters) {
        return -1;
    }

    ensure_buffers(ctx, input_len);

    size_t count = 0;
    uint64_t prev_string_state = 0;  /* 0 = outside string, 1 = inside */

    /* Process 64 bytes at a time */
    size_t i = 0;
    for (; i + 64 <= input_len && count < max_output; i += 64) {
        uint64_t structural, quotes, backslashes;
        classify_chunk_64(input + i, &structural, &quotes, &backslashes);

        /* Find escaped quotes (quotes preceded by odd backslash sequences) */
        uint64_t odd_bs = find_odd_backslash_sequences(backslashes);
        uint64_t escaped_quotes = quotes & (odd_bs << 1);
        uint64_t unescaped_quotes = quotes & ~escaped_quotes;

        /* Compute string mask via prefix XOR */
        uint64_t string_mask = prefix_xor(unescaped_quotes);

        /* Apply carry from previous chunk */
        if (prev_string_state) {
            string_mask = ~string_mask;
        }

        /* Update carry for next chunk (parity of unescaped quotes) */
        prev_string_state = __builtin_parityll(unescaped_quotes);

        /* Filter: structural chars outside strings, plus all quotes */
        uint64_t filtered = (structural & ~string_mask) | unescaped_quotes;

        /* Extract positions */
        while (filtered && count < max_output) {
            int pos = __builtin_ctzll(filtered);
            positions[count] = (uint32_t)(i + pos);
            characters[count] = input[i + pos];
            count++;
            filtered &= filtered - 1;  /* Clear lowest bit */
        }
    }

    /* Handle remaining bytes (scalar fallback) */
    int in_string = prev_string_state;
    int prev_backslash = 0;
    for (; i < input_len && count < max_output; i++) {
        uint8_t ch = input[i];

        if (ch == '\\' && !prev_backslash) {
            prev_backslash = 1;
            continue;
        }

        if (ch == '"' && !prev_backslash) {
            positions[count] = (uint32_t)i;
            characters[count] = ch;
            count++;
            in_string = !in_string;
        } else if (!in_string && !prev_backslash) {
            if (ch == '{' || ch == '}' || ch == '[' || ch == ']' ||
                ch == ':' || ch == ',') {
                positions[count] = (uint32_t)i;
                characters[count] = ch;
                count++;
            }
        }

        prev_backslash = 0;
    }

    return (int64_t)count;
}

int neon_json_classify(
    const uint8_t* input,
    uint8_t* output,
    size_t len
) {
    if (!input || !output || len == 0) return -1;

    /* Lookup table for classification */
    static const uint8_t LOOKUP[256] = {
        /* 0x00-0x0F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 0, 0, 9, 9, 0, 9, 9,
        /* 0x10-0x1F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        /* 0x20-0x2F */ 0, 9, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9, 9, 9,
        /* 0x30-0x3F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 6, 9, 9, 9, 9, 9,
        /* 0x40-0x4F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        /* 0x50-0x5F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 3, 8, 4, 9, 9,
        /* 0x60-0x6F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        /* 0x70-0x7F */ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 9, 2, 9, 9,
        /* 0x80-0xFF all OTHER */
        9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
        9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
        9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
        9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9
    };

    /* Use NEON for bulk processing */
    size_t i = 0;

    /* Load lookup table into NEON register for vectorized lookup */
    /* Note: vqtbl1q_u8 uses low nibble, so we need split lookup */

    /* For now, use scalar loop with LOOKUP table (still fast) */
    for (; i < len; i++) {
        output[i] = LOOKUP[input[i]];
    }

    return 0;
}

int neon_json_is_available(void) {
    return 1;  /* Always available on ARM64 macOS */
}

double neon_json_throughput_estimate(void) {
    /* Estimate based on typical M1/M2 performance */
    /* ~25 cycles per 64 bytes at 3 GHz = ~7.5 GB/s theoretical */
    /* Practical: 3-4 GB/s with memory and overhead */
    return 3500.0;  /* 3.5 GB/s estimate */
}
