#ifdef CV_MT_ARM32_EXPERIMENT
// Experimental ARM32 MacinTalk host. Not part of any app target.
// Existing HLE sees an i386-shaped argument frame in the SAME guest memory;
// guest execution and callbacks use the Thumb CPU instead of the x86 CPU.
#include "../mt_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
MtHle mt_arm32_audio_hle(const char *name);
MtHle mt_arm32_sqlite_hle(const char *name);
MtHle mt_arm32_thread_hle(const char *name);
MtHle mt_arm32_unicode_hle(const char *name);
void mt_arm32_dispatch_async_f(Mt *m, X86 *c);
void mt_arm32_unicode_reset(Mt *m);
void mt_arm32_audio_reset(void);
void mt_arm32_dispatch_reset(void);
void mt_arm32_sqlite_reset(Mt *m);
void mt_arm32_threads_reset(void);

static void reset_cpp(void);
void mt_arm32_reset(Mt *m) {
    mt_arm32_unicode_reset(m); mt_arm32_audio_reset(); mt_arm32_dispatch_reset();
    mt_arm32_sqlite_reset(m); mt_arm32_threads_reset(); reset_cpp();
}

static void h_new(Mt *m, X86 *c) { c->r[EAX] = mt_malloc(m, x86_arg(c, 0)); }
static void h_delete(Mt *m, X86 *c) { mt_free(m, x86_arg(c, 0)); }
// Normal execution only. Throw/resume remain unimplemented and fault;
// silently pretending to unwind a guest exception would corrupt its state.
static void h_unwind_registration(Mt *m, X86 *c) { (void)m; c->r[EAX] = 0; }
static void h_queue_attr(Mt *m, X86 *c) { (void)m; c->r[EAX] = x86_arg(c, 0); }
static void h_floatundidf(Mt *m, X86 *c) {
    (void)m;
    uint64_t value = (uint64_t)x86_arg(c, 0) | (uint64_t)x86_arg(c, 1) << 32;
    x86_fpush(c, (double)value);
}
static void h_scalbnf(Mt *m, X86 *c) {
    (void)m;
    uint32_t bits = x86_arg(c, 0); float value; memcpy(&value, &bits, 4);
    x86_fpush(c, scalbnf(value, (int)x86_arg(c, 1)));
}
static int compare_u32(const void *a, const void *b) {
    uint32_t x, y;
    memcpy(&x, a, 4); memcpy(&y, b, 4);
    return (x > y) - (x < y);
}
static void h_sort_u32(Mt *m, X86 *c) {
    uint32_t begin = x86_arg(c, 0), end = x86_arg(c, 1);
    if (end < begin || (end - begin) % 4) x86_fault(c, "invalid uint32 sort range");
    if (end != begin) { mt_check(m, c, begin, end - begin); qsort(G(m, begin), (end - begin) / 4, 4, compare_u32); }
}
// Darwin armv7 libc++'s default 12-byte basic_string layout:
// long {capacity|1, size, guest_data}; short {size<<1, data[11]}.
static void h_string_init(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), source = x86_arg(c, 1), length = x86_arg(c, 2);
    mt_check(m, c, object, 12); mt_check(m, c, source, length);
    if (length > 16 * 1024 * 1024) x86_fault(c, "experimental C++ string too large");
    if (length < 11) {
        memset(G(m, object), 0, 12);
        wr8(c, object, (uint8_t)(length << 1));
        if (length) memcpy(G(m, object + 1), G(m, source), length);
    } else {
        uint32_t capacity = (length + 16) & ~15u;
        uint32_t data = mt_malloc(m, capacity);
        memcpy(G(m, data), G(m, source), length); wr8(c, data + length, 0);
        wr32(c, object, capacity | 1); wr32(c, object + 4, length); wr32(c, object + 8, data);
    }
    c->r[EAX] = object;
}
static void h_string_delete(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0);
    if (rd8(c, object) & 1) mt_free(m, rd32(c, object + 8));
    memset(G(m, object), 0, 12);
}
static uint32_t string_size(X86 *c, uint32_t object) { return rd8(c, object) & 1 ? rd32(c, object + 4) : rd8(c, object) >> 1; }
static uint32_t string_data(X86 *c, uint32_t object) { return rd8(c, object) & 1 ? rd32(c, object + 8) : object + 1; }
static void string_append(Mt *m, X86 *c, uint32_t source, uint32_t length) {
    uint32_t object = x86_arg(c, 0), old_length = string_size(c, object), old_data = string_data(c, object);
    if (length > 16 * 1024 * 1024 || old_length > 16 * 1024 * 1024 - length) x86_fault(c, "C++ string append too large");
    uint32_t combined = mt_malloc(m, old_length + length + 1);
    mt_check(m, c, old_data, old_length); mt_check(m, c, source, length);
    memcpy(G(m, combined), G(m, old_data), old_length);
    memcpy(G(m, combined + old_length), G(m, source), length);
    int was_long = rd8(c, object) & 1;
    uint32_t args[] = {object, combined, old_length + length};
    for (unsigned i = 0; i < 3; i++) wr32(c, c->r[ESP] + 4 + i * 4, args[i]);
    h_string_init(m, c);
    if (was_long) mt_free(m, old_data);
    mt_free(m, combined);
}
static void h_string_push(Mt *m, X86 *c) {
    uint32_t byte = mt_malloc(m, 1);
    wr8(c, byte, (uint8_t)x86_arg(c, 1));
    string_append(m, c, byte, 1);
    mt_free(m, byte);
}
static void h_string_append_n(Mt *m, X86 *c) { string_append(m, c, x86_arg(c, 1), x86_arg(c, 2)); }
static void h_string_append_z(Mt *m, X86 *c) {
    uint32_t source = x86_arg(c, 1);
    string_append(m, c, source, (uint32_t)strlen(mt_str(m, source)));
}
static void h_string_append_repeat(Mt *m, X86 *c) {
    uint32_t count = x86_arg(c, 1), ch = x86_arg(c, 2);
    if (count > 16 * 1024 * 1024) x86_fault(c, "C++ repeated append too large");
    uint32_t bytes = mt_malloc(m, count + 1);
    memset(G(m, bytes), (int)(ch & 255), count);
    string_append(m, c, bytes, count); mt_free(m, bytes);
}
static void h_string_insert_char(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), iterator = x86_arg(c, 1), ch = x86_arg(c, 2);
    uint32_t data = string_data(c, object), length = string_size(c, object);
    if (iterator < data || iterator - data > length || length > 16 * 1024 * 1024)
        x86_fault(c, "invalid C++ string insert iterator");
    uint32_t at = iterator - data, combined = mt_malloc(m, length + 2);
    mt_check(m, c, data, length);
    memcpy(G(m, combined), G(m, data), at); wr8(c, combined + at, (uint8_t)ch);
    memcpy(G(m, combined + at + 1), G(m, data + at), length - at);
    int was_long = rd8(c, object) & 1;
    uint32_t args[] = {object, combined, length + 1};
    for (unsigned i = 0; i < 3; i++) wr32(c, c->r[ESP] + 4 + i * 4, args[i]);
    h_string_init(m, c);
    if (was_long) mt_free(m, data);
    mt_free(m, combined);
    c->r[EAX] = string_data(c, object) + at;
}
static void h_string_reserve(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), requested = x86_arg(c, 1);
    uint32_t capacity = rd8(c, object) & 1 ? (rd32(c, object) & ~1u) - 1 : 10;
    if (requested <= capacity) return;
    if (requested > 16 * 1024 * 1024) x86_fault(c, "C++ reserve too large");
    uint32_t data = string_data(c, object), length = string_size(c, object);
    uint32_t allocation = (requested + 16) & ~15u, replacement = mt_malloc(m, allocation);
    mt_check(m, c, data, length + 1); memcpy(G(m, replacement), G(m, data), length + 1);
    if (rd8(c, object) & 1) mt_free(m, data);
    wr32(c, object, allocation | 1); wr32(c, object + 4, length); wr32(c, object + 8, replacement);
}
static void h_string_assign_n(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), source = x86_arg(c, 1), length = x86_arg(c, 2);
    if (length > 16 * 1024 * 1024) x86_fault(c, "C++ assign too large");
    mt_check(m, c, source, length);
    uint32_t copy = mt_malloc(m, length + 1);
    memcpy(G(m, copy), G(m, source), length);
    uint32_t old = rd8(c, object) & 1 ? rd32(c, object + 8) : 0;
    wr32(c, c->r[ESP] + 8, copy);
    h_string_init(m, c);
    if (old) mt_free(m, old);
    mt_free(m, copy);
}
static void h_string_init_reserve(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), reserve = x86_arg(c, 3);
    h_string_init(m, c);
    wr32(c, c->r[ESP] + 8, reserve);
    h_string_reserve(m, c);
    c->r[EAX] = object;
}
static void h_string_assign_z(Mt *m, X86 *c) {
    uint32_t source = x86_arg(c, 1);
    wr32(c, c->r[ESP] + 12, (uint32_t)strlen(mt_str(m, source)));
    h_string_assign_n(m, c);
}
static void h_string_compare_z(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), length = string_size(c, object);
    const char *rhs = mt_str(m, x86_arg(c, 1));
    size_t rhs_length = strlen(rhs);
    uint32_t data = string_data(c, object);
    mt_check(m, c, data, length);
    int comparison = memcmp(G(m, data), rhs, length < rhs_length ? length : rhs_length);
    if (!comparison) comparison = (length > rhs_length) - (length < rhs_length);
    c->r[EAX] = (uint32_t)comparison;
}
static void h_string_copy(Mt *m, X86 *c) {
    uint32_t source = x86_arg(c, 1), length = string_size(c, source), data = string_data(c, source);
    wr32(c, c->r[ESP] + 8, data); wr32(c, c->r[ESP] + 12, length);
    h_string_init(m, c);
}
static void h_string_assign_string(Mt *m, X86 *c) {
    uint32_t source = x86_arg(c, 1), length = string_size(c, source), data = string_data(c, source);
    wr32(c, c->r[ESP] + 8, data); wr32(c, c->r[ESP] + 12, length);
    h_string_assign_n(m, c);
}
static void string_replace(Mt *m, X86 *c, uint32_t at, uint32_t removed, uint32_t source, uint32_t added) {
    uint32_t object=x86_arg(c,0);
    uint32_t length=string_size(c,object), data=string_data(c,object);
    if (at>length) x86_fault(c,"C++ string position out of range");
    if (removed>length-at) removed=length-at;
    if (added>16*1024*1024 || length-removed>16*1024*1024-added) x86_fault(c,"C++ string replacement too large");
    mt_check(m,c,data,length); mt_check(m,c,source,added);
    uint32_t total=length-removed+added, bytes=mt_malloc(m,total+1);
    memcpy(G(m,bytes),G(m,data),at); memcpy(G(m,bytes+at),G(m,source),added);
    memcpy(G(m,bytes+at+added),G(m,data+at+removed),length-at-removed);
    int was_long=rd8(c,object)&1;
    wr32(c,c->r[ESP]+8,bytes); wr32(c,c->r[ESP]+12,total); h_string_init(m,c);
    if (was_long) mt_free(m,data); mt_free(m,bytes);
}
static void h_string_insert_repeat(Mt *m,X86 *c) {
    uint32_t at=x86_arg(c,1), count=x86_arg(c,2), ch=x86_arg(c,3);
    if (count>16*1024*1024) x86_fault(c,"C++ insert too large");
    uint32_t bytes=mt_malloc(m,count+1); memset(G(m,bytes),(int)(ch&255),count);
    string_replace(m,c,at,0,bytes,count); mt_free(m,bytes);
}
static void h_string_insert_n(Mt *m,X86 *c) { string_replace(m,c,x86_arg(c,1),0,x86_arg(c,2),x86_arg(c,3)); }
static void h_string_insert_z(Mt *m,X86 *c) {
    uint32_t source=x86_arg(c,2), length=(uint32_t)strlen(mt_str(m,source));
    string_replace(m,c,x86_arg(c,1),0,source,length);
}
static void h_string_replace_n(Mt *m,X86 *c) { string_replace(m,c,x86_arg(c,1),x86_arg(c,2),x86_arg(c,3),x86_arg(c,4)); }
static void h_string_substring(Mt *m,X86 *c) {
    uint32_t source=x86_arg(c,1), at=x86_arg(c,2), count=x86_arg(c,3), length=string_size(c,source);
    if (at>length) x86_fault(c,"C++ substring position out of range");
    if (count>length-at) count=length-at;
    uint32_t data=string_data(c,source)+at;
    wr32(c,c->r[ESP]+8,data); wr32(c,c->r[ESP]+12,count); h_string_init(m,c);
}
static void h_dynamic_cast(Mt *m, X86 *c) {
    uint32_t object = x86_arg(c, 0), target = x86_arg(c, 2);
    if (!object) { c->r[EAX] = 0; return; }
    uint32_t vptr = rd32(c, object);
    uint32_t complete = object + rd32(c, vptr - 8), type = rd32(c, vptr - 4);
    const char *wanted = mt_str(m, rd32(c, target + 4));
    for (unsigned depth = 0; depth < 32; depth++) {
        if (!strcmp(mt_str(m, rd32(c, type + 4)), wanted)) { c->r[EAX] = complete; return; }
        uint32_t table = rd32(c, type);
        // RTTI's imported vtable address point is two words into the table.
        if (table < MT_TRAP_BASE || table >= MT_TRAP_BASE + 16u * (uint32_t)m->ntraps)
            x86_fault(c, "unrecognized RTTI vtable for %s", wanted);
        const char *name = m->trap_name[(table - MT_TRAP_BASE) / 16];
        if (!strcmp(name, "__ZTVN10__cxxabiv117__class_type_infoE")) { c->r[EAX] = 0; return; }
        if (strcmp(name, "__ZTVN10__cxxabiv120__si_class_type_infoE"))
            x86_fault(c, "experimental dynamic_cast needs multiple-inheritance support (%s)", wanted);
        type = rd32(c, type + 8); // single, public, non-virtual base at offset zero
    }
    x86_fault(c, "cyclic RTTI for %s", wanted);
}
static struct { uint32_t address; int busy; pthread_t owner; } guards[64];
static pthread_mutex_t guard_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t guard_changed = PTHREAD_COND_INITIALIZER;
static void h_guard_acquire(Mt *m, X86 *c) {
    uint32_t address = x86_arg(c, 0);
    pthread_mutex_lock(&guard_mutex);
    unsigned slot = 64;
    for (unsigned i = 0; i < 64; i++) if (guards[i].address == address) { slot = i; break; }
    if (slot == 64) for (unsigned i = 0; i < 64; i++) if (!guards[i].address) { slot = i; guards[i].address = address; break; }
    if (slot == 64) { pthread_mutex_unlock(&guard_mutex); x86_fault(c, "too many C++ static guards"); }
    while (guards[slot].busy) {
        if (m->dying || pthread_equal(guards[slot].owner, pthread_self())) {
            pthread_mutex_unlock(&guard_mutex); x86_fault(c, "recursive or cancelled C++ static initialization");
        }
        struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec++;
        pthread_cond_timedwait(&guard_changed, &guard_mutex, &until);
    }
    int initialize = !(rd8(c, address) & 1);
    if (initialize) { guards[slot].busy = 1; guards[slot].owner = pthread_self(); }
    pthread_mutex_unlock(&guard_mutex);
    c->r[EAX] = (uint32_t)initialize;
}
static void guard_finish(Mt *m, X86 *c, int initialized) {
    (void)m;
    uint32_t address = x86_arg(c, 0);
    pthread_mutex_lock(&guard_mutex);
    for (unsigned i = 0; i < 64; i++) if (guards[i].address == address) {
        if (initialized) wr8(c, address, 1);
        guards[i].busy = 0;
        pthread_cond_broadcast(&guard_changed); pthread_mutex_unlock(&guard_mutex); return;
    }
    pthread_mutex_unlock(&guard_mutex); x86_fault(c, "unknown C++ static guard");
}
static void h_guard_release(Mt *m, X86 *c) { guard_finish(m, c, 1); }
static void h_guard_abort(Mt *m, X86 *c) { guard_finish(m, c, 0); }
const char *mt_cf_text(Mt *m, uint32_t s);

