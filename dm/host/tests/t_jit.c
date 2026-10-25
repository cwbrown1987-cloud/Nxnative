// nn::jit stand-in (hle_jit.c): a synthetic plugin module whose entry points are host functions loads alone (loader.c nro_load_alone), sees the configuration the service gives,
// and its generated code (real AArch64 written into the MAP_JIT code memory) runs from the address GetJitEnvironmentInfo reports. No game files.
#include "../loader.c"
#include "../hle_jit.c"
#include <assert.h>
#include <stddef.h>

struct dm_flags g_flag;
uint64_t now_ns(void) { return 0; }
void gate_register(uint64_t a, const char *k, int n, uint64_t o) { (void)a; (void)k; (void)n; (void)o; }
void hlecount_seal(void) {}
void *hlecount_wrap(const char *kind, const char *name, void *fn) { (void)kind; (void)name; return fn; }
uint64_t resolve_import(module_t *m, const char *name) { (void)m; (void)name; return 0; }
int hle_implements(const char *name) { (void)name; return 0; }
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }

enum { S_VER = 1, S_RES, S_CFG, S_PREP, S_GEN, S_CTL, S_WEAK, S_N };
typedef struct {
    Elf64_Sym sym[S_N];
    char names[256];
    Elf64_Dyn dyn[3];
    Elf64_Rela rel[3];
    uint64_t slots[3], value;
} image;
static image im;
static uint8_t nro[0x80], nrr[0x80];
static int inited;
static uint64_t ctl_value;
static jit_config *seen_cfg;
static void *(*resolver)(const char *);

static void p_init(void) { inited++; }
static uint64_t p_version(void) { return 1; }
static void p_resolve(void *(*r)(const char *)) { resolver = r; }
static void p_configure(uint32_t *flags) { (void)flags; }
static void p_prepared(jit_config *c) { seen_cfg = c; }
static uint64_t p_control(int *ret, jit_config *c, uint64_t cmd, const void *in, size_t n, void *out, size_t on) {
    (void)c; (void)out; (void)on;
    *ret = cmd == 0 && n == 8 ? 0 : -1;
    if (!*ret) ctl_value = *(const uint64_t *)in;
    return 0;
}
// Writes "mov w0, #<data[0]>; ret" at the offset asked, through the plugin's own mapping of the code memory (sys_rx), and reports the range and data size back
static uint64_t p_generate(int *ret, jit_range *o0, jit_range *o1, jit_config *c, uint64_t cmd, const void *in, size_t n, const jit_range *c0, const jit_range *c1,
                           const void *data, size_t dn, void *out, size_t on) {
    (void)in; (void)n; (void)c1;
    assert(cmd == 7 && dn == 4 && on == 4);
    const uint8_t *d = data;
    for (int k = 4; k < 32; k++) assert(!d[k]);   // zero-padded to 32 bytes, as the SDK sends it
    uint32_t code[2] = {0x52800000u | (uint32_t)d[0] << 5, 0xd65f03c0u};
    memcpy((void *)(c->sys_rx.offset + c0->offset), code, sizeof code);
    *o0 = (jit_range){c0->offset, sizeof code}; *o1 = (jit_range){0, 0};
    memcpy(out, "done", 4);
    *ret = 0;
    return 0;
}

