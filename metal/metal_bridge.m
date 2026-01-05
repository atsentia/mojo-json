/**
 * Metal Bridge for JSON Character Classification
 *
 * Provides C-callable functions to load and execute Metal kernels
 * from Mojo via FFI.
 *
 * Build:
 *   clang -c metal_bridge.m -o metal_bridge.o -fobjc-arc
 *   clang -shared metal_bridge.o -o libmetal_bridge.dylib -framework Metal -framework Foundation
 *
 * Or combined:
 *   clang -shared -fobjc-arc metal_bridge.m -o libmetal_bridge.dylib -framework Metal -framework Foundation
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>

// Opaque context structure
typedef struct MetalContext {
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLCommandQueue> queue;

    // Pre-created pipelines for each kernel variant
    id<MTLComputePipelineState> pipeline_contiguous;
    id<MTLComputePipelineState> pipeline_vec4;
    id<MTLComputePipelineState> pipeline_lookup;
    id<MTLComputePipelineState> pipeline_lookup_vec8;

    // GpJSON-inspired pipelines (full Stage 1)
    id<MTLComputePipelineState> pipeline_quote_bitmap;
    id<MTLComputePipelineState> pipeline_string_mask;
    id<MTLComputePipelineState> pipeline_extract_structural;
    id<MTLComputePipelineState> pipeline_find_newlines;

    // Reusable buffers (for repeated calls with same size)
    id<MTLBuffer> input_buffer;
    id<MTLBuffer> output_buffer;
    uint32_t buffer_size;

    // GpJSON buffers for full pipeline
    id<MTLBuffer> quote_bits_buffer;      // 64-bit quote bitmaps
    id<MTLBuffer> quote_carry_buffer;     // Quote parity for carry
    id<MTLBuffer> structural_pos_buffer;  // Output positions
    id<MTLBuffer> structural_char_buffer; // Output characters
    id<MTLBuffer> atomic_counter_buffer;  // Atomic counter
    uint32_t gpjson_buffer_size;
} MetalContext;

/**
 * Initialize Metal context with specified metallib path.
 *
 * @param metallib_path Path to pre-compiled .metallib file
 * @return Opaque context pointer, or NULL on failure
 */
MetalContext* metal_json_init(const char* metallib_path) {
    @autoreleasepool {
        MetalContext* ctx = calloc(1, sizeof(MetalContext));
        if (!ctx) return NULL;

        // Get default GPU device
        ctx->device = MTLCreateSystemDefaultDevice();
        if (!ctx->device) {
            fprintf(stderr, "metal_json_init: No Metal device found\n");
            free(ctx);
            return NULL;
        }

        // Load metallib
        NSError* error = nil;
        NSString* path = [NSString stringWithUTF8String:metallib_path];
        NSURL* url = [NSURL fileURLWithPath:path];

        ctx->library = [ctx->device newLibraryWithURL:url error:&error];
        if (!ctx->library) {
            fprintf(stderr, "metal_json_init: Failed to load metallib: %s\n",
                    error.localizedDescription.UTF8String);
            free(ctx);
            return NULL;
        }

        // Create command queue
        ctx->queue = [ctx->device newCommandQueue];
        if (!ctx->queue) {
            fprintf(stderr, "metal_json_init: Failed to create command queue\n");
            free(ctx);
            return NULL;
        }

        // Create pipeline for each kernel variant
        id<MTLFunction> func;

        func = [ctx->library newFunctionWithName:@"json_classify_contiguous"];
        if (func) {
            ctx->pipeline_contiguous = [ctx->device newComputePipelineStateWithFunction:func error:&error];
            if (!ctx->pipeline_contiguous) {
                fprintf(stderr, "metal_json_init: Failed to create pipeline_contiguous: %s\n",
                        error.localizedDescription.UTF8String);
            }
        }

        func = [ctx->library newFunctionWithName:@"json_classify_vec4"];
        if (func) {
            ctx->pipeline_vec4 = [ctx->device newComputePipelineStateWithFunction:func error:&error];
            if (!ctx->pipeline_vec4) {
                fprintf(stderr, "metal_json_init: Failed to create pipeline_vec4: %s\n",
                        error.localizedDescription.UTF8String);
            }
        }

        func = [ctx->library newFunctionWithName:@"json_classify_lookup"];
        if (func) {
            ctx->pipeline_lookup = [ctx->device newComputePipelineStateWithFunction:func error:&error];
            if (!ctx->pipeline_lookup) {
                fprintf(stderr, "metal_json_init: Failed to create pipeline_lookup: %s\n",
                        error.localizedDescription.UTF8String);
            }
        }

        func = [ctx->library newFunctionWithName:@"json_classify_lookup_vec8"];
        if (func) {
            ctx->pipeline_lookup_vec8 = [ctx->device newComputePipelineStateWithFunction:func error:&error];
            if (!ctx->pipeline_lookup_vec8) {
                fprintf(stderr, "metal_json_init: Failed to create pipeline_lookup_vec8: %s\n",
                        error.localizedDescription.UTF8String);
            }
        }

        // Check that at least one pipeline was created
        if (!ctx->pipeline_lookup_vec8 && !ctx->pipeline_lookup &&
            !ctx->pipeline_contiguous && !ctx->pipeline_vec4) {
            fprintf(stderr, "metal_json_init: No pipelines created\n");
            free(ctx);
            return NULL;
        }

        // Create GpJSON-inspired pipelines (optional - for full Stage 1)
        func = [ctx->library newFunctionWithName:@"create_quote_bitmap"];
        if (func) {
            ctx->pipeline_quote_bitmap = [ctx->device newComputePipelineStateWithFunction:func error:&error];
        }

        func = [ctx->library newFunctionWithName:@"create_string_mask"];
        if (func) {
            ctx->pipeline_string_mask = [ctx->device newComputePipelineStateWithFunction:func error:&error];
        }

        func = [ctx->library newFunctionWithName:@"extract_structural_positions"];
        if (func) {
            ctx->pipeline_extract_structural = [ctx->device newComputePipelineStateWithFunction:func error:&error];
        }

        func = [ctx->library newFunctionWithName:@"find_newlines"];
        if (func) {
            ctx->pipeline_find_newlines = [ctx->device newComputePipelineStateWithFunction:func error:&error];
        }

        return ctx;
    }
}

