#include "../nvn/nvn_mtl.m"

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

int main(void) {
    int failed = 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatR32Uint) != 1;
    tex_t t = {.magic=MAGIC('T', 'E', 'X', 0), .serial = 70001};
    t.d.width = 4; t.d.height = 1; t.d.depth = 1; t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    mtl_init();
    MTLTextureDescriptor *d = tex_desc(&t, 0);
    failed += (d.usage & MTLTextureUsagePixelFormatView) != 0;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
    uint8_t bytes[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    id<MTLBuffer> src = [g_dev newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModeShared];
    mtl_sub_begin();
    res_add(src); res_add(base);   // Metal 4: both ends of a copy must be in the residency set
    id fill = blit();   // copies on the main command buffer go through the host wrapper (which carries its own barrier)
    [fill copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:16 sourceSize:MTLSizeMake(4, 1, 1)
               toTexture:base destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    enc_b_end(g_blit); g_blit = nil;
    serial_put(t.serial, base);
    id<MTLTexture> upgraded = tex_upgrade_pfv(&t, base, MTLPixelFormatR32Uint);
    failed += upgraded.pixelFormat != MTLPixelFormatRGBA8Unorm;   // the upgrade keeps the original format
    failed += !(upgraded.usage & MTLTextureUsagePixelFormatView);
    failed += serial_get(t.serial) != upgraded;   // the registration has been replaced
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTLTexture> view = [upgraded newTextureViewWithPixelFormat:MTLPixelFormatR32Uint];
    id<MTLBuffer> dst = [g_dev newBufferWithLength:sizeof bytes options:MTLResourceStorageModeShared];
    res_add(dst);
    id read = blit();
    [read copyFromTexture:view sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 1, 1)
                 toBuffer:dst destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    enc_b_end(g_blit); g_blit = nil;
    mtl_sub_commit(); mtl_drain();
    failed += memcmp(dst.contents, bytes, sizeof bytes) != 0;
    // A load-only image is legal on a ShaderRead texture; a write image must still be rejected.
    tex_t ro = {.magic=MAGIC('T','E','X',0), .serial=70002};
    ro.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_R32UI,.width=4,.height=1,.depth=1,.levels=1};
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:1 mipmapped:NO];
    rd.usage=MTLTextureUsageShaderRead; rd.storageMode=MTLStorageModeShared;
    id<MTLTexture> readonly=[g_dev newTextureWithDescriptor:rd];
    mtl_tex_init(&ro); tex_put(ro.serial, readonly); mtl_reg_tex(1001,&ro,NULL);
    nvn_rbind rb={.kind=NVN_RB_IMG,.dtt=MTLTextureType2D,.dpf=NVN_DPF_UINT};
    uint64_t rid=0; int real=0;
    failed += img_binding(1001,&rb,&rid,&real)!=readonly || !real;
    rb.rw=1; img_binding(1001,&rb,&rid,&real); failed += real!=0;
    // SPIRV-Cross emits a read-only texture_buffer beside its separate atomic pointer. Keep that real view.
    tex_t tb=ro; tb.serial++; tb.d.target=NVN_TEXTURE_TARGET_BUFFER;
    id<MTLBuffer> backing=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *bd=[MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 resourceOptions:backing.resourceOptions usage:MTLTextureUsageShaderRead];
    id<MTLTexture> bt=[backing newTextureWithDescriptor:bd offset:0 bytesPerRow:256];
    mtl_tex_init(&tb); tex_put(tb.serial,bt); mtl_reg_tex(1002,&tb,NULL); rb.rw=0; rb.dtt=MTLTextureTypeTextureBuffer;
    failed += img_binding(1002,&rb,&rid,&real)!=bt || !real;
    uint32_t sentinel=0x12345678; memcpy(backing.contents,&sentinel,sizeof sentinel);
    rb.rw=1; id<MTLTexture> writable=img_binding(1002,&rb,&rid,&real);
    failed += !real || !(writable.usage & MTLTextureUsageShaderWrite);
    failed += writable.buffer!=backing || writable.bufferOffset!=bt.bufferOffset;
    failed += *(uint32_t *)backing.contents!=sentinel;
    failed += serial_get(tb.serial)!=writable || rid!=writable.gpuResourceID._impl;
    // A later atomic/read binding must retain the upgraded view and same pool.
    rb.rw=0; failed += img_binding(1002,&rb,&rid,&real)!=writable || !real;
    // Exercise an actual GPU store through the upgraded view, then read the pool.
    NSError *store_error=nil;
    id<MTLLibrary> store_lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void clear_hist(texture_buffer<uint,access::write> t [[texture(0)]], uint i [[thread_position_in_grid]]) { t.write(uint4(0),i); }" options:nil error:&store_error];
    id<MTLComputePipelineState> store_ps=[g_dev newComputePipelineStateWithFunction:[store_lib newFunctionWithName:@"clear_hist"] error:&store_error];
    failed += store_ps==nil;
    if (store_ps) {
        memset(backing.contents,0x7f,16);
        id<MTLCommandQueue> sq=[g_dev newCommandQueue];
        id<MTLCommandBuffer> sc=[sq commandBuffer];
        id<MTLComputeCommandEncoder> se=[sc computeCommandEncoder];
        [se setComputePipelineState:store_ps]; [se setTexture:writable atIndex:0];
        [se dispatchThreads:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
        [se endEncoding]; [sc commit]; [sc waitUntilCompleted];
        failed += sc.status!=MTLCommandBufferStatusCompleted;
        uint32_t zeros[4]={0}; failed += memcmp(backing.contents,zeros,sizeof zeros)!=0;
    }
    // The pre-dispatch path upgrades a tiled output before any compute encoder.
    NvShader *writer=[NvShader new]; writer->rf.nb=1;
    writer->rf.b[0]=(nvn_rbind){.kind=NVN_RB_IMG,.rw=1,.reg=3,.dtt=MTLTextureType2D,.dpf=NVN_DPF_UINT};
    uint32_t image_values[4]={7,11,13,17};
    [readonly replaceRegion:MTLRegionMake2D(0,0,4,1) mipmapLevel:0 withBytes:image_values bytesPerRow:16];
    mtl_sub_begin(); S.img[5][3]=1001; img_prepare(writer,5);
    rb=(nvn_rbind){.kind=NVN_RB_IMG,.rw=1,.dtt=MTLTextureType2D,.dpf=NVN_DPF_UINT};
    id<MTLTexture> output=img_binding(1001,&rb,&rid,&real);
    failed += !real || !(output.usage & MTLTextureUsageShaderWrite);
    failed += serial_get(ro.serial)!=output;
    if (g_blit) { enc_b_end(g_blit); g_blit=nil; }
    mtl_sub_commit(); mtl_drain();
    uint32_t copied_values[4]={0};
    [output getBytes:copied_values bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,1) mipmapLevel:0];
    failed += memcmp(copied_values,image_values,sizeof image_values)!=0;
    // Attachment use must upgrade a previously read-only texture, as a clear already does.
    mtl_sub_begin();
    MTLRenderPassColorAttachmentDescriptor *att=[MTLRenderPassColorAttachmentDescriptor new];
    attach(att,&ro,NULL,0);
    failed += !(att.texture.usage & MTLTextureUsageRenderTarget);
    failed += serial_get(ro.serial)!=att.texture;
    if (g_blit) { enc_b_end(g_blit); g_blit=nil; }
    mtl_sub_commit(); mtl_drain();
    printf("pfv predicate failed=%d\n", failed);
    return failed != 0;
}
