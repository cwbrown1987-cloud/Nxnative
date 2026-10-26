// A high-priority same-core notification thread must yield its guest core while
// its HLE blocks on the host condition variable, then resume notification delivery.
#include "../dm.h"
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include "../hle_thread.c"
static int observed_wait(pthread_cond_t *, pthread_mutex_t *);
#define pthread_cond_wait observed_wait
#include "../hle_oe.c"
#undef pthread_cond_wait
static _Atomic int waiting;
static uint32_t message;
static thr_t *main_thread;
static int observed_wait(pthread_cond_t *cv, pthread_mutex_t *mu) {
    if (cv == &g_mq_cond) atomic_store(&waiting, 1);
    return pthread_cond_wait(cv, mu);
}
void dm_audio_suspend(int on) { (void)on; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }
void dm_gfx_suspend(int on) { (void)on; }
static void timeout(int sig) { (void)sig; const char message[] = "[RED] notification scheduler test timed out\n"; write(2, message, sizeof message - 1); _exit(99); }
static void *notify(void *unused) {
    (void)unused;
    thr_t *t = calloc(1, sizeof *t);
    t->started=1; t->prio=28; t->core=0; t->mask=1;
    t->pt=pthread_self(); t->host_work=&dm_host_work;
    t->hand[0].by=main_thread; t->hand[0].epoch=main_thread->hand_epoch; t->nhand=1;
    pthread_setspecific(g_keythr,t);
    pthread_mutex_lock(&G); t->all=g_all; g_all=t; pthread_mutex_unlock(&G);
    message=h_oe_PopMsg();
    pthread_mutex_lock(&G); t->exited=1; pthread_mutex_unlock(&G);
    return NULL;
}
int main(void) {
    signal(SIGALRM,timeout);alarm(10);
    svc_thread_main_init();
    thr_t *self=cur();main_thread=self;self->hand_epoch=1;self->mask=1;self->core=0;self->prio=44;
    pthread_t thread;assert(!pthread_create(&thread,NULL,notify,NULL));
    while(!atomic_load(&waiting)) sched_yield();
    pthread_mutex_lock(&g_mq_lock);pthread_mutex_unlock(&g_mq_lock);
    // Before the fix this never returns: the notifier blocks in a native HLE
    // wait but is still counted as a runnable higher-priority guest thread.
    dm_yield_to_core_peers(0);
    dm_focus_set(2);
    assert(!pthread_join(thread,NULL));
    assert(message==15);
    puts("blocked notification thread releases its guest core; wake and delivery passed");
    return 0;
}
