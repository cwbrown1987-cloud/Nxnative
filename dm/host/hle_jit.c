// nn::jit (code generation at run time). On Horizon the jit service loads the game's JIT plugin, an NRO the game reads from its own files, into a process of its own, maps the
// code memory the game gave it read-write there and read + execute in the game, and calls the plugin's entry points for GenerateCode and Control (yuzu's service/jit has the same
// calling conventions). Super Mario 64 (Super Mario 3D All-Stars, program 1, SDK 9.5.1) translates the N64 code its precompiled NRO lacks this way; its main imports nn::jit::Initialize,
// CreateJitEnvironment, GenerateCode, Control, GetJitEnvironmentInfo, DestroyJitEnvironment and Finalize, and the SDK's Initialize reached for the service and crashed (sdk+0x2e5414).
// The host has no service process, so it takes over the whole API: the plugin is one of the rewritten NROs (dm/tools/nro_collect.py finds it by the hash the game's NRR registers),
// loaded alone (loader.c nro_load_alone: on Horizon it is not linked with the game), and its entry points run on the calling thread. Its state lives in the transfer memory the game
// gives it (the work buffer's last part), as on Horizon. On the Mac the code memory is a MAP_JIT mapping at one address for the plugin and the game (yuzu maps it the same way), writable
// only while the plugin runs on that thread (pthread_jit_write_protect_np). iOS runs no code made at run time: there GenerateCode is served from a capture (C-3, below).
#include "hle.h"
#include <TargetConditionals.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

typedef struct { uint64_t offset, size; } jit_range;   // nn::jit::CodeRange: offset and size in the code (rx) or data (ro) memory
// The plugin's view of its memory (the JITConfiguration yuzu names): the game's code and data memory, the transfer memory, and the service's own mappings of the first two.
// Here sys_* are user_*: one mapping (the plugin writes its code through sys_rx: EmuSystemJITPlugin's GenerateCode keeps +0x30, and Control(0) hands +0 to the code it writes)
typedef struct { jit_range user_rx, user_ro, tmem, sys_rx, sys_ro; } jit_config;
// The SDK's environment (GetImpl(handle) is the handle itself, sdk+0x2e5680): +0 the service object, +8 code memory address, +0x10 its size, +0x18 data memory address, +0x20 its size;
// GetJitEnvironmentInfo copies +8..+0x28 (sdk+0x2e69e0). The host's handle points to the same layout, then its own fields
typedef struct {
    void *svc; uint64_t rx, rx_size, ro, ro_size;
    jit_config cfg;
    module_t *plugin;
    uint64_t (*gen)(int *ret, jit_range *c0_out, jit_range *c1_out, jit_config *cfg, uint64_t cmd, const void *in, size_t in_size, const jit_range *c0_in,
                    const jit_range *c1_in, const void *data, size_t data_size, void *out, size_t out_size);
    uint64_t (*ctl)(int *ret, jit_config *cfg, uint64_t cmd, const void *in, size_t in_size, void *out, size_t out_size);
    pthread_mutex_t mu;   // one request at a time, as the service's session serves them
    uint64_t ncalls[8], nbytes[8], ns[8];   // GenerateCode per command (0-7)
} jit_env;

static int jit_log_all(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_JIT_LOG"); v = e && atoi(e); } return v; }

// The plugin's helpers, which it looks up by name (nnjitpluginResolveBasicSymbols; on Horizon the service's own). Called from the plugin, so plain host functions
static void jit_panic(const char *msg) { LOG("[RED] JIT plugin PanicForPlugin: %s", msg ? msg : "(null)"); die("JIT plugin panic"); }
static void jit_abort(const char *cond, const char *fn, const char *file, int line) { LOG("[RED] JIT plugin abort: %s in %s (%s:%d)", cond ? cond : "", fn ? fn : "", file ? file : "", line); die("JIT plugin abort"); }
static void jit_unexpected(const char *fn, const char *file, int line) { LOG("[RED] JIT plugin unexpected default: %s (%s:%d)", fn ? fn : "", file ? file : "", line); die("JIT plugin abort"); }
static void *jit_resolve(const char *name) {
    static const struct { const char *name; void *fn; } t[] = {
        {"memcpy", (void *)memcpy}, {"memmove", (void *)memmove}, {"memset", (void *)memset}, {"PanicForPlugin", (void *)jit_panic},
        {"_ZN2nn4diag6detail9AbortImplEPKcS3_S3_i", (void *)jit_abort}, {"_ZN2nn6detail21UnexpectedDefaultImplEPKcS2_i", (void *)jit_unexpected},
    };
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++) if (name && !strcmp(name, t[i].name)) return t[i].fn;
    LOG("[RED] JIT plugin asks for %s, which the host does not provide", name ? name : "(null)");
    return NULL;
}

