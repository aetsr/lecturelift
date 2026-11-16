// HSCore render core. See include/HSCore.h for the contract.
#include "HSCore.h"
#include "DSP/Stages.hpp"
#include "Reverb/Reverb.hpp"
#include "Denoiser/Denoiser.hpp"

namespace hs {
DenoiserRT *createDenoiser(double sampleRate, int maxFrames, int ioBufferFrames, const char *modelPath,
                           float attenDb, bool synchronous, DenoiserStats *stats, int *err);
void processDenoiser(DenoiserRT *d, float *L, float *R, int n, double fs, bool on, float &mix, float mixStep);
}

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mach/mach_time.h>
#include <new>
#include <unistd.h>
#include <vector>

namespace {

constexpr int kMaxOutChannels = 64;
constexpr int kMaxOutBuffers = 32;

struct alignas(64) Telemetry {
    std::atomic<uint64_t> heartbeat{0};
    std::atomic<uint64_t> generation{0};
    std::atomic<uint64_t> callbacks{0};
    std::atomic<uint64_t> xruns{0};
    std::atomic<uint64_t> overloads{0};
    std::atomic<uint64_t> nonzeroBlocks{0};
    std::atomic<float> peakIn{0}, peakOut{0}, cpuLoad{0};
    std::atomic<int> fadeState{HS_FADE_SILENT};
    std::atomic<int> lastFrames{0};
    std::atomic<double> ioDelta{0};
    std::atomic<float> deessDb{0}, levelerGainDb{0}, compGrDb{0}, limiterGrDb{0}, dnMix{0};
    std::atomic<uint64_t> dspResets{0};
    std::atomic<uint64_t> stageTicks[HS_ST_COUNT] = {};
};

inline float absPeak(const float *p, int n, int stride) {
    float m = 0.f;
    for (int i = 0; i < n; ++i) {
        float v = std::fabs(p[i * stride]);
        m = v > m ? v : m;
    }
    return m;
}

} // namespace

struct hs_engine {
    // ---- configuration (written only while no IOProc runs) ----
    double sampleRate = 48000.0;
    int maxFrames = 0;
    float *left = nullptr;
    float *right = nullptr;
    int inBuffer = 0, inChannels = 2, inInterleaved = 1;
    int outBuffers = 0;
    int outChannels[kMaxOutBuffers] = {};
    int outInterleaved[kMaxOutBuffers] = {};
    int8_t outSource[kMaxOutChannels] = {};
    double hostTicksToNs = 1.0;

    // ---- RT state (owned by the audio thread) ----
    double lastOutSampleTime = -1.0;
    double lastInSampleTime = -1.0;
    int lastInFrames = 0;
    int lastFramesRT = 0;
    float fadeGain = 0.f;
    float fadeStep = 0.f;      // per-sample increment for a 20 ms ramp
    float meterDecay = 0.f;    // per-block decay factor applied before taking max

    // ---- control (any thread) ----
    std::atomic<int> fadeTarget{1};
    std::atomic<uint64_t> generationCtl{0};
    std::atomic<int> debugStall{0};

    // ---- capture of the unprocessed tap input (owner request: real-clip listening review) ----
    struct Capture {
        float *data = nullptr;              // interleaved stereo
        int64_t capacity = 0;               // frames
        std::atomic<int64_t> written{0};
    };
    std::atomic<Capture *> capture{nullptr};   // published by control, read once per IOProc call
    Capture *detached = nullptr;                // control-owned after detach
    uint64_t detachedAtCallback = 0;
    std::atomic<float> params[HS_P_COUNT];

    // ---- chain (RT-owned after prepare) ----
    float mix[HS_ST_COUNT] = {};          // per-stage bypass crossfade position (0 = bypassed)
    float mixStep = 0.f;                  // per-sample step for a 10 ms crossfade
    float *dryL = nullptr, *dryR = nullptr, *preL = nullptr, *preR = nullptr;
    float curTarget = NAN, curStrength = NAN;
    // A/B: the input before the chain, delayed by the current chain latency ("Original", time-aligned)
    float *abL = nullptr, *abR = nullptr; int abCap = 0, abPos = 0;
    float abMix = 0.f, abStep = 0.f;
    int abLat = 0, abLatNew = 0, abLatFade = 0, abLatFadeLen = 960;   // two-head crossfade on latency change
    hs::HighPass hpf;
    hs::ToneEQ eq;
    hs::DeEsser deess;
    hs::Leveler leveler;
    hs::Compressor comp;
    hs::Limiter limiter;
    hs::ReverbStage reverb;
    std::atomic<hs::DenoiserRT *> dn{nullptr};
    hs::DenoiserStats dnStats;                 // outlives any DenoiserRT (telemetry)
    hs::DenoiserRT *dnRetired[8] = {};         // unloaded, worker joined, freed in destroy (control-owned)
    int dnRetiredN = 0;
    float dnMix = 0.f, dnMixStep = 0.f;

    Telemetry t;

    hs_engine() {
        const float defaults[HS_P_COUNT] = {0, 0, 0, 0, 0, 0, 0, -3.f, 2.5f, 3.f, -18.f, 1.f, 0.15f, 15.f, 0.5f, 0.3f, 0.f, 12.f, 0.f, 0.f};
        for (int i = 0; i < HS_P_COUNT; ++i) params[i].store(defaults[i], std::memory_order_relaxed);
    }
    float p(int i) const { return params[i].load(std::memory_order_relaxed); }
    bool on(int i) const { return params[i].load(std::memory_order_relaxed) > 0.5f; }

    void resetStage(int st) {
        switch (st) {
        case HS_ST_HPF: hpf.reset(); break;
        case HS_ST_EQ: eq.reset(); break;
        case HS_ST_DEESS: deess.reset(); break;
        case HS_ST_LEVEL: leveler.reset(); comp.reset(); break;
        case HS_ST_LIMIT: limiter.reset(); break;
        default: break;
        }
    }
};

