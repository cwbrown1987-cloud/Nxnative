// Text of the Mac overlay panel (hud_text.h). Every formatter writes at most n
// bytes and NUL-terminates when n > 0; n = 0 writes nothing.
#include "hud_text.h"
#include <stdio.h>

int hud_mode_next(int mode) { return mode == HUD_ALL ? HUD_MINIMAL : mode == HUD_MINIMAL ? HUD_OFF : HUD_ALL; }   // anything else counts as off
const char *hud_mode_name(int mode) { return mode == HUD_ALL ? "all" : mode == HUD_MINIMAL ? "FPS only" : "off"; }

static int cap(int v, int max) { return v > max ? max : v; }   // each part capped so it always fits its buffer

void hud_rate_text(char *out, size_t n, int game, int shown) {
    char display[8] = "--", render[24] = "";
    if (shown >= 0) snprintf(display, sizeof display, "%d", cap(shown, 999));
    if (game >= 0) snprintf(render, sizeof render, " | game %d", cap(game, 999));
    snprintf(out, n, "FPS %s%s", display, render);
}
void hud_frame_text(char *out, size_t n, int game, int shown, int out_w, int out_h, int scene_w, int scene_h) {
    char rates[48], resolution[16] = "--", scene[24] = "";
    hud_rate_text(rates, sizeof rates, game, shown);
    if (out_w > 0 && out_h > 0) snprintf(resolution, sizeof resolution, "%dx%d", cap(out_w, 9999), cap(out_h, 9999));
    if (scene_w > 0 && scene_h > 0) snprintf(scene, sizeof scene, " (%dx%d)", cap(scene_w, 9999), cap(scene_h, 9999));
    snprintf(out, n, "%s  %s%s", rates, resolution, scene);
}

static void count_text(char *out, size_t n, const char *what, uint64_t fresh, int64_t total) {
    char t[16] = "--";   // total < 0: not known yet (the shader map is not loaded)
    if (total >= 0) snprintf(t, sizeof t, "%lld", (long long)(total > 999999 ? 999999 : total));
    snprintf(out, n, "New %s %llu / total %s", what, (unsigned long long)(fresh > 99999 ? 99999 : fresh), t);
}
void hud_shader_text(char *out, size_t n, uint64_t fresh, int64_t total) { count_text(out, n, "shaders", fresh, total); }
void hud_pipeline_text(char *out, size_t n, uint64_t fresh, int64_t total) { count_text(out, n, "render pipelines", fresh, total); }

void hud_load_text(char *out, size_t n, const dm_sysload *load) {
    size_t o = 0;   // the length the whole line would have; once past n nothing more is written (the cut write already ended with the NUL)
#define PUT(...) do { int k = snprintf(o < n ? out + o : NULL, o < n ? n - o : 0, __VA_ARGS__); if (k > 0) o += (size_t)k; } while (0)
    PUT("P"); for (int i = 0; i < load->np && i < DM_SYSLOAD_MAX_CORES; i++) PUT(" %2d%%", load->p[i]);   // a count past the arrays is clamped
    PUT("  E"); for (int i = 0; i < load->ne && i < DM_SYSLOAD_MAX_CORES; i++) PUT(" %2d%%", load->e[i]);
    if (load->thread_max >= 0) PUT("  T %d%%", load->thread_max);
    // "system": macOS's figure covers every app on the GPU, not this game alone (sysload_mac.c gpu_util); the game's own share follows in brackets
    if (load->gpu_sys >= 0) PUT("  GPU system %d%%", load->gpu_sys); else PUT("  GPU system --");
    if (load->gpu_game >= 0) PUT(" (game %d%%)", load->gpu_game);
#undef PUT
}
