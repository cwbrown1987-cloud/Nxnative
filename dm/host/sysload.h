// System load for the Mac overlay panel's load line, sampled every 0.5 s on a thread of its own (sysload_mac.c, Mac only); it never touches the
// guest's threads and the renderer. The types are plain C so the panel's text formatter (hud_text.h) and its test build without IOKit.
#pragma once

enum { DM_SYSLOAD_MAX_CORES = 32 };
// Percentages, -1 = not known. p / e: every performance / efficiency core in logical CPU order. thread_max: the busiest thread of this
// process, % of one core (thread_name: its name, for the log). gpu_sys: the whole GPU's utilisation as macOS reports it, every app on it
// included, not this game alone. gpu_game: this process's own share of GPU time.
typedef struct { int np, ne, p[DM_SYSLOAD_MAX_CORES], e[DM_SYSLOAD_MAX_CORES], thread_max, gpu_sys, gpu_game; char thread_name[64]; } dm_sysload;

void dm_sysload_start(void);           // starts the sampler thread once; any thread
int dm_sysload_get(dm_sysload *out);   // 0 before the first sample
