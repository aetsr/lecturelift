// Synthetic room impulse responses (DESIGN §7.6). Runs on a control thread (allocates).
// Early reflections: shoebox image-source model up to order 3, two ear positions for L/R.
// Late tail: independent noise per ear, split into 8 octave bands with equal energy (pink),
// each band decaying with its own RT60 (HF damping), faded in around the mixing time.
// Time zero = arrival of the direct sound; the direct sound itself is not included (dry path).
#include "HSCore.h"
#include "../DSP/Biquad.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {

struct Room { double lx, ly, lz, rt60, srcDist; };
constexpr Room kRooms[3] = {
    {8, 6, 3, 0.5, 3},        // seminar room
    {20, 15, 6, 1.0, 7},      // lecture hall
    {35, 25, 10, 1.6, 12},    // auditorium
};
constexpr double kC = 343.0;

struct Rng {   // xorshift64* + Box–Muller, deterministic
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed ? seed : 0x9E3779B97F4A7C15ull) {}
    double uni() { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return double((s * 2685821657736338717ull) >> 11) * (1.0 / 9007199254740992.0); }
    double gauss() { double u = std::max(uni(), 1e-300), v = uni(); return std::sqrt(-2 * std::log(u)) * std::cos(2 * M_PI * v); }
};

double bandRT(double rt60, double fc, double damping) {
    // Above 1 kHz the decay shortens with frequency (air + wall absorption); damping 0…1.
    return fc <= 1000 ? rt60 : rt60 * std::pow(1000.0 / fc, 0.6 * damping);
}

int irLength(const Room &r, double fs) { return int(std::ceil((1.2 * r.rt60 + 0.15) * fs)); }

void filterInPlace(std::vector<double> &x, const hs::BiquadCoeffs &c) {
    double z1 = 0, z2 = 0;
    for (double &v : x) {
        const double in = v, out = c.b0 * in + z1;
        z1 = c.b1 * in - c.a1 * out + z2;
        z2 = c.b2 * in - c.a2 * out;
        v = out;
    }
}