/// Runs one stage with click-free bypass: fully on → in place; fully off → skipped (bit-exact);
/// in between → processed and crossfaded with the dry copy over 10 ms.
template <class F>
static inline void runStage(hs_engine *e, int st, bool enabled, float *L, float *R, int n, F &&fn) {
    float m = e->mix[st];
    const float target = enabled ? 1.f : 0.f;
    if (m == 0.f && !enabled) return;
    const uint64_t t0 = mach_absolute_time();
    if (m == target) {
        fn(L, R, n);
    } else {
        // Entering from fully bypassed: no stale state. The limiter is kept warm instead (runChain).
        if (m == 0.f && st != HS_ST_LIMIT) e->resetStage(st);
        std::memcpy(e->dryL, L, sizeof(float) * size_t(n));
        std::memcpy(e->dryR, R, sizeof(float) * size_t(n));
        fn(L, R, n);
        const float step = enabled ? e->mixStep : -e->mixStep;
        for (int i = 0; i < n; ++i) {
            m += step;
            m = m < 0.f ? 0.f : (m > 1.f ? 1.f : m);
            L[i] = m * L[i] + (1.f - m) * e->dryL[i];
            R[i] = m * R[i] + (1.f - m) * e->dryR[i];
        }
        e->mix[st] = m;
    }
    e->t.stageTicks[st].fetch_add(mach_absolute_time() - t0, std::memory_order_relaxed);
}

static bool anyStageOn(const hs_engine *e) {
    for (int p = HS_P_MONO; p <= HS_P_REVERB_ON; ++p) if (e->on(p)) return true;
    return e->on(HS_P_DENOISE_ON);
}

static void resetAll(hs_engine *e) {
    for (int st = 0; st < HS_ST_COUNT; ++st) e->resetStage(st);
}

static void runChainInner(hs_engine *e, float *L, float *R, int n);

/// A/B wrapper: keeps a delay line of the chain input; "Original" = that input delayed by the current
/// chain latency, so switching is time-aligned (no lip-sync jump) and crossfaded over 20 ms.
static void runChain(hs_engine *e, float *L, float *R, int n) {
    if (!e->abL || n <= 0) { runChainInner(e, L, R, n); return; }
    const bool wantOrig = e->on(HS_P_AB_ORIGINAL);
    if (!wantOrig && e->abMix == 0.f) {   // fast path, still feed the delay line
        for (int i = 0; i < n; ++i) { e->abL[(e->abPos + i) % e->abCap] = L[i]; e->abR[(e->abPos + i) % e->abCap] = R[i]; }
        e->abPos = (e->abPos + n) % e->abCap;
        runChainInner(e, L, R, n);
        return;
    }
    for (int i = 0; i < n; ++i) { e->abL[(e->abPos + i) % e->abCap] = L[i]; e->abR[(e->abPos + i) % e->abCap] = R[i]; }
    runChainInner(e, L, R, n);
    int lat = hs_engine_latency_samples(e);
    lat = lat < e->abCap - n - 1 ? lat : e->abCap - n - 1;
    // Latency changes (denoiser mixed in/out) are crossfaded between two read heads over 20 ms
    // instead of jumping (a jump of ~2900 samples would click while on Original).
    if (lat != e->abLatNew && e->abLatFade == 0) {
        if (e->abMix == 0.f) { e->abLat = e->abLatNew = lat; }
        else { e->abLatNew = lat; e->abLatFade = e->abLatFadeLen; }
    }
    const float target = wantOrig ? 1.f : 0.f;
    for (int i = 0; i < n; ++i) {
        const int idx = ((e->abPos + i - e->abLat) % e->abCap + e->abCap) % e->abCap;
        float ol = e->abL[idx], orr = e->abR[idx];
        if (e->abLatFade > 0) {
            const int idx2 = ((e->abPos + i - e->abLatNew) % e->abCap + e->abCap) % e->abCap;
            const float t = 1.f - float(e->abLatFade) / float(e->abLatFadeLen);
            ol = (1.f - t) * ol + t * e->abL[idx2];
            orr = (1.f - t) * orr + t * e->abR[idx2];
            if (--e->abLatFade == 0) e->abLat = e->abLatNew;
        }
        e->abMix = target > e->abMix ? std::fmin(target, e->abMix + e->abStep) : std::fmax(target, e->abMix - e->abStep);
        const float a = e->abMix;
        // equal-power crossfade
        const float gp = std::cos(a * float(M_PI_2)), go = std::sin(a * float(M_PI_2));
        L[i] = gp * L[i] + go * ol;
        R[i] = gp * R[i] + go * orr;
    }
    e->abPos = (e->abPos + n) % e->abCap;
}

