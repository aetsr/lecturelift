// HSCore — real-time render core of LectureLift (C API).
// Rules for everything behind this header: no allocation, locks, logging, ObjC or Swift on the
// audio thread. Allocation happens only in hs_engine_create / hs_engine_prepare.
#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <os/workgroup.h>

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

typedef struct hs_engine hs_engine;

/// Output channel source codes for the channel map.
enum { HS_SRC_ZERO = 0, HS_SRC_LEFT = 1, HS_SRC_RIGHT = 2, HS_SRC_MONO = 3 };

/// Chain parameters (DESIGN §6/§7). Switches are 0/1; all settable from any thread.
enum {
    HS_P_MONO = 0,        // fold to mono at the start of the chain (default 1)
    HS_P_HPF_ON,          // 80 Hz high-pass
    HS_P_EQ_ON,           // tonal EQ
    HS_P_DEESS_ON,        // de-esser
    HS_P_LEVEL_ON,        // AGC + compressor
    HS_P_LIMIT_ON,        // −1 dBFS limiter
    HS_P_REVERB_ON,       // M3
    HS_P_DEBOX_DB,        // 300 Hz peak gain (default −3)
    HS_P_PRESENCE_DB,     // 3 kHz peak gain 0…+5 (default +2.5); 8 kHz shelf = 0.6 × this
    HS_P_DEESS_MAX_DB,    // max de-esser reduction 0…4 (default 3)
    HS_P_TARGET_LUFS,     // leveler target (default −18)
    HS_P_ROOM,            // 0 seminar room, 1 lecture hall, 2 auditorium (needs hs_engine_rebuild_reverb)
    HS_P_WET,             // reverb mix 0…0.4 (default 0.15)
    HS_P_PREDELAY_MS,     // 0…40 ms (default 15)
    HS_P_DAMPING,         // HF damping of the tail 0…1 (default 0.5; needs rebuild)
    HS_P_DISTANCE,        // 0…1 (default 0.3): duller dry + more wet
    HS_P_DENOISE_ON,      // "Qualität": DeepFilterNet3 (needs hs_engine_denoiser_load)
    HS_P_DENOISE_DB,      // attenuation limit 1…100 dB (default 12, D-023; ≥ 100 = unlimited)
    HS_P_LEVEL_STRENGTH,  // leveler 0 = gentle (3 s window, 1.5 dB/s, 3:1) … 1 = tight (1 s, 6 dB/s, 6:1)
    HS_P_AB_ORIGINAL,     // A/B: 1 = play the original (input delayed by the chain latency), 20 ms crossfade
    HS_P_COUNT
};

/// Stages for per-stage timing (hs_engine_stage_ns).
enum { HS_ST_MONO = 0, HS_ST_DENOISE, HS_ST_HPF, HS_ST_EQ, HS_ST_DEESS, HS_ST_LEVEL, HS_ST_REVERB, HS_ST_LIMIT, HS_ST_COUNT };

/// Fade states reported by hs_engine_fade_state.
enum { HS_FADE_SILENT = 0, HS_FADE_IN = 1, HS_FADE_OPEN = 2, HS_FADE_OUT = 3 };

hs_engine *_Nullable hs_engine_create(void);
void hs_engine_destroy(hs_engine *e);

/// Allocates all buffers. Not RT-safe. Must not be called while an IOProc uses the engine.
/// maxFrames: largest block the engine will ever be asked to render.
void hs_engine_prepare(hs_engine *e, double sampleRate, int maxFrames);

/// Describe the IOProc input: which AudioBuffer of the input list carries the tap, its channel
/// count (1 or 2) and whether it is interleaved. Not RT-safe (call before AudioDeviceStart).
void hs_engine_set_input(hs_engine *e, int bufferIndex, int channels, int interleaved);

/// Describe the IOProc output: for every output AudioBuffer its channel count and interleaving,
/// and for every channel (flattened over buffers) one HS_SRC_* code. Max 64 channels total.
void hs_engine_set_output_map(hs_engine *e, int numBuffers, const int *channelsPerBuffer,
                              const int *interleavedPerBuffer, const int8_t *sourcePerChannel);

/// The Core Audio IOProc. Pass the hs_engine* as client data.
OSStatus hs_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                   const AudioTimeStamp *inputTime, AudioBufferList *output,
                   const AudioTimeStamp *outputTime, void *_Nullable clientData);

