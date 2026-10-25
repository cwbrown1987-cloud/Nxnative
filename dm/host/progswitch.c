// In-process program switch (DM_PROGRAM_SWITCH=inproc): oe::ExecuteProgram ends the running program and starts the named one in the same process, as Horizon starts it in a
// new one. Without the switch on, the Mac starts the program's host in this process's place (execve) and the iOS app records it and ends (hle_oe.c).
//
// The run's state is everything the host holds for one program: its guest threads, guest address space, modules, the subsystems' objects and threads, and the statics of
// every host file. The statics are reset all at once: they live in the sections __DATA,__dmrun_data / __dmrun_bss (dm_run.h), whose bytes are saved here at process start
// and put back between two runs (dm_runstate_restore). What the bytes point at is released first, subsystem by subsystem (dm_*_end_run). This file's own state, the front
// end's and a few process-wide registrations live for the process (DM_PROCESS, or the pragma below).
#include "hle.h"
#include "front.h"
#include "progswitch.h"
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>
#pragma clang section bss="" data=""   // process-lifetime statics (dm_run.h): the switch outlives every run

// ---------- The run's statics ----------
static uint8_t *g_snap; static size_t g_snap_n;
static uint8_t *sect(const char *name, size_t *n) { unsigned long sz = 0; uint8_t *p = getsectiondata(&_mh_execute_header, "__DATA", name, &sz); *n = p ? sz : 0; return p; }
// At process start, before any host code ran but after the constructors (hle_movie.c and hle_nvn.c fill tables from theirs): main.m on iOS, main.c's main on the Mac
void dm_runstate_snapshot(void) {
    if (g_snap) return;
    size_t n; uint8_t *d = sect("__dmrun_data", &n);
    g_snap = malloc(n ? n : 1); g_snap_n = n;
    if (!g_snap) die("run state snapshot: no memory for %zu bytes", n);
    if (n) memcpy(g_snap, d, n);
}
// Between two runs, with no thread of the run left: the data section as it was at process start, the zero-fill section zeroed. Its whole pages are replaced with fresh
// zero pages (a fixed anonymous mapping), so the restore neither brings 20 MB of tables that a game never touched into memory nor keeps the pages a game filled;
// the pages it shares with other sections at its ends are cleared byte by byte. Returns the bytes cleared by hand (0 when every mapping worked)
size_t dm_runstate_restore(void) {
    if (!g_snap) die("run state restore without a snapshot");
    size_t n, z, by_hand = 0; uint8_t *d = sect("__dmrun_data", &n), *b = sect("__dmrun_bss", &z);
    if (n != g_snap_n) die("run state: the data section changed size (%zu, %zu)", n, g_snap_n);
    if (n) memcpy(d, g_snap, n);
    const uintptr_t pg = (uintptr_t)getpagesize();
    uint8_t *e = b + z, *lo = (uint8_t *)(((uintptr_t)b + pg - 1) & ~(pg - 1)), *hi = (uint8_t *)((uintptr_t)e & ~(pg - 1));
    if (hi <= lo) { memset(b, 0, z); return z; }
    memset(b, 0, (size_t)(lo - b)); memset(hi, 0, (size_t)(e - hi)); by_hand = (size_t)(lo - b) + (size_t)(e - hi);
    if (mmap(lo, (size_t)(hi - lo), PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED) {
        LOG("[RED] run state: the zero-fill pages could not be replaced (errno %d); clearing them", errno); memset(lo, 0, (size_t)(hi - lo)); by_hand += (size_t)(hi - lo); }
    return by_hand;
}

#ifndef DM_RUNSTATE_ONLY   // t_runstate tests the part above alone
// ---------- The switch ----------
// oe::ExecuteProgram (hle_oe.c) asks for it on the guest thread that called it, which then leaves. A coordinator thread of the host's own ends every guest thread
// (hle_thread.c dm_threads_terminate), runs each subsystem's end of the run, resets the run's statics and sets the next program's environment (apply), then wakes the main
// guest thread, which comes back to its exit point in main.c and runs the boot path again: modules, SDK start, nnMain. A guest thread that does not leave in time is reported
// and the switch falls back to what happens without it (fallback: the Mac's execve, the iOS app's record and exit), from that thread
int dm_program_switch_inproc(void) { const char *e = getenv("DM_PROGRAM_SWITCH"); return e && !strcmp(e, "inproc"); }
static dm_switch_req g_req;
static _Atomic int g_pending, g_parked, g_main_is_main, g_runs;
static dispatch_semaphore_t g_go;
static char *g_next_argv[3];
int dm_threads_terminate(uint64_t timeout_ns); void dm_threads_release(void); void dm_threads_term_begin(void);
void dm_gfx_end_run(void), dm_audio_end_run(void), dm_movie_end_run(void), dm_sdk16_end_run(void), dm_hid_end_run(void), dm_web_end_run(void);
void dm_fs_end_run(void), dm_svc_end_run(void), dm_modules_end_run(void), dm_jit_end_run(void);
void dm_movie_wake(void), dm_oe_wake(void), dm_os_wake(void), dm_web_wake(void);
void mtl_thread_reset(void), dm_audren_thread_reset(void);
extern __thread _Atomic int dm_host_work;
static void wake_waits(void) { dm_movie_wake(); dm_oe_wake(); dm_os_wake(); dm_web_wake(); }   // guest threads that wait in host code (dm_thread_term_check)
static void restore_on(void *p) {   // the run's statics back to process start, then the next program's environment (the main thread when the front end owns it)
    uint64_t t0 = now_ns(); size_t by_hand = dm_runstate_restore();
    const char *dir = g_req.apply ? g_req.apply(g_req.arg) : NULL;
    free(g_next_argv[1]); g_next_argv[0] = "dmhost"; g_next_argv[1] = dir ? strdup(dir) : NULL; g_next_argv[2] = NULL;
    *(uint64_t *)p = now_ns() - t0; (void)by_hand;
}
static void *coord_main(void *unused) {
    (void)unused; pthread_setname_np("dm-program-switch");
    uint64_t t0 = now_ns();
    dm_audio_suspend(1);   // no sound while the program ends
    int left;
    for (int round = 0; ; round++) {   // each round wakes the host-side waits again, as a guest thread may have entered one meanwhile
        wake_waits(); left = dm_threads_terminate(round ? 1000000000ull : 250000000ull);
        if (!left || round >= 4) break;
    }
    if (left) {
        LOG("[RED] program switch: %d guest thread(s) did not leave; program %d starts the way it does without DM_PROGRAM_SWITCH=inproc", left, g_req.index);
        if (g_req.fallback) g_req.fallback(g_req.fallback_arg);
        _exit(0);
    }
    for (int i = 0; i < 1000 && !atomic_load(&g_parked); i++) usleep(1000);   // the main guest thread is back at its exit point
    if (!atomic_load(&g_parked)) { LOG("[RED] program switch: the main guest thread did not come back"); if (g_req.fallback) g_req.fallback(g_req.fallback_arg); _exit(0); }
    uint64_t t1 = now_ns();
    dm_hid_end_run(); dm_web_end_run(); dm_sdk16_end_run(); dm_movie_end_run(); dm_audio_end_run(); dm_gfx_end_run();
    dm_jit_end_run(); dm_fs_end_run(); dm_svc_end_run(); dm_modules_end_run(); dm_threads_release();
    uint64_t t2 = now_ns(), tr = 0;
    if (atomic_load(&g_main_is_main)) restore_on(&tr); else dispatch_sync_f(dispatch_get_main_queue(), &tr, restore_on);
    if (!g_next_argv[1]) { LOG("[RED] program switch: no environment for program %d", g_req.index); if (g_req.fallback) g_req.fallback(g_req.fallback_arg); _exit(0); }
    LOG("program switch %d: program %d starts in this process (threads %.0f ms, end of the run %.0f ms, statics %.1f ms)", atomic_fetch_add(&g_runs, 1) + 1, g_req.index,
        (t1 - t0) / 1e6, (t2 - t1) / 1e6, tr / 1e6);
    dispatch_semaphore_signal(g_go);
    return NULL;
}
// On the guest thread in oe::ExecuteProgram, holding no host lock: 1 = the switch is under way and this thread has left (the call does not return); 0 = not switching here
int dm_program_switch_request(const dm_switch_req *r) {
    if (!dm_program_switch_inproc() || !g_snap) return 0;
    int dm_thread_main_ready(void);
    for (int i = 0; i < 2000 && !dm_thread_main_ready(); i++) usleep(5000);   // a request from the host's own thread (DM_CTL "program") while the run still boots
    if (!dm_thread_main_ready()) { LOG("[RED] program switch: the run has not started its main guest thread"); return 0; }
    if (atomic_exchange(&g_pending, 1)) { dm_thread_term_check(); return 1; }   // another thread asked first: this one leaves with the rest
    g_req = *r; atomic_store(&g_parked, 0);
    if (!g_go) g_go = dispatch_semaphore_create(0);
    LOG("program switch: this program ends, program %d starts in this process (DM_PROGRAM_SWITCH=inproc)", r->index);
    dm_threads_term_begin();
    pthread_t th; if (pthread_create(&th, NULL, coord_main, NULL)) { LOG("[RED] program switch: no coordinator thread"); atomic_store(&g_pending, 0); return 0; }
    pthread_detach(th);
    dm_thread_term_check();
    return 1;   // not a guest thread (cannot happen from ExecuteProgram): it returns
}
// main.c, on the main guest thread back at its exit point: 1 and the next program's arguments once its run may start, 0 when no switch is under way (nnMain returned)
int dm_program_switch_park(int *argc, char ***argv) {
    if (!atomic_load(&g_pending)) return 0;
    atomic_store(&g_main_is_main, pthread_main_np() != 0);
    atomic_store(&g_parked, 1);
    dispatch_semaphore_wait(g_go, DISPATCH_TIME_FOREVER);
    dm_host_work = 0; mtl_thread_reset(); dm_audren_thread_reset();   // this thread's own state of the run that ended
    atomic_store(&g_pending, 0);
    *argc = 2; *argv = g_next_argv;
    return 1;
}
#endif
