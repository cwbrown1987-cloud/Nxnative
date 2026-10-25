// Run state reset (progswitch.c dm_runstate_snapshot / dm_runstate_restore): the statics of per-run files go back to their values at process start, a lock left held is free
// again, a once flag runs again, a zero-fill table the run filled is zero and no longer resident; the statics of process files and DM_PROCESS ones keep their values
#include "../dm.h"
#include <sys/mman.h>
#include <unistd.h>
#pragma clang section bss="" data=""
void dm_runstate_snapshot(void); size_t dm_runstate_restore(void);
void run_once(void), run_touch(void); int run_counter(void), run_zero(void), run_process(void), run_trylock(void); char *run_big(size_t *n); extern int r_once_runs;
static int p_counter = 5;
static int checks, fails;
#define CHECK(c, s) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s %s\n", ok_ ? "✓" : "✗", s); } while (0)
static size_t resident(char *p, size_t n) {
    size_t pg = (size_t)getpagesize(), np = n / pg, r = 0; char *v = malloc(np);
    if (mincore(p, n, v)) { free(v); return (size_t)-1; }
    for (size_t i = 0; i < np; i++) r += v[i] & 1;
    free(v); return r * pg;
}
int main(void) {
    dm_runstate_snapshot();
    run_once(); run_touch(); p_counter++;
    size_t n; char *big = run_big(&n);
    CHECK(run_counter() == 15 && run_zero() == 7 && !run_trylock() && r_once_runs == 1 && resident(big, n) >= (32u << 20), "the run changed its statics, holds its lock and filled 32 MB of a table");
    size_t by_hand = dm_runstate_restore();
    CHECK(run_counter() == 5 && run_zero() == 0, "a per-run file's statics are back to their initial values");
    CHECK(run_trylock(), "a lock the run left held is free");
    run_once();
    CHECK(r_once_runs == 2, "a once flag runs its body again in the next run");
    CHECK(resident(big, n) < (1u << 20), "the zero-fill table's pages are given back (not resident)");
    int zero = 1; for (size_t i = 0; i < n; i += 4096) zero &= !big[i];
    CHECK(zero, "and it reads zero");
    CHECK(by_hand < 64 * 1024, "only the pages at the ends of the zero-fill section were cleared by hand");
    CHECK(p_counter == 6 && run_process() == 2, "a process file's statics and a DM_PROCESS static keep their values");
    printf("== %d checks, %d failed ==\n", checks, fails);
    return fails != 0;
}
