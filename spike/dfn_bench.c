// DFN3 spike: per-frame CPU cost and algorithmic delay of libDF (DeepFilterNet Plus) on this Mac.
// Build: see spike/run_dfn_spike.sh. Input: mono float32 WAV @48 kHz.
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <pthread/qos.h>

typedef struct DFState DFState;
extern DFState *df_create(const char *path, float atten_lim, const char *log_level);
extern size_t df_get_frame_length(DFState *st);
extern float df_process_frame(DFState *st, float *input, float *output);
extern void df_set_atten_lim(DFState *st, float lim_db);
extern void df_free(DFState *st);

static float *read_wav_f32(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(sz); fread(buf, 1, sz, f); fclose(f);
    for (long i = 12; i + 8 <= sz;) {
        uint32_t len; memcpy(&len, buf + i + 4, 4);
        if (!memcmp(buf + i, "data", 4)) {
            *n = len / 4; float *out = malloc(len); memcpy(out, buf + i + 8, len); free(buf); return out;
        }
        i += 8 + len + (len & 1);
    }
    fprintf(stderr, "no data chunk\n"); exit(1);
}

static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s model.tar.gz in.wav atten_lim_db [noise_dbfs]\n", argv[0]); return 1; }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    float lim = atof(argv[3]);
    float noise_db = argc > 4 ? atof(argv[4]) : -200;
    size_t n; float *x = read_wav_f32(argv[2], &n);
    srand(1);
    float namp = powf(10.f, noise_db / 20.f);
    for (size_t i = 0; i < n; i++) x[i] += namp * ((rand() / (float)RAND_MAX) * 2.f - 1.f) * 1.732f;

    DFState *st = df_create(argv[1], lim, NULL);
    size_t hop = df_get_frame_length(st);
    size_t frames = n / hop;
    float *y = calloc(frames * hop, sizeof(float));
    double *t = malloc(frames * sizeof(double));
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for (size_t k = 0; k < frames; k++) {
        uint64_t a = mach_absolute_time();
        df_process_frame(st, x + k * hop, y + k * hop);
        uint64_t b = mach_absolute_time();
        t[k] = (double)(b - a) * tb.numer / tb.denom / 1e3; // us
    }
    // skip warm-up frames
    size_t w = frames > 50 ? 50 : 0;
    double sum = 0; for (size_t k = w; k < frames; k++) sum += t[k];
    double mean = sum / (frames - w);
    qsort(t + w, frames - w, sizeof(double), cmpd);
    double p50 = t[w + (frames - w) / 2], p99 = t[w + (size_t)((frames - w) * 0.99)], mx = t[frames - 1];
    double frame_us = hop * 1e6 / 48000.0;
    // delay: lag maximizing normalized cross-correlation
    size_t m = frames * hop, best = 0; double bestc = -1;
    for (size_t lag = 0; lag < 4800 && lag < m; lag++) {
        double c = 0, ex = 0, ey = 0;
        for (size_t i = 48000; i + lag < m && i < 48000 * 20; i++) { c += x[i] * y[i + lag]; ex += x[i] * x[i]; ey += y[i + lag] * y[i + lag]; }
        c /= sqrt(ex * ey + 1e-20);
        if (c > bestc) { bestc = c; best = lag; }
    }
    printf("frames=%zu hop=%zu mean=%.0fus p50=%.0fus p99=%.0fus max=%.0fus  CPU(mean)=%.1f%%  CPU(p99)=%.1f%%  delay=%zu samples (%.1f ms, corr %.3f)\n",
           frames, hop, mean, p50, p99, mx, 100 * mean / frame_us, 100 * p99 / frame_us, best, best / 48.0, bestc);
    df_free(st);
    return 0;
}
