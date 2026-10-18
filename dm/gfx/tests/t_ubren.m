// Uniform update renaming (DM_NVN_UBREN, see g_ubd in nvn_mtl.m): production mtl_exec, a hand-written shader that outputs its uniform, additive blending, closed-form expectations.
// Run as is (mode 2: deferred across passes too, snapshots of partly covered ranges), with DM_NVN_UBREN=1 (first version: inside a pass only) and with DM_NVN_UBREN=0:
// pixels and guest memory must come out the same in all three; only the render pass count and the renamed / cut / snapshot counters differ.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }   // shader keys come from hle_nvn.c, which this test does not link
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t n = 1ull << 40; return ++n; }   // hle_nvn.c is not linked
static int fail, count, mode;
#define EXPECT(n,w,v) do { uint64_t a_=(w), b_=(v); count++; \
    printf("%s 期望 %#llx → 真结果 %#llx %s\n",n,(unsigned long long)a_,(unsigned long long)b_,a_==b_?"✓":"✗"); fail+=a_!=b_; } while(0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain make_chain(void) { chain c={0}; if(posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) {
    size_t sz=(8+n+7)&~7ull; if(c->n+sz>65536) abort();
    op_hdr h={op,(uint32_t)sz}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=sz;
}
static void state(chain *c, int kind, const void *s, size_t n) { p_bind_state b={.kind=kind}; if(n>sizeof b.bytes) abort(); memcpy(b.bytes,s,n); emit(c,OP_BIND_STATE,&b,sizeof b); }
static tex_t texture(void) {
    static uint64_t ser=7000; tex_t t={.magic=MAGIC('T','E','X',0),.serial=ser++}; t.d.width=t.d.height=8;
    t.d.depth=t.d.samples=1; t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t;
}
static prog_t pg;
static uint8_t *mem;   // guest uniform memory: one page in a pool
static void f4(float *v, int r, int g, int b) { v[0]=r/255.f; v[1]=g/255.f; v[2]=b/255.f; v[3]=0; }
static void put(int off, int r, int g, int b) { float v[4]; f4(v,r,g,b); memcpy(mem+off,v,16); }
static uint64_t rgb(int r, int g, int b) { return (uint64_t)r<<16|(uint64_t)g<<8|(uint64_t)b; }
static uint64_t mem_rgb(int off) { float v[4]; memcpy(v,mem+off,16); for(int k=0;k<4;k++) if(v[k]!=roundf(v[k]*255)/255.f) return ~0ull; return rgb((int)lroundf(v[0]*255),(int)lroundf(v[1]*255),(int)lroundf(v[2]*255)); }
// Target 8×8 cleared to 0, blending ONE + ONE: each draw adds the float4 its fragment shader reads from cb0 of the fragment stage
static void begin(chain *c, const tex_t *t, uint64_t ub, uint64_t ub_size) {
    p_set_rt r={.n=1}; r.color[0]=t; emit(c,OP_SET_RT,&r,sizeof r);
    p_viewports v={.n=1}; v.v[0][2]=v.v[0][3]=8; emit(c,OP_VIEWPORTS,&v,sizeof v);
    p_scissor sc={0,0,8,8}; emit(c,OP_SCISSOR,&sc,sizeof sc);
    p_clear_color cc={.index=0,.mask=15,.rgba={0,0,0,0}}; emit(c,OP_CLEAR_COLOR,&cc,sizeof cc);
    ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,8,8,1,1,1,1,1,1}; state(c,5,&d,sizeof d);
    color_st col={1,NVN_LOGIC_OP_COPY,NVN_ALPHA_FUNC_ALWAYS}; state(c,1,&col,sizeof col);
    blend_st b={0,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ONE,NVN_BLEND_EQUATION_ADD,NVN_BLEND_EQUATION_ADD}; state(c,0,&b,sizeof b);
    p_bind_program bp={&pg,3}; emit(c,OP_BIND_PROGRAM,&bp,sizeof bp);
    p_bind_buf u={.stage=1,.index=0,.addr=ub,.size=ub_size}; emit(c,OP_BIND_UBO,&u,sizeof u);
}
static void draw_cmd(chain *c) { p_draw d={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; emit(c,OP_DRAW,&d,sizeof d); }
static void update(chain *c, const void *dst, const void *data, uint64_t n) {
    struct { uint64_t dst, n; uint8_t data[64]; } u={(uint64_t)dst,n,{0}}; if(n>sizeof u.data) abort(); memcpy(u.data,data,n); emit(c,OP_UPDATE_UB,&u,16+n);
}
typedef struct { uint64_t px, passes, renamed, cuts, lands, snaps; } outcome;
static outcome run(chain *c, const tex_t *t) {
    emit(c,OP_END,NULL,0); state_reset(); memset(&R,0,sizeof R); vis_clear(); g_vis_on=g_vis_counting=0;
    uint64_t p0=g_stat_pass, n0=g_ubd_total, k0=g_ubd_cuts, l0=g_ubd_lands, s0=g_ubm_n;
    mtl_sub_begin(); mtl_exec(c->p);
    id<MTLBuffer> buf=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
      toBuffer:buf destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];   // the readback ends the pass like any copy (renamed updates land first)
    uint64_t f=mtl_sub_commit(); EXPECT("提交完成",1,mtl_wait(f,5000000000ull)); EXPECT("提交反馈无错误",0,mtl_last_commit_error());
    const uint8_t *q=buf.contents; unsigned bad=0; for(int k=1;k<64;k++) bad+=memcmp(q+4*k,q,4)!=0;
    EXPECT("64 像素一致",0,bad); EXPECT("alpha 为 0",0,q[3]);
    outcome o={rgb(q[0],q[1],q[2]),g_stat_pass-p0,g_ubd_total-n0,g_ubd_cuts-k0,g_ubd_lands-l0,g_ubm_n-s0};
    mtl_pool_del(c->p); free(c->p); return o;
}
typedef struct { int passes, renamed, cuts; } want;   // per mode: 2 (default), 1 (first version), 0 (off)
static void counts(const outcome *o, want m2, want m1, want m0) {
    want w=mode==2?m2:mode==1?m1:m0; EXPECT("渲染通道数",w.passes,o->passes); EXPECT("改名次数",w.renamed,o->renamed); EXPECT("被读者切开次数",w.cuts,o->cuts);
}
static void scan(const char *what, const char *msl, const char *name, uint32_t want_len) { EXPECT(what,want_len,msl_cb_len(msl,strlen(msl),name)); }
int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IONBF,0); setenv("DM_NVN_TBDR","0",1);
    const char *e=getenv("DM_NVN_UBREN"); mode=e&&!strcmp(e,"0")?0:e&&!strcmp(e,"1")?1:2; mtl_init();
    NSError *err=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\n"
      "struct U{constant float4 *c [[id(0)]];}; fragment float4 ub(constant U&a [[buffer(0)]]){return *a.c;}\n" options:nil error:&err];
    if(!lib) { fprintf(stderr,"%s\n",err.localizedDescription.UTF8String); return 2; }
    NvProg *p=[NvProg new]; p->sh[0]=[NvShader new]; p->sh[0]->fn=[lib newFunctionWithName:@"v"];
    p->sh[1]=[NvShader new]; NvShader *f=p->sh[1]; f->fn=[lib newFunctionWithName:@"ub"]; f->stage=1;
    f->rf.nb=1; f->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.dtt=2}; f->ae=[f->fn newArgumentEncoderWithBufferIndex:0];
    pg.serial=4100; serial_put(pg.serial,p);
    if(posix_memalign((void **)&mem,getpagesize(),getpagesize())) abort(); memset(mem,0,getpagesize()); mtl_pool_add(mem,getpagesize());
    float g[4],b[4],two[8]; f4(g,0,32,0); f4(b,0,0,64);
    { printf("CASE MSL 里 uniform 的静态读取长度\n"); const char *decl="struct S{ constant _16* fp_c3 [[id(0)]]; constant _16* fp_c31 [[id(1)]]; };\n";
      char m[512]; snprintf(m,sizeof m,"%sfloat a=(*spvDescriptorSet0.fp_c3)._m0[0].w+(*spvDescriptorSet0.fp_c3)._m0[5u].x+(*spvDescriptorSet0.fp_c31)._m0[9].y;",decl);
      scan("常量下标 0 与 5u → 96 字节（fp_c31 不算）",m,"fp_c3",96); scan("fp_c31 自己 → 160",m,"fp_c31",160);
      snprintf(m,sizeof m,"%sfloat a=(*spvDescriptorSet0.fp_c3)._m0[_12].w;",decl); scan("变量下标 → 未知",m,"fp_c3",0);
      snprintf(m,sizeof m,"%sfloat a=f(spvDescriptorSet0.fp_c3)+(*spvDescriptorSet0.fp_c3)._m0[1].x;",decl); scan("别的用法 → 未知",m,"fp_c3",0);
      scan("只声明没读 → 16",decl,"fp_c3",16); }
    { printf("CASE 通道内两次整段更新\n"); put(0,16,0,0); tex_t t=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem,16); draw_cmd(&c); update(&c,mem,g,16); draw_cmd(&c); update(&c,mem,b,16); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("三次绘制各读各自那一版",rgb(16,32,64),o.px); EXPECT("内存落成最后一版",rgb(0,0,64),mem_rgb(0)); counts(&o,(want){1,2,0},(want){1,2,0},(want){3,0,0}); }
    { printf("CASE 绑定只被部分覆盖（模式 2 做快照）\n"); put(0,16,0,0); put(16,0,0,0); tex_t t=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem,32); draw_cmd(&c); update(&c,mem,g,16); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("第二次绘制读到新值",rgb(16,32,0),o.px); EXPECT("内存",rgb(0,32,0),mem_rgb(0)); counts(&o,(want){1,1,0},(want){2,1,1},(want){2,0,0});
      EXPECT("快照次数",mode==2,o.snaps); }
    { printf("CASE 更新后紧跟清色\n"); put(0,16,0,0); tex_t t=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem,16); draw_cmd(&c); update(&c,mem,g,16);
      p_clear_color cc={.index=0,.mask=15,.rgba={0,0,0,0}}; emit(&c,OP_CLEAR_COLOR,&cc,sizeof cc); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("清色生效，只剩第二次绘制",rgb(0,32,0),o.px); counts(&o,(want){2,1,0},(want){2,1,0},(want){2,0,0}); }
    { printf("CASE 顶点缓冲与更新区间重叠\n"); put(0,16,0,0); tex_t t=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem,16); p_bind_vbuf vb={.first=0,.n=1}; vb.r[0]=(NVNbufferRange){(NVNbufferAddress)(uintptr_t)mem,16}; emit(&c,OP_BIND_VBUF,&vb,sizeof vb);
      draw_cmd(&c); update(&c,mem,g,16); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("第二次绘制读到新值",rgb(16,32,0),o.px); counts(&o,(want){2,1,1},(want){2,1,1},(want){2,0,0}); }
    { printf("CASE 更新后紧跟缓冲拷贝\n"); put(0,16,0,0); put(256,0,0,0); tex_t t=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem,16); draw_cmd(&c); update(&c,mem,g,16); uint64_t cp[3]={(uint64_t)mem,(uint64_t)mem+256,16}; emit(&c,OP_COPY_B2B,cp,sizeof cp);
      outcome o=run(&c,&t); EXPECT("像素",rgb(16,0,0),o.px); EXPECT("拷贝读到新值",rgb(0,32,0),mem_rgb(256)); EXPECT("内存",rgb(0,32,0),mem_rgb(0)); counts(&o,(want){1,1,0},(want){1,1,0},(want){1,0,0}); }
    { printf("CASE 后一次更新只盖一部分\n"); put(0,16,0,0); tex_t t=texture(); chain c=make_chain(); float z=64/255.f;
      begin(&c,&t,(uint64_t)mem,16); draw_cmd(&c); update(&c,mem,g,16); update(&c,mem+8,&z,4); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("两次更新按序叠上再画",rgb(16,32,64),o.px); EXPECT("内存",rgb(0,32,64),mem_rgb(0)); counts(&o,(want){1,2,0},(want){2,2,1},(want){2,0,0}); }
    { printf("CASE 后一次更新盖住整段\n"); put(0,16,0,0); tex_t t=texture(); chain c=make_chain(); float z=200/255.f;
      begin(&c,&t,(uint64_t)mem,16); draw_cmd(&c); update(&c,mem+8,&z,4); update(&c,mem,g,16); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("读最新一版",rgb(16,32,0),o.px); EXPECT("内存按序落成最新一版",rgb(0,32,0),mem_rgb(0)); counts(&o,(want){1,2,0},(want){1,2,0},(want){2,0,0}); }
    { printf("CASE 绑定在更新区间中段\n"); put(0,0,0,0); put(16,16,0,0); tex_t t=texture(); chain c=make_chain(); f4(two,99,99,99); f4(two+4,0,32,0);
      begin(&c,&t,(uint64_t)mem+16,16); draw_cmd(&c); update(&c,mem,two,32); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("按偏移读到新值",rgb(16,32,0),o.px); EXPECT("内存",rgb(0,32,0),mem_rgb(16)); counts(&o,(want){1,1,0},(want){1,1,0},(want){2,0,0}); }
    { printf("CASE 两个通道之间的更新（模式 2 不开拷贝编码器）\n"); put(512,16,0,0); tex_t t=texture(), t2=texture(); chain c=make_chain();
      begin(&c,&t,(uint64_t)mem+512,16); draw_cmd(&c);
      p_set_rt r={.n=1}; r.color[0]=&t2; emit(&c,OP_SET_RT,&r,sizeof r); p_clear_color cc={.index=0,.mask=15,.rgba={0,0,0,0}}; emit(&c,OP_CLEAR_COLOR,&cc,sizeof cc);
      update(&c,mem+512,g,16); draw_cmd(&c);
      outcome o=run(&c,&t2); EXPECT("第二个目标读到新值",rgb(0,32,0),o.px); EXPECT("内存",rgb(0,32,0),mem_rgb(512)); counts(&o,(want){2,1,0},(want){2,0,0},(want){2,0,0});
      EXPECT("落地次数（模式 2 只在读回的拷贝前）",mode==2,o.lands); }
    { printf("CASE 快照叠上已落地、GPU 还没执行的更新\n"); put(768,16,0,0); put(1536,0,0,0); tex_t t=texture(); chain c=make_chain(); float z=64/255.f;
      begin(&c,&t,(uint64_t)mem+768,16); draw_cmd(&c); update(&c,mem+768,g,16);
      uint64_t cp[3]={(uint64_t)mem+1536,(uint64_t)mem+1552,16}; emit(&c,OP_COPY_B2B,cp,sizeof cp);   // an unrelated copy: g lands here, its copy runs on the GPU only after the commit
      update(&c,mem+776,&z,4); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("第二次绘制读到 g 叠 z",rgb(16,32,64),o.px); EXPECT("内存",rgb(0,32,64),mem_rgb(768)); counts(&o,(want){2,2,0},(want){2,1,0},(want){2,0,0});
      EXPECT("快照次数",mode==2,o.snaps); }
    { printf("CASE GPU 写过的区间不做快照\n"); put(1024,0,0,0); put(1040,0,0,0); put(1792,16,0,0); tex_t t=texture(); chain c=make_chain(); float z=64/255.f;
      begin(&c,&t,(uint64_t)mem+1024,32); uint64_t cp[3]={(uint64_t)mem+1792,(uint64_t)mem+1024,16}; emit(&c,OP_COPY_B2B,cp,sizeof cp);   // the CPU sees (16,0,0) there only after the commit
      draw_cmd(&c); update(&c,mem+1032,&z,4); draw_cmd(&c);
      outcome o=run(&c,&t); EXPECT("按旧办法落地后再画",rgb(32,0,64),o.px); EXPECT("内存",rgb(16,0,64),mem_rgb(1024)); counts(&o,(want){2,1,1},(want){2,1,1},(want){2,0,0});
      EXPECT("快照次数",0,o.snaps); }
    { printf("CASE 着色器只读绑定的前 16 字节\n"); put(1280,16,0,0); put(1296,0,0,0); tex_t t=texture(); chain c=make_chain(); f->cb_len[0]=16;
      begin(&c,&t,(uint64_t)mem+1280,32); draw_cmd(&c); update(&c,mem+1296,g,16); draw_cmd(&c);
      outcome o=run(&c,&t); f->cb_len[0]=0; EXPECT("两次都读前 16 字节",rgb(32,0,0),o.px); EXPECT("内存",rgb(0,32,0),mem_rgb(1296)); counts(&o,(want){1,1,0},(want){2,1,1},(want){2,0,0});
      EXPECT("快照次数",0,o.snaps); }
    printf("== t_ubren（%s）：%d 项，失败 %d ==\n",mode==2?"缺省：通道之间也推迟":mode?"DM_NVN_UBREN=1":"DM_NVN_UBREN=0",count,fail); return fail!=0;
} }
