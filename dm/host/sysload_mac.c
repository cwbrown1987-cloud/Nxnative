// System load for the Mac overlay panel's load line (sysload.h; Mac only: IOKit), sampled every 0.5 s on a thread of its own ("dm-sysload", QoS utility) that never touches the
// guest's threads or the renderer. Each value is the delta over one window, with no smoothing:
// - per core: host_processor_info(PROCESSOR_CPU_LOAD_INFO) tick deltas; performance / efficiency by the device tree's cluster-type, hw.perflevel1 as the fallback;
// - T: the busiest thread of this process, its CPU time (user + system) per wall time, against baselines of this file's own (dm_thread_cpu's are the power line's);
// - GPU: IOAccelerator PerformanceStatistics "Device Utilization %", the whole GPU as Activity Monitor's GPU history shows it: every app on it, not
//   this game alone (the panel labels it "system"). An IORegistry property, not a documented API;
// - the bracketed share: this process's GPU time per wall time, from the accelerator's user clients this process opened (gpu_own_delta). It counts every GPU
//   job of the process (the renderer and whatever VideoToolbox runs in it), not only the game's command buffers.
// Started by the panel the first time it shows the load line (dm_sysload_start), so a run that never shows it has no such thread
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include "hle.h"
#include "hud_text.h"   // hud_load_text: the log line is the panel's text
#include "sysload.h"

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static dm_sysload g_cur; static int g_have;   // under g_mu: the last sample, published whole
int dm_sysload_get(dm_sysload *out) {
    pthread_mutex_lock(&g_mu); int have = g_have; if (have) *out = g_cur; pthread_mutex_unlock(&g_mu);
    return have;
}

// Everything below runs on dm-sysload only
// Raw ticks per core (CPU_STATE_*); returns the core count (at most DM_SYSLOAD_MAX_CORES), 0 when the host does not answer
static int cpu_ticks(host_t host, uint32_t tk[DM_SYSLOAD_MAX_CORES][CPU_STATE_MAX]) {
    natural_t n = 0; processor_info_array_t info = NULL; mach_msg_type_number_t cnt = 0;
    if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS || !info) return 0;
    int nc = n < DM_SYSLOAD_MAX_CORES ? (int)n : DM_SYSLOAD_MAX_CORES;
    for (int i = 0; i < nc; i++) for (int s = 0; s < CPU_STATE_MAX; s++) tk[i][s] = (uint32_t)info[i * CPU_STATE_MAX + s];
    vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof *info);   // the kernel's out-of-line copy (cnt integers)
    return nc;
}
// 'P' or 'E' per logical CPU id: hw.perflevel1 is the efficiency level and Apple silicon numbers its cores first (no second level: every core is a performance
// core); the device tree's cluster-type of each CPU (IODeviceTree:/cpus/cpuN, "E" / "P") overrides that, and anything that is not 'P' counts as efficiency
static void cpu_kinds(int nc, char *kind) {
    int ne = 0; size_t sz = sizeof ne;
    if (sysctlbyname("hw.perflevel1.logicalcpu", &ne, &sz, NULL, 0) || ne < 0 || ne > nc) ne = 0;
    for (int i = 0; i < nc; i++) kind[i] = i < ne ? 'E' : 'P';
    io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus"); io_iterator_t it = 0;
    if (cpus && IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS) {
        for (io_object_t c; (c = IOIteratorNext(it)); IOObjectRelease(c)) {
            CFTypeRef id = IORegistryEntryCreateCFProperty(c, CFSTR("logical-cpu-id"), kCFAllocatorDefault, 0);   // a number (cpu-id is raw data)
            CFTypeRef ct = IORegistryEntryCreateCFProperty(c, CFSTR("cluster-type"), kCFAllocatorDefault, 0);     // data: "E" / "P" and a NUL
            int lid = -1;
            if (id && CFGetTypeID(id) == CFNumberGetTypeID()) CFNumberGetValue(id, kCFNumberIntType, &lid);
            if (lid >= 0 && lid < nc && ct && CFGetTypeID(ct) == CFDataGetTypeID() && CFDataGetLength(ct) > 0) kind[lid] = CFDataGetBytePtr(ct)[0] == 'P' ? 'P' : 'E';
            if (id) CFRelease(id);
            if (ct) CFRelease(ct);
        }
        IOObjectRelease(it);
    }
    if (cpus) IOObjectRelease(cpus);
}

