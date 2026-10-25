#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w=(want), g=(got); count++; printf("%s expected %llu → got %llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(unsigned w) { static uint64_t s=9100; tex_t t={.magic=MAGIC('T', 'E', 'X', 0), .serial =s, .off=(int64_t)(s-9100)<<20}; s++; t.d.width=t.d.height=w; t.d.depth=t.d.samples=1; t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t; }
static int view(const tex_t *t) { static int id=1300; view_t v={.set_levels=1,.base_level=0,.nlevels=1}; mtl_reg_tex(id,t,&v); return id++; }
static void set_rt(chain *c, const tex_t *a) { p_set_rt r={.n=1}; r.color[0]=a; r.has_cview[0]=1; r.cview[0].set_levels=1; r.cview[0].nlevels=1; emit(c,OP_SET_RT,&r,sizeof r); p_viewports v={.n=1};v.v[0][2]=v.v[0][3]=8;emit(c,OP_VIEWPORTS,&v,sizeof v);p_scissor sc={0,0,8,8};emit(c,OP_SCISSOR,&sc,sizeof sc); }
static void bind_prog(chain *c, prog_t *p) { p_bind_program b={p,3}; emit(c,OP_BIND_PROGRAM,&b,sizeof b); }
static void bind_tex(chain *c, int id) { p_bind_handles b={.stage=1,.first=0,.n=1};b.h[0]=id;emit(c,OP_BIND_TEX,&b,sizeof b); }
static void draw_cmd(chain *c) { p_draw d={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; emit(c,OP_DRAW,&d,sizeof d); }
static void ds_off(chain *c) { ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP}; p_bind_state x={.kind=5}; memcpy(x.bytes,&d,sizeof d); emit(c,OP_BIND_STATE,&x,sizeof x); }
static void readback(const tex_t *t, uint8_t out[256]) { id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256]; uint64_t f=mtl_sub_commit(); EXPECT("submit completed",1,mtl_wait(f,5000000000ull)); EXPECT("no error in commit feedback",0,mtl_last_commit_error()); memcpy(out,b.contents,256); }
static NvProg *g_tkeep[256]; static int g_tnkeep;   /* program objects are permanent, as in t_zskip.m: the pipeline cache is keyed by object address */
// pg[0] writes (1,0,0,0.5); pg[1] writes the texel at (0,0) of its texture
static void setup_prog(prog_t *pg) { NSError *e=nil; id<MTLLibrary> l=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\nfragment float4 red(){return float4(1,0,0,0.5);}\nstruct A{texture2d<float> t[[id(0)]];}; fragment float4 sample(constant A&a[[buffer(0)]]){return a.t.read(uint2(0));}\n" options:nil error:&e]; if(!l){fprintf(stderr,"%s\n",e.localizedDescription.UTF8String);abort();} for(int i=0;i<2;i++)pg[i].serial=8100+i; for(int i=0;i<2;i++){NvProg *p=[NvProg new];p->sh[0]=[NvShader new];p->sh[0]->fn=[l newFunctionWithName:@"v"];p->sh[1]=[NvShader new];p->sh[1]->stage=1;p->sh[1]->fn=[l newFunctionWithName:i?@"sample":@"red"];strcpy(p->sh[1]->key,i?"5a5a5a5a5a5a5a5a_b":"7e7e7e7e7e7e7e7e_b");if(i){p->sh[1]->rf.nb=1;p->sh[1]->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.dtt=2};p->sh[1]->ae=[p->sh[1]->fn newArgumentEncoderWithBufferIndex:0];}if(g_tnkeep<256)g_tkeep[g_tnkeep++]=p;serial_put(pg[i].serial,p);} }
static void exec_chain(chain *c) { emit(c,OP_END,NULL,0); state_reset(); memset(&R,0,sizeof R); vis_clear(); g_vis_on=g_vis_counting=0; mtl_sub_begin(); uint64_t hh=(uint64_t)c->p; mtl_sub_index(&hh,1); mtl_exec(c->p); }
static void snap_env(const char *v) { if (v) setenv("DM_NVN_FB_SNAP",v,1); else unsetenv("DM_NVN_FB_SNAP"); g_fb_nk=-1; g_fb_all=g_fb_off=0; }
// Same-pass feedback sampling of an attachment the pass has already written (fb_prepare, g_fb_wrote): on NVN the sample reads what the earlier draw wrote; on Metal the attachment is in tile
// memory until the pass ends, and the texture reads the memory from before the pass (Super Mario 3D All-Stars' launcher: agl's movie gamma draw read zeros and every movie stayed transparent)
// mode 0: one pass draws red into A, then samples A into A (written earlier in the pass: snapshot); 1: as 0 with DM_NVN_FB_SNAP=0 (no snapshot);
// 2: red into A, the submission completes, then a new pass samples A into A as its first draw (memory holds red: no snapshot)
static uint64_t run(int mode, uint8_t px[256]) {
    static prog_t pg[2]; static int ready; if (!ready++) setup_prog(pg);
    tex_t a=tex(8); int aid=view(&a); snap_env(mode==1?"0":NULL);
    chain c=chain_new(); set_rt(&c,&a); ds_off(&c); bind_prog(&c,&pg[0]); draw_cmd(&c);
    if (mode==2) { exec_chain(&c); uint64_t f=mtl_sub_commit(); EXPECT("first submit completed",1,mtl_wait(f,5000000000ull)); c=chain_new(); set_rt(&c,&a); ds_off(&c); }
    uint64_t n0=g_fb_count;
    bind_prog(&c,&pg[1]); bind_tex(&c,aid); draw_cmd(&c); exec_chain(&c);
    uint64_t n=g_fb_count-n0; readback(&a,px); return n;
}
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);setenv("DM_NVN_TBDR","1",1);mtl_init();uint8_t px[256];
    uint64_t n=run(0,px); EXPECT("written earlier in the pass: one snapshot",1,n); EXPECT("written earlier in the pass: the sample read red (R)",255,px[0]); EXPECT("written earlier in the pass: the sample read red (A about 0.5)",1,px[3]>=127&&px[3]<=128);
    n=run(1,px); EXPECT("DM_NVN_FB_SNAP=0: no snapshot",0,n);
    n=run(2,px); EXPECT("first draw of its pass: no snapshot",0,n); EXPECT("first draw of its pass: the sample read red (R)",255,px[0]); EXPECT("first draw of its pass: the sample read red (A about 0.5)",1,px[3]>=127&&px[3]<=128);
    snap_env(NULL); printf("== %d checks, %d failed ==\n",count,fail); return fail!=0; }}
