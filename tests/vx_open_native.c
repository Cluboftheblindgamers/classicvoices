// The stream opens each Vocalizer engine with its fast code attached before
// the engine's own setup runs (vx_open_prepared, vxstream.c prepare_native):
// that setup then runs mostly as native code instead of on the interpreter,
// and the voice says exactly what it said before.
//
// Built and run by tools/check_panthera_port.py when --voice-root has the iOS 6
// compacts and --native-libraries the Mac fast code (cvnative_ios6.so).
#include "vxengine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void cv_set_native_dir(const char *dir);
int vx_try_native_dll(Vx *vx, const char *build);  // ports/posix/vx_native_dl.c

static void prepare(Vx *vx, void *build) { vx_try_native_dll(vx, build); }
static void prepare_legacy(Vx *vx, void *build) {
    vx_try_native_dll(vx, build);
    vx_set_native_limit(vx, 0x40000000u);
}

typedef struct { short *pcm; size_t n, cap; } Pcm;
static int collect(void *ctx, const int16_t *s, size_t n) {
    Pcm *p = ctx;
    if (p->n + n > p->cap) {
        p->cap = (p->n + n) * 2;
        p->pcm = realloc(p->pcm, p->cap * sizeof *p->pcm);
    }
    memcpy(p->pcm + p->n, s, n * sizeof *s);
    p->n += n;
    return 0;
}

static void require(int ok, const char *what) {
    if (!ok) { printf("FAIL %s\n", what); exit(1); }
}

int main(void) {
    const char *root = getenv("CV_PORT_ROOT"), *native = getenv("CV_PORT_NATIVE_DIR");
    if (!root || !native) { printf("SKIP vx_open_native: needs CV_PORT_ROOT and CV_PORT_NATIVE_DIR\n"); return 0; }
    char voiced[1200], lang[1200], common[1200], lib[1200];
    snprintf(voiced, sizeof voiced, "%s/ios6/voiced", root);
    snprintf(lang, sizeof lang, "%s/ios6/TTSResources/en-GB", root);
    snprintf(common, sizeof common, "%s/ios6/TTSResources/common", root);
    snprintf(lib, sizeof lib, "%s/cvnative_ios6.so", native);
    FILE *f = fopen(lib, "rb");
    if (!f) { printf("SKIP vx_open_native: no %s\n", lib); return 0; }
    fclose(f);
    cv_set_native_dir(native);

    char err[512];
    // as engines were opened before: fast code attached once vx_open returned
    Vx *after = vx_open(voiced, lang, common, err, sizeof err);
    require(after != NULL, err);
    unsigned long long setup_after = vx_instruction_count(after);
    vx_try_native_dll(after, "ios6");
    // as the stream opens them now
    Vx *before = vx_open_prepared(voiced, lang, common, prepare, "ios6", err, sizeof err);
    require(before != NULL, err);
    unsigned long long setup_before = vx_instruction_count(before);
    require(vx_has_native(after) && vx_has_native(before), "fast code attached both ways");
    require(setup_before * 4 < setup_after * 3, "engine setup runs mostly on the fast code when attached first");

    Vx *legacy = vx_open_prepared(voiced, lang, common, prepare_legacy, "ios6", err, sizeof err);
    require(legacy != NULL && vx_has_native(legacy), "legacy table safely attached after setup");
    require(vx_instruction_count(legacy) >= setup_after * 3 / 4, "legacy smaller table avoids native startup");
    vx_close(legacy);

    const char *text = "Settings, button. It is 4:15 PM on Saturday, October 10th, 2026.";
    Pcm a = {0}, b = {0};
    require(vx_speak_utf8(after, text, collect, &a) == 0, "speak (attached after setup)");
    require(vx_speak_utf8(before, text, collect, &b) == 0, "speak (attached before setup)");
    require(a.n > 0 && a.n == b.n && memcmp(a.pcm, b.pcm, a.n * sizeof *a.pcm) == 0, "same audio either way");
    vx_close(after);
    vx_close(before);
    free(a.pcm);
    free(b.pcm);
    printf("PASS Vocalizer engine setup on fast code: %.2f M instructions interpreted while opening iOS 6 Daniel, "
           "was %.2f M; same audio\n", setup_before / 1e6, setup_after / 1e6);
    return 0;
}
