// A Depth16Unorm load-clear with nvn_depth16_clear_value(d) stores the value a fragment writing depth d stores, for 1,000 depths across [0, 1] and the halves and thirds
// that sit on a bin edge (nvn_depth_clear.h). Expectations come from the GPU itself: the fragment's stored value is the reference. The raw clear value is counted too,
// to show how often the plain load-clear differs on this GPU (no failure either way)
#import <Metal/Metal.h>
#include <stdio.h>
#include "../nvn/nvn_depth_clear.h"

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { puts("t_depth16_clear: no Metal device, skipped"); return 0; }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); return { float4(q * 2 - 1, 0, 1) }; }\n"
        "struct F { float d [[depth(any)]]; };\n"
        "fragment F fs(constant float &d [[buffer(0)]]) { return { d }; }\n" options:nil error:&err];
    if (!lib) { printf("t_depth16_clear: shader compile failed: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    if (!ps || !ds) { printf("t_depth16_clear: pipeline failed: %s\n", err.localizedDescription.UTF8String); return 1; }
    enum { N = 1000 + 6, W = 8, H = 8 };
    double depth[N];
    for (int i = 0; i < 1000; i++) depth[i] = i / 999.0;
    const double extra[6] = {0.5, 0.25, 0.75, 1.0 / 3, 2.0 / 3, 32767.5 / 65535};
    for (int i = 0; i < 6; i++) depth[1000 + i] = extra[i];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:W height:H mipmapped:NO];
    td.textureType = MTLTextureType2DArray; td.arrayLength = N; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex[3] = {[dev newTextureWithDescriptor:td], [dev newTextureWithDescriptor:td], [dev newTextureWithDescriptor:td]};   // fragment, fixed clear, raw clear
    id<MTLBuffer> out = [dev newBufferWithLength:(size_t)3 * N * W * H * 2 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    for (int i = 0; i < N; i++) for (int k = 0; k < 3; k++) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = tex[k]; rp.depthAttachment.slice = (NSUInteger)i; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.depthAttachment.clearDepth = k == 0 ? 1.0 : k == 1 ? nvn_depth16_clear_value(depth[i]) : depth[i];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        if (k == 0) { float d = (float)depth[i]; [e setRenderPipelineState:ps]; [e setDepthStencilState:ds]; [e setFragmentBytes:&d length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
        [e endEncoding];
    }
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    for (int k = 0; k < 3; k++) for (int i = 0; i < N; i++)
        [b copyFromTexture:tex[k] sourceSlice:(NSUInteger)i sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                  toBuffer:out destinationOffset:((size_t)k * N + i) * W * H * 2 destinationBytesPerRow:W * 2 destinationBytesPerImage:W * H * 2];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("t_depth16_clear: command buffer failed: %s\n", cb.error.localizedDescription.UTF8String); return 1; }
    const uint16_t *v = out.contents;
    int fail = 0, raw_off = 0;
    for (int i = 0; i < N; i++) {
        const uint16_t *f = v + (size_t)i * W * H, *c = v + ((size_t)N + i) * W * H, *r = v + ((size_t)2 * N + i) * W * H;
        int bad = 0, roff = 0;
        for (int p = 0; p < W * H; p++) { bad |= c[p] != f[p]; roff |= r[p] != f[p]; }
        raw_off += roff;
        if (bad && fail++ < 10) printf("  depth %.9f: fragment %u, clear %u (raw clear %u)\n", depth[i], f[0], c[0], r[0]);
    }
    printf("t_depth16_clear: %d depths, fixed clear differs from the fragment in %d, the raw clear in %d (0.5: fragment %u, raw clear %u)\n",
           N, fail, raw_off, v[(size_t)1000 * W * H], v[((size_t)2 * N + 1000) * W * H]);
    return fail != 0;
} }