static void fixture(void) {
    module_t *m = &g_mod[0];
    m->base = (uint8_t *)&im; m->size = sizeof im; strcpy(m->name, "plug");
    static const char *nm[S_N] = {"", "nnjitpluginGetVersion", "nnjitpluginResolveBasicSymbols", "nnjitpluginConfigure", "nnjitpluginOnPrepared", "nnjitpluginGenerateCode",
                                  "nnjitpluginControl", "__rel_dyn_start"};
    static void *fn[S_N] = {0, (void *)p_version, (void *)p_resolve, (void *)p_configure, (void *)p_prepared, (void *)p_generate, (void *)p_control, 0};
    size_t o = 1;
    for (int i = 1; i < S_N; i++) {
        strcpy(im.names + o, nm[i]);
        im.sym[i] = (Elf64_Sym){.st_name = (uint32_t)o, .st_info = (i == S_WEAK ? STB_WEAK : 1) << 4, .st_shndx = i == S_WEAK ? 0 : 1,
                                .st_value = fn[i] ? (uint64_t)((uintptr_t)fn[i] - (uintptr_t)m->base) : 0};
        o += strlen(nm[i]) + 1;
    }
    m->symtab = im.sym; m->strtab = im.names; m->nsym = S_N; m->dyn = im.dyn;
    im.dyn[0] = (Elf64_Dyn){.d_tag = DT_RELA, .d_un.d_ptr = offsetof(image, rel)};
    im.dyn[1] = (Elf64_Dyn){.d_tag = DT_RELASZ, .d_un.d_val = sizeof im.rel};
    im.rel[0] = (Elf64_Rela){.r_offset = offsetof(image, slots), .r_info = R_AARCH64_RELATIVE, .r_addend = offsetof(image, value)};
    im.rel[1] = (Elf64_Rela){.r_offset = offsetof(image, slots) + 8, .r_info = (uint64_t)S_VER << 32 | R_AARCH64_ABS64, .r_addend = 4};
    im.rel[2] = (Elf64_Rela){.r_offset = offsetof(image, slots) + 16, .r_info = (uint64_t)S_WEAK << 32 | R_AARCH64_ABS64};
    build_symhash(m);
    m->nro = 1; m->data_off = offsetof(image, slots); m->pristine_len = sizeof im - m->data_off;
    m->pristine = malloc(m->pristine_len); memcpy(m->pristine, m->base + m->data_off, m->pristine_len);
    memcpy(nro + 0x10, "NRO0", 4); *(uint32_t *)(nro + 0x18) = sizeof nro; m->nro_size = sizeof nro; CC_SHA256(nro, sizeof nro, m->sha256);
    memcpy(nrr, "NRR0", 4);
    m->init = (uintptr_t)p_init - (uintptr_t)m->base;
    g_nmod = 1;
}

int main(void) {
    fixture();
    enum { RX = 0x200000, RO = 0x200000, TM = 0x200000 };
    uint8_t *work = NULL; assert(!posix_memalign((void **)&work, 0x200000, RX + RO + TM));
    uint64_t cfg[2] = {RX, RO}, plug[5] = {(uint64_t)nrr, sizeof nrr, (uint64_t)nro, sizeof nro, TM};
    void *h = NULL;
    h_jit_Initialize();
    assert(h_jit_Create(&h, cfg, plug, work, RX + RO + TM) == 0 && h);
    // Loaded alone: its own symbol and a relative relocation bound, the undefined weak one 0, its _init called once, and the game's lookups never see it
    assert(im.slots[0] == (uint64_t)&im.value && im.slots[1] == (uint64_t)(uintptr_t)p_version + 4 && im.slots[2] == 0);
    assert(inited == 1 && !guest_sym("nnjitpluginGenerateCode"));
    assert(resolver && resolver("memcpy") == (void *)memcpy && resolver("PanicForPlugin") == (void *)jit_panic && !resolver("nothing"));
    jit_info info = h_jit_Info(h);
    assert(info.rx_size == RX && info.ro_size == RO && info.rx && info.ro);
    // The plugin's configuration: the game's and the service's mappings are one, the transfer memory is the work buffer's last part
    assert(seen_cfg && seen_cfg->user_rx.offset == info.rx && seen_cfg->sys_rx.offset == info.rx && seen_cfg->user_ro.offset == info.ro && seen_cfg->sys_ro.offset == info.ro);
    assert(seen_cfg->tmem.offset == (uint64_t)(work + RX + RO) && seen_cfg->tmem.size == TM);

    uint64_t v = 0x1234; assert(h_jit_Control(h, 0, &v, sizeof v, NULL, 0) == 0 && ctl_value == 0x1234);
    assert(h_jit_Control(h, 5, &v, sizeof v, NULL, 0) == -1);

    // Two blocks at different offsets; each runs from the reported address and returns what it was generated for
    for (int k = 0; k < 2; k++) {
        jit_range c0 = {0x1000 * (uint64_t)(k + 1), RX - 0x1000 * (uint64_t)(k + 1)}, c1 = {0, 0}, o0, o1;
        uint32_t d = 42 + (uint32_t)k; char out[4] = {0};
        assert(h_jit_Generate(&o0, &o1, h, 7, NULL, 0, &c0, &c1, &d, sizeof d, out, sizeof out) == 0);
        assert(o0.offset == c0.offset && o0.size == 8 && !o1.size && !memcmp(out, "done", 4));
        int (*f)(void) = (int (*)(void))(info.rx + o0.offset);
        assert(f() == 42 + k);
    }
    h_jit_Destroy(h); h_jit_Finalize();
    free(g_mod[0].symh); free(g_mod[0].pristine); free(work);
    puts("jit: plugin loaded alone, configuration, Control, generated code runs from the code memory: OK");
    return 0;
}
