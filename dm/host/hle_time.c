// nn::time：真机经 time 服务取网络校准的用户时钟；宿主直接取系统时钟（单机、离线）。
// 布局按公开 Horizon ABI：PosixTime = int64 秒；CalendarTime = {s16 年, s8 月/日/时/分/秒}；
// CalendarAdditionalInfo = {u32 星期, u32 年内日, char 时区名[8], u32 夏令时, s32 UTC 偏移秒}。
// nn::time: a real device gets the network-calibrated user clock through the time service; the host reads the system clock directly (single machine, offline).
// Layout follows the public Horizon ABI: PosixTime = int64 seconds; CalendarTime = {s16 year, s8 month/day/hour/minute/second};
// CalendarAdditionalInfo = {u32 day of week, u32 day of year, char time zone name[8], u32 DST, s32 UTC offset in seconds}.
#include "hle.h"
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

typedef struct { int16_t year; int8_t month, day, hour, minute, second; int8_t pad; } CalendarTime;
typedef struct { uint32_t wday, yday; char tzname[8]; uint32_t dst; int32_t offset; } CalendarAdditionalInfo;

// DM_FIXED_TIME=秒（确定性对拍用；真值侧对应 dm/verify/ryu/drive.py --fix-time）：
// ① 用户时钟（存档 d2s +0x20 最后游玩时间、.meta last_modified_time 的来源）恒返回该值；
// ② 建局随机数种子那一处 time()（main 0x3509a0 bl time，返回点 0x3509a4，与 drive.py 同点）返回该值。
// 本 SDK 的 libc time() 是开机时长（clock_gettime(0) → __nnmusl_ClockGetTime → GetSystemTick），不是墙钟；
// main 另有 17 处 time() 调用不动，原样转给 SDK 自己的 time()。
// DM_FIXED_TIME=seconds (for deterministic comparison; the ground-truth side counterpart is dm/verify/ryu/drive.py --fix-time):
// ① the user clock (source of the save's d2s +0x20 last-played time and .meta last_modified_time) always returns this value;
// ② the one time() at the game-creation random seed (main 0x3509a0 bl time, return point 0x3509a4, same point as drive.py) returns this value.
// This SDK's libc time() is uptime (clock_gettime(0) → __nnmusl_ClockGetTime → GetSystemTick), not wall clock;
// the other 17 time() call sites in main are left alone and forwarded unchanged to the SDK's own time().
static int64_t fixed_time(void) {
    static int64_t v = -2;
    if (v == -2) { const char *e = getenv("DM_FIXED_TIME"); v = e ? strtoll(e, 0, 0) : -1;
                   if (v >= 0) LOG("DM_FIXED_TIME=%lld：用户时钟与建局 time()（main 0x3509a4）返回定值", (long long)v); }
    return v;
}
HLE_FORCE("time", "按返回点认出建局种子那一处（DM_FIXED_TIME）；其余原样转调 SDK 的 time()", int64_t, h_time_time, int64_t *t) {
    uint64_t lr = (uint64_t)__builtin_return_address(0);
    static int64_t (*sdk_time)(int64_t *); static uint64_t seed_ret;
    if (!sdk_time) {
        module_t *ms = NULL, *mm = NULL;
        for (int i = 0; i < g_nmod; i++) { if (!strcmp(g_mod[i].name, "sdk")) ms = &g_mod[i]; if (!strcmp(g_mod[i].name, "main")) mm = &g_mod[i]; }
        void *f = ms ? module_sym(ms, "time") : NULL; if (!f) die("SDK 里找不到 time");
        uint32_t w = mm && !strcmp(mm->build_id, DM_D2R_BUILD) ? *(uint32_t *)(mm->base + 0x3509a0) : 0;   // 只在 D2R 构建上读（别的游戏这里是不相干的代码，main 小于 3.3 MB 还会越界） | read only on the D2R build (elsewhere this is unrelated code, and a main smaller than 3.3 MB would be read past its end)
        if ((w & 0xfc000000) == 0x94000000) seed_ret = (uint64_t)mm->base + 0x3509a4;               // bl time（构建 db0507f3…；改写器会改跳转目标，只认 bl 本身） | bl time (build db0507f3…; the rewriter changes the branch target, so only the bl itself is matched)
        else if (fixed_time() >= 0) LOG("【红】DM_FIXED_TIME：main 0x3509a0 不是预期的 bl time（%#x），建局 time() 未固定", w);
        sdk_time = (int64_t (*)(int64_t *))f;
    }
    int64_t ft = fixed_time();
    if (ft >= 0 && lr == seed_ret) {
        static int once; if (!once++) LOG("DM_FIXED_TIME：建局 time() 返回 %lld", (long long)ft);
        if (t) *t = ft; return ft;
    }
    return sdk_time(t);
}

