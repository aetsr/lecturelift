// RT-safe DSP stages of the LectureLift chain (DESIGN §7). All buffers are allocated in prepare();
// process() never allocates, locks or logs. Stereo (2 channels), planar, in place.
#pragma once
#include "Biquad.hpp"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace hs {

inline float dbToLin(float db) { return std::pow(10.f, db / 20.f); }
inline float linToDb(float x) { return 20.f * std::log10(std::max(x, 1e-12f)); }
inline float powToDb(double p) { return float(10.0 * std::log10(std::max(p, 1e-24))); }
/// One-pole coefficient for a time constant in seconds.
inline float onePole(double tau, double fs) { return float(std::exp(-1.0 / (std::max(tau, 1e-6) * fs))); }

/// Rate guard (DESIGN §6): filters designed above 0.45·fs are disabled.
inline bool rateOK(double f, double fs) { return f < 0.45 * fs; }

// ---------------------------------------------------------------------------------------------
struct HighPass {
    Biquad bq;
    double fs = 48000;
    void prepare(double sr) { fs = sr; bq.set(designBiquad(FilterType::HighPass, fs, 80.0, M_SQRT1_2, 0)); bq.active = rateOK(80, fs); bq.reset(); }
    void reset() { bq.reset(); }
    void process(float *L, float *R, int n) { bq.process(L, n, 0); bq.process(R, n, 1); }
};

// ---------------------------------------------------------------------------------------------
/// Corrective/tonal EQ: de-box peak, presence peak, high shelf (= 0.6 × presence gain).
struct ToneEQ {
    Biquad box, presence, shelf;
    double fs = 48000;
    float curBox = NAN, curPres = NAN;

    void prepare(double sr) { fs = sr; curBox = curPres = NAN; reset(); }
    void reset() { box.reset(); presence.reset(); shelf.reset(); }
    /// Called once per block with the current parameter values; recomputes only on change.
    void update(float boxDb, float presDb) {
        if (boxDb != curBox) {
            box.set(designBiquad(FilterType::Peak, fs, 300.0, 1.0, boxDb));
            box.active = rateOK(300, fs);
            curBox = boxDb;
        }
        if (presDb != curPres) {
            presence.set(designBiquad(FilterType::Peak, fs, 3000.0, 1.0, presDb));
            presence.active = rateOK(3000, fs);
            shelf.set(designBiquad(FilterType::HighShelf, fs, 8000.0, 1.0, 0.6 * presDb));
            shelf.active = rateOK(8000, fs);
            curPres = presDb;
        }
    }
    void process(float *L, float *R, int n) {
        box.process(L, n, 0); box.process(R, n, 1);
        presence.process(L, n, 0); presence.process(R, n, 1);
        shelf.process(L, n, 0); shelf.process(R, n, 1);
    }
};

// ---------------------------------------------------------------------------------------------
/// Split-band de-esser (DESIGN §7.3). Detector = band energy (5–8 kHz) relative to full-band
/// energy of the PRE-EQ signal; reduction is applied to the high band (LR4 @ 5 kHz) of the post-EQ
/// signal. Stereo-linked.
struct DeEsser {
    double fs = 48000;
    // crossover (LR4 = two cascaded Butterworth sections)
    Biquad lp1, lp2, hp1, hp2;
    // detector
    Biquad detHP, detLP;
    float envBand = 0, envFull = 0, aAtt = 0, aRel = 0, gAtt = 0, gRel = 0;
    float gainDb = 0;                 // current reduction (≤ 0)
    float thresholdDb = -12, kneeDb = 6, slope = 0.5f, floorDb = -55;
    bool usable = true;
    float lastReductionDb = 0;        // telemetry
    float *bandL = nullptr, *bandR = nullptr, *det = nullptr;

