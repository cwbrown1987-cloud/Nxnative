// End of the run (hle_thread.c dm_threads_terminate, the in-process program switch): every guest thread leaves wherever it is, without running another instruction of its own code.
// "Guest code" here is functions in a text section of their own (__TEXT,__guest), which module_of recognises as a module, as the host does for the game's rewritten modules.
// The threads: one waiting on an event with no timeout, one waiting for a lock the main thread holds, one spinning in guest code with no SVC, one in a 10 s SleepThread, one created
// and never started, one looping through a host call (an HLE function, which is not interrupted) and guest code, and the main guest thread in a condition wait.
// Expected: all leave within a second, none reaches the code after its wait, the process is back to its thread count; a thread held in host code is reported and leaves once it returns
#include "../dm.h"
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <dispatch/dispatch.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void thr_svc_enter(uint64_t *regs, uint64_t pc), thr_svc_leave(void);
int dm_threads_terminate(uint64_t timeout_ns);
void dm_threads_release(void);
void dm_thread_set_exit_point(sigjmp_buf *jb);
void dm_thread_main_left(void);
int dm_terminating(void);

// ---- stubs for the host facilities hle_thread.c uses ----
struct dm_flags g_flag;
uint64_t g_t0_ns;
pthread_key_t g_key18;
__thread _Atomic int dm_host_work;
void crash_thread_init(void) {}
void guest_thread_init(void) {}
void *guest_sym(const char *name) { (void)name; return NULL; }
#include <mach/mach_time.h>
uint64_t now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }
static module_t g_guest_mod;
static uint64_t g_lo, g_hi;
module_t *module_of(const void *p) { return (uint64_t)p >= g_lo && (uint64_t)p < g_hi ? &g_guest_mod : NULL; }
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp) { (void)sp; ((void (*)(uint64_t))entry)(arg); abort(); }   // on the host stack: the test has no guest stacks
// crash.c's fault hooks and loader.c's fence: the fence takes execute permission from the guest section (page aligned, padded so no host code shares its pages)
static int (*g_hook)(void *, int, void *);
static void on_fault(int sig, siginfo_t *si, void *uc) { if (g_hook && g_hook(si->si_addr, 0, uc)) return; fprintf(stderr, "t_thread_term: unexpected fault %d at %p\n", sig, si->si_addr); _exit(3); }
void dm_fault_hook_register(int (*fn)(void *, int, void *)) {
    g_hook = fn; struct sigaction sa = {.sa_sigaction = on_fault, .sa_flags = SA_SIGINFO}; sigemptyset(&sa.sa_mask); sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
}
static _Atomic int g_fenced;
void dm_modules_fence(void) { g_fenced++; if (mprotect((void *)g_lo, g_hi - g_lo, PROT_READ)) { perror("fence"); _exit(4); } }

static int checks, fails;
#define CHECK(c, s) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s %s\n", ok_ ? "✓" : "✗", s); } while (0)
static _Atomic int g_after, g_ready, g_hostcalls;
static uint32_t g_ev_r, g_lock_word = 0, g_key_word, g_cv_lock;
static uint32_t g_main_handle;
static dispatch_semaphore_t g_hold;   // the host call the last thread makes waits on it
static _Atomic int g_hold_on;

// An SVC as the gate makes it: the gate frame registered on entry, released on exit (gate_dispatch in hle.c)
static uint64_t gsvc(int num, uint64_t *r) { thr_svc_enter(r, 0); svc_thread(num, r); thr_svc_leave(); return r[0]; }
static void host_call(void) { g_hostcalls++; usleep(2000); }   // an HLE function
static void host_hold(void) { dispatch_semaphore_wait(g_hold, DISPATCH_TIME_FOREVER); }   // an HLE function that does not return until the test lets it

