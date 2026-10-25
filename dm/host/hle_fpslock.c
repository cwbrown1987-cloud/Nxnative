// Engine frame limits kept in game memory (FPSLocker's evaluate_write entries): some engines cap their own frame rate with a value the host can raise. The target is the profile's
// fps_target (DM_FPS_TARGET overrides; 0 = leave the game's own limit), the same key that drives Tears of the Kingdom's frame step (loader.c install_fps_state). Called on every present
// (hle_nvn.c); the game sets the values after boot and may set them again, so each is written whenever it differs. Fixed addresses: each row runs only on the main build it was found in (AGENTS.md)
#include "hle.h"
#include <mach/mach.h>

// What a field holds: the frame rate as a float, vsyncs per frame (60 / frame rate) as an int32, or the frame time in milliseconds as a float. Copies: consecutive copies of the value
// (Unreal keeps one for the game thread, one for the render thread). A row with no pointer (ptr_off 0) has its field at main + field: a constant in main's read-only data, which the loader
// leaves writable (the image's data block on iOS too, loader.c map_image).
// At 60 a frame time gets MS_MARGIN less than the vsync: such a limiter counts from the frame's start, and the work after it (the GPU fence wait, the next frame's start) adds to the
// period, so frames at exactly 16.667 ms came 0.11 ms late each on the Mac (59.6 fps, every 150th frame shown two vsyncs). Slightly shorter, the host's present pacing sets the pace
// (the acquire waits): Luigi's Mansion 3's display interval p99 18.69 → 16.67 ms, 60.0 fps. Not at 30: with present_interval display the presents follow every vsync and hold no
// frame for two, so a shorter time showed some frames for one (30.4 fps); 30 writes the game's own 33.333 ms
enum { FPS_F32, VSYNCS_I32, MS_F32 };
#define MS_MARGIN 0.5f
static float ms_want(int fps) { return 1000.0f / (float)fps - (fps == 60 ? MS_MARGIN : 0); }
static const struct { const char *build, *what; uint64_t ptr_off; uint32_t field; uint8_t kind, copies; } k_locks[] = {
    // Monster Hunter Rise 16.0.2: RE Engine's frame limit, a float at [main+0x1295b3f0]+0x434 (the pointer is a global in main's bss). The frame loop (main+0x6b106c8) sleeps until
    // [+0x430] / [+0x434] sixtieths of a second have passed ([+0x430] = 60) and steps the game by the time that really passed (+0x41c), so a higher limit runs the game faster in frames
    // at the same speed. The game sets 30 after boot; it also asks for present interval 2, which the profile's present_interval display ignores.
    // From masagrator's FPSLocker config for this build (FPSLocker-Warehouse, patches/0100B04011742000/C9A3DD7702075ECD.yaml)
    { "c9a3dd7702075ecd90101f4555389582", "RE Engine frame limit", 0x1295b3f0, 0x434, FPS_F32, 1 },
    // Octopath Traveler 0 1.0.5: Unreal Engine 5's console variables t.MaxFPS (the game thread's frame limit: it sleeps until 1 / t.MaxFPS has passed and steps the game by the time that
    // really passed) and rhi.SyncInterval (vsyncs per present: the RHI's present interval). Each is a TAutoConsoleVariable in main's bss (vtable, the console object, then at +0x10 the pointer to
    // its value: the game thread's copy, then the render thread's). The game's config sets t.MaxFPS 30 ([ConsoleVariables] of DefaultEngine.ini; FrameRateLimit=30 of SwitchGameUserSettings.ini
    // sets it again) and rhi.SyncInterval 2 (SwitchDeviceProfiles.ini), so the game asks for present interval 2. Found from the names' references in the static constructors that register them
    // (main+0x2ca6524, main+0x1026e54; RegisterConsoleVariable, then AsVariableFloat / AsVariableInt stored at +0x10)
    { "9fe60a212cff9b9a3656ab63d4f882e5", "Unreal t.MaxFPS", 0x7c738d0 + 0x10, 0, FPS_F32, 2 },
    { "9fe60a212cff9b9a3656ab63d4f882e5", "Unreal rhi.SyncInterval", 0x7b32690 + 0x10, 0, VSYNCS_I32, 2 },
    // DRAGON QUEST XI S 1.0.4: Unreal Engine 4.18's t.MaxFPS and nvn.SyncInterval (the Switch RHI's present interval), the same TAutoConsoleVariable layout. The game's config sets
    // FrameRateLimit=30 (DefaultGameUserSettings.ini) and nvn.SyncInterval=2 (JackGame/Config/Switch/SwitchEngine.ini). Found from the names' references (UTF-32, as the engine's TCHAR on
    // the Switch) in the static constructors: main+0x1e7f98 (TAutoConsoleVariable<float> constructor main+0x6ee0e0, AsVariableFloat stored at +0x10) and main+0x21c00c
    { "1719aabfa5eae42b132b65770b871288", "Unreal t.MaxFPS", 0x8501c38 + 0x10, 0, FPS_F32, 2 },
    { "1719aabfa5eae42b132b65770b871288", "Unreal nvn.SyncInterval", 0x85270b8 + 0x10, 0, VSYNCS_I32, 2 },
    // DRAGON QUEST VII Reimagined 1.2.0: Unreal Engine 4.27's t.MaxFPS and rhi.SyncInterval, the same layout (names in UTF-16, the engine's TCHAR in this build). The game's config sets
    // FrameRateLimit=30 (DefaultGameUserSettings.ini, SwitchGameUserSettings.ini) and rhi.syncinterval=2 (SwitchDeviceProfiles.ini). Registered at main+0x4a61b40 (float, AsVariableFloat
    // stored at +0x10) and main+0x36164f4 (int, AsVariableInt at +0x10)
    { "f7ec03e4cb9de3bd8319d4e899d2e9cc", "Unreal t.MaxFPS", 0x7f41908 + 0x10, 0, FPS_F32, 2 },
    { "f7ec03e4cb9de3bd8319d4e899d2e9cc", "Unreal rhi.SyncInterval", 0x7dedf38 + 0x10, 0, VSYNCS_I32, 2 },
    // FINAL FANTASY RESONANCE 1.0.1: Unreal Engine 5.6.1's t.MaxFPS and rhi.SyncInterval, the same layout (names in UTF-16). The engine's Switch device profile sets rhi.syncinterval=2
    // (BaseSwitchDeviceProfiles.ini). Registered at main+0x33a4dec (float, IConsoleManager slot 2; AsVariableFloat stored at +0x10) and main+0x149e0bc (int, slot 1; AsVariableInt at +0x10)
    { "84e182f72ee1da4f477804bd05b54c15", "Unreal t.MaxFPS", 0x8c29af0 + 0x10, 0, FPS_F32, 2 },
    { "84e182f72ee1da4f477804bd05b54c15", "Unreal rhi.SyncInterval", 0x8adca10 + 0x10, 0, VSYNCS_I32, 2 },
    // Luigi's Mansion 3 1.4.0: Next Level Games' frame limiter. At the end of each frame the main thread calls the frame callbacks (main+0xb7c308) with the milliseconds since the frame
    // started; the limiter (main+0x7a3e70) runs jobs or sleeps until 33.333 ms have passed, the float at main+0x13c94dc (read only there, at main+0x7a3ea8 and main+0x7a3f18), and the game
    // steps by the time that really passed. The game asks for present interval 2 too, which the profile's present_interval display ignores; both are needed
    { "79e5950ffa85acf63e28c9aec051eac2", "NLG frame limiter target", 0, 0x13c94dc, MS_F32, 1 },
};
#define NLOCKS ((int)(sizeof k_locks / sizeof k_locks[0]))