/**
 * Ensure buffers are large enough for given size.
 * Reuses existing buffers if possible.
 */
static void ensure_buffers(MetalContext* ctx, uint32_t size) {
    if (ctx->buffer_size >= size && ctx->input_buffer && ctx->output_buffer) {
        return;
    }

    // Round up to 64KB for efficiency
    uint32_t alloc_size = ((size + 65535) / 65536) * 65536;

    ctx->input_buffer = [ctx->device newBufferWithLength:alloc_size
                                                 options:MTLResourceStorageModeShared];
    ctx->output_buffer = [ctx->device newBufferWithLength:alloc_size
                                                  options:MTLResourceStorageModeShared];
    ctx->buffer_size = alloc_size;
}

/**
 * Classify JSON characters using GPU.
 *
 * Uses the fastest available kernel (lookup_vec8 by default).
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
                        uint32_t size) {
    @autoreleasepool {
        if (!ctx || !input || !output || size == 0) {
            return -1;
        }

        // Select best pipeline
        id<MTLComputePipelineState> pipeline = ctx->pipeline_lookup_vec8;
        int bytes_per_thread = 8;

        if (!pipeline) {
            pipeline = ctx->pipeline_lookup;
            bytes_per_thread = 1;
        }
        if (!pipeline) {
            pipeline = ctx->pipeline_contiguous;
            bytes_per_thread = 1;
        }
        if (!pipeline) {
            return -1;  // No pipeline available
        }

        ensure_buffers(ctx, size);

        // Copy input to GPU buffer
        memcpy(ctx->input_buffer.contents, input, size);

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->output_buffer offset:0 atIndex:1];
        [encoder setBytes:&size length:sizeof(size) atIndex:2];

        // Calculate thread groups
        NSUInteger threads = (size + bytes_per_thread - 1) / bytes_per_thread;
        NSUInteger threadsPerGroup = pipeline.maxTotalThreadsPerThreadgroup;
        if (threadsPerGroup > threads) {
            threadsPerGroup = threads;
        }
        NSUInteger numGroups = (threads + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        // Check for errors
        if (commandBuffer.error) {
            fprintf(stderr, "metal_json_classify: GPU execution failed: %s\n",
                    commandBuffer.error.localizedDescription.UTF8String);
            return -1;
        }

        // Copy result back
        memcpy(output, ctx->output_buffer.contents, size);

        return 0;
    }
}

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
                                int kernel_variant) {
    @autoreleasepool {
        if (!ctx || !input || !output || size == 0) {
            return -1;
        }

        id<MTLComputePipelineState> pipeline;
        int bytes_per_thread;

        switch (kernel_variant) {
            case 0:
                pipeline = ctx->pipeline_contiguous;
                bytes_per_thread = 1;
                break;
            case 1:
                pipeline = ctx->pipeline_vec4;
                bytes_per_thread = 4;
                break;
            case 2:
                pipeline = ctx->pipeline_lookup;
                bytes_per_thread = 1;
                break;
            case 3:
            default:
                pipeline = ctx->pipeline_lookup_vec8;
                bytes_per_thread = 8;
                break;
        }

        if (!pipeline) {
            return -1;
        }

        ensure_buffers(ctx, size);
        memcpy(ctx->input_buffer.contents, input, size);

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->output_buffer offset:0 atIndex:1];
        [encoder setBytes:&size length:sizeof(size) atIndex:2];

        NSUInteger threads = (size + bytes_per_thread - 1) / bytes_per_thread;
        NSUInteger threadsPerGroup = MIN(pipeline.maxTotalThreadsPerThreadgroup, threads);
        NSUInteger numGroups = (threads + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            return -1;
        }

        memcpy(output, ctx->output_buffer.contents, size);
        return 0;
    }
}

/**
 * Free Metal context and resources.
 */
