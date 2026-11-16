// Neural speech enhancement (DESIGN §8, D-003/D-005/D-013/D-014/D-016/D-017). DeepFilterNet3 via the
// libDF C API (DeepFilterNet Plus + patches), loaded at runtime with dlopen so the package builds
// without Rust. libDF allocates per frame, so it never runs on the I/O thread: a worker thread with a
// Mach time-constraint policy (joined to the device's IOThread workgroup) processes 480-sample hops
// from an SPSC input ring into an SPSC output ring. The I/O thread reads the output with a fixed
// latency and falls back to an equally delayed copy of its input on underflow (no silence, no jump).
#pragma once
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <os/workgroup.h>
#include <pthread.h>
#include <mach/mach.h>

namespace hs {

/// Single-producer / single-consumer float ring; capacity is a power of two.
struct FloatRing {
    float *buf = nullptr;
    int64_t cap = 0, mask = 0;
    alignas(64) std::atomic<int64_t> w{0};
    alignas(64) std::atomic<int64_t> r{0};
    bool init(int64_t minCap) {
        cap = 1; while (cap < minCap) cap <<= 1;
        mask = cap - 1;
        buf = static_cast<float *>(std::malloc(size_t(cap) * sizeof(float)));
        if (buf) std::memset(buf, 0, size_t(cap) * sizeof(float));   // pre-touch
        return buf != nullptr;
    }
    ~FloatRing() { std::free(buf); }
    int64_t available() const { return w.load(std::memory_order_acquire) - r.load(std::memory_order_acquire); }
    int64_t write(const float *x, int64_t n) {   // producer; x == nullptr writes zeros
        const int64_t wi = w.load(std::memory_order_relaxed);
        const int64_t room = cap - (wi - r.load(std::memory_order_acquire));
        const int64_t k = n < room ? n : room;
        for (int64_t i = 0; i < k; ++i) buf[(wi + i) & mask] = x ? x[i] : 0.f;
        w.store(wi + k, std::memory_order_release);
        return k;
    }
    int64_t read(float *y, int64_t n) {          // consumer; y == nullptr discards
        const int64_t ri = r.load(std::memory_order_relaxed);
        const int64_t a = w.load(std::memory_order_acquire) - ri;
        const int64_t k = n < a ? n : a;
        if (y) for (int64_t i = 0; i < k; ++i) y[i] = buf[(ri + i) & mask];
        r.store(ri + k, std::memory_order_release);
        return k;
    }
};

/// Denoiser counters owned by the engine (outlive any DenoiserRT; read by the watchdog/UI).
struct DenoiserStats {
    std::atomic<uint64_t> hops{0}, hopNsTotal{0}, hopNsMax{0}, errors{0}, underflows{0}, dropped{0}, skipped{0};
    std::atomic<int> failed{0};
    void reset() {
        hops = 0; hopNsTotal = 0; hopNsMax = 0; errors = 0; underflows = 0; dropped = 0; skipped = 0; failed = 0;
    }
};

struct DFApi;   // dlopen'ed function table (Denoiser.cpp)

/// Everything the I/O thread and the worker share for one loaded denoiser. Created on a control
/// thread; its worker is stopped/joined on unload; the object itself is freed only once the I/O
/// thread provably no longer uses it (D-017).
struct DenoiserRT {
    static constexpr int kHop = 480;           // 10 ms at 48 kHz
    // ---- shared ----
    FloatRing in, out;
    semaphore_t sem = MACH_PORT_NULL;
    std::atomic<bool> stop{false};
    std::atomic<bool> paused{false};           // test hook: simulate a worker that falls behind
    std::atomic<bool> failNext{false};         // test hook: simulate a libDF error
    std::atomic<float> attenDb{8.f};
    std::atomic<os_workgroup_t> pendingWg{nullptr};   // control → worker (+1 reference, owned)
    std::atomic<int64_t> droppedPending{0};    // input samples the I/O side could not queue
    std::atomic<bool> failed{false};           // libDF error latched: stay on the delayed fallback
    DenoiserStats *stats = nullptr;            // engine-owned
    bool synchronous = false;                  // offline: the I/O-side caller runs the hops itself
    // ---- worker-owned ----
    void *df = nullptr;                        // DFState*
    const DFApi *api = nullptr;
    float curAtten = -1.f;
    float hopIn[kHop] = {}, hopOut[kHop] = {};
    pthread_t thread{};
    bool threadStarted = false;
    os_workgroup_t joined = nullptr;
    os_workgroup_join_token_s joinToken{};
    double ticksPerNs = 1.0;
    // ---- I/O-thread-owned ----
    int latency = 0;                           // samples: prefill + algorithmic
    int prefill = 0;
    float *delay = nullptr; int delayLen = 0, delayPos = 0;   // fallback copy of the input, same latency
    float *mono = nullptr, *dn = nullptr, *dly = nullptr;
    int64_t debt = 0;                          // output samples to discard after an underflow
    int64_t fed = 0;                           // samples fed since load (ramp-in only after `latency`)
    float fb = 1.f, fbStep = 0.f;              // fallback crossfade (0 = denoised, 1 = delayed input)
    int healthy = 0;                           // consecutive healthy samples since the last underflow

    /// One hop if available (worker, or the I/O side in synchronous mode).
    bool step();
    /// Stops and joins the worker (control thread). Idempotent.
    void stopWorker();
    ~DenoiserRT();
};

} // namespace hs
