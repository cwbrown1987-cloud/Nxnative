// Render enable (OP_RENDER_EN): production mtl_exec with the store lookahead index on.
// Tears of the Kingdom clears each render target under "flag != 0" and then reports a timestamp onto the flag, so a target is cleared at most once per frame;
// when the host treated the condition as "always", its second half-resolution lighting pass wiped the first pass's lighting and the deferred-lit scene came out black.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }   // shader keys from hle_nvn.c: this test does not link it
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t n = 1ull << 40; return ++n; }   // hle_nvn.c is not linked
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w=(want), g=(got); count++; printf("%s 期望 %llu → 真结果 %llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(void) { static uint64_t s=9500; tex_t t={.magic=MAGIC('T', 'E', 'X', 0), .serial=s++}; t.off=(int64_t)t.serial<<16;   /* distinct offsets: without storage, textures with equal pool / offset / description share one host texture */
    t.d.width=t.d.height=8; t.d.depth=t.d.samples=t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t; }
static void set_rt(chain *c, const tex_t *a) { p_set_rt r={.n=1}; r.color[0]=a; emit(c,OP_SET_RT,&r,sizeof r); p_viewports v={.n=1}; v.v[0][2]=v.v[0][3]=8; emit(c,OP_VIEWPORTS,&v,sizeof v); p_scissor sc={0,0,8,8}; emit(c,OP_SCISSOR,&sc,sizeof sc); }
static void clear_color(chain *c, float r, float g, float b) { p_clear_color x={.index=0,.mask=15,.rgba={r,g,b,1}}; emit(c,OP_CLEAR_COLOR,&x,sizeof x); }
static void render_en(chain *c, int mode, const void *addr) { p_render_en e={mode,0,(uint64_t)(uintptr_t)addr}; emit(c,OP_RENDER_EN,&e,sizeof e); }
static void report(chain *c, uint64_t type, const void *addr) { uint64_t x[2]={type,(uint64_t)(uintptr_t)addr}; emit(c,OP_REPORT_COUNTER,x,sizeof x); }
static void ds_off(chain *c) { ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP}; p_bind_state x={.kind=5}; memcpy(x.bytes,&d,sizeof d); emit(c,OP_BIND_STATE,&x,sizeof x); }
static prog_t g_cpg;
static void draw_red(chain *c) { p_bind_program b={&g_cpg,3}; emit(c,OP_BIND_PROGRAM,&b,sizeof b); ds_off(c); p_draw d={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; emit(c,OP_DRAW,&d,sizeof d); }
static void draw_corner(chain *c) { p_scissor sc={7,7,1,1}; emit(c,OP_SCISSOR,&sc,sizeof sc); draw_red(c); sc=(p_scissor){0,0,8,8}; emit(c,OP_SCISSOR,&sc,sizeof sc); }   // Opens the pass but leaves pixel (0, 0) as it was
static void setup_prog(void) {
    NSError *e=nil; id<MTLLibrary> l=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\nfragment float4 red(){return float4(1,0,0,1);}\n" options:nil error:&e];
    if(!l){fprintf(stderr,"%s\n",e.localizedDescription.UTF8String);abort();}
    g_cpg.serial=8600; NvProg *p=[NvProg new]; p->sh[0]=[NvShader new]; p->sh[0]->fn=[l newFunctionWithName:@"v"]; p->sh[1]=[NvShader new]; p->sh[1]->stage=1; p->sh[1]->fn=[l newFunctionWithName:@"red"];
    static NvProg *keep; keep=p; serial_put(g_cpg.serial,p);
}
static uint32_t run(chain *c, const tex_t *t) {   // Replays the chain as one submission (with the store lookahead index), returns the first pixel of t as RGBA8
    emit(c,OP_END,NULL,0); state_reset(); memset(&R,0,sizeof R); vis_clear(); g_vis_on=g_vis_counting=0;
    mtl_sub_begin(); uint64_t hh=(uint64_t)c->p; mtl_sub_index(&hh,1); mtl_exec(c->p);
    id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    uint64_t f=mtl_sub_commit(); EXPECT("提交完成",1,mtl_wait(f,5000000000ull)); EXPECT("提交反馈无错误",0,mtl_last_commit_error());
    uint32_t px; memcpy(&px,b.contents,4); return px;
}
enum { RED = 0xff0000ffu, BLUE = 0xffff0000u, GREEN = 0xff00ff00u };
// Clear-once: pass 1 clears A under the flag and reports a timestamp onto it, draws red; pass 2 (after another target) clears A to blue under the same flag
// and only draws a corner pixel. The report writes counter 0 = the reference at +16, so the second clear must be skipped, and pass 1's result must still be
// stored (the later conditional clear must not make its store redundant): pixel (0, 0) stays red
static uint32_t clear_once(int report_flag, uint64_t *flag) {
    tex_t a=tex(), mid=tex(); chain c=chain_new(); flag[0]=1; flag[1]=0; flag[2]=0; flag[3]=0;
    set_rt(&c,&a); render_en(&c,REN_IF_NOT_EQUAL,flag); clear_color(&c,0,0,0); if(report_flag) report(&c,NVN_COUNTER_TYPE_TIMESTAMP_TOP,flag); render_en(&c,REN_ALWAYS,NULL); draw_red(&c);
    set_rt(&c,&mid); clear_color(&c,0,0,0); draw_red(&c);
    set_rt(&c,&a); render_en(&c,REN_IF_NOT_EQUAL,flag); clear_color(&c,0,0,1); if(report_flag) report(&c,NVN_COUNTER_TYPE_TIMESTAMP_TOP,flag); render_en(&c,REN_ALWAYS,NULL); draw_corner(&c);
    set_rt(&c,&mid); draw_red(&c);
    return run(&c,&a);
}
int main(void){@autoreleasepool{
    setvbuf(stdout,NULL,_IONBF,0); setenv("DM_NVN_TBDR","1",1); mtl_init(); setup_prog();
    static uint64_t flag[4] __attribute__((aligned(16)));
    EXPECT("同一帧第二次条件清除被跳过：保留第一个通道画的红色",RED,clear_once(1,flag));
    EXPECT("计时报告写回：计数字段为 0",0,flag[0]);
    EXPECT("不报计时（标记一直不等）：两次清除都做，最后是蓝色",BLUE,clear_once(0,flag));
    {   // Never: the clear at the start of the next pass is skipped
        tex_t a=tex(), b=tex(); chain c=chain_new(); set_rt(&c,&a); clear_color(&c,0,1,0); draw_red(&c); set_rt(&c,&b); draw_red(&c);
        set_rt(&c,&a); render_en(&c,REN_NEVER,NULL); clear_color(&c,0,0,1); render_en(&c,REN_ALWAYS,NULL); draw_corner(&c);
        set_rt(&c,&b); draw_red(&c);
        EXPECT("恒不画：其间的清除不做，保留红色",RED,run(&c,&a)); }
    {   // A samples-passed result not out yet: memory says "equal" (would skip), but the report is in this submission, so draw
        static uint64_t q[4] __attribute__((aligned(16))); q[0]=7; q[1]=0; q[2]=7; q[3]=0;
        tex_t a=tex(); chain c=chain_new(); uint64_t t=NVN_COUNTER_TYPE_SAMPLES_PASSED; emit(&c,OP_RESET_COUNTER,&t,sizeof t);
        set_rt(&c,&a); clear_color(&c,0,1,0); draw_corner(&c); report(&c,NVN_COUNTER_TYPE_SAMPLES_PASSED,q);
        render_en(&c,REN_IF_NOT_EQUAL,q); draw_red(&c); render_en(&c,REN_ALWAYS,NULL);
        tex_t b=tex(); set_rt(&c,&b); draw_red(&c);
        EXPECT("样本数未出：照画（红）",RED,run(&c,&a)); }
    printf("== %d 项，失败 %d ==\n",count,fail); return fail!=0; }}