void metal_json_free(MetalContext* ctx) {
    if (ctx) {
        // ARC will handle release of Obj-C objects
        free(ctx);
    }
}

/**
 * Get GPU name for diagnostics.
 */
const char* metal_json_device_name(MetalContext* ctx) {
    if (!ctx || !ctx->device) {
        return "Unknown";
    }
    return ctx->device.name.UTF8String;
}

/**
 * Check if GPU is available.
 */
int metal_json_is_available(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil;
    }
}

// =============================================================================
// GpJSON-Inspired Full Stage 1 Pipeline
// =============================================================================

/**
 * Ensure GpJSON buffers are allocated for given input size.
 */
static void ensure_gpjson_buffers(MetalContext* ctx, uint32_t size) {
    if (ctx->gpjson_buffer_size >= size) {
        return;
    }

    // Round up to 64KB
    uint32_t alloc_size = ((size + 65535) / 65536) * 65536;
    uint32_t num_chunks = (size + 63) / 64;

    // 64-bit quote bitmaps (one uint64 per 64 bytes)
    ctx->quote_bits_buffer = [ctx->device newBufferWithLength:num_chunks * sizeof(uint64_t)
                                                      options:MTLResourceStorageModeShared];

    // Quote parity carry (one byte per chunk)
    ctx->quote_carry_buffer = [ctx->device newBufferWithLength:num_chunks
                                                       options:MTLResourceStorageModeShared];

    // Structural positions output (worst case: every byte is structural)
    ctx->structural_pos_buffer = [ctx->device newBufferWithLength:alloc_size * sizeof(uint32_t)
                                                          options:MTLResourceStorageModeShared];

    // Structural chars output
    ctx->structural_char_buffer = [ctx->device newBufferWithLength:alloc_size
                                                           options:MTLResourceStorageModeShared];

    // Atomic counter
    ctx->atomic_counter_buffer = [ctx->device newBufferWithLength:sizeof(uint32_t)
                                                          options:MTLResourceStorageModeShared];

    ctx->gpjson_buffer_size = alloc_size;
}

/**
 * Create quote bitmap - marks quote positions in 64-bit bitmaps.
 * Each thread processes 64 bytes into one uint64.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param size Input size
 * @param quote_bits Output: 64-bit quote bitmaps (caller allocates num_chunks uint64s)
 * @param quote_carry Output: Quote parity per chunk (caller allocates num_chunks bytes)
 * @return 0 on success, -1 on failure
 */
