// The per-run half of t_runstate: a host file's statics as dm.h places them (dm_run.h's sections)
#include "../dm.h"
#include <dispatch/dispatch.h>
static int r_counter = 5, r_zero;
static char r_big[64 << 20];
static pthread_mutex_t r_mu = PTHREAD_MUTEX_INITIALIZER;
DM_PROCESS int r_once_runs;   // counts the once body across runs
DM_PROCESS static int r_process = 1;   // a process-lifetime static in a per-run file
static void once_body(void *p) { (void)p; r_once_runs++; }
void run_once(void) { static dispatch_once_t once; dispatch_once_f(&once, NULL, once_body); }
void run_touch(void) { r_counter += 10; r_zero = 7; memset(r_big, 0x5a, 32 << 20); pthread_mutex_lock(&r_mu); r_process++; }   // leaves the lock held, as a thread that left would
int run_counter(void) { return r_counter; }
int run_zero(void) { return r_zero; }
int run_process(void) { return r_process; }
int run_trylock(void) { int ok = !pthread_mutex_trylock(&r_mu); if (ok) pthread_mutex_unlock(&r_mu); return ok; }
char *run_big(size_t *n) { *n = sizeof r_big; return r_big; }
