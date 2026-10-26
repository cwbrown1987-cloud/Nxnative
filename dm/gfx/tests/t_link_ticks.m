// The acquire's waits on the display link, counted in its own ticks (mtl_link_wait_ticks) or in the game's 60 Hz vsyncs (mtl_link_wait_tick): a 120 Hz link takes two of its
// ticks per vsync, so present_interval display at DM_PRESENT_HZ=120 needs the first to reach one frame per tick. A host thread stands in for the display link's callback
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static _Atomic int g_stop;
static void *ticker(void *a) { (void)a; while (!g_stop) { usleep(2000); pthread_mutex_lock(&g_link_mu); g_link_tick_n++; pthread_cond_broadcast(&g_link_cv); pthread_mutex_unlock(&g_link_mu); } return NULL; }
static uint64_t ticks_now(void) { pthread_mutex_lock(&g_link_mu); uint64_t n = g_link_tick_n; pthread_mutex_unlock(&g_link_mu); return n; }
// Ticks per wait over 50 waits of the given kind (frames that take no time: each wait is the whole frame)
static double per_wait(int own, int n) {
    for (int i = 0; i < 3; i++) own ? mtl_link_wait_ticks(n, 100000000ull) : mtl_link_wait_tick(n, 100000000ull);   // settle on the tick
    uint64_t t0 = ticks_now();
    for (int i = 0; i < 50; i++) own ? mtl_link_wait_ticks(n, 100000000ull) : mtl_link_wait_tick(n, 100000000ull);
    return (ticks_now() - t0) / 50.0;
}
int main(void) { @autoreleasepool {
    g_dm_present_link = 2; g_link = (CAMetalDisplayLink *)[NSObject new];   // a link is "on" while the object is set; nothing calls it here
    CHECK(mtl_link_active(), "the link counts as active");
    pthread_t th; pthread_create(&th, NULL, ticker, NULL);
    g_link_mode = 2;
    CHECK(mtl_link_rate() == 120, "a 120 Hz link reports 120");
    double a = per_wait(0, 1), b = per_wait(1, 1), c = per_wait(1, 2);
    printf("120 Hz link: interval 1 waits %.2f ticks, one own tick %.2f, two own ticks %.2f\n", a, b, c);
    CHECK(a > 1.8 && a < 2.2, "a 60 Hz vsync is two ticks of a 120 Hz link");
    CHECK(b > 0.8 && b < 1.2, "one own tick per frame: 120 frames a second");
    CHECK(c > 1.8 && c < 2.2, "two own ticks");
    g_link_mode = 1;
    CHECK(mtl_link_rate() == 60, "a 60 Hz link reports 60");
    a = per_wait(0, 1);
    CHECK(a > 0.8 && a < 1.2, "a 60 Hz link: one tick per vsync");
    g_link_mode = 3;
    CHECK(mtl_link_rate() == 30, "the 30 Hz power-saving link reports 30");
    g_stop = 1; pthread_join(th, NULL);
    printf("t_link_ticks: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
