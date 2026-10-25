// What Super Mario 64 (Super Mario 3D All-Stars) needed from the Vulkan layer: vkCmdClearColorImage / vkCmdClearDepthStencilImage clear the image (they were stubs, and the title's
// Mario head and logo failed their depth test against old values), the dynamic stencil masks pick a depth-stencil state of their own, specialization constants specialize the
// Metal function, and a linear R4G4 image (no Metal format) is sampled as RG8 converted from its memory at each submit
#include "../vk/hle_vk.m"
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void dm_vi_layer_crop(int c[4]) { c[0] = c[1] = c[2] = c[3] = 0; }
int dm_opmode(void) { return 1; }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)

static VkImage image(VkFormat f, VkImageUsageFlags u, VkImageTiling t, uint32_t w, uint32_t h) {
    VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = f, .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = 1,
                            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = t, .usage = u};
    VkImage im = NULL; h_vkCreateImage(&g_device, &ci, NULL, &im); return im;
}
static VkCommandBuffer cmdbuf(void) {
    static VkCommandPool pool; if (!pool) { VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; h_vkCreateCommandPool(&g_device, &pci, NULL, &pool); }
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer cb; h_vkAllocateCommandBuffers(&g_device, &ai, &cb); return cb;
}
static void run(VkCommandBuffer c) {   // replays one command buffer as vkQueueSubmit does and waits for it
    @autoreleasepool {
        rs_t s = {0}; s.cb = [g_q commandBuffer]; replay(&s, c); end_rp(&s, 1); end_blit(&s);
        [s.cb commit]; [s.cb waitUntilCompleted];
        CHECK(s.cb.status == MTLCommandBufferStatusCompleted, "the replayed commands completed");
    }
}
static void read_back(id<MTLTexture> t, void *out, NSUInteger bpr, NSUInteger h) {   // a private texture through a shared one
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> sh = [g_dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t toTexture:sh]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    [sh getBytes:out bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
    (void)h;
}

int main(void) {
    @autoreleasepool {
        dev_init();
        // Colour clear: an image with transfer-destination usage only gets render-target usage, and the clear reaches every texel
        VkImage col = image(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_IMAGE_TILING_OPTIMAL, 8, 4);
        CHECK(col && (col->tex.usage & MTLTextureUsageRenderTarget), "a transfer-destination image can be cleared");
        VkCommandBuffer cb = cmdbuf();
        VkClearColorValue cv = {.float32 = {1, 0, 0.5f, 1}}; VkImageSubresourceRange cr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0, VK_REMAINING_ARRAY_LAYERS};
        h_vkCmdClearColorImage(cb, col, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cv, 1, &cr);
        // Depth-stencil clear of the depth aspect only: depth becomes 0.25, the stencil keeps what an earlier clear wrote
        VkImage dsi = image(VK_FORMAT_D32_SFLOAT_S8_UINT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_TILING_OPTIMAL, 4, 4);
        VkClearDepthStencilValue dv = {1.0f, 7}; VkImageSubresourceRange both = {VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT, 0, 1, 0, 1};
        h_vkCmdClearDepthStencilImage(cb, dsi, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dv, 1, &both);
        VkClearDepthStencilValue dv2 = {0.25f, 99}; VkImageSubresourceRange donly = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
        h_vkCmdClearDepthStencilImage(cb, dsi, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dv2, 1, &donly);
        run(cb);
        uint8_t px[8 * 4 * 4]; read_back(col->tex, px, 8 * 4, 4);
        int ok = 1; for (int i = 0; i < 32; i++) ok &= px[4 * i] == 255 && px[4 * i + 1] == 0 && (px[4 * i + 2] == 127 || px[4 * i + 2] == 128) && px[4 * i + 3] == 255;
        CHECK(ok, "vkCmdClearColorImage filled the image");
        @autoreleasepool {   // depth and stencil read back plane by plane
            id<MTLBuffer> db = [g_dev newBufferWithLength:4 * 4 * 4 options:MTLResourceStorageModeShared], sb = [g_dev newBufferWithLength:4 * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
            [b copyFromTexture:dsi->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:db destinationOffset:0
                destinationBytesPerRow:16 destinationBytesPerImage:64 options:MTLBlitOptionDepthFromDepthStencil];
            [b copyFromTexture:dsi->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:sb destinationOffset:0
                destinationBytesPerRow:4 destinationBytesPerImage:16 options:MTLBlitOptionStencilFromDepthStencil];
            [b endEncoding]; [c commit]; [c waitUntilCompleted];
            const float *d = db.contents; const uint8_t *st = sb.contents; int dok = 1, sok = 1;
            for (int i = 0; i < 16; i++) { dok &= d[i] == 0.25f; sok &= st[i] == 7; }
            CHECK(dok, "the depth aspect was cleared to 0.25");
            CHECK(sok, "a depth-only clear kept the stencil the earlier clear wrote");
        }

        // Dynamic stencil masks: one depth-stencil state per mask combination, the same one again for the same masks
        VkPipeline p = zalloc(sizeof *p); p->dyn_scm = p->dyn_swm = 1;
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.frontFaceStencil = [MTLStencilDescriptor new]; dd.backFaceStencil = [MTLStencilDescriptor new]; p->dsd = dd;
        rs_t s = {0}; s.sten[0][0] = s.sten[0][1] = 0xff; s.sten[1][0] = s.sten[1][1] = 0x0f;
        id<MTLDepthStencilState> a = dss_of(&s, p), a2 = dss_of(&s, p);
        s.sten[1][0] = 0xf0; id<MTLDepthStencilState> bst = dss_of(&s, p);
        CHECK(a && a == a2 && bst && bst != a && p->dss_masks.count == 2, "dynamic stencil masks: one state per combination");
        p->dss_masks = nil; p->dsd = nil; free(p);

        // Specialization constants: a fragment function with an int function constant, specialized to two values, gives two functions, each kept per data
        NSError *err = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nconstant int k_tmp [[function_constant(0)]];\n"
                                                          "constant int k = is_function_constant_defined(k_tmp) ? k_tmp : 0;\nfragment float4 vk_spec() { return float4(k); }\n" options:nil error:&err];
        CHECK(lib, "test library compiles");
        g_lib = lib;
        struct VkShaderModule_T mod = {0}; mod.fn = [lib newFunctionWithName:@"vk_spec"];
        int v3 = 3, v5 = 5;
        VkSpecializationMapEntry me = {0, 0, 4};
        VkSpecializationInfo s3 = {1, &me, 4, &v3}, s5 = {1, &me, 4, &v5};
        id<MTLFunction> f3 = spec_fn(&mod, mod.fn, &s3), f3b = spec_fn(&mod, mod.fn, &s3), f5 = spec_fn(&mod, mod.fn, &s5);
        CHECK(f3 && f3 != mod.fn && f3 == f3b && f5 && f5 != f3, "specialized functions are made once per constant data");
        CHECK(spec_fn(&mod, mod.fn, NULL) == mod.fn, "no specialization data: the function itself");
        mod.fn = nil; mod.spec = nil;

        // A linear R4G4 image: RG8 in Metal, refreshed from its memory when the bytes change
        VkImage rg = image(VK_FORMAT_R4G4_UNORM_PACK8, VK_IMAGE_USAGE_SAMPLED_BIT, VK_IMAGE_TILING_LINEAR, 2, 2);
        CHECK(rg && rg->pitch, "linear R4G4 image created");
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = 4096, .memoryTypeIndex = 1};
        VkDeviceMemory mem; h_vkAllocateMemory(&g_device, &mai, NULL, &mem);
        CHECK(h_vkBindImageMemory(&g_device, rg, mem, 256) == VK_SUCCESS && rg->tex.pixelFormat == MTLPixelFormatRG8Unorm, "bound as an RG8 texture of its own");
        uint8_t *m = (uint8_t *)mem_buf(mem).contents + 256;
        m[0] = 0xf0; m[1] = 0x0f; m[rg->pitch] = 0x84; m[rg->pitch + 1] = 0x00;
        conv_refresh();
        uint8_t t[2 * 2 * 2]; [rg->tex getBytes:t bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
        CHECK(t[0] == 255 && t[1] == 0 && t[2] == 0 && t[3] == 255 && t[4] == 0x88 && t[5] == 0x44 && t[6] == 0 && t[7] == 0, "R4G4 → RG8, high nibble red");
        m[1] = 0x50; conv_refresh(); [rg->tex getBytes:t bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
        CHECK(t[2] == 0x55 && t[3] == 0, "a changed byte is converted again at the next submit");
        h_vkDestroyImage(&g_device, rg, NULL);
        CHECK(g_nconv == 0, "a destroyed image leaves the conversion list");
    }
    printf("t_vk_clear: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