static void runChainInner(hs_engine *e, float *L, float *R, int n) {
    if (!e->dryL || n <= 0) return;
    const bool active = anyStageOn(e) || e->mix[HS_ST_LIMIT] > 0.f;
    if (active) {   // NaN/Inf at the input would poison every filter state: replace with silence
        for (int i = 0; i < n; ++i) {
            if (!std::isfinite(L[i])) L[i] = 0.f;
            if (!std::isfinite(R[i])) R[i] = 0.f;
        }
    }
    runStage(e, HS_ST_MONO, e->on(HS_P_MONO), L, R, n, [](float *l, float *r, int k) {
        for (int i = 0; i < k; ++i) { const float m = 0.5f * (l[i] + r[i]); l[i] = m; r[i] = m; }
    });
    if (hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire); !d) {
        e->dnMix = 0.f;
        e->t.dnMix.store(0.f, std::memory_order_relaxed);
    } else {   // runs whenever loaded: rings + delay line stay current (no stale replay on re-enable)
        const uint64_t t0 = mach_absolute_time();
        d->attenDb.store(e->p(HS_P_DENOISE_DB), std::memory_order_relaxed);
        hs::processDenoiser(d, L, R, n, e->sampleRate, e->on(HS_P_DENOISE_ON), e->dnMix, e->dnMixStep);
        e->t.dnMix.store(e->dnMix, std::memory_order_relaxed);
        e->t.stageTicks[HS_ST_DENOISE].fetch_add(mach_absolute_time() - t0, std::memory_order_relaxed);
    }
    runStage(e, HS_ST_HPF, e->on(HS_P_HPF_ON), L, R, n, [e](float *l, float *r, int k) { e->hpf.process(l, r, k); });

    const bool deess = e->on(HS_P_DEESS_ON) || e->mix[HS_ST_DEESS] > 0.f;
    if (deess) {   // de-esser detector looks at the pre-EQ signal (DESIGN §7.3)
        std::memcpy(e->preL, L, sizeof(float) * size_t(n));
        std::memcpy(e->preR, R, sizeof(float) * size_t(n));
    }
    e->eq.update(e->p(HS_P_DEBOX_DB), e->p(HS_P_PRESENCE_DB));
    runStage(e, HS_ST_EQ, e->on(HS_P_EQ_ON), L, R, n, [e](float *l, float *r, int k) { e->eq.process(l, r, k); });
    const float maxRed = e->p(HS_P_DEESS_MAX_DB);
    runStage(e, HS_ST_DEESS, e->on(HS_P_DEESS_ON), L, R, n, [e, maxRed](float *l, float *r, int k) {
        e->deess.process(e->preL, e->preR, l, r, k, maxRed);
    });

    const float target = e->p(HS_P_TARGET_LUFS);
    // Make-up referenced at the per-channel RMS that corresponds to the LUFS target for a
    // centred (L = R) signal: −3.01 dB stereo sum, +0.691 BS.1770 offset → target − 2.3 dB.
    const float strength = e->p(HS_P_LEVEL_STRENGTH);
    if (strength != e->curStrength) { e->leveler.setStrength(strength); e->comp.setStrength(strength); e->curStrength = strength; e->curTarget = NAN; }
    if (target != e->curTarget) { e->comp.makeup = -e->comp.staticGain(target - 2.3f); e->curTarget = target; }
    runStage(e, HS_ST_LEVEL, e->on(HS_P_LEVEL_ON), L, R, n, [e, target](float *l, float *r, int k) {
        e->leveler.applyGain(l, r, k, target);
        e->comp.process(l, r, k);
        e->leveler.measureOutput(l, r, k, target);
    });
    {   // Reverb manages its own enable ramp and drains on zeros instead of resetting (D-013).
        const uint64_t t0 = mach_absolute_time();
        e->reverb.process(L, R, n, e->on(HS_P_REVERB_ON), e->p(HS_P_WET), e->p(HS_P_PREDELAY_MS), e->p(HS_P_DISTANCE));
        e->t.stageTicks[HS_ST_REVERB].fetch_add(mach_absolute_time() - t0, std::memory_order_relaxed);
    }

    // The limiter stage (its look-ahead delay) stays in the path whenever any stage is active, so the
    // chain latency is constant; HS_P_LIMIT_ON only switches the gain computation (D-012).
    const bool limitOn = e->on(HS_P_LIMIT_ON);
    if (!anyStageOn(e) && e->mix[HS_ST_LIMIT] == 0.f) {
        // Fully bypassed: keep the limiter's delay line and gain state warm on a scratch copy, so a
        // later switch-on crossfades from real history (no 1.5 ms of silence, no click). During that
        // 10 ms crossfade the dry part is the unprocessed original that was playing anyway (D-012).
        std::memcpy(e->dryL, L, sizeof(float) * size_t(n));
        std::memcpy(e->dryR, R, sizeof(float) * size_t(n));
        e->limiter.process(e->dryL, e->dryR, n, limitOn);
    }
    runStage(e, HS_ST_LIMIT, anyStageOn(e), L, R, n, [e, limitOn](float *l, float *r, int k) { e->limiter.process(l, r, k, limitOn); });

    if (active) {   // output guard: a non-finite block resets every stage and is replaced by silence
        float acc = 0.f;
        for (int i = 0; i < n; ++i) acc += L[i] + R[i];
        if (!std::isfinite(acc)) {
            resetAll(e);
            std::memset(L, 0, sizeof(float) * size_t(n));
            std::memset(R, 0, sizeof(float) * size_t(n));
            e->t.dspResets.fetch_add(1, std::memory_order_relaxed);
        }
    }

    e->t.deessDb.store(e->mix[HS_ST_DEESS] > 0 ? e->deess.lastReductionDb : 0.f, std::memory_order_relaxed);
    e->t.levelerGainDb.store(e->mix[HS_ST_LEVEL] > 0 ? e->leveler.gainDb : 0.f, std::memory_order_relaxed);
    e->t.compGrDb.store(e->mix[HS_ST_LEVEL] > 0 ? e->comp.lastGrDb : 0.f, std::memory_order_relaxed);
    e->t.limiterGrDb.store(e->mix[HS_ST_LIMIT] > 0 ? e->limiter.lastGrDb : 0.f, std::memory_order_relaxed);
}

static void applyFade(hs_engine *e, float *L, float *R, int n) {
    const int target = e->fadeTarget.load(std::memory_order_relaxed);
    float g = e->fadeGain;
    const float goal = target ? 1.f : 0.f;
    if (g == goal) {
        if (goal == 0.f) {
            std::memset(L, 0, sizeof(float) * n);
            std::memset(R, 0, sizeof(float) * n);
        }
    } else {
        const float step = target ? e->fadeStep : -e->fadeStep;
        for (int i = 0; i < n; ++i) {
            g += step;
            g = g < 0.f ? 0.f : (g > 1.f ? 1.f : g);
            L[i] *= g;
            R[i] *= g;
        }
    }
    e->fadeGain = g;
    int state = g >= 1.f ? HS_FADE_OPEN : (g <= 0.f ? HS_FADE_SILENT : (target ? HS_FADE_IN : HS_FADE_OUT));
    e->t.fadeState.store(state, std::memory_order_relaxed);
}