static int rd(uint64_t a, void *out, size_t n) { vm_size_t got = 0; return a >= 0x1000 && vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)out, &got) == KERN_SUCCESS && got == n; }

// Xenoblade Chronicles 2 3.0.0 (main FEEE7AFA8A1541BD): the frame rate the player picks in the game (key 2, front_mac.m on_key; DM_XC2_FPS at start), carried out by the stubs of the
// profile's patches.py (FPSLocker's config for this build): the host writes the effective target (state +0x4c; 30 while a cutscene plays, u8 main+0xbd8f40 = 1, as FPSLocker does: cutscenes
// are timed in frames), the dynamic-resolution budget (+0x48: (1 / fps) / vsyncs x 0.96) and the game's present interval (two u32 at main+0xb75c40: vsyncs per frame, 1 from 60 fps up)
// 0 = the game's own 30. Above 60 was tried (present tick, display link at 120 Hz one tick per frame, the game's present interval 1): the game still produced 60 frames a second, its
// main thread waiting on its workers and the render thread on GPU fences; whatever holds it is inside the engine, so only 30 and 60 are offered
static const int k_xc2_rates[] = {0, 60, 0, 0};
static int g_xc2 = -1, g_xc2_rate; static uint8_t *g_xc2_main;
static void xc2_find(void) {
    if (g_xc2 >= 0 || !g_nmod) return;   // modules not loaded yet (the window comes first): ask again later
    g_xc2 = 0;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main") && !strcmp(g_mod[i].build_id, "feee7afa8a1541bd67aed1a0061fbb57")) { g_xc2_main = g_mod[i].base; g_xc2 = 1; }
    if (g_xc2 && !dm_fps_state) { LOG("[RED] xc2: main without its frame-time stubs (patches.py): frame rate fixed at 30"); g_xc2 = 0; }
    if (!g_xc2) return;
    const char *e = getenv("DM_XC2_FPS"); int t = e ? atoi(e) : 0;   // not DM_FPS_TARGET: that one turns on the generic frame step (state +0), which this game does not use
    g_xc2_rate = t == 30 ? 0 : t;
    for (int k = 0; k < 2; k++) if (k_xc2_rates[k] == g_xc2_rate) goto ok;
    g_xc2_rate = 0;
ok:
    LOG("xc2: frame rate %s (key 2 switches 30 / 60)", g_xc2_rate ? "set by the host" : "the game's own 30");
}
static void xc2_tick(void) {
    xc2_find();
    if (g_xc2 != 1) return;
    // The stubs stay off (the game's own 30) through boot: the global the step goes to ([main+0xb900d0]) points to another object then, and stepping it made a worker thread assert
    // on NaNs at frame 3. 300 presents (10 s at 30) are well before the title screen
    static int presents; if (presents < 300) { presents++; float z = 0; memcpy(dm_fps_state + 0x4c, &z, 4); float dr0 = 1.0f / 30.0f / 2.0f * 0.96f; memcpy(dm_fps_state + 0x48, &dr0, 4); return; }
    int movie = g_xc2_main[0xbd8f40] == 1, fps = movie ? 30 : g_xc2_rate;
    uint32_t vs = fps ? (fps >= 60 ? 1 : 60 / fps) : 2;
    float eff = (float)fps, dr = (1.0f / (fps ? (float)fps : 30.0f)) / (float)vs * 0.96f;
    memcpy(dm_fps_state + 0x4c, &eff, 4); memcpy(dm_fps_state + 0x48, &dr, 4);
    uint32_t *pi = (uint32_t *)(g_xc2_main + 0xb75c40);   // left alone until the game has set it (all ones before) and while the game keeps its own rate
    if (getenv("DM_XC2_NOVS") == NULL && pi[0] != 0xffffffffu && (fps || movie) && (pi[0] != vs || pi[1] != vs)) { pi[0] = vs; pi[1] = vs; }
    // Above 60 the host's present tick follows the rate (a fixed 60 Hz otherwise)
    static int last = -1; if (fps != last) { void nvn_present_config(int hz, int display_mode); nvn_present_config(fps > 60 ? fps : 60, 0); void mtl_present_link_mode(int m); mtl_present_link_mode(fps > 60 ? 2 : 1); LOG("xc2: %d fps%s, present tick %d Hz", fps ? fps : 30, movie ? " (cutscene)" : "", fps > 60 ? fps : 60); last = fps; }
}
// key 2 in the game window: the next frame rate; returns it (30 for the game's own) or 0 when this game has no frame-rate choice
int dm_xc2_rate_cycle(void) {
    xc2_find(); if (g_xc2 != 1) return 0;
    int k = 0; while (k < 2 && k_xc2_rates[k] != g_xc2_rate) k++;
    g_xc2_rate = k_xc2_rates[(k + 1) % 2];
    return g_xc2_rate ? g_xc2_rate : 30;
}
int dm_xc2_rate(void) { xc2_find(); return g_xc2 == 1 ? (g_xc2_rate ? g_xc2_rate : 30) : 0; }