HLE_FORCE("_ZN2nn4time10InitializeEv", "连 time 服务；时钟改取宿主系统时间", Result, h_time_Initialize, void) { return RES_OK; }
HLE_FORCE("_ZN2nn4time13IsInitializedEv", "time 服务已被接管，恒为已初始化", int, h_time_IsInitialized, void) { return 1; }
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock14GetCurrentTimeEPNS0_9PosixTimeE", "用户时钟 → 宿主 time()", Result, h_time_GetCurrentTime, int64_t *out) {
    int64_t ft = fixed_time(); *out = ft >= 0 ? ft : time(NULL); return RES_OK;
}
// 首领连战第 6–10 关的强制恐怖地带（dm_bossrush.c 设）：g_dm_tz_time 非 0 且未过期时，只有「恐怖地带」那几处取时钟拿到它，存档时间等其余调用照旧。
// 哪几处：返回点落在地带函数 0x58f1e0 起的那一簇（0x58f1e0–0x591440），或返回后 8 条指令内调地带日程 0x58f310（服务端 0x636b38 套地带、0x694b48 等 9 处）。
// 过期：dm_bossrush 每拍续 1 秒，本局停拍（退出 / 崩溃）后不再生效，下一局建局时取到的是真实时钟。
// Forced Terror Zone for stages 6–10 of the boss rush (set by dm_bossrush.c): when g_dm_tz_time is non-zero and not expired, only the clock reads at the "Terror Zone" sites get it; save timestamps and all other calls are unchanged.
// Which sites: the return point falls in the cluster starting at the zone function 0x58f1e0 (0x58f1e0–0x591440), or the zone schedule 0x58f310 is called within 8 instructions after the return (server side 0x636b38 applying the zone, 0x694b48 and so on, 9 sites).
// Expiry: dm_bossrush renews it by 1 second every tick; once this run stops ticking (exit / crash) it no longer applies, and the next run gets the real clock when the game is created.
_Atomic int64_t g_dm_tz_time;
_Atomic uint64_t g_dm_tz_live_ns;
static int tz_site(uint64_t lr) {   // 只在强制期间才判，每次读返回点后 8 条指令，不缓存（多线程都会取时钟） | Checked only while forcing is active, reading the 8 instructions after the return point each time, no caching (several threads read the clock)
    static _Atomic uint64_t base; uint64_t b = atomic_load(&base);
    if (!b) { for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) b = (uint64_t)g_mod[i].base; atomic_store(&base, b); }
    if (!b || lr < b) return 0;
    uint64_t off = lr - b; if (off > 0x58f1e0 && off < 0x591440) return 1;
    for (int k = 0; k < 8; k++) { uint32_t w = *(const uint32_t *)(uintptr_t)(lr + 4 * k);
        if ((w & 0xfc000000) == 0x94000000) { int64_t imm = w & 0x3ffffff; if (imm & 0x2000000) imm -= 1 << 26; if (off + 4 * k + imm * 4 == 0x58f310) return 1; } }
    return 0;
}
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock3nowEv", "用户时钟 → 宿主 time()；首领连战强制地带时恐怖地带那几处另返回", int64_t, h_time_now, void) {
    int64_t tz = atomic_load(&g_dm_tz_time);
    if (tz && (uint64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC) < atomic_load(&g_dm_tz_live_ns) && tz_site((uint64_t)__builtin_return_address(0))) return tz;
    int64_t ft = fixed_time(); return ft >= 0 ? ft : time(NULL); }