static void freeCapture(hs_engine::Capture *c) {
    if (!c) return;
    std::free(c->data);
    delete c;
}

extern "C" {

hs_engine *hs_engine_create(void) {
    auto *e = new (std::nothrow) hs_engine();
    if (!e) return nullptr;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    e->hostTicksToNs = double(tb.numer) / double(tb.denom);
    return e;
}

void hs_engine_destroy(hs_engine *e) {
    if (!e) return;
    hs_engine_denoiser_unload(e, 1);   // joins the worker (destroy only runs once the I/O thread is gone)
    for (int i = 0; i < e->dnRetiredN; ++i) delete e->dnRetired[i];
    e->dnRetiredN = 0;
    freeCapture(e->capture.load(std::memory_order_acquire));
    freeCapture(e->detached);
    std::free(e->left); std::free(e->right);
    std::free(e->dryL); std::free(e->dryR); std::free(e->preL); std::free(e->preR);
    std::free(e->abL); std::free(e->abR);
    delete e;
}

void hs_engine_prepare(hs_engine *e, double sampleRate, int maxFrames) {
    std::free(e->left);
    std::free(e->right);
    e->sampleRate = sampleRate;
    e->maxFrames = maxFrames;
    e->left = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    e->right = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    for (float **b : {&e->dryL, &e->dryR, &e->preL, &e->preR}) {
        std::free(*b);
        *b = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    }
    e->mixStep = float(1.0 / (0.010 * sampleRate));
    std::free(e->abL); std::free(e->abR);
    e->abCap = 8192 + maxFrames;   // ≥ DFN3 latency (2896) + limiter (72) + one block
    e->abL = static_cast<float *>(std::calloc(size_t(e->abCap), sizeof(float)));
    e->abR = static_cast<float *>(std::calloc(size_t(e->abCap), sizeof(float)));
    e->abPos = 0; e->abMix = 0.f; e->abLat = e->abLatNew = 0; e->abLatFade = 0;
    e->abLatFadeLen = int(0.020 * sampleRate);
    e->curStrength = NAN;
    e->abStep = float(1.0 / (0.020 * sampleRate));
    for (int st = 0; st < HS_ST_COUNT; ++st) e->mix[st] = 0.f;
    e->hpf.prepare(sampleRate);
    e->eq.prepare(sampleRate);
    e->deess.prepare(sampleRate, maxFrames);
    e->leveler.prepare(sampleRate);
    e->comp.prepare(sampleRate, e->p(HS_P_TARGET_LUFS) - 2.3f);
    e->curTarget = e->p(HS_P_TARGET_LUFS);
    e->limiter.prepare(sampleRate);
    e->reverb.prepare(sampleRate, maxFrames);
    e->dnMix = 0.f;
    e->dnMixStep = float(1.0 / (0.020 * sampleRate));
    e->fadeStep = float(1.0 / (0.020 * sampleRate));
    e->meterDecay = 0.9f;
    e->lastOutSampleTime = -1.0;
    e->lastInSampleTime = -1.0;
}

void hs_engine_set_input(hs_engine *e, int bufferIndex, int channels, int interleaved) {
    e->inBuffer = bufferIndex;
    e->inChannels = channels < 1 ? 1 : channels;
    e->inInterleaved = interleaved;
}

void hs_engine_set_output_map(hs_engine *e, int numBuffers, const int *channelsPerBuffer,
                              const int *interleavedPerBuffer, const int8_t *sourcePerChannel) {
    numBuffers = numBuffers > kMaxOutBuffers ? kMaxOutBuffers : numBuffers;
    e->outBuffers = numBuffers;
    int total = 0;
    for (int b = 0; b < numBuffers; ++b) {
        e->outChannels[b] = channelsPerBuffer[b];
        e->outInterleaved[b] = interleavedPerBuffer[b];
        total += channelsPerBuffer[b];
    }
    total = total > kMaxOutChannels ? kMaxOutChannels : total;
    std::memset(e->outSource, 0, sizeof(e->outSource));
    std::memcpy(e->outSource, sourcePerChannel, size_t(total));
}

static inline void setFTZ() {
#if defined(__aarch64__)
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    if (!(fpcr & (1ULL << 24))) { fpcr |= (1ULL << 24); __asm__ volatile("msr fpcr, %0" : : "r"(fpcr)); }
#endif
}

void hs_engine_process_planar(hs_engine *e, float *left, float *right, int n) {
    setFTZ();
    for (int off = 0; off < n; off += e->maxFrames) {   // never exceed the prepared block size
        const int k = (n - off) < e->maxFrames ? (n - off) : e->maxFrames;
        runChain(e, left + off, right + off, k);
    }
}

OSStatus hs_ioproc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input,
                   const AudioTimeStamp *inputTime, AudioBufferList *output,
                   const AudioTimeStamp *outputTime, void *clientData) {
    auto *e = static_cast<hs_engine *>(clientData);
#if defined(__aarch64__)
    {   // flush denormals to zero on the I/O thread (FPCR.FZ)
        uint64_t fpcr;
        __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
        if (!(fpcr & (1ULL << 24))) { fpcr |= (1ULL << 24); __asm__ volatile("msr fpcr, %0" : : "r"(fpcr)); }
    }
#endif
    if (e->debugStall.load(std::memory_order_relaxed)) {
        for (UInt32 b = 0; output && b < output->mNumberBuffers; ++b)
            if (output->mBuffers[b].mData) std::memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        return noErr;
    }
    const uint64_t t0 = mach_absolute_time();
    e->t.heartbeat.store(t0, std::memory_order_release);
    e->t.generation.store(e->generationCtl.load(std::memory_order_relaxed), std::memory_order_relaxed);
    e->t.callbacks.fetch_add(1, std::memory_order_relaxed);

    // Output frame count = what the device asks for.
    int frames = 0;
    if (output && output->mNumberBuffers > 0 && e->outBuffers > 0) {
        const AudioBuffer &b0 = output->mBuffers[0];
        const int ch = b0.mNumberChannels > 0 ? int(b0.mNumberChannels) : 1;
        frames = int(b0.mDataByteSize / (sizeof(float) * unsigned(ch)));
    }
    if (frames > e->maxFrames) frames = e->maxFrames;

    // xrun detection: discontinuity of the output sample time.
    if (outputTime && (outputTime->mFlags & kAudioTimeStampSampleTimeValid)) {
        const double st = outputTime->mSampleTime;
        if (e->lastOutSampleTime >= 0.0 && std::fabs(st - (e->lastOutSampleTime + e->lastFramesRT)) > 0.5)
            e->t.xruns.fetch_add(1, std::memory_order_relaxed);
        e->lastOutSampleTime = st;
        e->lastFramesRT = frames;
    }
    e->t.lastFrames.store(frames, std::memory_order_relaxed);
    // xrun detection on the tap input side as well (DESIGN §5).
    if (inputTime && (inputTime->mFlags & kAudioTimeStampSampleTimeValid)) {
        const double st = inputTime->mSampleTime;
        if (e->lastInSampleTime >= 0.0 && std::fabs(st - (e->lastInSampleTime + e->lastInFrames)) > 0.5)
            e->t.xruns.fetch_add(1, std::memory_order_relaxed);
        e->lastInSampleTime = st;
        e->lastInFrames = frames;
    }
    if (inputTime && outputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid) &&
        (outputTime->mFlags & kAudioTimeStampHostTimeValid) && inputTime->mHostTime > 0) {
        const double d = (double(outputTime->mHostTime) - double(inputTime->mHostTime)) * e->hostTicksToNs * 1e-9;
        e->t.ioDelta.store(d, std::memory_order_relaxed);
    }

    // ---- input: tap buffer → planar L/R ----
    float *L = e->left, *R = e->right;
    int inFrames = 0;
    if (input && int(input->mNumberBuffers) > e->inBuffer && L && R) {
        const AudioBuffer &ib = input->mBuffers[e->inBuffer];
        const float *src = static_cast<const float *>(ib.mData);
        const int ch = ib.mNumberChannels > 0 ? int(ib.mNumberChannels) : 1;
        inFrames = src ? int(ib.mDataByteSize / (sizeof(float) * unsigned(ch))) : 0;
        if (inFrames > frames) inFrames = frames;
        if (ch >= 2) {
            for (int i = 0; i < inFrames; ++i) { L[i] = src[i * ch]; R[i] = src[i * ch + 1]; }
        } else {
            for (int i = 0; i < inFrames; ++i) { L[i] = R[i] = src[i]; }
        }
    }
    if (L && R && inFrames < frames) {
        std::memset(L + inFrames, 0, sizeof(float) * size_t(frames - inFrames));
        std::memset(R + inFrames, 0, sizeof(float) * size_t(frames - inFrames));
    }

    // Capture the raw tap input (before the chain) if a capture is armed. RT: copy + atomics only.
    if (hs_engine::Capture *c = e->capture.load(std::memory_order_acquire); c && L && R) {
        const int64_t w = c->written.load(std::memory_order_relaxed);
        const int64_t k = frames < (c->capacity - w) ? frames : (c->capacity - w);
        for (int64_t i = 0; i < k; ++i) { c->data[2 * (w + i)] = L[i]; c->data[2 * (w + i) + 1] = R[i]; }
        if (k > 0) c->written.store(w + k, std::memory_order_release);
    }

    // Meters + permission signal (non-zero input).
    if (frames > 0 && L && R) {
        float pin = absPeak(L, frames, 1);
        float pr = absPeak(R, frames, 1);
        pin = pin > pr ? pin : pr;
        if (pin > 0.f) e->t.nonzeroBlocks.fetch_add(1, std::memory_order_relaxed);
        float old = e->t.peakIn.load(std::memory_order_relaxed) * e->meterDecay;
        e->t.peakIn.store(pin > old ? pin : old, std::memory_order_relaxed);

        runChain(e, L, R, frames);
        applyFade(e, L, R, frames);

        float pout = absPeak(L, frames, 1);
        pr = absPeak(R, frames, 1);
        pout = pout > pr ? pout : pr;
        old = e->t.peakOut.load(std::memory_order_relaxed) * e->meterDecay;
        e->t.peakOut.store(pout > old ? pout : old, std::memory_order_relaxed);
    }

    // ---- planar L/R → output buffers via channel map ----
    if (output) {
        int chBase = 0;
        const int nb = int(output->mNumberBuffers) < e->outBuffers ? int(output->mNumberBuffers) : e->outBuffers;
        for (int b = 0; b < int(output->mNumberBuffers); ++b) {
            AudioBuffer &ob = output->mBuffers[b];
            const int ch = int(ob.mNumberChannels) > 0 ? int(ob.mNumberChannels) : 1;
            if (!ob.mData) { chBase += ch; continue; }
            if (b >= nb || frames == 0 || !L) { std::memset(ob.mData, 0, ob.mDataByteSize); chBase += ch; continue; }
            float *dst = static_cast<float *>(ob.mData);
            const int bufFrames = int(ob.mDataByteSize / (sizeof(float) * unsigned(ch)));
            const int n = bufFrames < frames ? bufFrames : frames;
            for (int c = 0; c < ch; ++c) {
                const int idx = chBase + c;
                const int8_t s = idx < kMaxOutChannels ? e->outSource[idx] : HS_SRC_ZERO;
                for (int i = 0; i < n; ++i) {
                    float v = 0.f;
                    if (s == HS_SRC_LEFT) v = L[i];
                    else if (s == HS_SRC_RIGHT) v = R[i];
                    else if (s == HS_SRC_MONO) v = 0.5f * (L[i] + R[i]);
                    dst[i * ch + c] = v;
                }
                for (int i = n; i < bufFrames; ++i) dst[i * ch + c] = 0.f;
            }
            chBase += ch;
        }
    }

    // CPU load: render time relative to the block duration (EMA).
    if (frames > 0) {
        const double ns = double(mach_absolute_time() - t0) * e->hostTicksToNs;
        const double blockNs = 1e9 * frames / e->sampleRate;
        const float load = float(ns / blockNs);
        const float prev = e->t.cpuLoad.load(std::memory_order_relaxed);
        e->t.cpuLoad.store(prev + 0.02f * (load - prev), std::memory_order_relaxed);
    }
    return noErr;
}

