// DeepFilterNet3 denoiser: dlopen'ed libDF, worker thread, fixed-latency hand-off (see Denoiser.hpp).
#include "Denoiser.hpp"
#include "HSCore.h"
#include "../../../vendor/libdf/include/hs_libdf.h"

#include <cmath>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <new>

namespace hs {

struct DFApi {
    hs_df_create_fn create = nullptr;
    hs_df_process_frame_fn process = nullptr;
    df_get_frame_length_fn frameLength = nullptr;
    df_set_atten_lim_fn setAtten = nullptr;
    df_free_fn free = nullptr;
};

static DFApi gApi;
static std::atomic<bool> gApiLoaded{false};

static inline void setFTZWorker() {
#if defined(__aarch64__)
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1ULL << 24);
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
#endif
}

bool DenoiserRT::step() {
    // Input the I/O side could not queue (ring full during a stall): emit the same number of output
    // samples as zeros so the output count stays aligned with the I/O side's count (D-017).
    if (int64_t drop = droppedPending.exchange(0, std::memory_order_acq_rel); drop > 0) {
        const int64_t k = out.write(nullptr, drop);
        if (k < drop) droppedPending.fetch_add(drop - k, std::memory_order_acq_rel);
        stats->dropped.fetch_add(uint64_t(k), std::memory_order_relaxed);
    }
    if (in.available() < kHop) return false;
    // Never write a partial hop: if the output ring has no room (catch-up burst after a stall while the
    // I/O side is still discarding its debt), wait. A partial write would lose samples for good and
    // leave the output stream permanently behind (found by testLongStallRecovers, D-025).
    if (out.cap - out.available() < kHop) return false;
    // Backlog older than the prefill is already too late (the I/O side discards it): skip DFN for
    // it so a catch-up after a stall is cheap and does not burn real-time budget.
    const bool stale = in.available() > prefill;
    in.read(hopIn, kHop);
    if (stale || failed.load(std::memory_order_relaxed)) {
        out.write(nullptr, kHop);
        stats->skipped.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    float a = attenDb.load(std::memory_order_relaxed);
    a = a < 1.f ? 1.f : a;   // libDF's 0 dB shortcut skips the 30 ms delay (D-016)
    if (a != curAtten) { api->setAtten(static_cast<DFState *>(df), a); curAtten = a; }
    const uint64_t t0 = mach_absolute_time();
    const float snr = failNext.exchange(false) ? NAN : api->process(static_cast<DFState *>(df), hopIn, hopOut);
    const uint64_t ns = uint64_t(double(mach_absolute_time() - t0) / ticksPerNs);
    if (std::isnan(snr)) {
        // libDF pops its rolling buffers before fallible code: after one error every later hop
        // fails too. Latch: no more libDF calls; the I/O side stays on the delayed fallback until
        // the control thread reloads the denoiser.
        failed.store(true, std::memory_order_release);
        stats->failed.store(1, std::memory_order_relaxed);
        stats->errors.fetch_add(1, std::memory_order_relaxed);
        out.write(nullptr, kHop);
        return true;
    }
    for (float &v : hopOut) if (!std::isfinite(v)) v = 0.f;
    out.write(hopOut, kHop);
    stats->hops.fetch_add(1, std::memory_order_relaxed);
    stats->hopNsTotal.fetch_add(ns, std::memory_order_relaxed);
    uint64_t prev = stats->hopNsMax.load(std::memory_order_relaxed);
    while (ns > prev && !stats->hopNsMax.compare_exchange_weak(prev, ns, std::memory_order_relaxed)) {}
    return true;
}

static void leaveWorkgroup(DenoiserRT *d) {
    if (!d->joined) return;
    os_workgroup_leave(d->joined, &d->joinToken);
    os_release(d->joined);
    d->joined = nullptr;
}

static void *workerMain(void *arg) {
    auto *d = static_cast<DenoiserRT *>(arg);
    pthread_setname_np("io.github.aetsr.lecturelift.denoiser");
    setFTZWorker();
    {   // Mach time-constraint policy: period one hop, computation ~3 ms, constraint one hop.
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        const double nsToAbs = double(tb.denom) / double(tb.numer);
        thread_time_constraint_policy_data_t pol;
        pol.period = uint32_t(10e6 * nsToAbs);
        pol.computation = uint32_t(3e6 * nsToAbs);
        pol.constraint = uint32_t(10e6 * nsToAbs);
        pol.preemptible = 1;
        thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                          thread_policy_t(&pol), THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    }
    while (!d->stop.load(std::memory_order_acquire)) {
        // (Re-)join the device's IOThread workgroup from this thread (os_workgroup_join must be called
        // by the joining thread). We own one reference per workgroup and release it after leaving.
        if (os_workgroup_t wg = d->pendingWg.exchange(nullptr, std::memory_order_acq_rel)) {
            leaveWorkgroup(d);
            if (os_workgroup_join(wg, &d->joinToken) == 0) d->joined = wg; else os_release(wg);
        }
        mach_timespec_t to{0, 50 * 1000 * 1000};
        semaphore_timedwait(d->sem, to);
        if (!d->paused.load(std::memory_order_acquire)) { while (d->step()) {} }
    }
    leaveWorkgroup(d);
    return nullptr;
}

void DenoiserRT::stopWorker() {
    if (!threadStarted) return;
    stop.store(true, std::memory_order_release);
    semaphore_signal(sem);
    pthread_join(thread, nullptr);
    threadStarted = false;
}

DenoiserRT::~DenoiserRT() {
    stopWorker();
    if (os_workgroup_t wg = pendingWg.exchange(nullptr)) os_release(wg);
    if (df && api) api->free(static_cast<DFState *>(df));
    if (sem != MACH_PORT_NULL) semaphore_destroy(mach_task_self(), sem);
    std::free(delay); std::free(mono); std::free(dn); std::free(dly);
}

} // namespace hs