int metal_json_create_quote_bitmap(MetalContext* ctx,
                                   const uint8_t* input,
                                   uint32_t size,
                                   uint64_t* quote_bits,
                                   uint8_t* quote_carry) {
    @autoreleasepool {
        if (!ctx || !ctx->pipeline_quote_bitmap || !input || size == 0) {
            return -1;
        }

        ensure_buffers(ctx, size);
        ensure_gpjson_buffers(ctx, size);

        uint32_t num_chunks = (size + 63) / 64;

        memcpy(ctx->input_buffer.contents, input, size);

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:ctx->pipeline_quote_bitmap];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:1];
        [encoder setBuffer:ctx->quote_carry_buffer offset:0 atIndex:2];
        [encoder setBytes:&size length:sizeof(size) atIndex:3];

        NSUInteger threadsPerGroup = MIN(ctx->pipeline_quote_bitmap.maxTotalThreadsPerThreadgroup, num_chunks);
        NSUInteger numGroups = (num_chunks + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            return -1;
        }

        memcpy(quote_bits, ctx->quote_bits_buffer.contents, num_chunks * sizeof(uint64_t));
        memcpy(quote_carry, ctx->quote_carry_buffer.contents, num_chunks);

        return 0;
    }
}

/**
 * Create string mask using prefix-XOR.
 * Converts quote bitmaps to in-string masks (bit=1 means inside string).
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
                                  uint32_t num_chunks) {
    @autoreleasepool {
        if (!ctx || !ctx->pipeline_string_mask || num_chunks == 0) {
            return -1;
        }

        memcpy(ctx->quote_bits_buffer.contents, quote_bits, num_chunks * sizeof(uint64_t));
        memcpy(ctx->quote_carry_buffer.contents, quote_carry, num_chunks);

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:ctx->pipeline_string_mask];
        [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->quote_carry_buffer offset:0 atIndex:1];
        [encoder setBytes:&num_chunks length:sizeof(num_chunks) atIndex:2];

        NSUInteger threadsPerGroup = MIN(ctx->pipeline_string_mask.maxTotalThreadsPerThreadgroup, num_chunks);
        NSUInteger numGroups = (num_chunks + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            return -1;
        }

        memcpy(quote_bits, ctx->quote_bits_buffer.contents, num_chunks * sizeof(uint64_t));

        return 0;
    }
}

/**
 * Extract structural character positions, filtering out those inside strings.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param string_mask In-string masks from create_string_mask
 * @param size Input size
 * @param output_pos Output: Positions of structural characters
 * @param output_chars Output: The structural characters themselves
 * @param output_count Output: Number of structural characters found
 * @return 0 on success, -1 on failure
 */
int metal_json_extract_structural(MetalContext* ctx,
                                  const uint8_t* input,
                                  const uint64_t* string_mask,
                                  uint32_t size,
                                  uint32_t* output_pos,
                                  uint8_t* output_chars,
                                  uint32_t* output_count) {
    @autoreleasepool {
        if (!ctx || !ctx->pipeline_extract_structural || !input || size == 0) {
            return -1;
        }

        ensure_buffers(ctx, size);
        ensure_gpjson_buffers(ctx, size);

        uint32_t num_chunks = (size + 63) / 64;

        memcpy(ctx->input_buffer.contents, input, size);
        memcpy(ctx->quote_bits_buffer.contents, string_mask, num_chunks * sizeof(uint64_t));

        // Reset atomic counter
        uint32_t zero = 0;
        memcpy(ctx->atomic_counter_buffer.contents, &zero, sizeof(zero));

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:ctx->pipeline_extract_structural];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:1];
        [encoder setBuffer:ctx->structural_pos_buffer offset:0 atIndex:2];
        [encoder setBuffer:ctx->structural_char_buffer offset:0 atIndex:3];
        [encoder setBuffer:ctx->atomic_counter_buffer offset:0 atIndex:4];
        [encoder setBytes:&size length:sizeof(size) atIndex:5];

        NSUInteger threadsPerGroup = MIN(ctx->pipeline_extract_structural.maxTotalThreadsPerThreadgroup, (NSUInteger)size);
        NSUInteger numGroups = (size + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            return -1;
        }

        memcpy(output_count, ctx->atomic_counter_buffer.contents, sizeof(uint32_t));
        if (*output_count > 0) {
            memcpy(output_pos, ctx->structural_pos_buffer.contents, *output_count * sizeof(uint32_t));
            memcpy(output_chars, ctx->structural_char_buffer.contents, *output_count);
        }

        return 0;
    }
}

/**
 * Find newline positions for NDJSON processing.
 *
 * @param ctx Context
 * @param input Input bytes
 * @param size Input size
 * @param newline_bits Output: 64-bit newline bitmaps (one uint64 per 64 bytes)
 * @return 0 on success, -1 on failure
 */