void hs_engine_set_fade_target(hs_engine *e, int open) { e->fadeTarget.store(open ? 1 : 0, std::memory_order_relaxed); }

void hs_engine_reset_fade(hs_engine *e, int startOpen) {
    e->fadeGain = startOpen ? 1.f : 0.f;
    e->fadeTarget.store(1, std::memory_order_relaxed);
    e->t.fadeState.store(startOpen ? HS_FADE_OPEN : HS_FADE_SILENT, std::memory_order_relaxed);
}

void hs_engine_set_generation(hs_engine *e, uint64_t g) { e->generationCtl.store(g, std::memory_order_relaxed); }

int hs_engine_capture_start(hs_engine *e, double seconds) {
    if (e->capture.load(std::memory_order_acquire) || e->detached) return -1;
    auto *c = new (std::nothrow) hs_engine::Capture();
    if (!c) return -2;
    c->capacity = int64_t(seconds * e->sampleRate);
    const size_t bytes = size_t(c->capacity) * 2 * sizeof(float);
    c->data = static_cast<float *>(std::malloc(bytes));
    if (!c->data) { delete c; return -2; }
    // Touch every page here (control thread): large calloc/malloc blocks are lazily mapped, and
    // ~5,600 first-touch page faults over 60 s on the I/O thread would risk xruns.
    std::memset(c->data, 0, bytes);
    e->capture.store(c, std::memory_order_release);
    return 0;
}

