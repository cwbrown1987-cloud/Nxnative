// Production ClearTexture: preserve channels and texels outside its explicit mask / region.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

int main(void) { @autoreleasepool {
    mtl_init();
    id<MTLCommandQueue> q = [g_dev newCommandQueue];
    struct { MTLPixelFormat pf; int mask, x, y, w, h, uints, level, slice; const char *label; } cases[] = {
        {MTLPixelFormatRGBA8Unorm,8,0,0,8,8,0,0,0,"alpha-only whole level"},
        {MTLPixelFormatRGBA8Unorm,2,2,1,3,2,0,0,0,"green-only subrectangle"},
        {MTLPixelFormatRGBA8Uint,5,1,2,4,3,1,0,0,"unsigned integer red / blue"},
        {MTLPixelFormatRGBA8Sint,10,0,0,8,8,1,0,0,"signed integer green / alpha"},
        {MTLPixelFormatRGBA8Unorm,8,0,0,4,4,0,1,1,"mip and array-layer view"}
    };
    for (unsigned i=0;i<sizeof cases/sizeof cases[0];i++) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[i].pf width:8 height:8 mipmapped:YES];
        td.textureType=MTLTextureType2DArray; td.arrayLength=2; td.storageMode=MTLStorageModePrivate;
        td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        id<MTLTexture> base=[g_dev newTextureWithDescriptor:td]; CHECK(base!=nil,"test target allocated"); if (!base) return 1;
        id<MTLCommandBuffer> cb=[q commandBuffer];
        for (unsigned l=0;l<td.mipmapLevelCount;l++) for (unsigned a=0;a<2;a++) {
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture=base; rp.colorAttachments[0].level=l; rp.colorAttachments[0].slice=a;
            rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
            rp.colorAttachments[0].clearColor=cases[i].uints?MTLClearColorMake(20,40,60,80):MTLClearColorMake(20./255,40./255,60./255,80./255);
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status==MTLCommandBufferStatusCompleted,"initial contents reach GPU");
        tex_t t={.magic=MAGIC('T','E','X',0), .serial=99501+i}; t.d.samples=1; t.d.width=t.d.height=8; t.d.depth=2; t.d.target=7; t.d.levels=4; t.d.format=0x25; t.d.flags=8;
        res_add(base); mtl_tex_init(&t); serial_put(t.serial,base);
        state_reset(); memset(&R,0,sizeof R); mtl_sub_begin(); R.has_sc=1; R.sc=(p_scissor){7,7,1,1};
        struct { op_hdr head; p_clear_tex clear; op_hdr end; } ops={0};
        ops.head=(op_hdr){OP_CLEAR_TEX,sizeof(op_hdr)+sizeof(p_clear_tex)}; ops.end=(op_hdr){OP_END,sizeof(op_hdr)};
        p_clear_tex *c=&ops.clear; c->tex=&t; c->mask=cases[i].mask; c->is_uint=cases[i].uints;
        c->r=(NVNcopyRegion){cases[i].x,cases[i].y,0,cases[i].w,cases[i].h,1};
        c->has_view=1; c->view.set_levels=c->view.set_layers=1; c->view.base_level=cases[i].level; c->view.min_layer=cases[i].slice;
        for (int k=0;k<4;k++) if (c->is_uint) c->c.u[k]=k+1; else c->c.f[k]=1;
        mtl_exec((const uint8_t *)&ops); mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(),"production clear completes without GPU error");
        int valid=1;
        for (unsigned l=0;l<td.mipmapLevelCount;l++) for (unsigned a=0;a<2;a++) {
            unsigned w=8>>l; id<MTLBuffer> out=[g_dev newBufferWithLength:256*w options:MTLResourceStorageModeShared];
            cb=[q commandBuffer]; id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
            [bl copyFromTexture:base sourceSlice:a sourceLevel:l sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,w,1)
                toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*w];
            [bl endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status==MTLCommandBufferStatusCompleted,"result readback completes");
            const uint8_t *bytes=out.contents;
            for (unsigned y=0;y<w;y++) for (unsigned x=0;x<w;x++) for (int k=0;k<4;k++) {
                int inside=l==(unsigned)cases[i].level && a==(unsigned)cases[i].slice && x>=(unsigned)cases[i].x && y>=(unsigned)cases[i].y && x<(unsigned)(cases[i].x+cases[i].w) && y<(unsigned)(cases[i].y+cases[i].h);
                uint8_t want=inside&&(cases[i].mask&(1<<k))?(cases[i].uints?k+1:255):(k+1)*20;
                valid &= bytes[y*256+x*4+k]==want;
            }
        }
        CHECK(valid,cases[i].label); mtl_tex_release(&t);
    }
    printf("texture region / channel clears: %d checks, %d failed\n",checks,failed); return failed!=0;
} }
