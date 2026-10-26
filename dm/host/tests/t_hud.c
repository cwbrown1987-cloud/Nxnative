// The Mac overlay panel's text (hud_text_mac.c): every line's format, the caps and "--" cases, the mode cycle, and every buffer size
// from 0 past the full line (the text is the line's prefix, NUL-terminated, and nothing at or after out[n] changes). Stops at the first failure
#include "hud_text.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;
static void check(int ok, const char *what) { checks++; if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }
static void same(const char *got, const char *want, const char *what) {
    checks++;
    if (strcmp(got, want)) { fprintf(stderr, "FAIL: %s: \"%s\", expected \"%s\"\n", what, got, want); exit(1); }
}
#define FRAME(want, ...) do { char b[128]; hud_frame_text(b, sizeof b, __VA_ARGS__); same(b, want, "frame(" #__VA_ARGS__ ")"); } while (0)

static dm_sysload g_load;   // the load the short-buffer case formats
static dm_sysload load(int np, int ne, int t, int gpu, int game) {
    static const int p[] = {55, 56, 55, 53}, e[] = {43, 29, 20, 12, 9, 7};
    dm_sysload l = {.np = np, .ne = ne, .thread_max = t, .gpu_sys = gpu, .gpu_game = game};
    memcpy(l.p, p, sizeof p); memcpy(l.e, e, sizeof e);
    return l;
}
static void frame_long(char *o, size_t n) { hud_frame_text(o, n, 1500, 1500, 10000, 10000, 1600, 900); }
static void rate_long(char *o, size_t n) { hud_rate_text(o, n, 1500, 1500); }
static void shader_long(char *o, size_t n) { hud_shader_text(o, n, 200000, 2000000); }
static void pipeline_long(char *o, size_t n) { hud_pipeline_text(o, n, 12, 3128); }
static void load_long(char *o, size_t n) { hud_load_text(o, n, &g_load); }
static void short_buffers(void (*f)(char *, size_t), const char *what) {
    char full[512], b[512], msg[160];
    f(full, sizeof full); size_t len = strlen(full);
    f(NULL, 0);   // n = 0 touches nothing, not even a NULL out
    for (size_t n = 0; n <= len + 1; n++) {
        memset(b, 0x7f, sizeof b); f(b, n);
        const char *z = n ? memchr(b, 0, n) : NULL; size_t got = z ? (size_t)(z - b) : 0;
        int ok = n == 0 || (z && got == (n - 1 < len ? n - 1 : len) && !memcmp(b, full, got));
        for (size_t i = n; i < sizeof b; i++) ok &= b[i] == 0x7f;
        snprintf(msg, sizeof msg, "%s in %zu bytes: a NUL-terminated prefix, nothing written past n", what, n);
        check(ok, msg);
    }
}