static void h_engine_bundle(Mt *m, X86 *c) {
    const char *identifier = mt_cf_text(m, x86_arg(c, 0));
    if (strcmp(identifier, "com.apple.speech.ttsservice.macintalk.MacinTalk"))
        x86_fault(c, "unhandled bundle identifier %s", identifier);
    char path[4096];
    snprintf(path, sizeof path, "%s", m->images[m->nimages - 1].path);
    char *slash = strrchr(path, '/');
    if (!slash) x86_fault(c, "engine path must be absolute");
    *slash = 0;
    c->r[EAX] = mt_cf_bundle(m, path);
}

static void h_bundle_url(Mt *m, X86 *c) {
    uint32_t bundle = x86_arg(c, 0);
    if (!bundle) { c->r[EAX] = 0; return; }
    const char *path = mt_cf_text(m, bundle);
    uint32_t text = mt_cf_string(m, path, strlen(path));
    // Reuse the existing CFURL constructor with its four arguments.
    uint32_t args[] = {0, text, 0, 1};
    for (unsigned i = 0; i < 4; i++) wr32(c, c->r[ESP] + 4 + i * 4, args[i]);
    mt_lookup_hle("_CFURLCreateWithFileSystemPath")(m, c);
}

static void h_append_path(Mt *m, X86 *c) {
    const char *base = mt_cf_text(m, x86_arg(c, 1));
    const char *part = mt_cf_text(m, x86_arg(c, 2));
    char path[4096];
    if (snprintf(path, sizeof path, "%s/%s", base, part) >= (int)sizeof path)
        x86_fault(c, "URL path too long");
    uint32_t text = mt_cf_string(m, path, strlen(path));
    uint32_t args[] = {0, text, 0, x86_arg(c, 3)};
    for (unsigned i = 0; i < 4; i++) wr32(c, c->r[ESP] + 4 + i * 4, args[i]);
    mt_lookup_hle("_CFURLCreateWithFileSystemPath")(m, c);
}