int64_t hs_engine_capture_progress(const hs_engine *e, int64_t *capacity) {
    const hs_engine::Capture *c = e->capture.load(std::memory_order_acquire);
    if (!c) c = e->detached;
    if (capacity) *capacity = c ? c->capacity : 0;
    return c ? c->written.load(std::memory_order_acquire) : -1;
}

int64_t hs_engine_capture_detach(hs_engine *e) {
    hs_engine::Capture *c = e->capture.exchange(nullptr, std::memory_order_acq_rel);
    if (!c) return e->detached ? e->detached->written.load(std::memory_order_acquire) : -1;
    e->detached = c;
    e->detachedAtCallback = e->t.callbacks.load(std::memory_order_acquire);
    return c->written.load(std::memory_order_acquire);
}

int64_t hs_engine_capture_copy(const hs_engine *e, float *dst, int64_t maxFrames) {
    const hs_engine::Capture *c = e->detached;
    if (!c) return -1;
    const int64_t n = c->written.load(std::memory_order_acquire);
    const int64_t k = n < maxFrames ? n : maxFrames;
    std::memcpy(dst, c->data, size_t(k) * 2 * sizeof(float));
    return k;
}

int hs_engine_capture_release(hs_engine *e, int ioprocStopped) {
    if (!e->detached) return 1;
    // An IOProc call that loaded the pointer before the detach may still be copying. Each call loads
    // it once, so two further calls (or a stopped IOProc) prove the old pointer is no longer in use.
    const uint64_t now = e->t.callbacks.load(std::memory_order_acquire);
    if (!ioprocStopped && now < e->detachedAtCallback + 2) return 0;
    freeCapture(e->detached);
    e->detached = nullptr;
    return 1;
}

void hs_engine_debug_stall(hs_engine *e, int on) { e->debugStall.store(on, std::memory_order_relaxed); }

void hs_engine_note_overload(hs_engine *e) {
    e->t.overloads.fetch_add(1, std::memory_order_relaxed);
    e->t.xruns.fetch_add(1, std::memory_order_relaxed);
}