#define GUEST __attribute__((section("__TEXT,__guest,regular,pure_instructions"), noinline, used, aligned(16384)))
GUEST static void g_wait_event(uint64_t a) { (void)a; uint64_t r[32] = {0}; uint32_t h[1] = {g_ev_r}; r[1] = (uint64_t)h; r[2] = 1; r[3] = (uint64_t)-1; g_ready++; gsvc(0x18, r); g_after |= 1; for (;;) ; }
GUEST static void g_wait_lock(uint64_t a) { (void)a; uint64_t r[32] = {0}; r[0] = g_main_handle; r[1] = (uint64_t)&g_lock_word; r[2] = 0x2222; g_ready++; gsvc(0x1A, r); g_after |= 2; for (;;) ; }
GUEST static void g_spin(uint64_t a) { (void)a; g_ready++; volatile uint64_t n = 0; while (n != ~0ull) n++; g_after |= 4; for (;;) ; }
GUEST static void g_sleep(uint64_t a) { (void)a; uint64_t r[32] = {0}; r[0] = 10000000000ull; g_ready++; gsvc(0x0B, r); g_after |= 8; for (;;) ; }
GUEST static void g_hostloop(uint64_t a) { (void)a; g_ready++; volatile uint64_t n = 0; for (;;) { host_call(); for (int i = 0; i < 1000; i++) n++; } }
GUEST static void g_held(uint64_t a) { (void)a; g_ready++; host_hold(); g_after |= 16; for (;;) ; }
GUEST static void g_unstarted(uint64_t a) { (void)a; g_after |= 32; for (;;) ; }
GUEST static void g_main_wait(void) { uint64_t r[32] = {0}; g_cv_lock = g_main_handle; r[0] = (uint64_t)&g_cv_lock; r[1] = (uint64_t)&g_key_word; r[2] = g_main_handle; r[3] = (uint64_t)-1; g_ready++; gsvc(0x1C, r); g_after |= 64; for (;;) ; }
static uint32_t create(void (*fn)(uint64_t), int start) {
    uint64_t r[32] = {0}; r[1] = (uint64_t)fn; r[3] = 0; r[4] = 44; r[5] = 0; svc_thread(0x08, r); uint32_t h = (uint32_t)r[1];
    if (start) { uint64_t s[32] = {h}; svc_thread(0x09, s); }
    return h;
}
static int nthreads(void) { thread_act_array_t a; mach_msg_type_number_t n = 0; if (task_threads(mach_task_self(), &a, &n)) return -1;
    for (unsigned i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), a[i]); vm_deallocate(mach_task_self(), (vm_address_t)a, n * sizeof *a); return (int)n; }

static sigjmp_buf g_main_jb; static _Atomic int g_main_out;
static void *main_guest(void *p) {   // the main guest thread: registered by svc_thread_main_init, its exit point set as main.c does
    (void)p;
    if (sigsetjmp(g_main_jb, 1)) { dm_thread_main_left(); g_main_out = 1; return NULL; }
    g_main_handle = svc_thread_main_init();
    dm_thread_set_exit_point(&g_main_jb);
    g_lock_word = g_main_handle | 0x40000000;   // the main thread holds the lock g_wait_lock waits for, waiters bit set as the SDK sets it before ArbitrateLock
    uint64_t r[32] = {0}; svc_thread(0x45, r); g_ev_r = (uint32_t)r[2];
    create(g_wait_event, 1); create(g_wait_lock, 1); create(g_spin, 1); create(g_sleep, 1); create(g_hostloop, 1); create(g_unstarted, 0);
    if (atomic_load(&g_hold_on)) create(g_held, 1);
    g_main_wait();
    return NULL;
}
// Padding that keeps the guest section's last page free of host code (the section starts page aligned: g_wait_event's alignment)
__asm__(".section __TEXT,__guest,regular,pure_instructions\n.p2align 14\n.space 16384\n.text\n");
int main(int argc, char **argv) {
    (void)argv; g_hold_on = argc > 1;   // the second run (t_thread_term held): a thread held in host code as well
    unsigned long sz = 0; uint8_t *sec = getsectiondata(&_mh_execute_header, "__TEXT", "__guest", &sz);
    g_lo = (uint64_t)sec & ~0x3FFFull; g_hi = ((uint64_t)sec + sz) & ~0x3FFFull; g_hold = dispatch_semaphore_create(0);
    if ((uint64_t)sec & 0x3FFF) { printf("✗ the guest section is not page aligned\n"); return 1; }
    int base = nthreads(), want = g_hold_on ? 7 : 6;
    pthread_t m; pthread_create(&m, NULL, main_guest, NULL);
    for (int i = 0; i < 400 && g_ready < want; i++) usleep(5000);
    usleep(50000);
    CHECK(g_ready == want && nthreads() >= base + want + 1, "the guest threads are running, each at its wait, spin or host-call loop");
    uint64_t t0 = now_ns(); int left = dm_threads_terminate(g_hold_on ? 300000000ull : 3000000000ull); double ms = (now_ns() - t0) / 1e6;
    if (!g_hold_on) {
        CHECK(left == 0, "every guest thread left: the event wait, the lock wait, the guest-code spin, the 10 s sleep, the unstarted thread, the host-call loop and the main thread");
        CHECK(ms < 1000, "they left within a second");
        CHECK(g_fenced <= 1, "guest code fenced at most once (when the host-call loop, seldom in guest code at a signal, is still there after 20 ms)");
    } else {
        CHECK(left == 1, "a thread held in host code is still there after the timeout, and reported");
        dispatch_semaphore_signal(g_hold);
        left = dm_threads_terminate(1000000000ull);
        CHECK(left == 0, "it leaves as soon as its host call returns into the fenced guest code");
    }
    if (g_after) printf("after mask %#x\n", (unsigned)g_after);
    CHECK(g_after == 0, "none ran the code after its wait (the unstarted thread never started)");
    pthread_join(m, NULL);
    CHECK(g_main_out, "the main guest thread came back to its exit point (main.c's frame), the host thread lives on");
    for (int i = 0; i < 200 && nthreads() > base; i++) usleep(5000);
    CHECK(nthreads() == base, "the process is back to its thread count");
    dm_threads_release();
    printf("== %d checks, %d failed ==\n", checks, fails);
    return fails != 0;
}