extern "C" {

int hs_denoiser_library_load(const char *dylibPath) {
    if (hs::gApiLoaded.load()) return 0;
    void *h = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL);
    if (!h) return -1;
    hs::DFApi api;
    api.create = reinterpret_cast<hs_df_create_fn>(dlsym(h, "hs_df_create"));
    api.process = reinterpret_cast<hs_df_process_frame_fn>(dlsym(h, "hs_df_process_frame"));
    api.frameLength = reinterpret_cast<df_get_frame_length_fn>(dlsym(h, "df_get_frame_length"));
    api.setAtten = reinterpret_cast<df_set_atten_lim_fn>(dlsym(h, "df_set_atten_lim"));
    api.free = reinterpret_cast<df_free_fn>(dlsym(h, "df_free"));
    if (!api.create || !api.process || !api.frameLength || !api.setAtten || !api.free) { dlclose(h); return -2; }
    hs::gApi = api;   // the handle is kept for the process lifetime
    hs::gApiLoaded.store(true);
    return 0;
}

int hs_denoiser_library_loaded(void) { return hs::gApiLoaded.load() ? 1 : 0; }

} // extern "C"

// Engine-facing helpers (used by RenderCore.cpp)
namespace hs {

DenoiserRT *createDenoiser(double sampleRate, int maxFrames, int ioBufferFrames, const char *modelPath,
                           float attenDb, bool synchronous, DenoiserStats *stats, int *err) {
    *err = 0;
    if (!gApiLoaded.load()) { *err = -1; return nullptr; }
    if (sampleRate != 48000.0) { *err = -3; return nullptr; }   // D-016: Qualität at 48 kHz only (for now)
    auto *d = new (std::nothrow) DenoiserRT();
    if (!d) { *err = -2; return nullptr; }
    d->api = &gApi;
    d->stats = stats;
    stats->reset();
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    d->ticksPerNs = double(tb.denom) / double(tb.numer);
    d->df = gApi.create(modelPath, attenDb, -15.f, 35.f, 35.f);
    if (!d->df || gApi.frameLength(static_cast<DFState *>(d->df)) != size_t(DenoiserRT::kHop)) { *err = -2; delete d; return nullptr; }
    d->attenDb.store(attenDb);
    d->synchronous = synchronous;
    if (!d->in.init(1 << 14) || !d->out.init(1 << 14)) { *err = -2; delete d; return nullptr; }
    // Fixed latency: prefill = hop + I/O buffer + 15 ms margin (DESIGN §9.1), + DFN3's 1440 samples.
    d->prefill = DenoiserRT::kHop + ioBufferFrames + 720;
    d->latency = d->prefill + 1440;
    {
        float z[1024] = {};
        for (int left = d->prefill; left > 0; left -= 1024) d->out.write(z, left < 1024 ? left : 1024);
    }
    d->delayLen = d->latency;
    d->delay = static_cast<float *>(std::calloc(size_t(d->delayLen), sizeof(float)));
    d->mono = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    d->dn = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    d->dly = static_cast<float *>(std::calloc(size_t(maxFrames), sizeof(float)));
    if (!d->delay || !d->mono || !d->dn || !d->dly) { *err = -2; delete d; return nullptr; }
    d->fbStep = float(1.0 / (0.005 * sampleRate));
    d->healthy = 0;
    d->fb = 1.f;
    if (semaphore_create(mach_task_self(), &d->sem, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) { *err = -2; delete d; return nullptr; }
    if (!synchronous) {
        if (pthread_create(&d->thread, nullptr, workerMain, d) != 0) { *err = -2; delete d; return nullptr; }
        d->threadStarted = true;
    }
    return d;
}

/// I/O thread: denoise the mono mid of L/R in place (both channels get the result), with a fixed
/// latency and a delay-line fallback on underflow. Runs whenever a denoiser is loaded (rings and the
/// delay line stay current, so re-enabling never replays stale audio); `mix` ramps in only after one
/// full latency of real input has been fed (no ramp onto the zero prefill) (D-017).
void processDenoiser(DenoiserRT *d, float *L, float *R, int n, double fs, bool on, float &mix, float mixStep) {
    for (int i = 0; i < n; ++i) d->mono[i] = 0.5f * (L[i] + R[i]);
    for (int i = 0; i < n; ++i) {   // equally delayed copy of the input (fallback)
        d->dly[i] = d->delay[d->delayPos];
        d->delay[d->delayPos] = d->mono[i];
        if (++d->delayPos == d->delayLen) d->delayPos = 0;
    }
    const int64_t queued = d->in.write(d->mono, n);
    if (queued < n) d->droppedPending.fetch_add(n - queued, std::memory_order_acq_rel);
    d->fed += n;
    if (d->synchronous) { while (d->step()) {} }
    else if (d->in.available() >= DenoiserRT::kHop) { semaphore_signal(d->sem); }

    if (d->debt > 0) {   // output that arrives late for an earlier block: discard to stay aligned
        const int64_t a = d->out.available();
        d->debt -= d->out.read(nullptr, d->debt < a ? d->debt : a);
    }
    bool under = false;
    if (d->debt == 0 && d->out.available() >= n) {
        d->out.read(d->dn, n);
    } else {
        const int64_t k = d->debt == 0 ? d->out.read(d->dn, n) : 0;
        for (int64_t i = k; i < n; ++i) d->dn[i] = d->dly[i];
        d->debt += n - k;
        under = true;
        d->stats->underflows.fetch_add(1, std::memory_order_relaxed);
    }
    d->healthy = under ? 0 : (d->healthy + n > (1 << 30) ? (1 << 30) : d->healthy + n);
    const bool failed = d->failed.load(std::memory_order_acquire);
    const float fbTarget = (failed || d->healthy < int(0.050 * fs)) ? 1.f : 0.f;
    const float target = (on && d->fed >= d->latency) ? 1.f : 0.f;
    for (int i = 0; i < n; ++i) {
        d->fb = fbTarget > d->fb ? std::fmin(fbTarget, d->fb + d->fbStep) : std::fmax(fbTarget, d->fb - d->fbStep);
        float v = (1.f - d->fb) * d->dn[i] + d->fb * d->dly[i];
        if (!std::isfinite(v)) v = 0.f;
        mix = target > mix ? std::fmin(target, mix + mixStep) : std::fmax(target, mix - mixStep);
        if (mix > 0.f) {
            L[i] = (1.f - mix) * L[i] + mix * v;
            R[i] = (1.f - mix) * R[i] + mix * v;
        }
    }
}

} // namespace hs
