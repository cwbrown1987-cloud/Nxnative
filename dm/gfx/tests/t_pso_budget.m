// The prebuild's compile budget (pre_trial / pre_pair in nvn_mtl.m, GitHub issue #294): each base is compiled first by a compiler without the serializer, outside g_arch_rw,
// within DM_PSO_PREBUILD_BUDGET seconds. Tiny shader libraries and a pair list as in t_pso_bundle. Checks: with the default budget every pair is built, written and stamped; with a
// budget no compile can meet (1 ns, over shaders the compiler has not seen, so no cache answers in time) every pair is left to the draws, none fails, the flush and the stamp still
// happen and nothing is held: a compile with the serializer (the draws' path, under g_arch_rw) and a flush both go through while the trials may still be running
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, want, ...) do { uint64_t w = (want), g = (__VA_ARGS__); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)

static int sh(NSString *cmd) { int r = system(cmd.UTF8String); return WIFEXITED(r) ? WEXITSTATUS(r) : -1; }
static void put(NSString *path, NSString *text) { [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static int lib(NSString *dir, NSString *name, NSString *src) {   // <dir>/<name>.metallib from MSL, with the SDK's compiler
    put([NSString stringWithFormat:@"%@/%@.metal", dir, name], src);
    return sh([NSString stringWithFormat:@"cd %@ && xcrun -sdk macosx metal -c %@.metal -o %@.air && xcrun -sdk macosx metallib %@.air -o %@.metallib && rm %@.metal %@.air", dir, name, name, name, name, name, name]);
}
static void reset_counts(void) { g_pre_done = g_pre_built = g_pre_archived = g_pre_skipped = g_pre_failed = g_pre_slow = 0; }
static NSUInteger files(NSString *dir) { return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mtl4a'"]].count; }

int main(void) { @autoreleasepool {
    char tmp[] = "/tmp/t_pso_budget.XXXXXX"; if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    NSString *arch = [root stringByAppendingPathComponent:@"archive"], *arch2 = [root stringByAppendingPathComponent:@"archive2"];
    NSString *v = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n";
    // the pid in every pixel shader: shaders this compiler service has not compiled before, so the 1 ns budget meets no cached result
    NSString *f = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(%d, %d, %d.0 / 65536.0, 1); }\n";
    [NSFileManager.defaultManager createDirectoryAtPath:msl withIntermediateDirectories:YES attributes:nil error:nil];
    int pid = getpid() & 0xffff;
    if (lib(msl, @"v1_bp", v) || lib(msl, @"f1_b", [NSString stringWithFormat:f, 1, 0, pid]) || lib(msl, @"f2_b", [NSString stringWithFormat:f, 0, 1, pid]) ||
        lib(msl, @"f3_b", [NSString stringWithFormat:f, 1, 1, pid]) || lib(msl, @"f4_b", [NSString stringWithFormat:f, 0, 0, pid])) {
        printf("t_pso_budget: no Metal compiler (xcrun metal), not run\n"); return 0; }
    put([msl stringByAppendingPathComponent:@"v1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
    for (NSString *k in @[@"f1", @"f2", @"f3", @"f4"]) put([msl stringByAppendingFormat:@"/%@_b.json", k], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\"}", DMSH_CHAIN]);
    put([tables stringByAppendingPathComponent:@"shader_map.tsv"], @"# empty\n");
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf1\nv1\tf2\n");
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_MANIFEST", "off", 1); unsetenv("DM_PSO_PREBUILD_BUDGET");
    mtl_init(); pso4_init();
    if (!g_comp4 || !g_ser4) { printf("t_pso_budget: no Metal 4 compiler, not run\n"); return 0; }

    // the default budget: built, written, stamped
    reset_counts();
    EXPECT("default budget: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("default budget: a trial compiler", 1, g_comp4_trial != nil);
    EXPECT("default budget: built", 2, g_pre_built);
    EXPECT("default budget: none past the budget", 0, g_pre_slow);
    EXPECT("default budget: one file written", 1, files(arch));
    EXPECT("default budget: stamped", 1, [NSFileManager.defaultManager fileExistsAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"]]);

    // a budget no compile meets, into a fresh folder with new pairs: every pair left to the draws, the run still finishes and stamps
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf3\nv1\tf4\n");
    g_arch_dir = arch2; g_arch4 = @[]; g_arch4p = @[];
    [NSFileManager.defaultManager createDirectoryAtPath:arch2 withIntermediateDirectories:YES attributes:nil error:nil];   // as a device's archive folder is (no flush makes it: nothing is built)
    setenv("DM_PSO_PREBUILD_BUDGET", "0.000000001", 1);
    reset_counts();
    uint64_t t0 = bp_now();
    EXPECT("1 ns budget: two pairs", 2, pso_prebuild(2, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("1 ns budget: finishes at once (no wait for a compile)", 1, bp_now() - t0 < 5ull * 1000000000ull);
    EXPECT("1 ns budget: none built", 0, g_pre_built);
    EXPECT("1 ns budget: both past the budget", 2, g_pre_slow);
    EXPECT("1 ns budget: both left to the draws", 2, g_pre_skipped);
    EXPECT("1 ns budget: none failed", 0, g_pre_failed);
    EXPECT("1 ns budget: stamped (left pairs do not hold the stamp back)", 1, [NSFileManager.defaultManager fileExistsAtPath:[arch2 stringByAppendingPathComponent:@"prebuilt.tsv"]]);

    // nothing is held: a serializer compile under g_arch_rw (as a draw makes it) and a flush both go through while the trials may still run
    unsetenv("DM_PSO_PREBUILD_BUDGET");
    MTL4RenderPipelineDescriptor *m = pre_desc(@"v1", @"f3", 0);
    EXPECT("after: a descriptor", 1, m != nil);
    NSError *e = nil;
    pthread_rwlock_rdlock(&g_arch_rw); id ps = ga_capture(m, nil, &e); pthread_rwlock_unlock(&g_arch_rw);
    EXPECT("after: the draws' compile goes through", 1, ps != nil);
    atomic_fetch_add(&g_arch_new, 1);
    dispatch_sync(g_arch_q, ^{ arch_flush(); });
    EXPECT("after: the flush writes", 1, g_arch_flush_ok);
    usleep(500000);   // let the abandoned trials finish: their handlers must not touch the gone stack frames

    printf("t_pso_budget: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
