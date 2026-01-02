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

    // Reusable buffers (for repeated calls with same size)
    id<MTLBuffer> input_buffer;
    id<MTLBuffer> output_buffer;
    uint32_t buffer_size;
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