int main(void) {
    check(hud_mode_next(HUD_OFF) == HUD_ALL && hud_mode_next(HUD_ALL) == HUD_MINIMAL && hud_mode_next(HUD_MINIMAL) == HUD_OFF, "mode cycle 0 -> 1 -> 2 -> 0");
    check(hud_mode_next(7) == HUD_ALL && hud_mode_next(-1) == HUD_ALL, "an unknown mode (a stale saved value) cycles to all");
    same(hud_mode_name(HUD_ALL), "all", "mode name"); same(hud_mode_name(HUD_MINIMAL), "FPS only", "mode name"); same(hud_mode_name(HUD_OFF), "off", "mode name");

    FRAME("FPS 60 | game 60  1920x1080 (1600x900)", 60, 60, 1920, 1080, 1600, 900);
    FRAME("FPS 30 | game 30  1280x720", 30, 30, 1280, 720, 0, 0);
    FRAME("FPS 60 | game 30  1920x1080 (1600x900)", 30, 60, 1920, 1080, 1600, 900);   // the screen's rate first, the game's second
    FRAME("FPS --  --", -1, -1, 0, 0, 0, 0);   // nothing known yet
    FRAME("FPS -- | game 60  1920x1080", 60, -1, 1920, 1080, 0, 0);   // no screen reading yet: never replaced by the game's rate
    FRAME("FPS 0 | game 60  1920x1080", 60, 0, 1920, 1080, 0, 0);   // nothing reached the screen for 1.5 s
    FRAME("FPS 999 | game 999  9999x9999 (9999x9999)", 1500, 1500, 10000, 10000, 12000, 12000);   // every part capped
    FRAME("FPS 30 | game 30  1920x1080", 30, 30, 1920, 1080, 1600, 0);   // one scene side unknown: no brackets
    FRAME("FPS 30 | game 30  --", 30, 30, 2560, 0, 0, 0);   // an output size without both sides is unknown
    FRAME("FPS 0 | game 0  1920x1080 (1440x810)", 0, 0, 1920, 1080, 1440, 810);

    char b[256];
    hud_rate_text(b, sizeof b, 60, 59); same(b, "FPS 59 | game 60", "rate(60, 59)");
    hud_rate_text(b, sizeof b, -1, -1); same(b, "FPS --", "rate(-1, -1)");
    hud_rate_text(b, sizeof b, -1, 60); same(b, "FPS 60", "rate(-1, 60): the game's rate left out while not known");
    hud_shader_text(b, sizeof b, 3, 7428); same(b, "New shaders 3 / total 7428", "shader(3, 7428)");
    hud_shader_text(b, sizeof b, 0, -1); same(b, "New shaders 0 / total --", "shader(0, -1)");
    hud_shader_text(b, sizeof b, 200000, 2000000); same(b, "New shaders 99999 / total 999999", "shader(200000, 2000000)");
    hud_pipeline_text(b, sizeof b, 12, 3128); same(b, "New render pipelines 12 / total 3128", "pipeline(12, 3128)");
    hud_pipeline_text(b, sizeof b, 0, -1); same(b, "New render pipelines 0 / total --", "pipeline(0, -1)");
    hud_pipeline_text(b, sizeof b, UINT64_MAX, INT64_MAX); same(b, "New render pipelines 99999 / total 999999", "pipeline(max, max)");

    dm_sysload l = load(4, 6, 47, 99, 70);
    hud_load_text(b, sizeof b, &l); same(b, "P 55% 56% 55% 53%  E 43% 29% 20% 12%  9%  7%  T 47%  GPU system 99% (game 70%)", "load (4 P, 6 E, T 47, GPU 99, game 70)");
    l = load(4, 6, -1, -1, -1);
    hud_load_text(b, sizeof b, &l); same(b, "P 55% 56% 55% 53%  E 43% 29% 20% 12%  9%  7%  GPU system --", "load (no T, GPU -1, game -1)");
    l = load(4, 6, -1, -1, 70);
    hud_load_text(b, sizeof b, &l); same(b, "P 55% 56% 55% 53%  E 43% 29% 20% 12%  9%  7%  GPU system -- (game 70%)", "load (no T, GPU -1, game 70)");
    l = load(0, 0, -1, 0, 0);
    hud_load_text(b, sizeof b, &l); same(b, "P  E  GPU system 0% (game 0%)", "load (no cores, idle GPU)");
    char want[256] = "P"; l = load(DM_SYSLOAD_MAX_CORES + 9, 0, -1, -1, -1);   // a core count past the arrays: only the arrays are read
    for (int i = 0; i < DM_SYSLOAD_MAX_CORES; i++) { l.p[i] = 1; strcat(want, "  1%"); }
    strcat(want, "  E  GPU system --"); hud_load_text(b, sizeof b, &l); same(b, want, "load (core count past the arrays)");

    g_load = load(4, 6, 47, 99, 70);
    short_buffers(shader_long, "shader"); short_buffers(pipeline_long, "pipeline"); short_buffers(load_long, "load");
    short_buffers(frame_long, "frame"); short_buffers(rate_long, "rate");
    printf("hud: %d checks passed (FPS, shader, pipeline and load lines, caps, short buffers, mode cycle)\n", checks);
    return 0;
}