/// Offline / test entry point: runs exactly the same DSP chain as hs_ioproc on planar stereo
/// buffers in place (n <= maxFrames). RT-safe.
void hs_engine_process_planar(hs_engine *e, float *left, float *right, int n);

// ---- control (any thread, lock-free) ----
/// 1 = fade in to full level (20 ms), 0 = fade out to silence (20 ms).
void hs_engine_set_fade_target(hs_engine *e, int open);
/// Starts in HS_FADE_SILENT (or HS_FADE_OPEN if `startOpen`), so a new session fades in.
void hs_engine_reset_fade(hs_engine *e, int startOpen);
void hs_engine_set_generation(hs_engine *e, uint64_t generation);
/// Test hook: while set, the IOProc outputs silence and stops updating the heartbeat (simulated stall).
void hs_engine_debug_stall(hs_engine *e, int on);
/// Called from a HAL property listener on kAudioDeviceProcessorOverload.
void hs_engine_note_overload(hs_engine *e);

// ---- parameters / presets (any thread, lock-free) ----
void hs_engine_set_param(hs_engine *e, int param, float value);
float hs_engine_get_param(const hs_engine *e, int param);
/// Presets: "off", "clarity", "seminar", "hall", "auditorium". Returns 0 on success, -1 if unknown.
int hs_engine_apply_preset(hs_engine *e, const char *name);
/// The values a preset would set: out[HS_P_COUNT], setMask[HS_P_COUNT] (1 = the preset sets it).
/// Lets the control side write preset + overrides as one merged set (no transient preset values).
int hs_preset_values(const char *name, float *out, unsigned char *setMask);
/// Cumulative nanoseconds spent in a stage (HS_ST_*), for benchmarks.
uint64_t hs_engine_stage_ns(const hs_engine *e, int stage);

/// Exposed for unit tests: RBJ design (type 0 LP, 1 HP, 2 BP, 3 peak, 4 low shelf, 5 high shelf)
/// and BS.1770 K-weighting; out = {b0, b1, b2, a1, a2} (a0 = 1).
void hs_design_biquad(int type, double fs, double f0, double q, double gainDb, double *out5);
void hs_design_kweighting(double fs, double *shelf5, double *rlb5);

// ---- capture of the unprocessed tap input (control thread; the IOProc only copies) ----
/// Arms a capture of `seconds` of the raw tap input (before the chain). -1 if one is pending.
int hs_engine_capture_start(hs_engine *e, double seconds);
/// Frames written so far (−1 if none); `capacity` receives the target length.
int64_t hs_engine_capture_progress(const hs_engine *e, int64_t *_Nullable capacity);
/// Stops the IOProc from writing; returns the frames captured. Then copy, then release.
int64_t hs_engine_capture_detach(hs_engine *e);
/// Copies up to maxFrames interleaved stereo frames of the detached capture into dst.
int64_t hs_engine_capture_copy(const hs_engine *e, float *dst, int64_t maxFrames);
/// Frees the detached capture once the IOProc can no longer touch it (2 further calls, or
/// `ioprocStopped`). Returns 1 when freed (or nothing to free), 0 to retry later.
int hs_engine_capture_release(hs_engine *e, int ioprocStopped);

// ---- denoiser (control thread; allocates, starts/joins the worker) ----
/// Loads libDF (DeepFilterNet Plus + LectureLift patch) once per process. 0 ok, -1 dlopen failed,
/// -2 symbols missing.
int hs_denoiser_library_load(const char *dylibPath);
int hs_denoiser_library_loaded(void);
/// Creates the DFN3 state + worker and hands it to the audio thread. `synchronous` (offline renderer,
/// tests): no worker; hops are computed inline, deterministic. `ioBufferFrames` sizes the fixed
/// latency. 0 ok; -1 library not loaded; -2 model/resources; -3 sample rate ≠ 48 kHz; -4 already loaded.
int hs_engine_denoiser_load(hs_engine *e, const char *modelPath, int synchronous, int ioBufferFrames);
/// Unpublishes, waits until the audio thread no longer uses it (unless `ioprocStopped`), stops and
/// joins the worker, frees libDF state. Must run before hs_engine_destroy on live engines.
void hs_engine_denoiser_unload(hs_engine *e, int ioprocStopped);
/// The device's IOThread workgroup (kAudioDevicePropertyIOThreadOSWorkgroup, +1 reference: ownership
/// passes to the engine); the worker joins it from its own thread and releases it after leaving.
void hs_engine_denoiser_set_workgroup(hs_engine *e, void *_Nullable wg);
int hs_engine_denoiser_latency(const hs_engine *e);
/// Test hook: pause/resume the worker (underflow fallback test).
void hs_engine_denoiser_test_pause(hs_engine *e, int paused);
/// Test hook: the next hop behaves as if libDF returned an error.
void hs_engine_denoiser_test_fail(hs_engine *e);

