#ifdef CV_MT_ARM32_EXPERIMENT
// Offline RemoteIO sink for the private ARM32 experiment. No host device
// audio, audio-unit registration, or user audio settings are touched.
#include "../mt_internal.h"
#include <string.h>
#include <stdatomic.h>

static uint32_t callback, refcon, component, instance;
static uint32_t timestamp, flags, list, samples;
static atomic_int started;
static double sample_rate = 22050;
static int fixed_fraction;
static uint64_t position;
void mt_arm32_audio_reset(void) {
    callback=refcon=component=instance=timestamp=flags=list=samples=0;
    atomic_store(&started,0); sample_rate=22050; fixed_fraction=0; position=0;
}

static void h_find(Mt *m, X86 *c) {
    uint32_t description = x86_arg(c, 1);
    if (rd32(c, description) != 0x61756f75 || rd32(c, description + 4) != 0x72696f63)
        x86_fault(c, "experimental audio supports RemoteIO only");
    if (!component) component = mt_static(m, 16);
    c->r[EAX] = x86_arg(c, 0) ? 0 : component;
}
static void h_new(Mt *m, X86 *c) {
    if (x86_arg(c, 0) != component) x86_fault(c, "unknown audio component");
    if (!instance) instance = mt_static(m, 16);
    wr32(c, x86_arg(c, 1), instance);
    c->r[EAX] = 0;
}
static void h_start(Mt *m, X86 *c) { (void)m; position = 0; atomic_store(&started, 1); c->r[EAX] = 0; }
static void h_stop(Mt *m, X86 *c) { (void)m; atomic_store(&started, 0); c->r[EAX] = 0; }
static void h_set(Mt *m, X86 *c) {
    uint32_t property = x86_arg(c, 1), data = x86_arg(c, 4), size = x86_arg(c, 5);
    if (property == 8 && size == 40) {
        // iOS 10 RemoteIO uses signed 8.24 fixed-point PCM; also allow float.
        uint32_t format = rd32(c, data + 8), bits = rd32(c, data + 32), channels = rd32(c, data + 28);
        uint32_t format_flags = rd32(c, data + 12);
        if (format != 0x6c70636d || bits != 32 || channels != 1 || (format_flags != 0xc0c && format_flags != 0x29))
            x86_fault(c, "unsupported RemoteIO PCM format %#x, bits %u, channels %u, flags %#x", format, bits, channels, rd32(c, data + 12));
        memcpy(&sample_rate, G(m, data), 8);
        fixed_fraction = format_flags == 0xc0c ? 24 : 0;
    } else if (property == 23 && size == 8) {
        callback = rd32(c, data); refcon = rd32(c, data + 4);
    } else {
        x86_fault(c, "unsupported RemoteIO property %u (%u bytes)", property, size);
    }
    c->r[EAX] = 0;
}

MtHle mt_arm32_audio_hle(const char *name) {
    if (!strcmp(name, "_AudioComponentFindNext")) return h_find;
    if (!strcmp(name, "_AudioComponentInstanceNew")) return h_new;
    if (!strcmp(name, "_AudioComponentInstanceDispose") || !strcmp(name, "_AudioUnitUninitialize")) return h_stop;
    if (!strcmp(name, "_AudioOutputUnitStart")) return h_start;
    if (!strcmp(name, "_AudioOutputUnitStop")) return h_stop;
    if (!strcmp(name, "_AudioUnitSetProperty")) return h_set;
    return NULL;
}

double mt_arm32_audio_rate(void) { return sample_rate; }
int mt_arm32_audio_started(void) { return atomic_load(&started); }
uint32_t mt_arm32_render(Mt *m, float *output, uint32_t frames) {
    if (!atomic_load(&started) || !callback || frames > 1024) return 0;
    if (!samples) {
        samples = mt_static(m, 4096); list = mt_static(m, 16);
        timestamp = mt_static(m, 64); flags = mt_static(m, 4);
    }
    X86 *c = &m->main->cpu;
    memset(G(m, timestamp), 0, 64);
    double sample_time = (double)position;
    memcpy(G(m, timestamp), &sample_time, 8);
    wr32(c, timestamp + 56, 1); // armv7 offsetof(AudioTimeStamp,mFlags), verified with clang
    wr32(c, flags, 0);
    wr32(c, list, 1); wr32(c, list + 4, 1); wr32(c, list + 8, frames * 4); wr32(c, list + 12, samples);
    memset(G(m, samples), 0, frames * 4);
    uint32_t args[] = {refcon, flags, timestamp, 0, frames, list};
    uint32_t result = mt_call(m, callback, 6, args);
    if (result) x86_fault(c, "RemoteIO callback returned %d", (int)result);
    if (fixed_fraction) {
        for (uint32_t i = 0; i < frames; i++) output[i] = (int32_t)rd32(c, samples + i * 4) / 16777216.0f;
    } else memcpy(output, G(m, samples), frames * 4);
    position += frames;
    return frames;
}

#endif