    void prepare(double sr, int maxFrames) {
        fs = sr;
        double fx = 5000, fh = 8000;
        if (!rateOK(fh, fs)) { fh = 0.42 * fs; fx = std::min(fx, 0.3 * fs); }   // move band down at low rates
        usable = rateOK(fx, fs) && fx > 2000;
        const auto lp = designBiquad(FilterType::LowPass, fs, fx, M_SQRT1_2, 0);
        const auto hp = designBiquad(FilterType::HighPass, fs, fx, M_SQRT1_2, 0);
        lp1.set(lp); lp2.set(lp); hp1.set(hp); hp2.set(hp);
        detHP.set(designBiquad(FilterType::HighPass, fs, fx, M_SQRT1_2, 0));
        detLP.set(designBiquad(FilterType::LowPass, fs, fh, M_SQRT1_2, 0));
        aAtt = onePole(0.005, fs);
        aRel = onePole(0.060, fs);
        gAtt = onePole(0.002, fs);
        gRel = onePole(0.040, fs);
        std::free(bandL); std::free(bandR); std::free(det);
        bandL = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
        bandR = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
        det = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
        reset();
    }
    ~DeEsser() { std::free(bandL); std::free(bandR); std::free(det); }
    void reset() {
        lp1.reset(); lp2.reset(); hp1.reset(); hp2.reset(); detHP.reset(); detLP.reset();
        envBand = envFull = 0; gainDb = 0;
    }

    /// Static curve: dB of reduction (≤ 0) for a band-to-full ratio in dB.
    static float curve(float ratioDb, float thr, float knee, float slope, float maxRed) {
        const float over = ratioDb - thr;
        float red;
        if (over <= -knee / 2) red = 0;
        else if (over >= knee / 2) red = slope * over;
        else { const float x = over + knee / 2; red = slope * x * x / (2 * knee); }
        return -std::min(red, maxRed);
    }

    /// preL/preR: detector input (post-HPF, pre-EQ). L/R: post-EQ signal, processed in place.
    void process(const float *preL, const float *preR, float *L, float *R, int n, float maxRedDb) {
        if (!usable) return;
        for (int i = 0; i < n; ++i) det[i] = 0.5f * (preL[i] + preR[i]);
        // detector envelope, per sample
        float minGain = 0;
        for (int i = 0; i < n; ++i) {
            const float full = det[i];
            const float band = detLP.tick(detHP.tick(full, 0), 0);
            const float pb = band * band, pf = full * full;
            envBand = pb > envBand ? aAtt * envBand + (1 - aAtt) * pb : aRel * envBand + (1 - aRel) * pb;
            envFull = pf > envFull ? aAtt * envFull + (1 - aAtt) * pf : aRel * envFull + (1 - aRel) * pf;
            const float bandDb = powToDb(envBand);
            float target = 0;
            if (bandDb > floorDb) target = curve(bandDb - powToDb(envFull), thresholdDb, kneeDb, slope, maxRedDb);
            // gain smoothing in dB (attack 2 ms, release 40 ms)
            const float a = target < gainDb ? gAtt : gRel;
            gainDb = a * gainDb + (1 - a) * target;
            det[i] = gainDb;   // reuse as per-sample gain buffer (dB)
            minGain = std::min(minGain, gainDb);
        }
        lastReductionDb = minGain;
        // split post-EQ signal; out = low + g·high
        std::memcpy(bandL, L, sizeof(float) * size_t(n));
        std::memcpy(bandR, R, sizeof(float) * size_t(n));
        lp1.process(L, n, 0); lp2.process(L, n, 0); lp1.process(R, n, 1); lp2.process(R, n, 1);
        hp1.process(bandL, n, 0); hp2.process(bandL, n, 0); hp1.process(bandR, n, 1); hp2.process(bandR, n, 1);
        for (int i = 0; i < n; ++i) {
            const float g = dbToLin(det[i]);
            // LR4 bands are in phase; the sum is flat with an all-pass phase response.
            L[i] += g * bandL[i];
            R[i] += g * bandR[i];
        }
    }
};

// ---------------------------------------------------------------------------------------------
/// BS.1770 momentary loudness meter: K-weighted, 100 ms blocks, 400 ms momentary value.
struct LoudnessMeter {
    Biquad shelf, rlb;
    int blockLen = 4800, pos = 0;
    double acc = 0, mom[4] = {};
    int momPos = 0;
    void prepare(double fs) {
        BiquadCoeffs s, r; designKWeighting(fs, s, r);
        shelf.set(s); rlb.set(r);
        blockLen = int(fs / 10);
        reset();
    }
    void reset() { shelf.reset(); rlb.reset(); pos = 0; acc = 0; momPos = 0; for (double &m : mom) m = 0; }
    /// Returns true when a 100 ms block completed; then `blockMs` = block mean square (L+R power sum)
    /// and `momLufs` = 400 ms momentary loudness.
    inline bool push(float l, float r, double &blockMs, float &momLufs) {
        const float kl = rlb.tick(shelf.tick(l, 0), 0);
        const float kr = rlb.tick(shelf.tick(r, 1), 1);
        acc += double(kl) * kl + double(kr) * kr;
        if (++pos < blockLen) return false;
        blockMs = acc / blockLen;
        acc = 0; pos = 0;
        mom[momPos] = blockMs; momPos = (momPos + 1) & 3;
        momLufs = -0.691f + powToDb((mom[0] + mom[1] + mom[2] + mom[3]) / 4);
        return true;
    }
};

