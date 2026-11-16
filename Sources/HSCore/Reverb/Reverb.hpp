// Convolution reverb stage (DESIGN §7.5, decision D-013). TwoStageFFTConvolver (head 256, tail 4096)
// computed synchronously on the I/O thread; the R convolver's tail phase is staggered so the two
// tail jobs never land in the same callback. IR changes: the new pair is built on a control thread
// and handed over through an SPSC inbox; the RT thread switches the input to the new pair, lets the
// old one ring out on zeros with a 300 ms fade and returns it through the outbox (no pre-roll,
// no reset/free on the audio thread).
#pragma once
#include "TwoStageFFTConvolver.h"
#include "../DSP/Stages.hpp"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace hs {

/// A built convolver pair. Constructed, initialised and destroyed on control threads only.
struct ReverbPair {
    fftconvolver::TwoStageFFTConvolver L, R;
    int irLen = 0;
    static constexpr int kHead = 256, kTail = 4096;

    /// Allocates. phaseL/phaseR: zeros fed after init to stagger the tail jobs (0 … kTail).
    bool build(const float *irL, const float *irR, int n, int phaseL, int phaseR) {
        if (!L.init(kHead, kTail, irL, size_t(n)) || !R.init(kHead, kTail, irR, size_t(n))) return false;
        std::vector<float> z(static_cast<size_t>(kTail), 0.f), o(static_cast<size_t>(kTail));
        if (phaseL > 0) L.process(z.data(), o.data(), size_t(phaseL));
        if (phaseR > 0) R.process(z.data(), o.data(), size_t(phaseR));
        irLen = n;
        return true;
    }
};

/// Lock-free single-producer / single-consumer queue of pointers.
template <int CAP>
struct PtrQueue {
    std::atomic<int> r{0}, w{0};
    void *slot[CAP] = {};
    bool push(void *p) {
        const int wi = w.load(std::memory_order_relaxed), next = (wi + 1) % CAP;
        if (next == r.load(std::memory_order_acquire)) return false;
        slot[wi] = p;
        w.store(next, std::memory_order_release);
        return true;
    }
    void *pop() {
        const int ri = r.load(std::memory_order_relaxed);
        if (ri == w.load(std::memory_order_acquire)) return nullptr;
        void *p = slot[ri];
        r.store((ri + 1) % CAP, std::memory_order_release);
        return p;
    }
    bool full() const { return (w.load(std::memory_order_acquire) + 1) % CAP == r.load(std::memory_order_acquire); }
    bool empty() const { return r.load(std::memory_order_acquire) == w.load(std::memory_order_acquire); }
};

struct ReverbStage {
    double fs = 48000;
    int maxFrames = 0;
    // ---- RT-owned ----
    ReverbPair *cur = nullptr, *old = nullptr;
    int oldFadeLeft = 0, oldFadeLen = 14400;
    float m = 0, mStep = 0;              // enable mix (10 ms ramp)
    long long drainLeft = 0;             // zeros still to feed after disabling (clean state, no reset)
    // pre-delay (two-tap crossfade on change)
    float *pdL = nullptr, *pdR = nullptr;
    int pdCap = 0, pdW = 0, delayCur = 0, delayNew = 0, pdFade = 0, pdFadeLen = 960;
    // distance: dry high-shelf cut via one-pole split
    float lpL = 0, lpR = 0, lpA = 0;
    float curWet = -1.f, curDist = 0.f;   // last applied wet / distance (per-sample interpolation)
    float *inL = nullptr, *inR = nullptr, *wetL = nullptr, *wetR = nullptr, *oL = nullptr, *oR = nullptr, *zeros = nullptr;
    unsigned long long swaps = 0;
    // ---- control-side ----
    PtrQueue<4> inbox, outbox;
    int builtRoom = -1;
    float builtDamping = -1;
    int buildCount = 0;

    void prepare(double sr, int frames) {
        fs = sr; maxFrames = frames;
        pdCap = int(0.042 * fs) + 1;
        for (float **b : {&pdL, &pdR}) { std::free(*b); *b = static_cast<float *>(std::calloc(size_t(pdCap), sizeof(float))); }
        for (float **b : {&inL, &inR, &wetL, &wetR, &oL, &oR, &zeros}) {
            std::free(*b); *b = static_cast<float *>(std::calloc(size_t(frames), sizeof(float)));
        }
        mStep = float(1.0 / (0.010 * fs));
        oldFadeLen = int(0.300 * fs);
        pdFadeLen = int(0.020 * fs);
        lpA = float(1.0 - std::exp(-2.0 * M_PI * 5000.0 / fs));
        pdW = 0; delayCur = delayNew = int(0.015 * fs); pdFade = 0;
        m = 0; drainLeft = 0; lpL = lpR = 0; curWet = -1.f; curDist = 0.f;
        // Existing pairs belong to the old rate: retire them (prepare runs with no I/O active).
        delete cur; delete old; cur = old = nullptr;
        while (void *p = inbox.pop()) delete static_cast<ReverbPair *>(p);
        while (void *p = outbox.pop()) delete static_cast<ReverbPair *>(p);
        builtRoom = -1; builtDamping = -1; buildCount = 0;
    }
    ~ReverbStage() {
        for (float *b : {pdL, pdR, inL, inR, wetL, wetR, oL, oR, zeros}) std::free(b);
        delete cur; delete old;
        while (void *p = inbox.pop()) delete static_cast<ReverbPair *>(p);
        while (void *p = outbox.pop()) delete static_cast<ReverbPair *>(p);
    }