void hs_engine_read_telemetry(const hs_engine *e, hs_telemetry *o) {
    o->heartbeatHostTime = e->t.heartbeat.load(std::memory_order_acquire);
    o->generation = e->t.generation.load(std::memory_order_relaxed);
    o->callbacks = e->t.callbacks.load(std::memory_order_relaxed);
    o->xruns = e->t.xruns.load(std::memory_order_relaxed);
    o->overloads = e->t.overloads.load(std::memory_order_relaxed);
    o->nonzeroBlocks = e->t.nonzeroBlocks.load(std::memory_order_relaxed);
    o->peakIn = e->t.peakIn.load(std::memory_order_relaxed);
    o->peakOut = e->t.peakOut.load(std::memory_order_relaxed);
    o->cpuLoad = e->t.cpuLoad.load(std::memory_order_relaxed);
    o->fadeState = e->t.fadeState.load(std::memory_order_relaxed);
    o->lastFrames = e->t.lastFrames.load(std::memory_order_relaxed);
    o->ioDeltaSec = e->t.ioDelta.load(std::memory_order_relaxed);
    o->deessDb = e->t.deessDb.load(std::memory_order_relaxed);
    o->levelerGainDb = e->t.levelerGainDb.load(std::memory_order_relaxed);
    o->compGrDb = e->t.compGrDb.load(std::memory_order_relaxed);
    o->limiterGrDb = e->t.limiterGrDb.load(std::memory_order_relaxed);
    o->dspResets = e->t.dspResets.load(std::memory_order_relaxed);
    o->limiterClips = e->limiter.clipped;   // offline/test diagnostic (RT-owned counter)
    {   // engine-owned counters: no dereference of a DenoiserRT that may be unloading (D-017)
        const hs::DenoiserStats &s = e->dnStats;
        o->dnUnderflows = s.underflows.load(std::memory_order_relaxed);
        o->dnHops = s.hops.load(std::memory_order_relaxed);
        o->dnHopMeanUs = o->dnHops ? double(s.hopNsTotal.load(std::memory_order_relaxed)) / double(o->dnHops) / 1e3 : 0;
        o->dnHopMaxUs = double(s.hopNsMax.load(std::memory_order_relaxed)) / 1e3;
        o->dnNaN = s.errors.load(std::memory_order_relaxed);
        o->dnFailed = s.failed.load(std::memory_order_relaxed);
        o->dnSkipped = s.skipped.load(std::memory_order_relaxed);
        o->dnMix = e->t.dnMix.load(std::memory_order_relaxed);
    }
}

int hs_engine_latency_samples(const hs_engine *e) {
    int lat = anyStageOn(e) ? e->limiter.latency() : 0;
    const hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire);
    if (d && e->t.dnMix.load(std::memory_order_relaxed) > 0.f) lat += d->latency;
    return lat;
}

int hs_engine_denoiser_load(hs_engine *e, const char *modelPath, int synchronous, int ioBufferFrames) {
    if (e->dn.load(std::memory_order_acquire)) return -4;
    int err = 0;
    hs::DenoiserRT *d = hs::createDenoiser(e->sampleRate, e->maxFrames, ioBufferFrames, modelPath,
                                           e->p(HS_P_DENOISE_DB), synchronous != 0, &e->dnStats, &err);
    if (!d) return err;
    e->dn.store(d, std::memory_order_release);
    return 0;
}

void hs_engine_denoiser_unload(hs_engine *e, int ioprocStopped) {
    hs::DenoiserRT *d = e->dn.exchange(nullptr, std::memory_order_acq_rel);
    if (!d) return;
    d->stopWorker();   // the worker never touches I/O-side state; safe to join now
    bool proven = false;
    if (!ioprocStopped) {
        // The I/O thread loads the pointer once per callback; two further callbacks prove it is no
        // longer in use. Bounded wait (a stopped device never advances the counter).
        const uint64_t c0 = e->t.callbacks.load(std::memory_order_acquire);
        for (int i = 0; i < 100 && !proven; ++i) {
            proven = e->t.callbacks.load(std::memory_order_acquire) >= c0 + 2;
            if (!proven) usleep(2000);
        }
    }
    // Not proven (timeout, or the IOProc was just destroyed without heartbeat proof): park it; the
    // engine frees it in hs_engine_destroy, which only runs after ≥ 1 s of heartbeat silence (D-017).
    if (proven) delete d;
    else if (e->dnRetiredN < 8) e->dnRetired[e->dnRetiredN++] = d;
    else delete e->dnRetired[0], e->dnRetired[0] = d;   // never expected; oldest is ≥ 7 unloads old
}

void hs_engine_denoiser_set_workgroup(hs_engine *e, void *wg) {
    // Takes ownership of one reference (the HAL property getter returns +1; caller must release).
    auto *w = static_cast<os_workgroup_t>(wg);
    hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire);
    if (!d) { if (w) os_release(w); return; }
    if (os_workgroup_t old = d->pendingWg.exchange(w, std::memory_order_acq_rel)) os_release(old);
    semaphore_signal(d->sem);
}

void hs_engine_denoiser_test_fail(hs_engine *e) {
    if (hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire)) d->failNext.store(true);
}

void hs_engine_denoiser_test_pause(hs_engine *e, int paused) {
    if (hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire)) d->paused.store(paused != 0);
}

int hs_engine_denoiser_latency(const hs_engine *e) {
    const hs::DenoiserRT *d = e->dn.load(std::memory_order_acquire);
    return d ? d->latency : 0;
}

void hs_engine_set_param(hs_engine *e, int param, float value) {
    if (param < 0 || param >= HS_P_COUNT || !std::isfinite(value)) return;
    // DENOISE_DB ≥ 1: at exactly 0 dB libDF bypasses with the *undelayed* frame (tract.rs:558-561),
    // which would make the latency jump by 1440 samples when the slider leaves 0 (D-016).
    static const float lo[HS_P_COUNT] = {0, 0, 0, 0, 0, 0, 0, -12.f, 0.f, 0.f, -30.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 1.f, 0.f, 0.f};
    static const float hi[HS_P_COUNT] = {1, 1, 1, 1, 1, 1, 1, 6.f, 6.f, 6.f, -10.f, 2.f, 0.4f, 40.f, 1.f, 1.f, 1.f, 100.f, 1.f, 1.f};
    if (param == HS_P_ROOM) value = std::round(value);
    value = value < lo[param] ? lo[param] : (value > hi[param] ? hi[param] : value);
    e->params[param].store(value, std::memory_order_relaxed);
}
float hs_engine_get_param(const hs_engine *e, int param) {
    return (param >= 0 && param < HS_P_COUNT) ? e->p(param) : 0.f;
}