/// Speech AGC toward a loudness target (DESIGN §7.4, revised after review D-012):
/// FEED-FORWARD — loudness is measured on the input before the AGC gain (no feedback loop, so no
/// limit cycle). ~3 s window over active blocks; relative gate (−10 LU under the slow speech level,
/// floor −60 LUFS); gain frozen during pauses; the gate leaks down after 3 s of pause so a lasting
/// level drop is followed (no latch-up). A slow trim loop (0.9 /s nominal, ≈0.3 /s effective through the compressor, ±4 dB, anti-windup) measured after the
/// compressor removes the compressor's make-up calibration error. ±12 dB, up 1.5 dB/s, down 6 dB/s.
struct Leveler {
    static constexpr int kWindowBlocks = 30;
    LoudnessMeter in, out;
    double win[kWindowBlocks] = {};
    int winCount = 0, winPos = 0;
    float speechLevel = NAN;
    int pauseBlocks = 0, activeRun = 0;
    float gainDb = 0, targetGainDb = 0, trimDb = 0;
    float upPerSample = 0, downPerSample = 0;
    float curLin = 1, curLinDb = 0;
    bool paused = true;
    double fs = 48000;
    int windowBlocks = kWindowBlocks;

    void prepare(double sr) {
        fs = sr;
        in.prepare(fs); out.prepare(fs);
        setStrength(0.f);
        reset();
    }
    /// 0 = gentle (3 s window, up 1.5 / down 6 dB/s) … 1 = tight (1 s window, up 6 / down 10 dB/s).
    /// Called from the audio thread on change (no allocation); restarts the window.
    void setStrength(float s) {
        s = std::clamp(s, 0.f, 1.f);
        windowBlocks = std::max(5, int(std::lround(30 - 20 * s)));
        upPerSample = float((1.5 + 4.5 * s) / fs);
        downPerSample = float((6.0 + 4.0 * s) / fs);
        winCount = 0; winPos = 0;
    }
    void reset() {
        in.reset(); out.reset();
        winCount = winPos = 0; speechLevel = NAN; pauseBlocks = 0; activeRun = 0;
        gainDb = targetGainDb = trimDb = 0; curLin = 1; curLinDb = 0; paused = true;
    }

    void endInputBlock(double blockMs, float momLufs, float targetLufs) {
        const float gate = std::max(-60.f, std::isnan(speechLevel) ? -60.f : speechLevel - 10.f);
        paused = momLufs < gate;
        // The 400 ms momentary value straddles pause edges: also require the 100 ms block itself to
        // be active before it enters the window or the trim (no pumping at pause edges).
        const bool blockActive = -0.691f + powToDb(blockMs) >= gate;
        activeRun = (!paused && blockActive) ? activeRun + 1 : 0;
        if (paused) {
            // Lasting quiet (> 3 s): let the speech level leak down 0.5 dB per block so a real level
            // drop is picked up after a few seconds instead of freezing forever.
            if (++pauseBlocks > 30 && !std::isnan(speechLevel)) speechLevel = std::max(-50.f, speechLevel - 0.5f);
            return;
        }
        pauseBlocks = 0;
        if (!blockActive) return;
        speechLevel = std::isnan(speechLevel) ? momLufs : speechLevel + 0.02f * (momLufs - speechLevel);
        win[winPos] = blockMs; winPos = (winPos + 1) % windowBlocks;
        winCount = std::min(winCount + 1, windowBlocks);
        double sum = 0;
        for (int k = 0; k < winCount; ++k) sum += win[k];
        const float loud = -0.691f + powToDb(sum / winCount);
        targetGainDb = std::clamp(targetLufs - loud + trimDb, -12.f, 12.f);
    }