// ---- reverb (control thread; allocates) ----
/// Builds the convolver pair for the current HS_P_ROOM / HS_P_DAMPING at the prepared rate and hands
/// it to the audio thread. Also frees pairs the audio thread has retired. Returns 0 on success,
/// 1 if nothing needed rebuilding, -1 if the hand-over queue is full (retry later), -2 on failure.
int hs_engine_rebuild_reverb(hs_engine *e, uint64_t seed);
/// Frees retired convolver pairs (call periodically from a control thread).
void hs_engine_collect_garbage(hs_engine *e);
/// 1 if HS_P_ROOM / HS_P_DAMPING differ from the last built IR.
int hs_engine_reverb_needs_rebuild(const hs_engine *e);
/// Test helper: the reverb's two-stage convolver (head 256, tail 4096) on a mono signal, in blocks.
int hs_test_convolve(const float *ir, int irLen, const float *in, float *out, int n, int block);
/// "vdsp" if FFTConvolver was compiled with the Accelerate backend.
const char *hs_fft_backend(void);

// ---- synthetic impulse responses (control thread; allocates) ----
/// Rooms: 0 = seminar room (RT60 0.5 s), 1 = lecture hall (1.0 s), 2 = auditorium (1.6 s).
int hs_ir_length(int room, double fs);
/// Writes a stereo IR (unit energy, time zero = direct-sound arrival, no direct sound) and returns
/// its length. damping 0…1 shortens the decay above 1 kHz. Deterministic for a given seed.
int hs_ir_generate(int room, float damping, double fs, uint64_t seed, float *outL, float *outR, int capacity);
float hs_ir_target_rt60(int room);

// ---- telemetry (any thread, lock-free) ----
typedef struct {
    uint64_t heartbeatHostTime;   // mach_absolute_time of the last IOProc call
    uint64_t generation;          // generation seen by the last IOProc call
    uint64_t callbacks;           // number of IOProc calls
    uint64_t xruns;               // sample-time discontinuities + overload notifications
    uint64_t overloads;           // overload notifications only
    uint64_t nonzeroBlocks;       // input blocks containing at least one non-zero sample
    float peakIn, peakOut;        // linear, decaying peak meters
    float cpuLoad;                // EMA of render time / block duration (0..1)
    int fadeState;                // HS_FADE_*
    int lastFrames;               // frames in the last IOProc block
    double ioDeltaSec;            // outputTime.mHostTime − inputTime.mHostTime of the last block (tap → output)
    float deessDb;                // current de-esser reduction (≤ 0)
    float levelerGainDb;          // current AGC gain
    float compGrDb;               // compressor gain reduction (≤ 0)
    float limiterGrDb;            // limiter gain reduction (≤ 0)
    uint64_t dspResets;           // non-finite output blocks that forced a chain reset
    uint64_t limiterClips;        // samples the limiter's final safety clamp had to change
    uint64_t dnUnderflows;        // denoiser output not ready in time (fallback used)
    uint64_t dnHops;              // denoiser hops processed
    double dnHopMeanUs, dnHopMaxUs; // libDF time per 10 ms hop (worker)
    uint64_t dnNaN;               // libDF errors (the denoiser then latches onto the delayed fallback)
    int dnFailed;                 // 1 = latched failure: reload the denoiser
    uint64_t dnSkipped;           // hops skipped (stale backlog after a stall, or failed)
    float dnMix;                  // denoiser stage mix (0 = bypassed … 1 = fully on)
} hs_telemetry;

void hs_engine_read_telemetry(const hs_engine *e, hs_telemetry *out);
/// Algorithmic latency in samples: the limiter look-ahead whenever any stage is active, else 0.
int hs_engine_latency_samples(const hs_engine *e);

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