HLE_FORCE("_ZN2nn4time23StandardUserSystemClock9to_time_tERKNSt3__16chrono10time_pointINS0_17SystemClockTraitsENS3_8durationIlNS2_5ratioILl1ELl1EEEEEEE",
          "SDK 实现与 now() 配套，一并接管", int64_t, h_time_to_time_t, const int64_t *tp) { return *tp; }
HLE_FORCE("_ZN2nn4time14ToCalendarTimeEPNS0_12CalendarTimeEPNS0_22CalendarAdditionalInfoERKNS0_9PosixTimeE",
          "连 time 服务的时区规则；改用宿主 localtime_r", Result, h_time_ToCalendarTime, CalendarTime *ct, CalendarAdditionalInfo *ai, const int64_t *pt) {
    time_t t = *pt; struct tm tm; localtime_r(&t, &tm);
    static int once; if (!once++) LOG("ToCalendarTime：首次换算 %lld → %04d-%02d-%02d %02d:%02d（时区 %s，偏移 %ld 秒）", (long long)t, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_zone ? tm.tm_zone : "?", (long)tm.tm_gmtoff);
    if (ct) *ct = (CalendarTime){(int16_t)(tm.tm_year + 1900), (int8_t)(tm.tm_mon + 1), (int8_t)tm.tm_mday, (int8_t)tm.tm_hour, (int8_t)tm.tm_min, (int8_t)tm.tm_sec, 0};
    if (ai) { memset(ai, 0, sizeof *ai); ai->wday = tm.tm_wday; ai->yday = tm.tm_yday; strlcpy(ai->tzname, tm.tm_zone ? tm.tm_zone : "UTC", sizeof ai->tzname);
              ai->dst = tm.tm_isdst > 0; ai->offset = (int32_t)tm.tm_gmtoff; }
    return RES_OK;
}
// 反向：本地日历 → 绝对秒（十三机兵防卫圈）。夏令时切换时一个本地时刻可对应 0 或 2 个绝对秒，宿主 mktime 只给一个
// The reverse: local calendar → absolute seconds (13 Sentinels). Around a daylight-saving switch one local time maps to 0 or 2 absolute seconds; the host's mktime gives one
HLE_FORCE("_ZN2nn4time11ToPosixTimeEPiPNS0_9PosixTimeEiRKNS0_12CalendarTimeE",
          "连 time 服务的时区规则；改用宿主 mktime", Result, h_time_ToPosixTime, int *count, int64_t *out, int n, const CalendarTime *ct) {
    struct tm tm = {.tm_year = ct->year - 1900, .tm_mon = ct->month - 1, .tm_mday = ct->day, .tm_hour = ct->hour, .tm_min = ct->minute, .tm_sec = ct->second, .tm_isdst = -1};
    time_t t = mktime(&tm);
    if (count) *count = n > 0;
    if (n > 0 && out) out[0] = (int64_t)t;
    return RES_OK;
}
// 本地时刻换算强制接宿主 libc：SDK 自带的 localtime / localtime_r / mktime 没有时区数据、恒按 UTC（宿主实测：编年史「首次发现」由
// main+0xb04d34 调 localtime 再 strftime 出，差 8 小时）。真机 Switch 的 SDK 按系统时区换算，这里跟宿主系统时区走才一致；
// 宿主 TZ 平时 = 系统时区，只在 DM_FIXED_TIME 确定性对拍时钉 UTC（main.c）。struct tm 布局两边相同（9 个 int、long 偏移、时区名指针）。
// gmtime / gmtime_r / timegm 本来就是 UTC，不接。hle_table.c 的同名直通项只在符号没有定义时才生效（SDK 有定义），所以要 HLE_FORCE
// Local time conversion is forced onto the host libc: the SDK's own localtime / localtime_r / mktime have no time zone data and always use UTC (measured on the host: the chronicle's 「首次发现」(First Discovered) is produced by
// main+0xb04d34 calling localtime and then strftime, and was off by 8 hours). The SDK on a real Switch converts by the system time zone, so only following the host system time zone here is consistent;
// the host TZ normally = the system time zone, and is pinned to UTC only for deterministic comparison with DM_FIXED_TIME (main.c). The struct tm layout is the same on both sides (9 ints, long offset, time zone name pointer).
// gmtime / gmtime_r / timegm are UTC anyway and are not taken over. The same-named pass-through entries in hle_table.c only take effect when the symbol has no definition (the SDK defines them), hence HLE_FORCE
HLE_FORCE("localtime", "本地时刻 → 宿主 localtime（跟系统时区）", struct tm *, h_localtime, const int64_t *t) { time_t v = (time_t)*t; return localtime(&v); }
HLE_FORCE("localtime_r", "本地时刻 → 宿主 localtime_r（跟系统时区）", struct tm *, h_localtime_r, const int64_t *t, struct tm *out) { time_t v = (time_t)*t; return localtime_r(&v, out); }
HLE_FORCE("mktime", "本地日历 → 绝对秒，宿主 mktime（跟系统时区）", int64_t, h_mktime, struct tm *tm) { return (int64_t)mktime(tm); }

