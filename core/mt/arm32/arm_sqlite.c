#ifdef CV_MT_ARM32_EXPERIMENT
// Read-only guest SQLite handles. Blob pointers always refer to guest memory.
#include "../mt_internal.h"
#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>

static struct { void *pointer; int database; uint32_t *blobs; int columns; } handles[256];
static uint32_t put(X86 *c, void *pointer, int database) {
    if (!pointer) return 0;
    for (uint32_t i = 1; i < 256; i++) if (!handles[i].pointer) {
        handles[i].pointer = pointer; handles[i].database = database; return i;
    }
    x86_fault(c, "too many experimental SQLite handles");
}
static uint32_t handle(X86 *c, int database) {
    uint32_t h = x86_arg(c, 0);
    if (!h || h >= 256 || !handles[h].pointer || handles[h].database != database)
        x86_fault(c, "invalid experimental SQLite handle %u", h);
    return h;
}
static void clear_blob(Mt *m, uint32_t h) {
    for (int i = 0; i < handles[h].columns; i++) mt_free(m, handles[h].blobs[i]);
    free(handles[h].blobs); handles[h].blobs = NULL; handles[h].columns = 0;
}
void mt_arm32_sqlite_reset(Mt *m) {
    for (unsigned i=1;i<256;i++) if (handles[i].pointer && !handles[i].database) {
        clear_blob(m,i); sqlite3_finalize(handles[i].pointer); handles[i].pointer=NULL;
    }
    for (unsigned i=1;i<256;i++) if (handles[i].pointer) sqlite3_close(handles[i].pointer);
    memset(handles,0,sizeof handles);
}
static void h_open(Mt *m, X86 *c) {
    if (x86_arg(c, 2) & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) x86_fault(c, "SQLite probe permits read-only assets");
    if (x86_arg(c, 3)) x86_fault(c, "custom SQLite VFS unsupported");
    sqlite3 *db = NULL;
    int result = sqlite3_open_v2(mt_str(m, x86_arg(c, 0)), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    wr32(c, x86_arg(c, 1), put(c, db, 1)); c->r[EAX] = (uint32_t)result;
}
static void h_prepare(Mt *m, X86 *c) {
    uint32_t h = handle(c, 1), sql = x86_arg(c, 1), tail = x86_arg(c, 4);
    sqlite3_stmt *statement = NULL;
    const char *rest = NULL, *text = mt_str(m, sql);
    int result = sqlite3_prepare_v2(handles[h].pointer, text, (int)x86_arg(c, 2), &statement, &rest);
    wr32(c, x86_arg(c, 3), put(c, statement, 0));
    if (tail) wr32(c, tail, rest ? sql + (uint32_t)(rest - text) : 0);
    c->r[EAX] = (uint32_t)result;
}
static void h_bind(Mt *m, X86 *c) {
    uint32_t h = handle(c, 0);
    const char *text = x86_arg(c, 2) ? mt_str(m, x86_arg(c, 2)) : NULL;
    c->r[EAX] = (uint32_t)sqlite3_bind_text(handles[h].pointer, (int)x86_arg(c, 1), text, (int)x86_arg(c, 3), SQLITE_TRANSIENT);
}
static void h_step(Mt *m, X86 *c) { uint32_t h = handle(c, 0); clear_blob(m, h); c->r[EAX] = (uint32_t)sqlite3_step(handles[h].pointer); }
static void h_reset(Mt *m, X86 *c) { uint32_t h = handle(c, 0); clear_blob(m, h); c->r[EAX] = (uint32_t)sqlite3_reset(handles[h].pointer); }
static void h_finalize(Mt *m, X86 *c) {
    uint32_t h = handle(c, 0); clear_blob(m, h);
    c->r[EAX] = (uint32_t)sqlite3_finalize(handles[h].pointer); handles[h].pointer = NULL;
}
static void h_close(Mt *m, X86 *c) {
    (void)m; uint32_t h = handle(c, 1); int rc = sqlite3_close(handles[h].pointer);
    if (!rc) handles[h].pointer = NULL;
    c->r[EAX] = (uint32_t)rc;
}
static void h_integer(Mt *m, X86 *c) {
    (void)m; uint32_t h = handle(c, 0);
    uint64_t value = (uint64_t)sqlite3_column_int64(handles[h].pointer, (int)x86_arg(c, 1));
    c->r[EAX] = (uint32_t)value; c->r[EDX] = (uint32_t)(value >> 32);
}
static void h_bytes(Mt *m, X86 *c) { (void)m; uint32_t h = handle(c, 0); c->r[EAX] = (uint32_t)sqlite3_column_bytes(handles[h].pointer, (int)x86_arg(c, 1)); }
static void h_blob(Mt *m, X86 *c) {
    uint32_t h = handle(c, 0); int column = (int)x86_arg(c, 1);
    int columns = sqlite3_column_count(handles[h].pointer);
    if (column < 0 || column >= columns) x86_fault(c, "invalid SQLite column");
    if (!handles[h].blobs) {
        handles[h].blobs = calloc((size_t)columns, sizeof(uint32_t));
        if (!handles[h].blobs) x86_fault(c, "cannot allocate SQLite blob handles");
        handles[h].columns = columns;
    }
    if (handles[h].blobs[column]) { c->r[EAX] = handles[h].blobs[column]; return; }
    const void *blob = sqlite3_column_blob(handles[h].pointer, column);
    int bytes = sqlite3_column_bytes(handles[h].pointer, column);
    if (!blob || !bytes) { c->r[EAX] = 0; return; }
    handles[h].blobs[column] = mt_malloc(m, (uint32_t)bytes);
    memcpy(G(m, handles[h].blobs[column]), blob, (size_t)bytes); c->r[EAX] = handles[h].blobs[column];
}
MtHle mt_arm32_sqlite_hle(const char *name) {
    if (!strcmp(name, "_sqlite3_open_v2")) return h_open;
    if (!strcmp(name, "_sqlite3_prepare_v2")) return h_prepare;
    if (!strcmp(name, "_sqlite3_bind_text")) return h_bind;
    if (!strcmp(name, "_sqlite3_step")) return h_step;
    if (!strcmp(name, "_sqlite3_reset")) return h_reset;
    if (!strcmp(name, "_sqlite3_finalize")) return h_finalize;
    if (!strcmp(name, "_sqlite3_close")) return h_close;
    if (!strcmp(name, "_sqlite3_column_int64")) return h_integer;
    if (!strcmp(name, "_sqlite3_column_bytes")) return h_bytes;
    if (!strcmp(name, "_sqlite3_column_blob")) return h_blob;
    return NULL;
}

#endif