static io_service_t g_accel;   // the first IOAccelerator whose PerformanceStatistics has the utilisation, kept for good once found
// The whole GPU's utilisation in %, -1 when no accelerator reports it
static int gpu_util(void) {
    if (!g_accel) {
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return -1;   // takes the matching dictionary
        for (io_service_t s; (s = IOIteratorNext(it));) {
            CFTypeRef ps = g_accel ? NULL : IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID() && CFDictionaryContainsKey(ps, CFSTR("Device Utilization %"))) g_accel = s; else IOObjectRelease(s);
            if (ps) CFRelease(ps);
        }
        IOObjectRelease(it);
        if (!g_accel) return -1;
    }
    int v = -1; CFTypeRef ps = IORegistryEntryCreateCFProperty(g_accel, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);   // a fresh copy each read
    if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
        CFTypeRef u = CFDictionaryGetValue(ps, CFSTR("Device Utilization %"));
        if (u && CFGetTypeID(u) == CFNumberGetTypeID()) CFNumberGetValue(u, kCFNumberIntType, &v);
    }
    if (ps) CFRelease(ps);
    return v < 0 ? -1 : v > 100 ? 100 : v;
}
// This process's GPU time since the last call in ns, -1 when not known. task_info(TASK_POWER_INFO_V2)'s task_gpu_utilisation is not it: xnu fills it only on
// x86_64 and it stays 0 on Apple silicon (measured: 0 after 3.7 s of Metal GPU time). The accelerator's user clients carry it instead, as Activity Monitor's
// GPU time column reads it: each child of g_accel is one Metal connection, IOUserClientCreator "pid <n>, <name>", AppUsage[].accumulatedGPUTime in ns (measured
// against the sum of Metal's GPUEndTime - GPUStartTime). Kept by registry entry id, so a client that closes drops out instead of turning the sum back; a client
// seen for the first time counts whole (it was opened since), except in the first walk, which only takes the baselines
enum { MAX_GPU_CLIENTS = 64 };
typedef struct { uint64_t id, ns; } gpu_client;
static gpu_client g_gc[MAX_GPU_CLIENTS], g_gc_new[MAX_GPU_CLIENTS]; static int g_ngc, g_gc_base;
static CFStringRef g_gc_me;   // "pid <this process>,"
static int64_t gpu_own_delta(void) {
    io_iterator_t it = 0;
    if (!g_accel || IORegistryEntryGetChildIterator(g_accel, kIOServicePlane, &it) != KERN_SUCCESS) return -1;
    if (!g_gc_me) g_gc_me = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("pid %d,"), (int)getpid());
    int nnew = 0; uint64_t d = 0;
    for (io_object_t c; (c = IOIteratorNext(it)); IOObjectRelease(c)) {
        CFTypeRef who = IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
        int mine = who && CFGetTypeID(who) == CFStringGetTypeID() && CFStringHasPrefix(who, g_gc_me);
        if (who) CFRelease(who);
        uint64_t id = 0;
        if (!mine || nnew == MAX_GPU_CLIENTS || IORegistryEntryGetRegistryEntryID(c, &id) != KERN_SUCCESS) continue;
        uint64_t ns = 0; CFTypeRef au = IORegistryEntryCreateCFProperty(c, CFSTR("AppUsage"), kCFAllocatorDefault, 0);   // one entry per API ("Metal")
        if (au && CFGetTypeID(au) == CFArrayGetTypeID()) for (CFIndex i = 0, n = CFArrayGetCount(au); i < n; i++) {
            CFTypeRef e = CFArrayGetValueAtIndex(au, i), t = e && CFGetTypeID(e) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(e, CFSTR("accumulatedGPUTime")) : NULL;
            int64_t v = 0; if (t && CFGetTypeID(t) == CFNumberGetTypeID() && CFNumberGetValue(t, kCFNumberSInt64Type, &v) && v > 0) ns += (uint64_t)v;
        }
        if (au) CFRelease(au);
        int k = 0; while (k < g_ngc && g_gc[k].id != id) k++;
        d += k < g_ngc ? (ns > g_gc[k].ns ? ns - g_gc[k].ns : 0) : ns;
        g_gc_new[nnew++] = (gpu_client){id, ns};
    }
    int whole = IOIteratorIsValid(it); IOObjectRelease(it);
    if (!whole) for (int k = 0; k < g_ngc && nnew < MAX_GPU_CLIENTS; k++) {   // a client opened or closed under the walk, which may have missed some: keep their baselines
        int j = 0; while (j < nnew && g_gc_new[j].id != g_gc[k].id) j++;
        if (j == nnew) g_gc_new[nnew++] = g_gc[k];
    }
    memcpy(g_gc, g_gc_new, (size_t)nnew * sizeof *g_gc); g_ngc = nnew;
    if (!g_gc_base) { g_gc_base = whole; return -1; }
    return whole ? (int64_t)d : -1;
}