static void h_url_reachable(Mt *m, X86 *c) {
    c->r[EAX] = access(mt_cf_text(m, x86_arg(c, 0)), F_OK) == 0;
    uint32_t error = x86_arg(c, 1);
    if (error) wr32(c, error, 0);
}
static void h_bundle_create(Mt *m, X86 *c) { c->r[EAX] = mt_cf_bundle(m, mt_cf_text(m, x86_arg(c, 1))); }
static void h_read_stream(Mt *m, X86 *c) {
    const char *path = mt_cf_text(m, x86_arg(c, 1));
    c->r[EAX] = mt_cf_string(m, path, strlen(path));
}
static void h_stream_open(Mt *m, X86 *c) { c->r[EAX] = access(mt_cf_text(m, x86_arg(c, 0)), R_OK) == 0; }
static void h_plist_stream(Mt *m, X86 *c) {
    uint32_t stream = x86_arg(c, 1), error = x86_arg(c, 5), format = x86_arg(c, 4);
    FILE *f = fopen(mt_cf_text(m, stream), "rb");
    if (!f) { c->r[EAX] = 0; return; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    rewind(f);
    if (size < 0 || size > 16 * 1024 * 1024) { fclose(f); x86_fault(c, "plist stream too large"); }
    uint32_t bytes = mt_malloc(m, (uint32_t)size);
    if (fread(G(m, bytes), 1, (size_t)size, f) != (size_t)size) { fclose(f); x86_fault(c, "plist read failed"); }
    fclose(f);
    uint32_t args[] = {0, bytes, (uint32_t)size};
    for (unsigned i = 0; i < 3; i++) wr32(c, c->r[ESP] + 4 + i * 4, args[i]);
    mt_lookup_hle("_CFDataCreate")(m, c);
    uint32_t xml_args[] = {0, c->r[EAX], 0, error};
    for (unsigned i = 0; i < 4; i++) wr32(c, c->r[ESP] + 4 + i * 4, xml_args[i]);
    mt_lookup_hle("_CFPropertyListCreateFromXMLData")(m, c);
    if (format) wr32(c, format, 100); // kCFPropertyListXMLFormat_v1_0
    mt_free(m, bytes);
}

static void arm_trap(Cpu *arm, uint32_t addr, void *ctx) {
    MtThread *t = ctx;
    Mt *m = t->m;
    X86 *c = &t->cpu;
    uint32_t index = (addr - MT_TRAP_BASE) / 16;
    if ((addr & 15) || index >= (uint32_t)m->ntraps)
        cpu_fault(arm, "invalid ARM import trap %#x", addr);
    const char *name = m->trap_name[index];
    MtHle handler = m->trap_fn[index];
    MtHle audio = mt_arm32_audio_hle(name);
    if (audio) handler = audio;
    MtHle sqlite = mt_arm32_sqlite_hle(name);
    if (sqlite) handler = sqlite;
    MtHle thread = mt_arm32_thread_hle(name);
    if (thread) handler = thread;
    if (!strcmp(name, "__Znwm") || !strcmp(name, "__Znam")) handler = h_new;
    if (!strcmp(name, "__ZdlPv") || !strcmp(name, "__ZdaPv")) handler = h_delete;
    if (!strcmp(name, "__Unwind_SjLj_Register") || !strcmp(name, "__Unwind_SjLj_Unregister")) handler = h_unwind_registration;
    if (!strcmp(name, "_CFBundleGetBundleWithIdentifier")) handler = h_engine_bundle;
    if (!strcmp(name, "_CFBundleCopyBundleURL")) handler = h_bundle_url;
    if (!strcmp(name, "_CFURLCreateCopyAppendingPathComponent")) handler = h_append_path;
    if (!strcmp(name, "_CFURLResourceIsReachable")) handler = h_url_reachable;
    if (!strcmp(name, "_CFBundleCreate")) handler = h_bundle_create;
    if (!strcmp(name, "_CFBundleCopyResourcesDirectoryURL")) handler = h_bundle_url;
    // iOS exposes the modern inode64 layout under the unadorned names.
    // Checked with clang's armv7 iOS ABI: st_size at 60, sizeof(stat)=108.
    if (!strcmp(name, "_stat")) handler = mt_lookup_hle("_stat$INODE64");
    if (!strcmp(name, "_fstat")) handler = mt_lookup_hle("_fstat$INODE64");
    if (!strcmp(name, "_CFReadStreamCreateWithFile")) handler = h_read_stream;
    if (!strcmp(name, "_CFReadStreamOpen")) handler = h_stream_open;
    if (!strcmp(name, "_CFPropertyListCreateWithStream")) handler = h_plist_stream;
    if (!strcmp(name, "_dispatch_queue_attr_make_with_qos_class")) handler = h_queue_attr;
    if (!strcmp(name, "_dispatch_async_f")) handler = mt_arm32_dispatch_async_f;
    if (!strcmp(name, "___floatundidf")) handler = h_floatundidf;
    if (!strcmp(name, "_scalbnf")) handler = h_scalbnf;
    if (!strcmp(name, "___dynamic_cast")) handler = h_dynamic_cast;
    if (!strcmp(name, "___cxa_guard_acquire")) handler = h_guard_acquire;
    if (!strcmp(name, "___cxa_guard_release")) handler = h_guard_release;
    if (!strcmp(name, "___cxa_guard_abort")) handler = h_guard_abort;
    if (!strcmp(name, "__ZNSt3__16__sortIRNS_6__lessIjjEEPjEEvT0_S5_T_")) handler = h_sort_u32;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6__initEPKcm")) handler = h_string_init;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6__initEPKcmm")) handler = h_string_init_reserve;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEED1Ev")) handler = h_string_delete;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE9push_backEc")) handler = h_string_push;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKcm")) handler = h_string_append_n;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKc")) handler = h_string_append_z;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEmc")) handler = h_string_append_repeat;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6insertENS_11__wrap_iterIPKcEEc")) handler = h_string_insert_char;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7reserveEm")) handler = h_string_reserve;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKcm")) handler = h_string_assign_n;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKc")) handler = h_string_assign_z;
    if (!strcmp(name, "__ZNKSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7compareEPKc")) handler = h_string_compare_z;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1ERKS5_")) handler = h_string_copy;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEaSERKS5_")) handler = h_string_assign_string;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6insertEmmc")) handler = h_string_insert_repeat;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6insertEmPKcm")) handler = h_string_insert_n;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6insertEmPKc")) handler = h_string_insert_z;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7replaceEmmPKcm")) handler = h_string_replace_n;
    if (!strcmp(name, "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1ERKS5_mmRKS4_")) handler = h_string_substring;
    MtHle unicode = mt_arm32_unicode_hle(name);
    if (unicode) handler = unicode;
    if (!handler)
        cpu_fault(arm, "unimplemented ARM import %s (lr=%#x)", name, arm->k.r[14]);
    uint32_t saved_sp = c->r[ESP];
    // Put the compatibility frame below the live ARM stack. Nested guest
    // callbacks must in turn start below this frame, not overwrite it.
    uint32_t arm_sp = arm->k.r[13];
    uint32_t frame = (arm_sp - 256) & ~15u;
    c->r[ESP] = frame;
    c->eip = arm->k.r[14] & ~1u;
    wr32(c, frame, arm->k.r[14]);
    for (unsigned i = 0; i < 32; i++)
        wr32(c, frame + 4 + 4 * i, i < 4 ? arm->k.r[i] : rd32(c, arm_sp + 4 * (i - 4)));
    arm->k.r[13] = frame - 16;
    c->r[EAX] = c->r[EDX] = 0;
    c->top = 0;
    memset(c->tag, 1, sizeof c->tag);
    if (m->verbose > 1) fprintf(stderr, "[arm-hle] %s\n", name);
    handler(m, c);
    // iOS armv7 uses the soft-float calling convention: floating results
    // are returned in r0/r1, whereas the existing HLE puts them in ST(0).
    if (!c->tag[c->top]) {
        double value = x86_fpop(c);
        if (!strcmp(name, "_ceilf") || !strcmp(name, "_floorf") ||
            !strcmp(name, "_expf") || !strcmp(name, "_powf") ||
            !strcmp(name, "_logf") || !strcmp(name, "_log2f") ||
            !strcmp(name, "_exp2f") || !strcmp(name, "_cosf") ||
            !strcmp(name, "_sinf") || !strcmp(name, "_scalbnf") ||
            !strcmp(name, "_cblas_sdot") || !strcmp(name, "_cblas_snrm2")) {
            float f = (float)value;
            memcpy(&arm->k.r[0], &f, 4);
        } else {
            uint64_t bits;
            memcpy(&bits, &value, 8);
            arm->k.r[0] = (uint32_t)bits;
            arm->k.r[1] = (uint32_t)(bits >> 32);
        }
    } else {
        arm->k.r[0] = c->r[EAX];
        arm->k.r[1] = c->r[EDX];
    }
    arm->k.r[13] = arm_sp;
    c->r[ESP] = saved_sp;
}