    /// Measures the input (pre-gain) and applies the AGC gain, in place.
    void applyGain(float *L, float *R, int n, float targetLufs) {
        double blockMs; float mom;
        for (int i = 0; i < n; ++i) {
            if (in.push(L[i], R[i], blockMs, mom)) endInputBlock(blockMs, mom, targetLufs);
            if (!paused && gainDb != targetGainDb) {
                gainDb = gainDb < targetGainDb ? std::min(targetGainDb, gainDb + upPerSample)
                                               : std::max(targetGainDb, gainDb - downPerSample);
            }
            if (gainDb != curLinDb) { curLin = dbToLin(gainDb); curLinDb = gainDb; }
            L[i] *= curLin; R[i] *= curLin;
        }
    }

    /// Slow trim loop on the final (post-compressor) loudness. Frozen during pauses.
    void measureOutput(const float *L, const float *R, int n, float targetLufs) {
        double blockMs; float mom;
        for (int i = 0; i < n; ++i) {
            // Anti-windup: integrate only while the AGC sits at its target (not ramping, not
            // pinned at ±12 dB); otherwise the ramp error itself would wind the trim up.
            // …and only after 4 consecutive active blocks, so the 400 ms output window is all speech.
            const bool settled = std::fabs(gainDb - targetGainDb) < 1.0f && std::fabs(targetGainDb) < 11.9f && activeRun >= 4;
            if (out.push(L[i], R[i], blockMs, mom) && !paused && settled && mom > -70.f) {
                trimDb = std::clamp(trimDb + 0.09f * (targetLufs - mom), -4.f, 4.f);   // 0.9 /s nominal ≈ 0.3 /s through the 3:1 compressor
            }
        }
    }
};

// ---------------------------------------------------------------------------------------------
/// Gentle 3:1 compressor with soft knee and auto make-up (DESIGN §7.4). Stereo-linked RMS.
struct Compressor {
    double fs = 48000;
    float thr = -24, ratio = 3, knee = 6;
    float env = 0, aRms = 0, gainDb = 0, aAtt = 0, aRel = 0, makeup = 0, makeupSmooth = NAN;
    float lastGrDb = 0;

    void prepare(double sr, float referenceDb) {
        fs = sr;
        aRms = onePole(0.010, fs);
        setStrength(0.f);
        makeup = -staticGain(referenceDb);   // restore the level at the reference input level
        reset();
    }
    /// 0 = gentle (3:1, −24 dB, 15/200 ms) … 1 = tight (6:1, −30 dB, 8/150 ms). Make-up is recomputed by the caller.
    void setStrength(float s) {
        s = std::clamp(s, 0.f, 1.f);
        ratio = 3.f + 3.f * s;
        thr = -24.f - 6.f * s;
        aAtt = onePole(0.015 - 0.007 * s, fs);
        aRel = onePole(0.200 - 0.050 * s, fs);
    }
    void reset() { env = 0; gainDb = 0; }
    float staticGain(float inDb) const {
        const float over = inDb - thr;
        if (over <= -knee / 2) return 0;
        if (over >= knee / 2) return -over * (1 - 1 / ratio);
        const float x = over + knee / 2;
        return -(1 - 1 / ratio) * x * x / (2 * knee);
    }
    void process(float *L, float *R, int n) {
        float minGr = 0;
        for (int i = 0; i < n; ++i) {
            const float p = 0.5f * (L[i] * L[i] + R[i] * R[i]);
            env = aRms * env + (1 - aRms) * p;
            const float target = staticGain(powToDb(env));
            const float a = target < gainDb ? aAtt : aRel;
            gainDb = a * gainDb + (1 - a) * target;
            if (std::isnan(makeupSmooth)) makeupSmooth = makeup;
            minGr = std::min(minGr, gainDb);
            // make-up follows changes smoothly (a strength change moves it by ~5 dB)
            makeupSmooth += 0.0005f * (makeup - makeupSmooth);
            const float g = dbToLin(gainDb + makeupSmooth);
            L[i] *= g; R[i] *= g;
        }
        lastGrDb = minGr;
    }
};