int metal_json_find_newlines(MetalContext* ctx,
                             const uint8_t* input,
                             uint32_t size,
                             uint64_t* newline_bits) {
    @autoreleasepool {
        if (!ctx || !ctx->pipeline_find_newlines || !input || size == 0) {
            return -1;
        }

        ensure_buffers(ctx, size);
        ensure_gpjson_buffers(ctx, size);

        uint32_t num_chunks = (size + 63) / 64;

        memcpy(ctx->input_buffer.contents, input, size);

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:ctx->pipeline_find_newlines];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:1];  // Reuse for newlines
        [encoder setBytes:&size length:sizeof(size) atIndex:2];

        NSUInteger threadsPerGroup = MIN(ctx->pipeline_find_newlines.maxTotalThreadsPerThreadgroup, num_chunks);
        NSUInteger numGroups = (num_chunks + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            return -1;
        }

        memcpy(newline_bits, ctx->quote_bits_buffer.contents, num_chunks * sizeof(uint64_t));

        return 0;
    }
}

/**
 * Full GPU Stage 1: Run the complete GpJSON pipeline.
 *
 * This combines:
 * 1. create_quote_bitmap - Find quote positions
 * 2. create_string_mask - Prefix-XOR to mark string regions
 * 3. extract_structural_positions - Get structural chars outside strings
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
                           uint32_t* output_count) {
    @autoreleasepool {
        if (!ctx || !input || size == 0) {
            return -1;
        }

        // Check all required pipelines are available
        if (!ctx->pipeline_quote_bitmap ||
            !ctx->pipeline_string_mask ||
            !ctx->pipeline_extract_structural) {
            return -1;
        }

        ensure_buffers(ctx, size);
        ensure_gpjson_buffers(ctx, size);

        uint32_t num_chunks = (size + 63) / 64;

        // Copy input once
        memcpy(ctx->input_buffer.contents, input, size);

        // Create command buffer for all passes
        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];

        // Pass 1: Create quote bitmap
        {
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            [encoder setComputePipelineState:ctx->pipeline_quote_bitmap];
            [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
            [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:1];
            [encoder setBuffer:ctx->quote_carry_buffer offset:0 atIndex:2];
            [encoder setBytes:&size length:sizeof(size) atIndex:3];

            NSUInteger tpg = MIN(ctx->pipeline_quote_bitmap.maxTotalThreadsPerThreadgroup, num_chunks);
            [encoder dispatchThreadgroups:MTLSizeMake((num_chunks + tpg - 1) / tpg, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(tpg, 1, 1)];
            [encoder endEncoding];
        }

        // Pass 2: Create string mask (depends on pass 1)
        {
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            [encoder setComputePipelineState:ctx->pipeline_string_mask];
            [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:0];
            [encoder setBuffer:ctx->quote_carry_buffer offset:0 atIndex:1];
            [encoder setBytes:&num_chunks length:sizeof(num_chunks) atIndex:2];

            NSUInteger tpg = MIN(ctx->pipeline_string_mask.maxTotalThreadsPerThreadgroup, num_chunks);
            [encoder dispatchThreadgroups:MTLSizeMake((num_chunks + tpg - 1) / tpg, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(tpg, 1, 1)];
            [encoder endEncoding];
        }

        // Pass 3: Extract structural positions (depends on pass 2)
        {
            // Reset atomic counter
            uint32_t zero = 0;
            memcpy(ctx->atomic_counter_buffer.contents, &zero, sizeof(zero));

            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            [encoder setComputePipelineState:ctx->pipeline_extract_structural];
            [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
            [encoder setBuffer:ctx->quote_bits_buffer offset:0 atIndex:1];
            [encoder setBuffer:ctx->structural_pos_buffer offset:0 atIndex:2];
            [encoder setBuffer:ctx->structural_char_buffer offset:0 atIndex:3];
            [encoder setBuffer:ctx->atomic_counter_buffer offset:0 atIndex:4];
            [encoder setBytes:&size length:sizeof(size) atIndex:5];

            NSUInteger tpg = MIN(ctx->pipeline_extract_structural.maxTotalThreadsPerThreadgroup, (NSUInteger)size);
            [encoder dispatchThreadgroups:MTLSizeMake((size + tpg - 1) / tpg, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(tpg, 1, 1)];
            [encoder endEncoding];
        }

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            fprintf(stderr, "metal_json_full_stage1: GPU execution failed: %s\n",
                    commandBuffer.error.localizedDescription.UTF8String);
            return -1;
        }

        // Copy results back
        memcpy(output_count, ctx->atomic_counter_buffer.contents, sizeof(uint32_t));
        if (*output_count > 0) {
            memcpy(output_pos, ctx->structural_pos_buffer.contents, *output_count * sizeof(uint32_t));
            memcpy(output_chars, ctx->structural_char_buffer.contents, *output_count);
        }

        return 0;
    }
}

/**
 * Check if GpJSON pipeline is available.
 */