static int range_ok(const jit_range *r, uint64_t size) { return r->offset <= size && r->size <= size - r->offset; }

HLE_FORCE("_ZN2nn3jit10InitializeEv", "connects to the jit service; the host runs the plugin itself", void, h_jit_Initialize, void) { LOG("init takeover: jit::Initialize (no-op)"); }
HLE_FORCE("_ZN2nn3jit8FinalizeEv", "Initialize opened no session", void, h_jit_Finalize, void) { }

// CreateJitEnvironment(&handle, config, plugin, work, work_size): config = {code memory size, data memory size}, plugin = {NRR buffer, NRO buffer, transfer memory size} (sizes 2 MB
// multiples, as the SDK checks), work = code memory | data memory | transfer memory (2 MB aligned). Aborts as the SDK does on a failure (it has no error return the game checks)
HLE_FORCE("_ZN2nn3jit20CreateJitEnvironmentEPNS0_9JitHandleERKNS0_27JitEnvironmentConfigurationERKNS0_13JitPluginInfoEPvm",
          "the jit service: load the plugin NRO into the host and give it code memory the game can run", Result, h_jit_Create,
          void **out, const uint64_t *cfg, const uint64_t *plug, uint8_t *work, uint64_t work_size) {
    uint64_t rx_size = cfg[0], ro_size = cfg[1], tmem_size = plug[4];
    if (((uintptr_t)work | rx_size | ro_size | tmem_size) & 0x1fffff || rx_size + ro_size + tmem_size > work_size) die("jit::CreateJitEnvironment: sizes %#llx / %#llx / %#llx, work %p + %#llx (the SDK aborts)",
        (unsigned long long)rx_size, (unsigned long long)ro_size, (unsigned long long)tmem_size, work, (unsigned long long)work_size);
    // The NRO is one of the two buffers (the NRR the other; Super Mario 64 passes the NRR first)
    const uint8_t *nro = NULL; uint64_t nro_size = 0;
    for (int k = 0; k < 2; k++) { const uint8_t *b = (const uint8_t *)plug[2 * k]; if (b && plug[2 * k + 1] >= 0x80 && !memcmp(b + 0x10, "NRO0", 4)) { nro = b; nro_size = plug[2 * k + 1]; } }
    if (!nro) die("jit::CreateJitEnvironment: no NRO among the plugin buffers");
    uint32_t n = *(const uint32_t *)(nro + 0x18); if (n > nro_size) n = (uint32_t)nro_size;
    uint8_t sha[32]; CC_SHA256(nro, n, sha);
    char hx[17]; for (int k = 0; k < 8; k++) snprintf(hx + 2 * k, 3, "%02x", sha[k]);
    module_t *m = nro_find(sha);
    if (!m) die("jit::CreateJitEnvironment: no rewritten NRO with SHA-256 %s… (%u bytes): the plugin is not in the patched modules' nro.tsv", hx, n);
    jit_env *e = calloc(1, sizeof *e);
    pthread_mutex_init(&e->mu, NULL);
    e->plugin = m;
    uint8_t *rx = NULL;
#if TARGET_OS_IPHONE
    die("jit::CreateJitEnvironment: iOS runs no code generated at run time");
#else
    rx = mmap(NULL, rx_size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (rx == MAP_FAILED) die("jit: MAP_JIT mapping of %#llx bytes failed", (unsigned long long)rx_size);
#endif
    uint8_t *ro = mmap(NULL, ro_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (ro == MAP_FAILED) die("jit: data memory of %#llx bytes", (unsigned long long)ro_size);
    e->rx = (uint64_t)rx; e->rx_size = rx_size; e->ro = (uint64_t)ro; e->ro_size = ro_size;
    // On Horizon the work buffer's code and data parts become code memory the game no longer reaches, and the transfer memory part the plugin's state
    e->cfg = (jit_config){{e->rx, rx_size}, {e->ro, ro_size}, {(uint64_t)(work + rx_size + ro_size), tmem_size}, {e->rx, rx_size}, {e->ro, ro_size}};
    nro_load_alone(m);
    // As the service loads a plugin (yuzu LoadPlugin): its _init, GetVersion (1), ResolveBasicSymbols, SetupDiagnostics (off), Configure, OnPrepared
    void *gv = module_sym(m, "nnjitpluginGetVersion"), *rb = module_sym(m, "nnjitpluginResolveBasicSymbols"), *sd = module_sym(m, "nnjitpluginSetupDiagnostics"),
         *cf = module_sym(m, "nnjitpluginConfigure"), *op = module_sym(m, "nnjitpluginOnPrepared");
    e->gen = module_sym(m, "nnjitpluginGenerateCode"); e->ctl = module_sym(m, "nnjitpluginControl");
    if (!gv || !cf || !e->gen || !op) die("jit: %s lacks the plugin entry points (GetVersion, Configure, GenerateCode, OnPrepared)", m->name);
    if (m->init) ((void (*)(void))(m->base + m->init))();
    uint64_t ver = ((uint64_t (*)(void))gv)();
    if (ver != 1) die("jit: %s is plugin version %llu, the service takes 1", m->name, (unsigned long long)ver);
    if (rb) ((void (*)(void *))rb)((void *)jit_resolve);
    void *res = (void *)jit_resolve;
    if (sd) ((void (*)(uint32_t, void **))sd)(0, &res);
    uint32_t flags = 0;
    ((void (*)(uint32_t *))cf)(&flags);
    ((void (*)(jit_config *))op)(&e->cfg);
    *out = e;
    LOG("jit::CreateJitEnvironment: plugin %s (SHA-256 %s…, %u bytes) loaded; code memory %p + %#llx (MAP_JIT), data memory %p + %#llx, plugin state %p + %#llx (the work buffer's last part)",
        m->name, hx, n, rx, (unsigned long long)rx_size, ro, (unsigned long long)ro_size, (void *)e->cfg.tmem.offset, (unsigned long long)tmem_size);
    return 0;
}

HLE_FORCE("_ZN2nn3jit21DestroyJitEnvironmentENS0_9JitHandleE", "unload the plugin and free its code memory", void, h_jit_Destroy, jit_env *e) {
    if (!e) return;
    LOG("jit::DestroyJitEnvironment: GenerateCode %llu / %llu / %llu / %llu calls (commands 1-4)", (unsigned long long)e->ncalls[1], (unsigned long long)e->ncalls[2],
        (unsigned long long)e->ncalls[3], (unsigned long long)e->ncalls[4]);
    if (e->plugin->fini) ((void (*)(void))(e->plugin->base + e->plugin->fini))();
    e->plugin->loaded = 0;
    munmap((void *)e->rx, e->rx_size); munmap((void *)e->ro, e->ro_size);
    pthread_mutex_destroy(&e->mu); free(e);
}

typedef struct { uint64_t rx, rx_size, ro, ro_size; } jit_info;
HLE_FORCE("_ZN2nn3jit21GetJitEnvironmentInfoENS0_9JitHandleE", "where the code and data memory are mapped in the game", jit_info, h_jit_Info, jit_env *e) {
    return (jit_info){e->rx, e->rx_size, e->ro, e->ro_size};
}

// Control(handle, command, in, in_size, out, out_size): the plugin's return value (the SDK aborts when the service fails; the plugin's wrapper fails only without a Control)
HLE_FORCE("_ZN2nn3jit7ControlENS0_9JitHandleEmPKvmPvm", "the plugin's nnjitpluginControl", int, h_jit_Control, jit_env *e, uint64_t cmd, const void *in, size_t in_size, void *out, size_t out_size) {
    if (!e->ctl) die("jit::Control: the plugin has no nnjitpluginControl");
    int ret = -1;
    pthread_mutex_lock(&e->mu);
    uint64_t w = e->ctl(&ret, &e->cfg, cmd, in, in_size, out, out_size);
    pthread_mutex_unlock(&e->mu);
    LOG("jit::Control command %llu, in %p + %#zx, out %p + %#zx: %d%s", (unsigned long long)cmd, in, in_size, out, out_size, ret, w ? " (the plugin's wrapper failed)" : "");
    if (w) die("jit::Control: the plugin's wrapper failed (the SDK aborts)");
    return ret;
}

// GenerateCode(&code_out, &data_out, handle, command, in, in_size, code_in, data_in, data, data_size, out, out_size): the ranges are offsets in the code and data memory;
// data (at most 32 bytes) goes to the plugin zero-padded to 32, as the SDK sends it. After the plugin wrote code, the SDK invalidates the instruction cache over code_out and cleans the
// data cache over data_out (sdk+0x2e6bcc); here the plugin wrote through the same mapping, so invalidating the code range is all
HLE_FORCE("_ZN2nn3jit12GenerateCodeEPNS0_9CodeRangeES2_NS0_9JitHandleEmPKvmRKS1_S7_S5_mPvm", "the plugin's nnjitpluginGenerateCode, writing into the MAP_JIT code memory",
          int, h_jit_Generate, jit_range *c0_out, jit_range *c1_out, jit_env *e, uint64_t cmd, const void *in, size_t in_size, const jit_range *c0_in, const jit_range *c1_in,
          const void *data, size_t data_size, void *out, size_t out_size) {
    uint8_t d32[32] = {0}; memcpy(d32, data, data_size < 32 ? data_size : 32);
    jit_range o0 = {0}, o1 = {0};
    int ret = -1;
    uint64_t t0 = now_ns();
    pthread_mutex_lock(&e->mu);
#if !TARGET_OS_IPHONE
    pthread_jit_write_protect_np(0);
#endif
    uint64_t w = e->gen(&ret, &o0, &o1, &e->cfg, cmd, in, in_size, c0_in, c1_in, d32, data_size, out, out_size);
#if !TARGET_OS_IPHONE
    pthread_jit_write_protect_np(1);
#endif
    if (!w && !ret && o0.size) {
        if (!range_ok(&o0, e->rx_size)) die("jit::GenerateCode: the plugin returned code range %#llx + %#llx beyond the code memory", (unsigned long long)o0.offset, (unsigned long long)o0.size);
        sys_icache_invalidate((void *)(e->rx + o0.offset), o0.size);
    }
    uint64_t dt = now_ns() - t0; unsigned c = cmd < 8 ? (unsigned)cmd : 0;
    uint64_t k = ++e->ncalls[c]; e->nbytes[c] += o0.size; e->ns[c] += dt;
    pthread_mutex_unlock(&e->mu);
    if (k <= 16 || jit_log_all() || !(k & (k - 1)))
        LOG("jit::GenerateCode #%llu command %llu: in %p + %#zx, code in %#llx + %#llx, data %zu bytes %016llx %016llx, out %#zx → %d, code %#llx + %#llx, data %#llx + %#llx, %.2f ms (command %llu so far: %llu bytes, %.1f ms)",
            (unsigned long long)k, (unsigned long long)cmd, in, in_size, (unsigned long long)c0_in->offset, (unsigned long long)c0_in->size, data_size,
            (unsigned long long)__builtin_bswap64(*(uint64_t *)d32), (unsigned long long)__builtin_bswap64(*(uint64_t *)(d32 + 8)), out_size, ret,
            (unsigned long long)o0.offset, (unsigned long long)o0.size, (unsigned long long)o1.offset, (unsigned long long)o1.size, dt / 1e6,
            (unsigned long long)cmd, (unsigned long long)e->nbytes[c], e->ns[c] / 1e6);
    if (w) { LOG("[RED] jit::GenerateCode: the plugin's wrapper failed (command %llu)", (unsigned long long)cmd); die("jit::GenerateCode failed (the SDK aborts)"); }
    if (ret) LOG("[RED] jit::GenerateCode command %llu: the plugin returned %d (the service fails the request)", (unsigned long long)cmd, ret);
    // DM_JIT_DUMP=<dir>: each call's code as <dir>/<n>_<command>_<offset>.bin, for reading offline
    static const char *dump; static int dump_set, nd;
    if (!dump_set) { dump = getenv("DM_JIT_DUMP"); dump_set = 1; }
    if (dump && o0.size) {
        char p[1024]; snprintf(p, sizeof p, "%s/%05d_%llu_%llx.bin", dump, nd++, (unsigned long long)cmd, (unsigned long long)o0.offset);
        FILE *f = fopen(p, "wb"); if (f) { fwrite((void *)(e->rx + o0.offset), 1, o0.size, f); fclose(f); }
    }
    if (c0_out) *c0_out = o0;
    if (c1_out) *c1_out = o1;
    return ret;
}