// ---------------------------------------------------------------------------------------------
/// Look-ahead peak limiter (DESIGN §7.4, revised D-012). Required gain → sliding-window minimum over
/// la+1 samples (monotonic deque) → box average over la+1 samples. Every window averaged at output
/// time contains the delayed sample, so the gain is ≤ its requirement by construction: smooth attack,
/// no clipping. Release: one-pole 50 ms. Stereo-linked. A final clamp only catches float rounding.
/// When `limitOn` is false the stage is a pure delay (constant chain latency, D-012).
struct Limiter {
    double fs = 48000;
    int la = 72;
    float ceiling = 0.8912509f;   // −1 dBFS
    float *dl = nullptr, *dr = nullptr;     // delay lines (la + 1)
    float *gq = nullptr; long long *iq = nullptr;   // deque, capacity la + 3
    double *box = nullptr; double boxSum = 0; // box filter of the held minimum (la + 1)
    int head = 0, tail = 0, cap = 0, boxPos = 0, wpos = 0;
    long long idx = 0;
    float g = 1, aRel = 0, lastGrDb = 0, onMix = 0, onStep = 0;
    unsigned long long clipped = 0;   // samples the final clamp had to change (should stay 0)

    void prepare(double sr) {
        fs = sr;
        la = std::max(1, int(std::lround(0.0015 * fs)));
        std::free(dl); std::free(dr); std::free(gq); std::free(iq); std::free(box);
        dl = static_cast<float *>(std::calloc(size_t(la + 1), sizeof(float)));
        dr = static_cast<float *>(std::calloc(size_t(la + 1), sizeof(float)));
        cap = la + 3;
        gq = static_cast<float *>(std::calloc(size_t(cap), sizeof(float)));
        iq = static_cast<long long *>(std::calloc(size_t(cap), sizeof(long long)));
        box = static_cast<double *>(std::calloc(size_t(la + 1), sizeof(double)));
        aRel = onePole(0.050, fs);
        onStep = float(1.0 / (0.010 * fs));
        reset();
    }
    ~Limiter() { std::free(dl); std::free(dr); std::free(gq); std::free(iq); std::free(box); }
    void reset() {
        if (dl) std::memset(dl, 0, sizeof(float) * size_t(la + 1));
        if (dr) std::memset(dr, 0, sizeof(float) * size_t(la + 1));
        if (box) for (int k = 0; k <= la; ++k) box[k] = 1.0;
        boxSum = la + 1; boxPos = 0;
        head = tail = 0; idx = 0; wpos = 0; g = 1;
    }
    int latency() const { return la; }

    void process(float *L, float *R, int n, bool limitOn) {
        float minG = 1;
        for (int i = 0; i < n; ++i) {
            const float peak = std::max(std::fabs(L[i]), std::fabs(R[i]));
            // Requirement is always computed (warm history even while off), so switching on finds
            // the right gain for the samples already in the delay line.
            const float req = peak > ceiling ? ceiling / peak : 1.f;
            // evict old entries first (window = [idx − la, idx]), then push → at most la + 1 entries
            while (head != tail && iq[head] < idx - la) head = (head + 1) % cap;
            while (head != tail) {
                const int last = (tail - 1 + cap) % cap;
                if (gq[last] >= req) tail = last; else break;
            }
            gq[tail] = req; iq[tail] = idx; tail = (tail + 1) % cap;
            const double held = gq[head];
            boxSum += held - box[boxPos]; box[boxPos] = held; boxPos = (boxPos + 1) % (la + 1);
            const float avg = float(boxSum / (la + 1));
            g = avg < g ? avg : aRel * g + (1 - aRel) * avg;   // attack exact (≤ requirement), release smooth
            minG = std::min(minG, 1.f + onMix * (g - 1.f));
            dl[wpos] = L[i]; dr[wpos] = R[i];
            const int rpos = (wpos + 1) % (la + 1);
            // Toggling blends the gain in/out over 10 ms (no click); the clamp acts only when fully on.
            onMix = limitOn ? std::min(1.f, onMix + onStep) : std::max(0.f, onMix - onStep);
            const float ge = 1.f + onMix * (g - 1.f);
            float yl = dl[rpos] * ge, yr = dr[rpos] * ge;
            wpos = rpos;
            if (onMix >= 1.f) {
                const float cl = std::clamp(yl, -ceiling, ceiling), cr = std::clamp(yr, -ceiling, ceiling);
                if (std::fabs(cl - yl) > 1e-6f * ceiling || std::fabs(cr - yr) > 1e-6f * ceiling) ++clipped;
                yl = cl; yr = cr;
            }
            L[i] = yl; R[i] = yr;
            ++idx;
        }
        // keep the running sum exact over long runs
        if ((idx & 0xFFFF) < n) { boxSum = 0; for (int k = 0; k <= la; ++k) boxSum += box[k]; }
        lastGrDb = linToDb(minG);
    }
};

} // namespace hs
