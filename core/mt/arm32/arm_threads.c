#ifdef CV_MT_ARM32_EXPERIMENT
// Detached guest pthreads for the command-line experiment (no join API used).
#include "../mt_internal.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { MtThread *thread; uint32_t function, context; } Start;
static _Thread_local jmp_buf *thread_exit;
static uint32_t known_ids[64];
static unsigned id_count;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
void mt_arm32_threads_reset(void) { pthread_mutex_lock(&mutex); memset(known_ids,0,sizeof known_ids); id_count=0; pthread_mutex_unlock(&mutex); }

static void *entry(void *opaque) {
    Start *start = opaque;
    MtThread *t = start->thread;
    Mt *m = t->m;
    uint32_t function = start->function, context = start->context;
    free(start);
    jmp_buf exit;
    thread_exit = &exit;
    t->cpu.fault = &t->fault;
    if (setjmp(t->fault)) {
        if (!m->dying) { fprintf(stderr, "ARM32 pthread fault: %s\n", t->cpu.err); m->broken = 1; }
    } else if (!setjmp(exit)) mt_call_on(m, &t->cpu, function, 1, &context);
    thread_exit = NULL;
    mt_thread_free(t);
    __sync_sub_and_fetch(&m->live, 1);
    return NULL;
}
static void h_create(Mt *m, X86 *c) {
    if (x86_arg(c, 1)) x86_fault(c, "custom pthread attributes unsupported by probe");
    uint32_t output = x86_arg(c, 0);
    MtThread *t = mt_thread_new(m);
    if (!t) { c->r[EAX] = EAGAIN; return; }
    Start *start = calloc(1, sizeof *start);
    if (!start) { mt_thread_free(t); c->r[EAX] = ENOMEM; return; }
    start->thread = t; start->function = x86_arg(c, 2); start->context = x86_arg(c, 3);
    uint32_t id = t->self;
    pthread_mutex_lock(&mutex);
    if (id_count == 64) { pthread_mutex_unlock(&mutex); mt_thread_free(t); free(start); c->r[EAX] = EAGAIN; return; }
    known_ids[id_count++] = id;
    pthread_mutex_unlock(&mutex);
    __sync_add_and_fetch(&m->live, 1);
    int result = mt_thread_start(entry, start);
    if (result) { __sync_sub_and_fetch(&m->live, 1); mt_thread_free(t); free(start); }
    else wr32(c, output, id);
    c->r[EAX] = (uint32_t)result;
}
static void h_detach(Mt *m, X86 *c) {
    (void)m;
    uint32_t id = x86_arg(c, 0); int found = 0;
    pthread_mutex_lock(&mutex);
    for (unsigned i = 0; i < id_count; i++) if (known_ids[i] == id) found = 1;
    pthread_mutex_unlock(&mutex);
    c->r[EAX] = found ? 0 : ESRCH;
}
static void h_exit(Mt *m, X86 *c) {
    (void)m;
    if (!thread_exit) x86_fault(c, "pthread_exit outside a guest pthread");
    longjmp(*thread_exit, 1);
}
MtHle mt_arm32_thread_hle(const char *name) {
    if (!strcmp(name, "_pthread_create")) return h_create;
    if (!strcmp(name, "_pthread_detach")) return h_detach;
    if (!strcmp(name, "_pthread_exit")) return h_exit;
    return NULL;
}

#endif