void dm_fps_lock_tick(void) {
    xc2_tick();
    static int state = -2, rows[NLOCKS], nrow, nlog[NLOCKS], target; static uint8_t *base; static const char *src;
    if (state == -1) return;
    if (state == -2) {
        state = -1;
        for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main"))
            for (int k = 0; k < NLOCKS; k++) if (!strcmp(g_mod[i].build_id, k_locks[k].build)) { rows[nrow++] = k; base = g_mod[i].base; }
        if (!nrow) return;
        const char *e = getenv("DM_FPS_TARGET"); int t = e ? atoi(e) : DM_GAME_FPS_TARGET; src = e ? "DM_FPS_TARGET" : "game profile fps_target";
        if (t != 0 && t != 30 && t != 60) { LOG("[RED] DM_FPS_TARGET=%s: must be 0, 30 or 60; leaving the game's frame limit", e); t = 0; }
        if (!t) { for (int r = 0; r < nrow; r++) LOG("main: %s left as the game sets it (%s)", k_locks[rows[r]].what, src); return; }
        target = t; state = 0;
    }
    for (int r = 0; r < nrow; r++) {
        int k = rows[r]; uint64_t obj = (uint64_t)(uintptr_t)base;
        if (k_locks[k].ptr_off && (!rd((uint64_t)(uintptr_t)(base + k_locks[k].ptr_off), &obj, sizeof obj) || !obj)) continue;   // not created yet
        for (int c = 0; c < k_locks[k].copies; c++) {
            uint64_t a = obj + k_locks[k].field + 4 * (uint64_t)c; uint32_t cur, want; char was[16];
            if (!rd(a, &cur, sizeof cur)) break;
            if (k_locks[k].kind == FPS_F32 || k_locks[k].kind == MS_F32) {
                int ms = k_locks[k].kind == MS_F32; float f, w = ms ? ms_want(target) : (float)target; memcpy(&f, &cur, sizeof f); memcpy(&want, &w, sizeof want);
                if (cur == want || !(ms ? f >= 8 && f <= 100 : f >= 10 && f <= 120)) continue;   // already set, or not set yet (RE Engine: 6000 at boot; Unreal: 0 = no limit until the config sets it)
                snprintf(was, sizeof was, ms ? "%.3f ms" : "%g", f);
            } else {
                want = 60 / (uint32_t)target;
                if (cur == want || cur < 1 || cur > 4) continue;
                snprintf(was, sizeof was, "%u", cur);
            }
            uint32_t *p = (uint32_t *)(uintptr_t)a;
            dm_guest_write_prepare(p, sizeof *p); __atomic_store_n(p, want, __ATOMIC_RELAXED);
            if (nlog[k] < 8) { nlog[k]++; char now[24];
                if (k_locks[k].kind == MS_F32) snprintf(now, sizeof now, "%.3f ms (%d fps)", ms_want(target), target);
                else snprintf(now, sizeof now, "%u%s", k_locks[k].kind == FPS_F32 ? (unsigned)target : want, k_locks[k].kind == FPS_F32 ? " fps" : " vsyncs");
                LOG("main: %s%s %s → %s (%s)", k_locks[k].what, k_locks[k].copies > 1 ? (c ? " (render thread)" : " (game thread)") : "", was, now, src); }
        }
    }
}