void generate(const Room &room, double damping, double fs, uint64_t seed, std::vector<float> &outL, std::vector<float> &outR) {
    const int n = irLength(room, fs);
    const double V = room.lx * room.ly * room.lz;
    const double S = 2 * (room.lx * room.ly + room.lx * room.lz + room.ly * room.lz);
    const double alpha = std::clamp(0.161 * V / (S * room.rt60), 0.02, 0.95);   // Sabine
    const double beta = std::sqrt(1 - alpha);
    const double tMix = std::sqrt(V) * 1e-3;                                      // s
    // Source at the front, centred; listener srcDist behind it; ears ±9 cm.
    const double src[3] = {room.lx / 2, 1.5, 1.6};
    const double lis[2][3] = {{room.lx / 2 - 0.09, std::min(1.5 + room.srcDist, room.ly - 1.0), 1.2},
                              {room.lx / 2 + 0.09, std::min(1.5 + room.srcDist, room.ly - 1.0), 1.2}};
    const double dDirect = std::hypot(std::hypot(src[0] - lis[0][0], src[1] - lis[0][1]), src[2] - lis[0][2]);

    std::vector<double> ear[2] = {std::vector<double>(size_t(n), 0.0), std::vector<double>(size_t(n), 0.0)};
    // ---- early reflections, per order (higher orders duller) ----
    const double orderLP[4] = {0, 9000, 6000, 4000};
    for (int e = 0; e < 2; ++e) {
        Rng jrng(seed ^ 0xA5A5A5A5u);   // same jitter per image for both ears: no false ITD
        std::vector<double> ord[4];
        for (auto &o : ord) o.assign(size_t(n), 0.0);
        for (int i = -3; i <= 3; ++i)
            for (int j = -3; j <= 3; ++j)
                for (int k = -3; k <= 3; ++k) {
                    const int order = std::abs(i) + std::abs(j) + std::abs(k);
                    if (order == 0 || order > 3) continue;
                    // image position: mirror the source across walls
                    auto img = [](int m, double s, double L) { return m % 2 == 0 ? m * L + s : (m + 1) * L - s; };
                    const double ix = img(i, src[0], room.lx), iy = img(j, src[1], room.ly), iz = img(k, src[2], room.lz);
                    const double d = std::hypot(std::hypot(ix - lis[e][0], iy - lis[e][1]), iz - lis[e][2]);
                    // ±0.3 ms jitter per image breaks the periodic, metallic pattern of a perfect shoebox
                    const double jitter = (jrng.uni() - 0.5) * 0.6e-3;
                    const double t = (d - dDirect) / kC + jitter;
                    const int idx = int(std::lround(t * fs));
                    if (idx < 1 || idx >= n) continue;
                    ord[order][size_t(idx)] += std::pow(beta, order) * dDirect / d;
                }
        for (int o = 1; o <= 3; ++o) {
            filterInPlace(ord[o], hs::designBiquad(hs::FilterType::LowPass, fs, std::min(orderLP[o], 0.45 * fs), M_SQRT1_2, 0));
            for (int s = 0; s < n; ++s) ear[e][size_t(s)] += ord[o][size_t(s)];
        }
    }
    // ER energy in the window just before the mixing time → tail level continuity.
    const int mixIdx = std::max(2, int(tMix * fs));
    double erEnergy = 0;
    // The diffuse tail fades in from the first reflection (not only near t_mix), so large rooms
    // don't sound like sparse discrete echoes before the mixing time.
    int firstRefl = mixIdx / 2;
    for (int s = 1; s < mixIdx; ++s) if (ear[0][size_t(s)] != 0.0 || ear[1][size_t(s)] != 0.0) { firstRefl = s; break; }
    const int w0 = std::min(firstRefl, mixIdx - 1);
    for (int e = 0; e < 2; ++e) for (int s = w0; s < mixIdx; ++s) erEnergy += ear[e][size_t(s)] * ear[e][size_t(s)];
    const double erRate = erEnergy / (2.0 * std::max(1, mixIdx - w0));   // per sample, per ear

    // ---- late tail ----
    const double centres[8] = {63, 125, 250, 500, 1000, 2000, 4000, 8000};
    Rng rng(seed);
    for (int e = 0; e < 2; ++e) {
        std::vector<double> tail(size_t(n), 0.0);
        for (int b = 0; b < 8; ++b) {
            const double fc = centres[b];
            if (fc / M_SQRT2 >= 0.45 * fs) break;
            std::vector<double> x(static_cast<size_t>(n));
            for (double &v : x) v = rng.gauss();
            const double lo = fc / M_SQRT2, hi = fc * M_SQRT2;
            if (b > 0) { auto c = hs::designBiquad(hs::FilterType::HighPass, fs, lo, M_SQRT1_2, 0); filterInPlace(x, c); filterInPlace(x, c); }
            if (b < 7 && hi < 0.45 * fs) { auto c = hs::designBiquad(hs::FilterType::LowPass, fs, hi, M_SQRT1_2, 0); filterInPlace(x, c); filterInPlace(x, c); }
            double en = 0;
            for (double v : x) en += v * v;
            const double norm = 1.0 / std::sqrt(en / n);            // equal energy per band (pink)
            const double k = 6.907755278982137 / bandRT(room.rt60, fc, damping);   // ln(1000) / RT
            for (int s = 0; s < n; ++s) tail[size_t(s)] += x[size_t(s)] * norm * std::exp(-k * s / fs);
        }
        // fade the tail in from the first reflection (w0) to tMix (raised cosine)
        for (int s = 0; s < n; ++s) {
            double w = s < w0 ? 0.0 : (s >= mixIdx ? 1.0 : 0.5 - 0.5 * std::cos(M_PI * (s - w0) / double(mixIdx - w0)));
            tail[size_t(s)] *= w;
        }
        // scale so the tail's energy rate at the mixing time matches the early reflections
        double tr = 0;
        const int a = mixIdx, bEnd = std::min(n, mixIdx + std::max(1, mixIdx / 2));
        for (int s = a; s < bEnd; ++s) tr += tail[size_t(s)] * tail[size_t(s)];
        tr /= std::max(1, bEnd - a);
        const double g = tr > 0 ? std::sqrt(std::max(erRate, 1e-12) / tr) : 0;
        for (int s = 0; s < n; ++s) ear[e][size_t(s)] += g * tail[size_t(s)];
    }
    // ---- 100 Hz high-pass (2nd order) removes DC and rumble from the tail ----
    for (int e = 0; e < 2; ++e) filterInPlace(ear[e], hs::designBiquad(hs::FilterType::HighPass, fs, 100.0, M_SQRT1_2, 0));
    // ---- normalise: unit energy (mean over both ears) ----
    double tot = 0;
    for (int e = 0; e < 2; ++e) for (double v : ear[e]) tot += v * v;
    const double gn = tot > 0 ? 1.0 / std::sqrt(tot / 2) : 0;
    outL.resize(size_t(n)); outR.resize(size_t(n));
    for (int s = 0; s < n; ++s) { outL[size_t(s)] = float(ear[0][size_t(s)] * gn); outR[size_t(s)] = float(ear[1][size_t(s)] * gn); }
}

} // namespace

extern "C" {

int hs_ir_length(int room, double fs) {
    if (room < 0 || room > 2) return 0;
    return irLength(kRooms[room], fs);
}

int hs_ir_generate(int room, float damping, double fs, uint64_t seed, float *outL, float *outR, int capacity) {
    if (room < 0 || room > 2 || !outL || !outR) return 0;
    std::vector<float> l, r;
    generate(kRooms[room], std::clamp(double(damping), 0.0, 1.0), fs, seed, l, r);
    const int n = std::min(capacity, int(l.size()));
    std::copy(l.begin(), l.begin() + n, outL);
    std::copy(r.begin(), r.begin() + n, outR);
    return n;
}

float hs_ir_target_rt60(int room) { return (room >= 0 && room <= 2) ? float(kRooms[room].rt60) : 0.f; }

} // extern "C"
