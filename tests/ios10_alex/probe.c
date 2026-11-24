// Private local engine probe. No firmware or voice data is distributed.
#include "mt_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
uint32_t mt_arm32_render(Mt *m, float *output, uint32_t frames);
double mt_arm32_audio_rate(void);
int mt_arm32_audio_started(void);
uint32_t mt_cf_number(Mt *m, double value);
double mt_cf_number_value(Mt *m, uint32_t object);

static void write16(FILE *f, uint16_t value) { fputc(value & 255, f); fputc(value >> 8, f); }
static void write32(FILE *f, uint32_t value) { write16(f, value & 65535); write16(f, value >> 16); }
static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

static int write_wav(const char *path, const float *pcm, uint32_t count, uint32_t rate) {
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    fwrite("RIFF", 1, 4, f); write32(f, 36 + count * 2); fwrite("WAVEfmt ", 1, 8, f);
    write32(f, 16); write16(f, 1); write16(f, 1); write32(f, rate); write32(f, rate * 2);
    write16(f, 2); write16(f, 16); fwrite("data", 1, 4, f); write32(f, count * 2);
    for (uint32_t i = 0; i < count; i++) {
        float sample = isfinite(pcm[i]) ? fmaxf(-1, fminf(1, pcm[i])) : 0;
        write16(f, (uint16_t)(int16_t)lrintf(sample * 32767));
    }
    return fclose(f) != 0;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) { fprintf(stderr, "usage: %s /path/to/MacinTalk [/path/to/Alex/AssetData [output.wav]]\n", argv[0]); return 2; }
    // A bad guest loop must not leave a test running indefinitely.
    alarm(30);
    char err[512] = {0};
    Mt *m = mt_create_arm32(err, sizeof err);
    if (!m) { fprintf(stderr, "%s\n", err); return 1; }
    m->verbose = getenv("MT_VERBOSE") ? atoi(getenv("MT_VERBOSE")) : 1;
    // RemoteIO render timestamps and the guest wall clock must advance at
    // the same rate. The older Mac host normally accelerates both by 128x.
    mt_set_speed(1);
    jmp_buf fault;
    m->fault = m->main->cpu.fault = &fault;
    if (setjmp(fault)) {
        fprintf(stderr, "PROBE BLOCKED: %s%s\n", m->err, m->main->cpu.err);
        // A fault can leave locks held; terminate this isolated process.
        return 1;
    }
    int image = mt_load(m, argv[1]);
    mt_bind_all(m);
    fprintf(stderr, "ARM32 image loaded and bound (%d imports)\n", m->ntraps);
    uint32_t open = mt_export(m, image, "_SEOpenSpeechChannel");
    fprintf(stderr, "SEOpenSpeechChannel=%#x\n", open);
    if (!open) return 1;
    mt_run_initializers(m);
    fprintf(stderr, "ARM32 initializers completed\n");
    uint32_t channel_slot = mt_static(m, 4);
    uint32_t result = mt_call(m, open, 1, &channel_slot);
    uint32_t channel = rd32(&m->main->cpu, channel_slot);
    fprintf(stderr, "SEOpenSpeechChannel returned %d, channel=%#x\n", (int)result, channel);
    if (result || !channel) return 1;
    if (argc >= 3) {
        char description[4096];
        snprintf(description, sizeof description, "%s/Contents/Resources/VoiceDescription", argv[2]);
        FILE *f = fopen(description, "rb");
        unsigned char header[12];
        if (!f || fread(header, 1, sizeof header, f) != sizeof header) {
            if (f) fclose(f);
            fprintf(stderr, "cannot read VoiceDescription\n");
            return 1;
        }
        fclose(f);
        uint32_t spec = mt_static(m, 8);
        for (unsigned i = 0; i < 2; i++) {
            unsigned char *p = header + 4 + i * 4;
            uint32_t value = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
            wr32(&m->main->cpu, spec + i * 4, value);
        }
        uint32_t use_args[] = {channel, spec, mt_cf_bundle(m, argv[2])};
        result = mt_call(m, mt_export(m, image, "_SEUseVoice"), 3, use_args);
        fprintf(stderr, "SEUseVoice(Alex) returned %d\n", (int)result);
        if (result) return 1;
        const char *keys[] = {"pbas", "pitchBase", "pmod", "rate"};
        for (unsigned i = 0; i < 4; i++) {
            uint32_t slot = mt_static(m, 4), key = mt_cf_string(m, keys[i], strlen(keys[i]));
            uint32_t args[] = {channel, key, slot};
            uint32_t rc = mt_call(m, mt_export(m, image, "_SECopySpeechProperty"), 3, args);
            uint32_t number = rd32(&m->main->cpu, slot);
            fprintf(stderr, "Property %s: rc=%d value=%.3f\n", keys[i], (int)rc, number ? mt_cf_number_value(m, number) : -1);
        }
        uint32_t reset_args[]={channel,mt_cf_string(m,"rset",4),0};
        result=mt_call(m,mt_export(m,image,"_SESetSpeechProperty"),3,reset_args);
        fprintf(stderr,"Reset using rset: rc=%d\n",(int)result);
        if (result) return 1;
        const char *pitch = getenv("ALEX_PROBE_PITCH");
        if (pitch) {
            double value = strtod(pitch, NULL);
            if (!isfinite(value) || value < 20 || value > 80) return 2;
            uint32_t args[] = {channel, mt_cf_string(m, "pbas", 4), mt_cf_number(m, value)};
            result = mt_call(m, mt_export(m, image, "_SESetSpeechProperty"), 3, args);
            fprintf(stderr, "Set pitch %.2f: rc=%d\n", value, (int)result);
            if (result) return 1;
        }
        const char *rate=getenv("ALEX_PROBE_RATE");
        if (rate) {
            uint32_t key=mt_cf_string(m,"rate",4), args[]={channel,key,mt_cf_number(m,strtod(rate,NULL))};
            result=mt_call(m,mt_export(m,image,"_SESetSpeechProperty"),3,args);
            uint32_t slot=mt_static(m,4), get[]={channel,key,slot};
            uint32_t rc=mt_call(m,mt_export(m,image,"_SECopySpeechProperty"),3,get);
            fprintf(stderr,"Set rate %s: rc=%d readback_rc=%d value=%.3f\n",rate,(int)result,(int)rc,mt_cf_number_value(m,rd32(&m->main->cpu,slot)));
            if (result || rc) return 1;
        }
    }
    if (argc == 4) {
        const char *resume_output = getenv("ALEX_PROBE_RESUME_OUTPUT");
        for (int pass = 0; pass < (resume_output ? 2 : 1); pass++) {
            const char *text = getenv("ALEX_PROBE_TEXT");
            if (!text) text = "Hello. This is Alex from iOS ten.";
            if (pass) text = "Hello again. Alex can speak after interruption.";
            mt_audio_begin();
            uint32_t args[] = {channel, mt_cf_string(m, text, strlen(text)), 0};
            result = mt_call(m, mt_export(m, image, "_SESpeakCFString"), 3, args);
            fprintf(stderr, "SESpeakCFString returned %d\n", (int)result);
            if (result) return 1;
            const uint32_t capacity = 22050 * 20;
            float *pcm = calloc(capacity, sizeof(float));
            if (!pcm) { fprintf(stderr, "cannot allocate capture buffer\n"); return 1; }
            uint32_t count = 0;
            int was_started = 0;
            const char *cancel = getenv("ALEX_PROBE_CANCEL_FRAMES");
            uint32_t cancel_at = !pass && cancel ? (uint32_t)strtoul(cancel, NULL, 10) : 0;
            int cancelled = 0;
            double render_due = now();
            for (unsigned attempt = 0; attempt < 20000 && count + 512 <= capacity; attempt++) {
                if (m->broken) { fprintf(stderr, "guest speech worker faulted\n"); free(pcm); return 1; }
                int started = mt_arm32_audio_started();
                if (was_started && !started) break;
                was_started |= started;
                uint32_t rendered = mt_arm32_render(m, pcm + count, 512);
                count += rendered;
                if (cancel_at && count >= cancel_at && !cancelled) {
                    uint32_t stop_args[] = {channel, 0};
                    double began = now();
                    result = mt_call(m, mt_export(m, image, "_SEStopSpeechAt"), 2, stop_args);
                    fprintf(stderr, "SEStopSpeechAt after %u frames: rc=%d elapsed_ms=%.3f\n", count, (int)result, (now() - began) * 1000);
                    if (result) { free(pcm); return 1; }
                    cancelled = 1;
                }
                if (rendered) {
                    render_due += rendered / mt_arm32_audio_rate();
                    double delay = render_due - now();
                    if (delay > 0) usleep((useconds_t)(delay * 1e6));
                } else { render_due = now(); usleep(1000); }
            }
            if (mt_arm32_audio_started()) { fprintf(stderr, "capture reached its limit before output stopped\n"); free(pcm); return 1; }
            fprintf(stderr, "Captured %u samples at %.0f Hz\n", count, mt_arm32_audio_rate());
            if (!count || write_wav(pass ? resume_output : argv[3], pcm, count, (uint32_t)mt_arm32_audio_rate())) { free(pcm); return 1; }
            free(pcm);
        }
    }
    uint32_t close = mt_export(m, image, "_SECloseSpeechChannel");
    if (close) mt_call(m, close, 1, &channel);
    mt_destroy(m);
    return 0;
}
