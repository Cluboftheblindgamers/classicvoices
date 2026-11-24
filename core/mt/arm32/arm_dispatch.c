#ifdef CV_MT_ARM32_EXPERIMENT
// Serial dispatch_async_f queues for the isolated engine probe.
#include "../mt_internal.h"
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <string.h>

typedef struct Job { uint32_t function, context; struct Job *next; } Job;
typedef struct {
    uint32_t guest;
    MtThread *thread;
    Job *head, *tail;
} Queue;
static Queue queues[8];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
void mt_arm32_dispatch_reset(void) { pthread_mutex_lock(&mutex); memset(queues,0,sizeof queues); pthread_mutex_unlock(&mutex); }

static void *worker(void *opaque) {
    Queue *q = opaque;
    MtThread *t = q->thread;
    Mt *m = t->m;
    t->cpu.fault = &t->fault;
    int failed = setjmp(t->fault);
    if (failed) {
        fprintf(stderr, "ARM32 worker fault: %s\n", t->cpu.err);
        m->broken = 1;
    } else for (;;) {
        pthread_mutex_lock(&mutex);
        while (!q->head && !m->dying) {
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_nsec += 10000000;
            if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&changed, &mutex, &until);
        }
        if (m->dying) { pthread_mutex_unlock(&mutex); break; }
        Job *job = q->head;
        q->head = job->next;
        if (!q->head) q->tail = NULL;
        uint32_t function = job->function, context = job->context;
        free(job);
        pthread_mutex_unlock(&mutex);
        mt_call_on(m, &t->cpu, function, 1, &context);
    }
    pthread_mutex_lock(&mutex);
    while (q->head) { Job *job = q->head; q->head = job->next; free(job); }
    q->tail = NULL;
    pthread_mutex_unlock(&mutex);
    mt_thread_free(t);
    __sync_sub_and_fetch(&m->live, 1);
    return NULL;
}

void mt_arm32_dispatch_async_f(Mt *m, X86 *c) {
    uint32_t guest = x86_arg(c, 0);
    Job *job = calloc(1, sizeof *job);
    if (!job) x86_fault(c, "cannot allocate ARM32 dispatch job");
    job->context = x86_arg(c, 1); job->function = x86_arg(c, 2);
    pthread_mutex_lock(&mutex);
    Queue *q = NULL;
    for (unsigned i = 0; i < 8; i++) if (queues[i].guest == guest && queues[i].thread) { q = &queues[i]; break; }
    if (!q) for (unsigned i = 0; i < 8; i++) if (!queues[i].thread) {
        q = &queues[i]; q->guest = guest; q->thread = mt_thread_new(m);
        if (!q->thread) { pthread_mutex_unlock(&mutex); free(job); x86_fault(c, "out of ARM32 dispatch threads"); }
        __sync_add_and_fetch(&m->live, 1);
        int rc = mt_thread_start(worker, q);
        if (rc) {
            mt_thread_free(q->thread); q->thread = NULL;
            __sync_sub_and_fetch(&m->live, 1);
            pthread_mutex_unlock(&mutex); free(job); x86_fault(c, "cannot start ARM32 dispatch worker: %d", rc);
        }
        break;
    }
    if (!q) { pthread_mutex_unlock(&mutex); free(job); x86_fault(c, "too many ARM32 dispatch queues"); }
    if (q->tail) q->tail->next = job; else q->head = job;
    q->tail = job;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    c->r[EAX] = 0;
}

#endif