// 时钟快照与钟差（王国之泪 1.0.0）：SDK 这几处都要 time 服务对象（Initialize 接管后它一直是空的，原版直接中止）或服务的共享内存。
// 宿主：steady 时钟 = 墙钟秒、时钟源号取一个固定值（跨次启动的快照仍能直接相减，同真机没重置过 RTC 的情形）；用户钟、网络钟都 = 墙钟，偏移 0。
// ClockSnapshot 布局（0xD0 字节，sdk 15.3.1 构造函数反汇编：+0x50 / +0x58 两份日历缺省 1970-01-01，+0x60 / +0x78 两份附加信息、时区名 "UTC"）：
//   +0x00 用户钟上下文 {偏移 s64, steady 时间点 {秒 s64, 时钟源号 16 字节}}、+0x20 网络钟上下文、+0x40 用户钟秒、+0x48 网络钟秒、
//   +0x90 steady 时间点、+0xA8 地区名 36 字节、+0xCC 自动校时、+0xCD 类型
// Clock snapshots and clock differences (TotK 1.0.0): in the SDK all of these need the time service object (null since Initialize is taken over; the original aborts) or the service's shared memory.
// Host: steady clock = wall-clock seconds with a fixed clock source id (snapshots from different launches still subtract directly, as on a device whose RTC was never reset); the user and network clocks = wall clock, offset 0.
// ClockSnapshot layout (0xD0 bytes, from the sdk 15.3.1 constructor disassembly: two calendars at +0x50 / +0x58 defaulting to 1970-01-01, two additional infos at +0x60 / +0x78 with time zone name "UTC"):
//   +0x00 user clock context {offset s64, steady time point {seconds s64, clock source id 16 bytes}}, +0x20 network clock context, +0x40 user clock seconds, +0x48 network clock seconds,
//   +0x90 steady time point, +0xA8 location name 36 bytes, +0xCC automatic correction, +0xCD type
typedef struct { int64_t sec; uint8_t source[16]; } SteadyPoint;
typedef struct { int64_t offset; SteadyPoint steady; } ClockContext;
typedef struct {
    ClockContext user, network; int64_t user_time, network_time;
    CalendarTime user_cal, network_cal; CalendarAdditionalInfo user_info, network_info;
    SteadyPoint steady; char location[36]; uint8_t auto_correct, type; uint16_t pad;
} ClockSnapshot;
_Static_assert(sizeof(ClockSnapshot) == 0xD0 && __builtin_offsetof(ClockSnapshot, steady) == 0x90 && __builtin_offsetof(ClockSnapshot, auto_correct) == 0xCC, "ClockSnapshot 布局");
#define RES_TIME_NOT_FOUND 0x19074u   // time 模块 116，描述 200：两份快照没有共同的时钟可比 | time module 116, description 200: the two snapshots share no clock to compare
static const uint8_t g_steady_source[16] = {'n', 'x', 'n', 'a', 't', 'i', 'v', 'e', '-', 's', 't', 'e', 'a', 'd', 'y', 0};
static int64_t wall_now(void) { int64_t ft = fixed_time(); return ft >= 0 ? ft : time(NULL); }
HLE_FORCE("_ZN2nn4time13ClockSnapshot29CreateWithStandardSystemClockEPS1_", "要 time 服务对象；按宿主墙钟填快照",
          Result, h_time_SnapshotCreate, ClockSnapshot *s) {
    int64_t now = wall_now(); memset(s, 0, sizeof *s);
    s->steady.sec = now; memcpy(s->steady.source, g_steady_source, 16);
    s->user = s->network = (ClockContext){0, s->steady};
    s->user_time = s->network_time = now;
    h_time_ToCalendarTime(&s->user_cal, &s->user_info, &now); s->network_cal = s->user_cal; s->network_info = s->user_info;
    char link[256]; ssize_t n = readlink("/etc/localtime", link, sizeof link - 1); const char *z = NULL;
    if (n > 0) { link[n] = 0; z = strstr(link, "zoneinfo/"); }
    strlcpy(s->location, z ? z + 9 : "UTC", sizeof s->location);
    s->auto_correct = 1;
    return RES_OK;
}
// 两份快照的间隔（纳秒）：同一时钟源就用 steady 时间点相减，否则两边都有网络钟秒就用它，再不行回「没有可比的钟」（同 Ryujinx 的服务端实现）
// Span between two snapshots (nanoseconds): with the same clock source subtract the steady time points; otherwise use the network clock seconds if both have them; otherwise answer "no comparable clock" (same as Ryujinx's service implementation)
HLE_FORCE("_ZN2nn4time20CalculateSpanBetweenEPNS_8TimeSpanERKNS0_13ClockSnapshotES5_", "要 time 服务对象；宿主按快照内容相减",
          Result, h_time_SpanBetween, int64_t *out, const ClockSnapshot *a, const ClockSnapshot *b) {
    if (!memcmp(a->steady.source, b->steady.source, 16)) { *out = (b->steady.sec - a->steady.sec) * 1000000000; return RES_OK; }
    if (a->network_time && b->network_time) { *out = (b->network_time - a->network_time) * 1000000000; return RES_OK; }
    return RES_TIME_NOT_FOUND;
}
// 用户手动改钟造成的差（纳秒）：用户钟上下文偏移之差；时钟源不同、或两边都开着自动校时，答 0（同 Ryujinx）。宿主的偏移恒 0，所以恒 0
// Difference caused by the user changing the clock by hand (nanoseconds): the difference of the user clock context offsets; with different clock sources, or automatic correction on in both, the answer is 0 (same as Ryujinx). The host's offset is always 0, so this is always 0
HLE_FORCE("_ZN2nn4time48CalculateStandardUserSystemClockDifferenceByUserERKNS0_13ClockSnapshotES3_", "要 time 服务对象；宿主按快照内容算",
          int64_t, h_time_UserDiff, const ClockSnapshot *a, const ClockSnapshot *b) {
    if (memcmp(a->user.steady.source, b->user.steady.source, 16) || (a->auto_correct && b->auto_correct)) return 0;
    return (b->user.offset - a->user.offset) * 1000000000;
}
HLE_FORCE("_ZN2nn4time19StandardSteadyClock3nowEv", "读 time 服务的共享内存；宿主 = 快照里同一个 steady 秒（墙钟）", int64_t, h_time_SteadyNow, void) { return wall_now(); }