    /// RT: accept a new pair when the outbox can take the one being retired.
    void takeInbox() {
        if (inbox.empty()) return;
        if (old) return;                     // never cut a running 300 ms fade short (click); wait for it
        auto *p = static_cast<ReverbPair *>(inbox.pop());
        if (!p) return;
        old = cur;
        oldFadeLeft = old ? oldFadeLen : 0;
        cur = p;
        ++swaps;
    }

    void predelay(const float *L, const float *R, int n, int target) {
        if (target != delayNew && pdFade == 0) { delayNew = target; pdFade = pdFadeLen; }
        for (int i = 0; i < n; ++i) {
            pdL[pdW] = L[i]; pdR[pdW] = R[i];
            const int a = (pdW - delayCur + pdCap) % pdCap;
            float l = pdL[a], r = pdR[a];
            if (pdFade > 0) {
                const int b = (pdW - delayNew + pdCap) % pdCap;
                const float t = 1.f - float(pdFade) / float(pdFadeLen);
                l = (1 - t) * l + t * pdL[b];
                r = (1 - t) * r + t * pdR[b];
                if (--pdFade == 0) delayCur = delayNew;
            }
            inL[i] = l; inR[i] = r;
            pdW = (pdW + 1) % pdCap;
        }
    }

    void process(float *L, float *R, int n, bool enabled, float wet, float predelayMs, float distance) {
        takeInbox();
        const bool on = enabled && cur;
        if (!on && m == 0.f && drainLeft <= 0 && !old) return;   // fully idle: bit-exact bypass

        const int delay = std::clamp(int(std::lround(predelayMs * 1e-3 * fs)), 0, pdCap - 1);
        if (on && m == 0.f) {   // (re-)entering from 0, also mid-drain: no stale pre-delay history (D-014)
            std::memset(pdL, 0, sizeof(float) * size_t(pdCap));
            std::memset(pdR, 0, sizeof(float) * size_t(pdCap));
            delayCur = delayNew = delay; pdFade = 0;
        }
        if (cur) {
            if (on || m > 0.f) {
                predelay(L, R, n, delay);
                for (int i = 0; i < n; ++i) {   // a non-finite sample would poison the convolver for ~2 s
                    if (!std::isfinite(inL[i])) inL[i] = 0.f;
                    if (!std::isfinite(inR[i])) inR[i] = 0.f;
                }
                cur->L.process(inL, wetL, size_t(n));
                cur->R.process(inR, wetR, size_t(n));
            } else {                          // draining: feed zeros so the state ends clean
                cur->L.process(zeros, wetL, size_t(n));
                cur->R.process(zeros, wetR, size_t(n));
                drainLeft -= n;
                std::memset(wetL, 0, sizeof(float) * size_t(n));
                std::memset(wetR, 0, sizeof(float) * size_t(n));
            }
        } else {
            std::memset(wetL, 0, sizeof(float) * size_t(n));
            std::memset(wetR, 0, sizeof(float) * size_t(n));
        }
        if (old) {                            // old room rings out on zeros, fading over 300 ms
            old->L.process(zeros, oL, size_t(n));
            old->R.process(zeros, oR, size_t(n));
            for (int i = 0; i < n; ++i) {
                const float g = float(std::max(0, oldFadeLeft - i)) / float(oldFadeLen);
                wetL[i] += g * oL[i]; wetR[i] += g * oR[i];
            }
            oldFadeLeft = std::max(0, oldFadeLeft - n);
            if (oldFadeLeft == 0 && outbox.push(old)) old = nullptr;
        }
        if (!on && m == 0.f) return;          // draining only: dry untouched

        // wet / distance arrive per block (sliders): interpolate linearly across the block.
        if (curWet < 0.f) { curWet = wet; curDist = distance; }
        const float w0 = curWet, d0 = curDist, inv = 1.f / float(n);
        const float target = on ? 1.f : 0.f;
        for (int i = 0; i < n; ++i) {
            const float t = float(i + 1) * inv;
            const float wetNow = w0 + t * (wet - w0), distNow = d0 + t * (distance - d0);
            const float wetGain = wetNow * dbToLin(3.f * distNow);
            const float shelf = dbToLin(-4.f * distNow) - 1.f;
            m = target > m ? std::min(target, m + mStep) : std::max(target, m - mStep);
            lpL += lpA * (L[i] - lpL); lpR += lpA * (R[i] - lpR);
            const float dl = L[i] + shelf * (L[i] - lpL), dr = R[i] + shelf * (R[i] - lpR);   // distance: duller dry
            const float yl = (1.f - wetNow) * dl + wetGain * wetL[i];
            const float yr = (1.f - wetNow) * dr + wetGain * wetR[i];
            L[i] = (1.f - m) * L[i] + m * yl;
            R[i] = (1.f - m) * R[i] + m * yr;
        }
        curWet = wet; curDist = distance;
        if (!on && m == 0.f) drainLeft = (cur ? cur->irLen : 0) + pdCap;
    }
};

} // namespace hs