void mt_arm32_thread_init(MtThread *t) {
    cpu_init(&t->arm, t->m->mem);
    t->arm.k.r[13] = t->stack_top - 16;
    t->arm.trap_lo = MT_TRAP_BASE;
    t->arm.trap_hi = MT_TRAP_BASE + 16u * MT_TRAP_SLOTS;
    t->arm.trap = arm_trap;
    t->arm.trap_ctx = t;
    t->arm.return_addr = MT_STOP;
    t->arm.abort = &t->m->dying;
}

uint32_t mt_arm32_call(Mt *m, X86 *c, uint32_t fn, int nargs, const uint32_t *args) {
    MtThread *t = mt_tls(m, c);
    Cpu *arm = &t->arm;
    // iOS 10 uses four-byte ARM-mode `ldr pc, [pc, #offset]` stubs,
    // already supported by the Vocalizer Thumb dispatcher. Match the
    // indirect-symbol indexes rather than assuming section order.
    for (int i = 0; i < m->nimages; i++) {
        MtImage *im = &m->images[i];
        for (int j = 0; j < im->nsects; j++) {
            typeof(im->sects[0]) *stub = &im->sects[j];
            if ((stub->flags & 255) != 8 || stub->r2 != 4) continue;
            for (int k = 0; k < im->nsects; k++) {
                typeof(im->sects[0]) *ptr = &im->sects[k];
                if ((ptr->flags & 255) != 7 || ptr->size != stub->size) continue;
                arm->stub_lo = stub->addr + im->slide;
                arm->stub_hi = arm->stub_lo + stub->size;
                arm->lazy_base = ptr->addr + im->slide;
            }
        }
    }
    jmp_buf fault;
    jmp_buf *previous_fault = arm->fault_jmp;
    arm->fault_jmp = &fault;
    if (setjmp(fault)) {
        arm->fault_jmp = previous_fault;
        x86_fault(c, "%s", arm->fault_msg);
    }
    uint32_t hi;
    uint32_t result = cpu_call(arm, fn, args, nargs, &hi);
    arm->fault_jmp = previous_fault;
    c->r[EAX] = result;
    c->r[EDX] = hi;
    return result;
}

static void reset_cpp(void) { pthread_mutex_lock(&guard_mutex); memset(guards,0,sizeof guards); pthread_mutex_unlock(&guard_mutex); }

#endif