enum { MAX_THR = 512 };
typedef struct { uint64_t id, us; } thr_time;
static thr_time g_tt[MAX_THR], g_tt_new[MAX_THR]; static int g_ntt;   // CPU time by thread id at the last sample; threads that exited drop out
// The busiest thread of this process over the last wall_us, % of one core (-1 when not known), and its name (its pthread name, else "thread <id>"). A thread seen
// for the first time only takes its baseline
static int busiest_thread(uint64_t wall_us, char *name, size_t n) {
    thread_act_array_t th = NULL; mach_msg_type_number_t nth = 0; name[0] = 0;
    if (task_threads(mach_task_self(), &th, &nth) != KERN_SUCCESS) return -1;
    int nnew = 0, best = -1; uint64_t best_us = 0, best_id = 0;
    for (mach_msg_type_number_t i = 0; i < nth; i++) {
        thread_identifier_info_data_t ii; mach_msg_type_number_t c1 = THREAD_IDENTIFIER_INFO_COUNT;
        thread_basic_info_data_t bi; mach_msg_type_number_t c2 = THREAD_BASIC_INFO_COUNT;
        if (nnew == MAX_THR || thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c1) != KERN_SUCCESS ||
            thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c2) != KERN_SUCCESS) continue;   // gone since task_threads
        uint64_t us = (uint64_t)(bi.user_time.seconds + bi.system_time.seconds) * 1000000u + (uint64_t)(bi.user_time.microseconds + bi.system_time.microseconds);
        g_tt_new[nnew++] = (thr_time){ii.thread_id, us};
        for (int k = 0; k < g_ntt; k++) if (g_tt[k].id == ii.thread_id) {
            uint64_t d = us > g_tt[k].us ? us - g_tt[k].us : 0;
            if (best < 0 || d > best_us) { best = (int)i; best_us = d; best_id = ii.thread_id; }
            break;
        }
    }
    if (best >= 0) {   // only the winner's name, while its port is still held (pthread_getname_np checks the thread is still listed)
        pthread_t pt = pthread_from_mach_thread_np(th[best]);
        if (!pt || pthread_getname_np(pt, name, n) || !name[0]) snprintf(name, n, "thread %llu", (unsigned long long)best_id);
    }
    for (mach_msg_type_number_t i = 0; i < nth; i++) mach_port_deallocate(mach_task_self(), th[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof *th);
    memcpy(g_tt, g_tt_new, (size_t)nnew * sizeof *g_tt); g_ntt = nnew;
    if (best < 0 || !wall_us) return -1;
    uint64_t pct = (best_us * 100 + wall_us / 2) / wall_us;
    return pct > 100 ? 100 : (int)pct;
}

static void *sysload_main(void *arg) {
    (void)arg;
    pthread_setname_np("dm-sysload");
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);   // under a millisecond of work twice a second: never in the way of the game's threads
    host_t host = mach_host_self();                        // one send right, kept for the thread's life
    uint32_t t0[DM_SYSLOAD_MAX_CORES][CPU_STATE_MAX], t1[DM_SYSLOAD_MAX_CORES][CPU_STATE_MAX]; char kind[DM_SYSLOAD_MAX_CORES];
    int nc = cpu_ticks(host, t0); if (nc) cpu_kinds(nc, kind);
    char nm[64]; busiest_thread(0, nm, sizeof nm);   // the first baselines
    gpu_util(); gpu_own_delta();                      // finds the accelerator; its clients' baselines
    uint64_t w0 = now_ns();
    for (unsigned k = 1;; k++) {
        usleep(500000);
        dm_sysload s = {.thread_max = -1, .gpu_sys = -1, .gpu_game = -1};
        int n1 = cpu_ticks(host, t1); uint64_t w1 = now_ns(), wall = w1 - w0; int64_t gd = gpu_own_delta();
        if (n1 && !nc) cpu_kinds(n1, kind);   // the host answered for the first time: this round only takes the baseline
        else for (int i = 0; i < n1 && i < nc; i++) {
            uint32_t d[CPU_STATE_MAX]; for (int j = 0; j < CPU_STATE_MAX; j++) d[j] = t1[i][j] - t0[i][j];   // 32-bit differences survive a counter wrap
            uint64_t db = (uint64_t)d[CPU_STATE_USER] + d[CPU_STATE_SYSTEM] + d[CPU_STATE_NICE], dt = db + d[CPU_STATE_IDLE];
            int v = dt ? (int)((db * 100 + dt / 2) / dt) : 0;
            if (kind[i] == 'P') s.p[s.np++] = v; else s.e[s.ne++] = v;
        }
        if (n1) { nc = n1; memcpy(t0, t1, sizeof t0); }   // a failed read keeps the older baseline (the next window is longer)
        s.thread_max = busiest_thread(wall / 1000, s.thread_name, sizeof s.thread_name);
        s.gpu_sys = gpu_util();
        if (gd >= 0 && wall) { uint64_t v = ((uint64_t)gd * 100 + wall / 2) / wall; s.gpu_game = v > 100 ? 100 : (int)v; }   // overlapping work can pass 100
        pthread_mutex_lock(&g_mu); g_cur = s; g_have = 1; pthread_mutex_unlock(&g_mu);
        w0 = w1;
        if (k % 60 == 0) {   // every 30 s
            char t[256]; hud_load_text(t, sizeof t, &s);
            LOG("front end: load %s (T is the busiest thread: %s; the brackets are this process's own GPU time)", t, s.thread_name[0] ? s.thread_name : "not known");
        }
    }
    return NULL;
}
static void sysload_spawn(void) {
    pthread_t th;
    if (pthread_create(&th, NULL, sysload_main, NULL)) { LOG("[RED] front end: the load sampler thread could not start; the overlay has no load line"); return; }
    pthread_detach(th);
}
void dm_sysload_start(void) { static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, sysload_spawn); }