int metal_json_has_gpjson_pipeline(MetalContext* ctx) {
    if (!ctx) return 0;
    return (ctx->pipeline_quote_bitmap &&
            ctx->pipeline_string_mask &&
            ctx->pipeline_extract_structural) ? 1 : 0;
}

// =============================================================================
// Fused Kernel (Single-Pass Structural Extraction)
// =============================================================================

/**
 * Fused single-pass structural extraction.
 *
 * Combines quote bitmap + prefix-XOR + extraction into ONE kernel dispatch.
 * Eliminates 2 kernel dispatches and 2 memory round-trips.
 *
 * @param ctx Context
 * @param input Input JSON bytes
 * @param size Input size
 * @param output_pos Output: structural positions
 * @param output_chars Output: structural characters
 * @param output_count Output: number found
 * @return 0 on success, -1 on failure
 */
int metal_json_fused_extract(MetalContext* ctx,
                             const uint8_t* input,
                             uint32_t size,
                             uint32_t* output_pos,
                             uint8_t* output_chars,
                             uint32_t* output_count) {
    @autoreleasepool {
        if (!ctx || !input || size == 0) {
            return -1;
        }

        // Get fused pipeline (create on first use)
        static id<MTLComputePipelineState> fused_pipeline = nil;
        if (!fused_pipeline) {
            NSError* error = nil;
            id<MTLFunction> func = [ctx->library newFunctionWithName:@"fused_structural_extract"];
            if (!func) {
                fprintf(stderr, "metal_json_fused_extract: Fused kernel not found\n");
                return -1;
            }
            fused_pipeline = [ctx->device newComputePipelineStateWithFunction:func error:&error];
            if (!fused_pipeline) {
                fprintf(stderr, "metal_json_fused_extract: Failed to create pipeline: %s\n",
                        error.localizedDescription.UTF8String);
                return -1;
            }
        }

        ensure_buffers(ctx, size);
        ensure_gpjson_buffers(ctx, size);

        uint32_t num_chunks = (size + 63) / 64;

        // Copy input
        memcpy(ctx->input_buffer.contents, input, size);

        // Reset atomic counter
        uint32_t zero = 0;
        memcpy(ctx->atomic_counter_buffer.contents, &zero, sizeof(zero));

        id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:fused_pipeline];
        [encoder setBuffer:ctx->input_buffer offset:0 atIndex:0];
        [encoder setBuffer:ctx->structural_pos_buffer offset:0 atIndex:1];
        [encoder setBuffer:ctx->structural_char_buffer offset:0 atIndex:2];
        [encoder setBuffer:ctx->atomic_counter_buffer offset:0 atIndex:3];
        [encoder setBuffer:ctx->quote_carry_buffer offset:0 atIndex:4];  // Reuse for carry
        [encoder setBytes:&size length:sizeof(size) atIndex:5];

        // Each thread processes 64 bytes (one chunk)
        NSUInteger threadsPerGroup = MIN(fused_pipeline.maxTotalThreadsPerThreadgroup, num_chunks);
        NSUInteger numGroups = (num_chunks + threadsPerGroup - 1) / threadsPerGroup;

        [encoder dispatchThreadgroups:MTLSizeMake(numGroups, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error) {
            fprintf(stderr, "metal_json_fused_extract: GPU execution failed: %s\n",
                    commandBuffer.error.localizedDescription.UTF8String);
            return -1;
        }

        // Copy results
        memcpy(output_count, ctx->atomic_counter_buffer.contents, sizeof(uint32_t));
        if (*output_count > 0) {
            memcpy(output_pos, ctx->structural_pos_buffer.contents, *output_count * sizeof(uint32_t));
            memcpy(output_chars, ctx->structural_char_buffer.contents, *output_count);
        }

        return 0;
    }
}

/**
 * Check if fused kernel is available.
 */
int metal_json_has_fused_kernel(MetalContext* ctx) {
    if (!ctx || !ctx->library) return 0;
    id<MTLFunction> func = [ctx->library newFunctionWithName:@"fused_structural_extract"];
    return func != nil;
}
