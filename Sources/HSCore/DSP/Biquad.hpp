// Biquad design (RBJ Audio EQ Cookbook, double precision) and an RT-safe transposed
// direct-form-II processor. Header-only, no allocation.
#pragma once
#include <cmath>

namespace hs {

struct BiquadCoeffs {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;   // normalised (a0 = 1)
    static BiquadCoeffs identity() { return {}; }
};

enum class FilterType { LowPass, HighPass, BandPass, Peak, LowShelf, HighShelf };

/// RBJ cookbook. For shelves `q` is the shelf slope S (1 = steepest without overshoot).
inline BiquadCoeffs designBiquad(FilterType t, double fs, double f0, double q, double gainDb) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * M_PI * f0 / fs;
    const double cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (t) {
    case FilterType::LowPass:
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case FilterType::HighPass:
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case FilterType::BandPass:   // constant 0 dB peak gain
        b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case FilterType::Peak:
        b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
    case FilterType::LowShelf:
    case FilterType::HighShelf: {
        alpha = sw / 2.0 * std::sqrt((A + 1 / A) * (1 / q - 1) + 2);
        const double s = 2 * std::sqrt(A) * alpha;
        if (t == FilterType::LowShelf) {
            b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s);
            a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s;
        } else {
            b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s);
            a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s;
        }
        break;
    }
    }
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

/// One biquad section with per-channel state (max 2 channels). Coefficients are swapped by value
/// (POD) on the audio thread; state is kept, which is click-free enough for ≤30 updates/s.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1[2] = {0, 0}, z2[2] = {0, 0};
    bool active = true;   // false = identity (e.g. design frequency above 0.45·fs)

    void set(const BiquadCoeffs &c) {
        b0 = float(c.b0); b1 = float(c.b1); b2 = float(c.b2); a1 = float(c.a1); a2 = float(c.a2);
    }
    void reset() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }

    inline void process(float *x, int n, int ch) {
        if (!active) return;
        float s1 = z1[ch], s2 = z2[ch];
        for (int i = 0; i < n; ++i) {
            const float in = x[i];
            const float out = b0 * in + s1;
            s1 = b1 * in - a1 * out + s2;
            s2 = b2 * in - a2 * out;
            x[i] = out;
        }
        // Flush denormals in the state.
        z1[ch] = std::fabs(s1) < 1e-25f ? 0.f : s1;
        z2[ch] = std::fabs(s2) < 1e-25f ? 0.f : s2;
    }
    inline float tick(float in, int ch) {
        const float out = b0 * in + z1[ch];
        z1[ch] = b1 * in - a1 * out + z2[ch];
        z2[ch] = b2 * in - a2 * out;
        return out;
    }
};

/// BS.1770 K-weighting designed for any sample rate (stage 1: high shelf, stage 2: RLB high-pass),
/// using the analogue prototype parameters that reproduce the published 48 kHz coefficients.
inline void designKWeighting(double fs, BiquadCoeffs &shelf, BiquadCoeffs &rlb) {
    {   // pre-filter (high shelf)
        const double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
        const double K = std::tan(M_PI * f0 / fs), Vh = std::pow(10.0, G / 20.0), Vb = std::pow(Vh, 0.4996667741545416);
        const double a0 = 1.0 + K / Q + K * K;
        shelf = {(Vh + Vb * K / Q + K * K) / a0, 2.0 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
                 2.0 * (K * K - 1.0) / a0, (1.0 - K / Q + K * K) / a0};
    }
    {   // RLB high-pass
        const double f0 = 38.13547087602444, Q = 0.5003270373238773;
        const double K = std::tan(M_PI * f0 / fs);
        const double a0 = 1.0 + K / Q + K * K;
        rlb = {1.0, -2.0, 1.0, 2.0 * (K * K - 1.0) / a0, (1.0 - K / Q + K * K) / a0};
    }
}

} // namespace hs