// The Mac's DM_CTL "cvarf <main offset> <value>" (hle_hid.c), for trying an Unreal console variable while the game runs: the TAutoConsoleVariable at main+offset holds at +0x10
// the pointer to its value, the game thread's copy then the render thread's; both are set to the float
void dm_ctl_cvar_f32(uint64_t off, float v) {
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) {
        uint64_t obj; if (!rd((uint64_t)(uintptr_t)(g_mod[i].base + off + 0x10), &obj, sizeof obj) || !obj) { LOG("DM_CTL: cvarf main+%#llx: no value pointer yet", (unsigned long long)off); return; }
        for (int c = 0; c < 2; c++) { float *p = (float *)(uintptr_t)(obj + 4 * (uint64_t)c); dm_guest_write_prepare(p, sizeof *p); *p = v; }
        LOG("DM_CTL: cvarf main+%#llx = %g (both copies at %#llx)", (unsigned long long)off, v, (unsigned long long)obj);
    }
}
// "peek <guest address> <count>": count floats (and their bits) from guest memory, read safely, to the log
void dm_ctl_peek(uint64_t a, int n) {
    for (int i = 0; i < n && i < 64; i += 4) {
        uint32_t w[4] = {0}; int k = n - i < 4 ? n - i : 4;
        if (!rd(a + 4 * (uint64_t)i, w, 4 * (size_t)k)) { LOG("DM_CTL: peek %#llx: not readable", (unsigned long long)(a + 4 * (uint64_t)i)); return; }
        float f[4]; memcpy(f, w, sizeof f);
        LOG("DM_CTL: peek %#llx: %g %g %g %g (%08x %08x %08x %08x)", (unsigned long long)(a + 4 * (uint64_t)i), f[0], f[1], f[2], f[3], w[0], w[1], w[2], w[3]);
    }
}
// "memdump <guest address> <bytes> <path>": guest memory to a file, read safely (stops at the first unreadable page)
void dm_ctl_memdump(uint64_t a, uint64_t n, const char *path) {
    FILE *f = fopen(path, "wb"); if (!f) { LOG("[RED] DM_CTL: memdump: cannot open %s", path); return; }
    static uint8_t buf[1 << 16]; uint64_t done = 0;
    while (done < n) { size_t k = n - done < sizeof buf ? (size_t)(n - done) : sizeof buf; if (!rd(a + done, buf, k)) break; fwrite(buf, 1, k, f); done += k; }
    fclose(f); LOG("DM_CTL: memdump %#llx: %llu of %llu bytes → %s", (unsigned long long)a, (unsigned long long)done, (unsigned long long)n, path);
}
// "cvari <main offset> <value>": the same for an int console variable
void dm_ctl_cvar_i32(uint64_t off, int32_t v) {
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) {
        uint64_t obj; if (!rd((uint64_t)(uintptr_t)(g_mod[i].base + off + 0x10), &obj, sizeof obj) || !obj) { LOG("DM_CTL: cvari main+%#llx: no value pointer yet", (unsigned long long)off); return; }
        for (int c = 0; c < 2; c++) { int32_t *p = (int32_t *)(uintptr_t)(obj + 4 * (uint64_t)c); dm_guest_write_prepare(p, sizeof *p); *p = v; }
        LOG("DM_CTL: cvari main+%#llx = %d (both copies at %#llx)", (unsigned long long)off, v, (unsigned long long)obj);
    }
}