int hs_preset_values(const char *name, float *out, unsigned char *setMask) {
    hs_engine *tmp = hs_engine_create();   // control thread only (allocates)
    if (!tmp) return -1;
    for (int i = 0; i < HS_P_COUNT; ++i) tmp->params[i].store(NAN);
    const int r = hs_engine_apply_preset(tmp, name);
    for (int i = 0; i < HS_P_COUNT; ++i) {
        const float v = tmp->params[i].load();
        setMask[i] = std::isnan(v) ? 0 : 1;
        out[i] = std::isnan(v) ? 0.f : v;
    }
    hs_engine_destroy(tmp);
    return r;
}

int hs_engine_apply_preset(hs_engine *e, const char *name) {
    struct Preset { const char *name; float sw[7]; float room, wet, predelay; };   // switches: mono, hpf, eq, deess, level, limit, reverb
    static const Preset presets[] = {
        {"off", {0, 0, 0, 0, 0, 0, 0}, 1, 0.15f, 15},
        {"clarity", {1, 1, 1, 1, 1, 1, 0}, 1, 0.15f, 15},
        {"hall", {1, 1, 1, 1, 1, 1, 1}, 1, 0.15f, 15},
        {"auditorium", {1, 1, 1, 1, 1, 1, 1}, 2, 0.18f, 20},
        {"seminar", {1, 1, 1, 1, 1, 1, 1}, 0, 0.12f, 10},
    };
    for (const auto &pr : presets) {
        if (std::strcmp(pr.name, name) != 0) continue;
        for (int i = 0; i < 7; ++i) hs_engine_set_param(e, HS_P_MONO + i, pr.sw[i]);
        if (std::strcmp(name, "off") != 0) {
            hs_engine_set_param(e, HS_P_DEBOX_DB, -3.f);
            hs_engine_set_param(e, HS_P_PRESENCE_DB, 2.5f);
            hs_engine_set_param(e, HS_P_DEESS_MAX_DB, 3.f);
            hs_engine_set_param(e, HS_P_TARGET_LUFS, -18.f);
            hs_engine_set_param(e, HS_P_ROOM, pr.room);
            hs_engine_set_param(e, HS_P_WET, pr.wet);
            hs_engine_set_param(e, HS_P_PREDELAY_MS, pr.predelay);
            hs_engine_set_param(e, HS_P_DAMPING, 0.5f);
            hs_engine_set_param(e, HS_P_DISTANCE, 0.3f);
        }
        return 0;
    }
    return -1;
}

void hs_engine_collect_garbage(hs_engine *e) {
    while (void *p = e->reverb.outbox.pop()) delete static_cast<hs::ReverbPair *>(p);
}

int hs_engine_reverb_needs_rebuild(const hs_engine *e) {
    return int(e->p(HS_P_ROOM)) != e->reverb.builtRoom || e->p(HS_P_DAMPING) != e->reverb.builtDamping;
}

int hs_engine_rebuild_reverb(hs_engine *e, uint64_t seed) {
    hs_engine_collect_garbage(e);
    if (!hs_engine_reverb_needs_rebuild(e)) return 1;
    if (e->reverb.inbox.full()) return -1;
    const int room = int(e->p(HS_P_ROOM));
    const float damping = e->p(HS_P_DAMPING);
    const int n = hs_ir_length(room, e->sampleRate);
    std::vector<float> l(static_cast<size_t>(n)), r(static_cast<size_t>(n));
    if (hs_ir_generate(room, damping, e->sampleRate, seed, l.data(), r.data(), n) != n) return -2;
    auto *pair = new (std::nothrow) hs::ReverbPair();
    if (!pair) return -2;
    // Tail-job phases alternate per build (0/½ then ¼/¾ then 0/½ …), so during a 300 ms crossfade
    // the old and the new pair's four tail jobs never land in the same callback.
    const int T = hs::ReverbPair::kTail;
    const bool even = e->reverb.buildCount % 2 == 0;
    if (!pair->build(l.data(), r.data(), n, even ? 0 : T / 4, even ? T / 2 : 3 * T / 4)) { delete pair; return -2; }
    if (!e->reverb.inbox.push(pair)) { delete pair; return -1; }
    e->reverb.builtRoom = room;
    e->reverb.builtDamping = damping;
    e->reverb.buildCount++;
    return 0;
}

int hs_test_convolve(const float *ir, int irLen, const float *in, float *out, int n, int block) {
    fftconvolver::TwoStageFFTConvolver c;
    if (!c.init(hs::ReverbPair::kHead, hs::ReverbPair::kTail, ir, size_t(irLen))) return -1;
    for (int off = 0; off < n; off += block) {
        const int k = (n - off) < block ? (n - off) : block;
        c.process(in + off, out + off, size_t(k));
    }
    return 0;
}

const char *hs_fft_backend(void) {
#if defined(AUDIOFFT_APPLE_ACCELERATE)
    return "vdsp";
#else
    return "ooura";
#endif
}

uint64_t hs_engine_stage_ns(const hs_engine *e, int stage) {
    if (stage < 0 || stage >= HS_ST_COUNT) return 0;
    return uint64_t(double(e->t.stageTicks[stage].load(std::memory_order_relaxed)) * e->hostTicksToNs);
}

void hs_design_biquad(int type, double fs, double f0, double q, double gainDb, double *o) {
    const auto c = hs::designBiquad(static_cast<hs::FilterType>(type), fs, f0, q, gainDb);
    o[0] = c.b0; o[1] = c.b1; o[2] = c.b2; o[3] = c.a1; o[4] = c.a2;
}
void hs_design_kweighting(double fs, double *s5, double *r5) {
    hs::BiquadCoeffs s, r;
    hs::designKWeighting(fs, s, r);
    s5[0] = s.b0; s5[1] = s.b1; s5[2] = s.b2; s5[3] = s.a1; s5[4] = s.a2;
    r5[0] = r.b0; r5[1] = r.b1; r5[2] = r.b2; r5[3] = r.a1; r5[4] = r.a2;
}

} // extern "C"
