# LectureLift — Design

> **Naming note:** developed under the working title *Hörsaal* (German for "lecture hall"); published as **LectureLift**. Preset IDs were renamed to English for publication: `aus→off`, `klarheit→clarity`, `seminarraum→seminar`, `hoersaal→hall`, `audimax→auditorium`; the German UI labels are unchanged. This document is the design as written before
> implementation; some scripts it mentions (`make_dev_cert.sh`, `fetch_corpus.sh`, `make_zoomlike.py`, `eval.sh`)
> were planned but not implemented (scope simplified, see DECISIONS D-026). The decision log records what was built.


Status: **v3: approved by owner (D-006)** · 2026-11-16 · M1 in progress
Inputs: `docs/PRIOR_ART.md`, owner decisions D-002 (base = option b) and D-003 (budgets) in `docs/DECISIONS.md`, DFN3 spike (§9.3), language addendum `docs/ADDENDUM_LANGUAGES.md` (§11).

---

## 1. Goals and budgets

| Mode | Chain | CPU (one M1 P-core) | Added latency |
|---|---|---|---|
| **Standard** (default) | HPF → EQ → de-esser → leveler → reverb → limiter | **≤ 5 %** | **≤ 60 ms** |
| **Qualität** (opt-in) | + DeepFilterNet3 before the HPF | **≤ 12 %** | **≤ 80 ms** |
| Off | tap destroyed, browser plays natively | 0 | 0 |
| Idle (target apps silent) | tap destroyed until output resumes | ≈ 0 | — |

The chain is language-agnostic: one chain and one set of defaults for German and English, with no language detection.

## 2. What is reused, modified, new

| Part | Source | Status |
|---|---|---|
| Tap → private aggregate → IOProc; teardown order | AudioCap (BSD-2) pattern, Apple "Capturing system audio with Core Audio taps" | **re-implemented in C**, attributed |
| Lifecycle behaviours (device switch, BT rate change, orphan sweep, health check) | FineTune as **behaviour list only** (clean room, see §12) | new code |
| Edge-case facts (zeroed buffers without permission, settable tap description, bundle-ID taps) | catap (MIT) docs | design input |
| Idle auto-off, Low-Power-Mode auto-off | eqtune (Apache-2.0) idea | new code |
| Partitioned convolution | **FFTConvolver (MIT)**, vendored, vDSP backend; `TwoStageFFTConvolver` subclassed to run the tail on a worker | vendored + small subclass |
| DeepFilterNet3 | **libDF C API from DeepFilterNet Plus** @ `2dc5273d` (MIT/Apache), DFN3 weights (MIT/Apache) | vendored static lib (built by script) |
| RNNoise | xiph/rnnoise core (BSD-3), pinned tag | vendored C, conditional on German test |
| Biquads, de-esser, leveler, limiter, IR generator, render core, UI, CLI | — | **new** |

## 3. Architecture

```
                          ┌──────────────────────── LectureLift.app (LSUIElement) ─────────────────────┐
 Chrome/Safari/Arc/FF     │  UI (SwiftUI MenuBarExtra, @MainActor)                                      │
 helper processes         │     │  settings (@AppStorage) ── ParamStore (atomics) ──┐                   │
   │ audio                │     ▼                                                    ▼                   │
   ▼                      │  SessionController (Swift, serial `lifecycle` queue)   RenderCore (C/C++)    │
 Core Audio process tap ──┼─► TapManager: tap + private aggregate + IOProc ──────► hs_render(ctx, in,out)│
 (mutedWhenTapped)        │     ▲ HAL listeners / NSWorkspace sleep-wake           │   │  SPSC rings      │
                          │     │ watchdog (heartbeat)                             │   ▼                  │
                          │     └──────────────── teardown = original audio back   │  DenoiseWorker ──┐   │
                          │                                                        │  (libDF / RNNoise)│  │
                          │                                                        │  ReverbTailWorker ◄┘  │
                          └──────────────────────────────────────── output subdevice = default output ──┘
```

### Modules (SwiftPM targets)

| Target | Lang | Responsibility |
|---|---|---|
| `HSCore` | C/C++20 | `RenderCore`, all DSP stages (`DSP/`), `Reverb/` (convolver wrapper + IR generator), `Denoiser/` (backend interface, libDF + RNNoise backends, worker), SPSC ring, param atomics, meters. **Everything the I/O thread touches lives here.** No Swift, no ObjC, no allocation after `prepare()`. |
| `HSAudio` | Swift (+ thin C for the IOProc trampoline) | `TapManager` (tap/aggregate/IOProc lifecycle), `ProcessResolver` (browser processes), `DeviceMonitor`, `PowerMonitor` (sleep/wake, Low Power Mode), `Watchdog`, `SessionController` (state machine) |
| `HSApp` | Swift/SwiftUI | `UI/`, onboarding, settings, hotkey, launch-at-login, String Catalog (de default, en) |
| `lecturelift-render` | Swift CLI | offline renderer: same `HSCore` chain, WAV in/out, `--preset`, `--bench`, `--impulse` |
| `HSCoreTests`, `HSAudioTests` | Swift Testing / XCTest | §13 |
| `vendor/` | — | `FFTConvolver/` (source), `rnnoise/` (source), `libdf/` (xcframework produced by `scripts/build_libdf.sh`) |

**Why C/C++ for the render path:** Swift class references on the I/O thread mean retain/release, which is exactly FineTune's residual RT issue. Swift `nonisolated(unsafe)` pointer swaps are formally data races. A C/C++ core with `std::atomic` and POD state makes the RT rules checkable by inspection and by a `-fno-exceptions -fno-rtti` build of the RT translation units.

Build: **SwiftPM only** (`swift build`, `swift test`). `scripts/build.sh` assembles the `.app` (Info.plist, resources, models), signs it and makes a DMG with `hdiutil`. No `.xcodeproj` needs maintaining.

**Signing and TCC:** the audio-capture grant is bound to the app's designated requirement. An ad-hoc signature's requirement is its cdhash, which changes with every build, so the permission would be re-requested after each rebuild. `build.sh` therefore signs with `$LECTURELIFT_SIGN_IDENTITY` when set: an Apple Development certificate, or a local self-signed code-signing certificate created once with `scripts/make_dev_cert.sh`. It falls back to ad-hoc only with a printed warning. On this machine an **Apple Development** identity exists and is used (D-006). `build.sh` selects it by matching "Apple Development" so no personal data is committed. The TCC grant survives rebuilds because the designated requirement is identity-based, not cdhash-based (verified in M1). The live app is **always run from the assembled `.app`**, never via `swift run`: a bare binary has no `NSAudioCaptureUsageDescription`.

## 4. Process tap and aggregate lifecycle

### 4.1 Which processes are tapped
Browsers render audio in helper processes, not in the main PID.

`ProcessResolver` builds the tap's process list from `kAudioHardwarePropertyProcessObjectList`, using each process object's `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyPID`, in this order:
1. **Bundle-ID prefix match** against the user's selection (`com.google.Chrome` matches `com.google.Chrome.helper*`; Arc `company.thebrowser.Browser*`; Firefox `org.mozilla.firefox*` plus `org.mozilla.plugincontainer`). Public API only.
2. **Responsible-PID match** for processes whose bundle ID doesn't share the prefix. Example: Safari's audio comes from `com.apple.WebKit.GPU`, which is shared per host app. This uses the private `responsibility_get_pid_responsible_for_pid` via `dlsym`, called **only if present**. When it is unavailable, step 1 still works and Safari shows as "eingeschränkt" (limited) in the UI. *Risk accepted for a non-App-Store app; documented in README.*
3. **macOS 26+:** additionally set `CATapDescription.bundleIDs` + `processRestoreEnabled = true`. **M1 must verify** whether this covers Chromium helpers or WebKit.GPU. If it doesn't, steps 1–2 stay authoritative.

The process list is re-evaluated on `kAudioHardwarePropertyProcessObjectList` changes, debounced 200 ms on the lifecycle queue. It is applied by **setting `kAudioTapPropertyDescription` on the live tap** (settable per catap). If that fails, we fall back to rebuilding.

### 4.2 Creation (lifecycle queue only)
1. `CATapDescription(stereoMixdownOfProcesses:)`, `isPrivate = true`, `muteBehavior = .mutedWhenTapped`, `name = "LectureLift"`, explicit `uuid`.
2. `AudioHardwareCreateProcessTap` → `tapID`. Read `kAudioTapPropertyFormat` (expect Float32, 2 ch, device rate). **Until permission is confirmed (§4.6), the tap is created with `muteBehavior = .unmuted`.** The first-ever session therefore never mutes the browser into silence; once confirmed, it is recreated muted.
3. Private aggregate: `UID = "io.github.aetsr.lecturelift.agg.<uuid>"`, `Name = "LectureLift"`, `IsPrivate = 1`, `MainSubDevice = ClockDevice = <default output UID>`, `SubDeviceList = [output]`, `TapList = [{uid: tap, DriftCompensation: 1}]`, `TapAutoStart = 0`.
4. Set `kAudioDevicePropertyBufferFrameSize = 256` on the aggregate. If refused, read back the actual value and use it in the latency computation.
5. `AudioDeviceCreateIOProcID(agg, hs_ioproc, ctx)`: a plain **C function pointer** with a raw context pointer. No block and no Swift capture.
6. Query `kAudioDevicePropertyIOThreadOSWorkgroup` on the aggregate. Each worker thread is created with an explicit **Mach time-constraint policy** (`THREAD_TIME_CONSTRAINT_POLICY`: period = I/O buffer duration, computation ≈ its measured cost, constraint = period). The thread then **joins the workgroup from itself** (`os_workgroup_join` must be called on the joining thread). `lifecycle` sends "join(wg)" / "leave" commands through the worker's command slot and waits for an ack (park/ack handshake). Joining alone does not make a thread real-time.
7. Read the **real output stream format** of the aggregate (`kAudioDevicePropertyStreamConfiguration` / stream virtual format, output scope): channel count (1 for HFP, 2, or multichannel interfaces), interleaved vs. non-interleaved, and `kAudioDevicePropertyPreferredChannelsForStereo`. `RenderCore.prepare(sampleRate, maxFrames, inLayout, outLayout)`: all allocation happens here. The render path accepts **variable frame counts ≤ maxFrames** each cycle, writes stereo to the preferred pair (or the L+R sum to mono outputs) and zeroes all other channels.
8. `AudioDeviceStart`. Start the 250 ms watchdog timer.

### 4.3 Teardown (fixed order, idempotent, lifecycle queue)
`AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap` → workers leave the workgroup and park → `RenderCore` is freed only after the IOProc is destroyed. Destroying the tap releases `mutedWhenTapped`, and the browser audio is native again.

### 4.4 Events → reconcile

**Model:** HAL and system events do not act directly. Each event only marks the session *dirty* and (re)starts a **150 ms debounce** on `lifecycle`. When it fires, `reconcile()` reads the *current* world (default output UID and alive state, nominal rate, tap format, target process list, sleep state, enabled/idle/permission flags), computes the desired session and compares it with the running one. If they differ, `reconcile()` tears down and creates **once**. Every session has a **generation number**. Listener callbacks, watchdog checks and IOProc heartbeats carry or compare it, and anything stamped with an old generation is ignored. An AirPods connect (default-device + rate + format burst) thus causes one rebuild, not four. Exceptions that skip the debounce: device not alive and `willSleep` (immediate teardown), service restart (below).

The table below lists which inputs reconcile reads and the special handling per case.


| Event (source) | Action |
|---|---|
| Default output changed (`kAudioHardwarePropertyDefaultOutputDevice`) | debounced reconcile: fade out 20 ms → teardown → create on the new device. Expected gap ≈ 100–200 ms, measured in M1. |
| Output device dies (`kAudioDevicePropertyDeviceIsAlive` = 0) | immediate teardown (no fade, the device is gone) → wait for the new default → create |
| Output nominal rate change (`kAudioDevicePropertyNominalSampleRate`; BT A2DP↔HFP) | teardown → create at the new rate (DSP re-prepared, IRs regenerated for the rate) |
| Tap format change (`kAudioTapPropertyFormat`) | same as rate change |
| Target process list change | live tap-description update (§4.1) |
| All target processes stop output (`kAudioProcessPropertyIsRunningOutput` false for **N = 15 s**, tunable after M1 measurement) | **idle teardown**, keep listeners. On `IsRunningOutput` true → create. Short pauses are covered by the in-render silence skip (CPU ≈ 0), so a resume does not play ~150 ms raw audio and then a gap. |
| `NSWorkspace.willSleepNotification` | teardown (synchronous, before sleep) |
| `NSWorkspace.didWakeNotification` | wait 1 s, re-resolve devices and processes → create if enabled and not idle |
| `kAudioHardwarePropertyServiceRestarted` (coreaudiod restart) | still call `AudioDeviceStop` / `AudioDeviceDestroyIOProcID` / destroy calls and **ignore errors**. The HAL I/O thread lives in our process and may still be inside `hs_render`. Free `RenderCore` only after the heartbeat has been silent for **≥ 1 s**. Re-register all HAL listeners (the old registrations are gone), make the workers leave the stale workgroup, bump the generation, then reconcile. |
| Low Power Mode on (`NSProcessInfoPowerStateDidChange`) | Qualität mode drops to Standard. Optional setting: full off. |
| Permission revoked / not granted | §4.6 |
| App quit (`applicationWillTerminate`), SIGTERM/SIGINT (`DispatchSource` signal handlers, not raw handlers) | teardown |

### 4.5 Fail-safe: never leave the user in silence

| Failure | Detection | Response |
|---|---|---|
| IOProc stops being called while the device is "running" | IOProc stores `mach_absolute_time` + generation in an atomic heartbeat. The watchdog runs on **its own serial queue** (not `lifecycle`, so a hung HAL call can't disable it), every 250 ms. It is **armed only after the first heartbeat of the current generation** (or 2 s after start: Bluetooth start-up and wake can exceed 500 ms). It fires when there has been no beat for > 500 ms. | request teardown (unmutes), retry with backoff 1 s/5 s/30 s, UI shows "Neu verbinden…". If `lifecycle` itself does not respond within 3 s (hung HAL call): last resort `exit` and relaunch via the login item, which is only safe if Plan A holds (kill -9 test). |
| DSP produces NaN/Inf or ≥ +6 dBFS sustained | per-block check in `RenderCore` (cheap: limiter output peak + `isfinite` on block sum) | state reset of the offending stage + crossfade to delayed dry for 1 s; counter shown in debug |
| Denoiser worker late (ring underflow) | IOProc sees fewer samples than needed; also listen for `kAudioDeviceProcessorOverload` | crossfade (5 ms) to the **denoiser bypass delay line** (`dnDelay`, length L_dn, at the denoiser insert point, §6), so EQ/leveler/reverb keep running with no level or timbre jump. Fade back after **~50 ms** of healthy fill. Count events; the UI shows "Denoiser überlastet" if > 3 per minute. |
| Hang of the main thread | irrelevant to audio, which is independent of main | — |
| Tap/aggregate creation fails | OSStatus | stay off, show the error, the original audio is untouched (no tap = no mute) |
| **App crash / SIGKILL** | — | **Verified (D-007, macOS 27.2):** process death releases the mute even if a public tap object is orphaned; private objects are invisible to other processes. → Private tap + aggregate; no guard helper. A launch-time sweep of public leftovers with prefix `de.hoersaal.` is kept as tidiness only. No raw signal handler does HAL IPC. |

### 4.6 Permission
- `Info.plist`: `NSAudioCaptureUsageDescription` (de/en).
- There is no public query API for the System Audio Recording grant, and missing permission produces **zeroed buffers, no error**. Paused, muted or DRM tabs *also* give exact zeros while `IsRunningOutput` is true, so zeros alone are ambiguous.
- **Primary signal (D-010):** the TCC state via the private `TCCAccessPreflight("kTCCServiceAudioCapture")` (AudioCap pattern), polled every 2 s. Mute only when `granted`; `undetermined` (prompt pending; the tap already delivers audio then) stays unmuted; `denied` → onboarding.
- Fallback if the SPI is missing: a persisted flag `permissionConfirmed` is set (with the app's signing identity) the **first time any non-zero sample arrives**. Until then the tap runs **unmuted** (§4.2), so the user hears the original. If there are only zeros for 5 s while `IsRunningOutput` is true, show onboarding ("Systemaudio-Aufnahme erlauben" + button to `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`). After confirmation, zeros never trigger onboarding again (only an explicit tap-creation permission error does). Optional second signal: AudioCap's private TCC preflight via `dlsym`, if present.
- On first launch the onboarding sheet explains the prompt before we trigger it.

## 5. Threading model and RT rules

| Thread | Priority | May do | Must not do |
|---|---|---|---|
| Main | UI | SwiftUI, settings, start/stop requests | HAL create/destroy (blocks up to 100s of ms) |
| `lifecycle` serial queue | userInitiated | all HAL calls, listeners, watchdog, IR generation, convolver/denoiser construction | touch RT state except via the defined handoffs |
| HAL I/O thread | RT (HAL) | `hs_render()` only | allocate, free, lock, log, ObjC/Swift calls, syscalls except Mach `semaphore_signal` |
| `DenoiseWorker` | joined to aggregate workgroup | `df_process_frame` (allocates internally: acceptable here, not on I/O) | block on anything but its semaphore |
| `ReverbTailWorker` | joined to workgroup | FFTConvolver tail stage | same |

Handoffs (all lock-free):
- **Parameters:** `std::atomic<float>` per parameter (relaxed), read once per block, smoothed per sample or per 32-sample sub-block (one-pole, 20 ms) → no zipper noise.
- **Structural objects** (new IR/convolver, new denoiser backend, biquad coefficient sets): built on `lifecycle`, passed through an SPSC "inbox" of pointers. The RT thread swaps one in **only if the outbox has a free slot** (otherwise it retries next block) and puts the old object into the SPSC "outbox"; `lifecycle` drains and frees it. No timers, and no "free after 0.5 s". A new convolver is **pre-rolled** on `lifecycle` with the last ~IR-length of input history, so its tail isn't empty, or else the wet path is faded over ~300 ms. Either way the reverb doesn't dip on IR change.
- **Audio to/from workers:** SPSC float ring buffers (power-of-two, acquire/release indices, cache-line-padded). The I/O thread wakes the worker with `semaphore_signal` (Mach, RT-safe).
- **Meters/telemetry → UI:** atomics (peak in/out, GR, CPU ns per block, underflow count, **xrun count**) polled by the UI at 30 Hz.
- **Xrun counter:** counts (a) `kAudioDeviceProcessorOverload` notifications on the aggregate, (b) discontinuities in the IOProc's `inOutputTime.mSampleTime` (jump ≠ previous frame count) and in the tap input time stamps, (c) denoiser ring underflows and convolver tail misses (counted separately but also shown as glitch risk). Shown in the UI meters and the debug panel and logged per session; `lecturelift-render --bench` reports deadline misses against a simulated I/O period.

CPU% in the UI = EMA(`ns spent in hs_render` + worker ns) / wall-clock ns of the audio delivered, measured with `mach_absolute_time` around the render call and in each worker.

Enforcement: RT translation units compile with `-fno-exceptions -fno-rtti`. A debug-only `RTGuard` interposes `malloc`/`free`/`pthread_mutex_lock` and traps when the calling thread is flagged as RT (test builds only). The unit tests run the whole chain under it.

## 6. Signal flow per block (`hs_render`)

```
tap in (2ch interleaved Float32, device rate)
  → deinterleave → [mono fold? M = (L+R)/2 → both channels]   (default ON)
  → dryDelay  (delay line, length = chain latency L, for A/B and denoiser fallback)
  → [Denoiser (Qualität): mono → ring → worker → ring, fixed latency L_dn;
      parallel dnDelay (L_dn) as underflow fallback]                         ── bypassable
  → HPF 80 Hz (2nd-order Butterworth, 12 dB/oct)                            ── bypassable
  → EQ: peak −3 dB@300 Hz Q1 · peak +2.5 dB@3 kHz Q1 ("Presence") · high-shelf +1.5 dB@8 kHz ── bypassable
  → De-esser (split-band, §7.3)                                              ── bypassable
  → Leveler (AGC → −18 LUFS, + 3:1 compressor)                               ── bypassable
  → Reverb (stereo IR, dry/wet, pre-delay, HF damping, distance)             ── bypassable
  → Limiter (−1 dBFS ceiling, 1.5 ms lookahead)                              ── bypassable
  → A/B crossfade (20 ms equal-power) between processed and dryDelay
  → silence gate → interleave → output subdevice
```
- When **all stages are bypassed and the denoiser is off**, L = 0, and the path is a copy: **bit-identical** (null test).
- `dryDelay` length always equals the active algorithmic latency, so A/B is time-aligned (no lip-sync jump when switching). The **denoiser fallback uses its own `dnDelay`** at the insert point, so the rest of the chain keeps processing. The limiter lookahead is constant in all modes. Switching Standard↔Qualität changes L: the change is done by crossfading (20 ms) between two read heads of the delay lines, never by resizing a running delay.
- **Silence skip:** if the input block peak is below −90 dBFS and the samples since the last non-silent block exceed **L + pre-delay + IR length + limiter lookahead**, output zeros and skip all stages: O(1) per block. On resume, stage states and the denoiser rings are **reset** before processing, so no stale audio is played. Idle teardown (§4.4) takes over after 15 s of process-level silence.
- **Sample rate:** the chain runs at the **device rate** (48 kHz in practice for built-in speakers and AirPods; 44.1 kHz possible on USB DACs). All coefficients and IRs are computed for the actual rate, including BS.1770 K-weighting, which is redesigned per rate rather than using the 48 kHz table. **Rate guards:** a filter stage whose design frequency exceeds 0.45·fs auto-bypasses. At 16 kHz HFP this disables the 8 kHz shelf, and the de-esser band moves down or disables. Qualität mode is unavailable below 44.1 kHz. At 44.1 kHz the denoiser's SRC latency and CPU are counted in §9. Only the denoiser requires 48 kHz: at other rates its worker resamples (AudioConverter, prepared once, on the worker thread). *Deviation from the brief ("convert to 48 kHz"):* this avoids two SRC passes on the I/O thread when the device isn't 48 kHz. Logged as D-004.

## 7. DSP stages

Common C++ interface (`DSP/Stage.h`):
```cpp
struct Stage {
  virtual void prepare(double sr, int maxFrames, int ch) = 0;   // may allocate
  virtual void reset() = 0;                                     // RT-safe
  virtual void process(float* const* io, int ch, int n) = 0;    // RT-safe, in place
  virtual int  latencySamples() const { return 0; }
};
```
Bypass is handled by the chain (skip call + 10 ms crossfade on toggle), not by each stage.

### 7.1 HPF
2nd-order Butterworth high-pass at 80 Hz (RBJ, Q = 0.7071), per-channel state, `vDSP_biquad`.

### 7.2 EQ
RBJ cookbook biquads: peaking 300 Hz −3 dB Q 1.0, peaking 3 kHz +2.5 dB Q 1.0, high shelf 8 kHz +1.5 dB (S = 1). The "Presence" slider maps to the 3 kHz gain (0…+5 dB) and scales the shelf by 0.6×. Coefficients are computed on `lifecycle` and handed over as an immutable POD set through the structural **inbox/outbox** (§5); a two-slot atomic-index double buffer would tear on two quick updates. Slider drags are coalesced to ≤ 30 updates/s.

### 7.3 De-esser (addendum)
- **Split-band:** Linkwitz-Riley 4th-order crossover at 5 kHz, so LP + HP sum flat. Only the HP band is attenuated.
- **Detector:** band-pass 5–8 kHz energy versus full-band energy, both RMS with 5 ms attack and 60 ms release. Gain reduction is driven by the **ratio** (sibilance relative to the speech level), not by the absolute level. That keeps it independent of loudness, mic and language. A German "sch" and an English "sh" trigger by the same physical criterion.
- **Detector input is taken pre-EQ** (after the HPF), so the Präsenz slider doesn't shift the de-esser threshold. Reduction is applied to the post-EQ HP band.
- An **absolute floor gate** (band energy below −55 dBFS → no reduction) keeps it from acting on hiss or codec noise in pauses.
- Static curve: threshold ratio −12 dB, **slope 0.5 dB reduction per dB above threshold**, soft knee 6 dB, **max reduction 3 dB (default "mild")**, adjustable up to 4 dB in Custom. Default **ON**.
- Placed after the EQ (it sees the presence boost) and before the leveler (so the leveler doesn't re-amplify sibilants).

### 7.4 Leveler + limiter
- **AGC (revised D-012):** **feed-forward**: K-weighted (BS.1770, redesigned per rate) loudness of the input *before* the gain, ~3 s window over active 100 ms blocks. **Relative gate:** blocks more than 10 LU below the slow speech level (absolute floor −60 LUFS) count as pause, and **gain is frozen**. The gate leaks down after 3 s of pause so lasting level drops are followed. Gain up 1.5 dB/s, down 6 dB/s, range ±12 dB, target **−18 LUFS**. A slow **trim loop** on the post-compressor loudness (±4 dB, anti-windup) removes the compressor's make-up calibration error.
- **Compressor:** 3:1, threshold −24 dBFS RMS, attack 15 ms, release 200 ms, soft knee 6 dB, make-up from the static curve at the per-channel RMS that corresponds to the target (target − 2.3 dB).
- **Limiter (revised D-012):** 1.5 ms look-ahead (72 samples at 48 k). Required gain → sliding-window minimum (monotonic deque) → box average over the look-ahead, so the gain reaches the requirement exactly when the peak leaves the delay line (no clipping). Release 50 ms, **stereo-linked**, ceiling −1 dBFS; the final clamp only catches rounding. Its delay stays in the path whenever any stage is active (**constant chain latency**); `LIMIT_ON` blends the gain over 10 ms.

### 7.5 Reverb
- **Engine:** two `TwoStageFFTConvolver` instances (L and R IR), **head block 128, tail block 4096** (requirement: tail block ≥ 2 × maxFrames). The subclass overrides `startBackgroundProcessing`/`waitForBackgroundProcessing` to hand the tail to `ReverbTailWorker` (semaphore + SPSC). **`waitForBackgroundProcessing` never blocks on the I/O thread.** Upstream `process()` calls it before every tail swap. Ours is a non-blocking "done?" check: on a miss that tail block is replaced by zeros and counted (meter + debug). Zero added latency: the head covers the first samples directly. A 256-frame I/O with a 128 head is fine. Unaligned I/O sizes stay correct but cost more (benched in M3). Input is the mono mid (mono fold) or L/R. Output is stereo; decorrelated L/R IRs give width.
- **Mix:** wet default **15 %** (range 0–40 %), pre-delay default **15 ms** (range 0–40 ms), applied as a delay line in front of the convolver (no IR regeneration on change).
- **HF damping:** a parameter of the IR generator (frequency-dependent decay). A change triggers IR regeneration on `lifecycle` (debounced 150 ms) and an RT crossfade swap.
- **Distance (optional, default 0.3):** dry path gets a gentle 1-pole high-shelf cut (0 to −4 dB above 5 kHz), and wet gets 0 to +3 dB.
- **User IR:** WAV/AIFF via `AVAudioFile` on `lifecycle`, resampled to the device rate, truncated to 3 s, normalised to the same energy as the synthetic IRs.

### 7.6 Synthetic IR generator (`Reverb/IRGenerator`)
Deterministic (seeded PCG32), generated at the device rate:
1. **Early reflections:** image-source model of a shoebox up to order 3. Wall absorption is derived from the target RT60 via Sabine. Each image is a delayed, distance-attenuated impulse, low-passed by order. The source is 1.5 m in front of the listener for "Seminarraum" and further away for the larger rooms. L/R uses two listener positions 18 cm apart.
2. **Late tail:** Gaussian noise split into 8 octave bands (LR crossovers). Each band gets its own exponential envelope from RT60(f) = RT60 × damping curve (HF damping shortens bands above 2 kHz). Independent noise for L/R gives decorrelation.
3. **Transition:** crossfade from ER to tail around the mixing time t_mix ≈ √V ms (V in m³).
4. **Time zero is the direct-sound arrival:** reflections are placed relative to the direct path, otherwise 7–12 m of source distance would add 20–35 ms of dead time on top of the pre-delay. Direct sound removed (the dry path carries it). Energy is normalised so 15 % wet sounds equally present across presets.

| Preset | Room (L×W×H m) | RT60 | Source distance |
|---|---|---|---|
| Seminarraum | 8 × 6 × 3 | 0.5 s | 3 m |
| **Hörsaal** (default) | 20 × 15 × 6 | 1.0 s | 7 m |
| Audimax | 35 × 25 × 10 | 1.6 s | 12 m |

Verified by test: Schroeder backward integration, T30 fit (−5 to −35 dB) within ±10 % of the target, per preset and at 44.1 and 48 kHz.

## 8. Denoiser

```c
typedef struct hs_denoiser_vtbl {
  int   (*hop)(void*);                 // samples per frame at 48 kHz (480)
  int   (*latency)(void*);             // algorithmic, samples
  void  (*set_strength_db)(void*, float);
  float (*process)(void*, const float* in, float* out); // worker thread only
} hs_denoiser_vtbl;
```
- **DFN3 backend:** libDF C API from DeepFilterNet Plus, pinned commit `2dc5273d16e1e3769527ad0740654c5ccde581cc`, model `DeepFilterNet3_onnx.tar.gz` (bundled, 7.2 MB). `df_create(path, atten_lim)`, `df_set_atten_lim` for the strength slider. Range 0–24 dB, **default 8 dB** once enabled (mild: Zoom audio is already denoised). Mono only. Turning Qualität on forces mono fold.
- **RNNoise backend:** BSD-3 core, 480-sample frames at 48 kHz. Strength = wet/dry mix of the denoised signal (RNNoise has no attenuation limit). **Kept only if it passes the German listening test (§11.3); otherwise removed before M4 closes.**
- **Small patch file** `vendor/libdf/patches/0001-capi.patch` (MIT/Apache, applied by `build_libdf.sh`): (a) expose the LSNR thresholds that `capi.rs` hardcodes (−15 / 35 / 35 dB, `capi.rs:29-31`) via a `df_set_thresholds` call. Lowering the DF-decoder threshold may skip the DF decoder on already-clean Zoom audio and save CPU; to be re-spiked in M4 before relying on it. (b) Replace `expect()` panics across the FFI boundary with error returns (a panic across FFI aborts the app → stuck-mute scenario).
- **Why libDF C API over ONNX Runtime:** libDF contains the full STFT/ERB/deep-filter/post-filter pipeline matched to the weights. The ONNX route would mean re-implementing that DSP in Swift/C around three graphs, plus a ~25 MB runtime. The spike shows libDF meets the relaxed budget (§9.3). LL model rejected (16.7 % CPU).
- **Worker:** wakes on semaphore, processes all complete 480-sample hops in the input ring, writes the output ring. On the I/O side the read position trails the write position by the fixed `L_dn` (§9.1). Underflow → dry fallback (§4.5).
- `scripts/build_libdf.sh`: rustup toolchain **1.88.0** (pinned), clone DeepFilterNet Plus at the pinned commit, `cargo build --release -p deep_filter --features capi --lib` for `aarch64-apple-darwin`, wrap `libdf.a` + generated header (cbindgen) in `vendor/libdf/libdf.xcframework`, record checksums. Model copied to `Resources/Models/`.

## 9. Latency and CPU budgets

### 9.1 Latency (at 48 kHz, aggregate buffer 256 frames)

| Contribution | Standard | Qualität | Source |
|---|---|---|---|
| Tap → IOProc → output: 1 I/O cycle + safety offsets of the aggregate | ~6–12 ms | ~6–12 ms | estimate, **measured in M1** |
| Limiter lookahead | 1.5 ms | 1.5 ms | design |
| Reverb (two-stage, head 128) | 0 | 0 | design |
| DFN3 algorithmic (STFT + 2+2 lookahead) | — | **30.0 ms** | **measured** (spike) |
| Ring delay **D = 480 + B + M** (hop + I/O buffer B + margin M); B = 256, M = 720 (15 ms, covers the 14.7 ms outlier) | — | **30.3 ms** | design, recomputed from actual B at prepare |
| SRC to/from 48 kHz (only at 44.1 kHz devices) | — | +≈ 2 ms | estimate |
| **Total (target)** | **≈ 8–14 ms** (≤ 60) | **≈ 68–76 ms** (≤ 80) | |

D is computed from the **actual** buffer size at prepare time. With B = 512 the margin stays at M; it is never derived from a fixed "10 + 10 ms". If the measured p99.9 worker time (M4 long spike) needs M > 720, the total budget is rechecked against 80 ms first.

The UI shows **"Latenz: X ms"** = aggregate input latency + safety offsets + buffer (read from `kAudioDevicePropertyLatency`, `…SafetyOffset`, `…BufferFrameSize` of tap stream and output stream) + `RenderCore.latencySamples()`. The offline CLI `--impulse` measures the algorithmic part exactly. The app-level number is validated once in M1 with a loopback test: a browser plays a click, and the tap of the aggregate output (a second, unmuted global tap) is compared against the tapped input.

### 9.2 CPU (one M1 P-core, 48 kHz stereo-out)

| Stage | Estimate | Verified in |
|---|---|---|
| I/O overhead, conversion, meters | 0.3 % | M1 |
| HPF + EQ (4 biquads × 2 ch) | 0.1 % | M2 bench |
| De-esser + leveler + limiter | 0.3 % | M2 bench |
| Reverb 2 × TwoStage (IR ≤ 1.6 s + ER) | 1–2 % | M3 bench |
| **Standard total** | **≈ 2–3 %** (≤ 5) | M3/M6 |
| DFN3 (spike, mono) | **9.2 % mean, 10–12 % p99** | measured |
| **Qualität total** | **≈ 10.7–11.7 % mean** (≤ 12) — **tight**; would fail if judged at p99 | M4 |

**Metric (owner, D-006):** the CPU budget is judged as the **mean over 60 s of continuous speech**; p99 and max are shown alongside. **Hard criterion: zero audio dropouts/xruns.** Brief p99 peaks above 12 % are acceptable as long as the audio never glitches.

If Qualität exceeds 12 % in M4, the fallbacks in order are: (1) shorten the reverb in Qualität mode (IR truncated to 1.2 s); (2) report to the owner. (A CPU-specific libDF build was tested and gives nothing, §9.3.)

### 9.3 DFN3 spike (2026-11-16, this Mac: Apple M1, macOS 27.2)
`spike/dfn_bench.c`, `spike/run_dfn_spike.sh`; libDF from DeepFilterNet Plus @2dc5273d, Rust 1.88.0, release build; QoS user-interactive; 50 warm-up frames skipped. German (macOS voice "Anna") and English ("Samantha") TTS of a lecture paragraph, ~45 s each; clean and with white noise at −40 dBFS; attenuation limit 100 dB and 10 dB.

| Model | Lang | Mean CPU | p99 CPU | Max frame | Delay |
|---|---|---|---|---|---|
| DFN3 | de | 9.1–9.5 % | 9.9–12.0 % | 1.2–14.7 ms (one outlier) | 1440 smp = **30.0 ms** |
| DFN3 | en | 9.2–9.3 % | 9.9–10.7 % | 1.5–2.3 ms | 30.0 ms |
| DFN3-LL | de/en | 16.6–16.9 % | 17.8–19.1 % | 2.0–2.6 ms | 480 smp = 10.0 ms |

**Follow-up (start of M4):** rerun for ≥ 10 min on a time-constraint, workgroup-joined thread; report p99.9 and max. The 14.7 ms outlier may be preemption at the user-interactive QoS level. Per-frame allocation inside libDF is acceptable on the worker given the margin M and the `dnDelay` fallback.

Conclusions: DFN3 fits the relaxed budget with little headroom. CPU cost does not depend on language or SNR: the SNR-skip in libDF never triggered at these levels. The 14.7 ms outlier (> one 10 ms hop) sets the ring margin M = 15 ms (§9.1). LL is rejected.
`target-cpu=apple-m1` build (Rust `RUSTFLAGS=-C target-cpu=apple-m1`), alternated with the generic build on the same input (de, 10 dB, −40 dBFS noise): apple-m1 9.6 % / 8.9 %, generic 9.5 % / 9.0 % mean, so **no measurable gain** (tract already dispatches NEON kernels at runtime). Not used.

## 10. UI

MenuBarExtra (`.window` style), no Dock icon (`LSUIElement`).
- Header: **big on/off toggle** (off = tap destroyed) + status ("Aktiv · Chrome", "Wartet auf Audio", "Keine Berechtigung", "Neu verbinden…").
- **A/B segmented control "Original | LectureLift"** (20 ms crossfade, time-aligned dry).
- Preset picker: **Aus / Nur Klarheit (EQ + De-Esser + Leveler) / Hörsaal / Audimax / Custom** (+ Seminarraum as a room size). Moving any slider switches to Custom.
- Sliders: Entrauschen (Aus · 0–24 dB, switching on = Qualität mode, with a CPU/latency hint), Raumgröße (Seminarraum/Hörsaal/Audimax), Hall-Anteil, Distanz, Präsenz. "Erweitert" disclosure: per-stage bypass toggles, de-esser max reduction, HF damping, pre-delay, mono fold, user IR file.
- Captured apps: checklist of running audio processes grouped by app (defaults: Chrome, Safari, Arc, Firefox if installed).
- Meters: input/output peak bars, CPU %, measured latency, denoiser-overload indicator.
- Settings: global shortcut (default ⌃⌥H, `RegisterEventHotKey`, needs no Accessibility permission), "Bei Anmeldung starten" (`SMAppService.mainApp`), language follows the system (de default, en), Low-Power behaviour.
- Persistence: `@AppStorage`/`UserDefaults`, one Codable `ChainSettings` blob + version key.
- While a session is active: `ProcessInfo.beginActivity(.userInitiated)` so App Nap doesn't throttle the lifecycle/watchdog queues. Optional: a loudness-matched A/B (Original gain-matched to the processed level), so the comparison isn't biased by level.
- Strings: `Localizable.xcstrings`, source language **de**, en translation.

## 11. Language independence (addendum)

### 11.1 Rules
- One chain and one set of defaults; no language detection, no per-language presets. Every level-dependent detector works on **ratios or K-weighted loudness**, never on absolute thresholds tuned to one language's spectrum.

### 11.2 Model language check (from PRIOR_ART §3)
DFN3: multilingual DNS4 incl. 874 German talkers, low risk. RNNoise: no German training data, so it's conditional. DPDFNet: rejected (English-weighted, CPU).

### 11.3 Test corpus and listening tests
- **Corpus:** openly licensed only, ~20 clips per language, 10–30 s each. Sources: Mozilla Common Voice `de`/`en` (CC0); LibriVox public-domain recordings in German and English. Plus a **fricative/plosive set**: sentences dense in "sch, ch, s, z, pf, t, k" (de) and "s, sh, th, f, t, k" (en). Clips are stored with source URL + license in `TestCorpus/MANIFEST.csv`. Audio is fetched by `scripts/fetch_corpus.sh` (pinned URLs + SHA-256), not committed.
- **Zoom-like simulation** (`scripts/make_zoomlike.py`, documented in `TestCorpus/ZOOMLIKE.md`; deterministic seeds; dev-only Python 3 + numpy/scipy, nothing shipped). Each clean clip gets these variants:
  1. **Band-limit:** resample to 16 kHz and back (wideband call) and 7 kHz low-pass at 48 kHz (super-wideband Zoom), both 8th-order Butterworth.
  2. **Codec-like artifacts:** Opus at 16 and 24 kb/s VBR via `opusenc`/`opusdec` (libopus, BSD) when installed. Fallback: MDCT-domain coarse quantisation with spectral-hole filling (≈ "metallic/underwater"). 1 % simulated packet loss with PLC on one variant.
  3. **Aggressive noise suppression:** add room/fan noise (DEMAND-style synthetic noise, seeded) at 15 dB SNR, then a spectral-subtraction suppressor with over-subtraction α = 3 and floor −30 dB, producing musical noise and clipped word onsets the way Zoom/Teams NS does.
  4. **Level swings:** a slow gain random walk of ±8 dB (0.05–0.3 Hz) plus a fast-attack AGC pump on onsets.
  The full chain is `clean → noise → NS → band-limit → codec → level swings`, plus single-factor variants for diagnosis.
- **Repo contents:** only scripts, `TestCorpus/MANIFEST.csv` (source URL, license, SHA-256, language, speaker sex, duration) and generation docs. Audio lives in `TestCorpus/.cache/` (git-ignored) and is produced by `scripts/fetch_corpus.sh` + `make_zoomlike.py`.
- **Objective checks (automated in M6):** per clip and language, the HF energy ratio (4–10 kHz) before and after the denoiser and after the de-esser. Fricative onsets must not lose more than 3 dB more than vowels (detects "smearing/cutting"). A loudness target of ±1 LU is checked for both languages.
- **Listening test (M4 gate):** A/B with `lecturelift-render` on the German and English fricative sets for DFN3 at 8 and 16 dB and RNNoise. RNNoise is dropped if it audibly smears German fricatives or the objective check fails.

### 11.4 Bilingual evaluation (M6)
- `scripts/eval.sh` runs `lecturelift-render` over **the full corpus × every preset** (Aus, Nur Klarheit, Hörsaal, Audimax, Seminarraum, + Qualität variants) and writes `eval/results.csv` + `eval/REPORT.md`.
- **Reported per language** (mean, spread, and per-preset table):
  - CPU / real-time factor (from `--bench`);
  - integrated loudness (BS.1770 LUFS) before and after;
  - **non-intrusive quality score:** DNSMOS P.835 (SIG/BAK/OVRL), *if its license permits use*. To be checked at M6 start: the DNSMOS ONNX models ship in microsoft/DNS-Challenge, so the license must be confirmed for that path. Alternative with a known-compatible license: TorchAudio-SQUIM objective (BSD-2). NISQA weights are non-commercial, so it is excluded. The metric is dev-only and never shipped.
- **Flag rule:** a preset is flagged if the de–en difference of the per-language *change* (processed − original) exceeds **0.15 MOS** or **1 LU**, or the fricative-onset loss differs by more than **1.5 dB**. Flags go into REPORT.md, and the bilingual results go to Fable in the M6 review.
- **Listening pairs:** `eval/listening/<lang>/<clip>__<preset>__{A_original,B_processed}.wav` (loudness-matched, 10–20 s, ~6 clips per language), git-ignored, regenerated by `eval.sh`.

### 11.5 UI strings
All UI text, tooltips (`.help`), onboarding, permission and error messages live in `Localizable.xcstrings` with **de (source) + en**. A unit test fails if any key lacks either language.

## 12. Clean-room and licensing rules
- Implementation sources: Apple documentation and headers, AudioCap (BSD-2), FFTConvolver (MIT), libDF (MIT/Apache), RNNoise (BSD-3), catap/eqtune docs (MIT/Apache).
- FineTune (GPL-3) contributes only the behaviour list in §4.4/§4.5, written in our own words. While coding, its source is not open. No identifiers, comments, constants or control flow are reused. Timing constants are derived from our own measurements.
- GPL/AGPL code (FineTune, Radioform, SystemEQ, curve, the werman RNNoise wrapper) never enters the tree. audiotee (no LICENSE file) is used for ideas only.
- `THIRD_PARTY_NOTICES.md` lists AudioCap, FFTConvolver, libDF + **all its Rust crate dependencies** (generated with `cargo about` at build time), DFN3 weights, RNNoise, and the corpus sources (tests only).

## 13. Tests
- **Unit (HSCore):** biquad coefficients against reference values (RBJ, double-precision oracle); de-esser static curve; leveler steady-state reaching −18 ±1 LUFS on pink noise and speech; limiter ceiling never exceeded (true sample) on adversarial input.
- **IR generator:** RT60 within ±10 % (Schroeder/T30) per preset and rate; determinism (same seed → same IR).
- **Convolver:** TwoStage (with worker) against naive direct convolution for a 2048-tap IR, error < −100 dB, block sizes 1…1024 including odd sizes.
- **Null test:** everything bypassed and denoiser off → bit-identical; A/B "Original" → equals the delayed input exactly.
- **Latency:** impulse through `lecturelift-render --impulse` per mode equals `latencySamples()`.
- **RT safety:** the full chain under `RTGuard` (malloc/lock interposer) for 60 s of input with parameter automation and IR swaps.
- **Benchmark:** `lecturelift-render --bench` reports the real-time factor per stage and in total, Standard and Qualität, as JSON.
- **HSAudio:** state-machine tests with a fake HAL (event sequences: sleep during device switch, service restart during idle, …).
- **Manual (documented checklists):** `kill -9` mute release; AirPods connect/disconnect; sleep/wake with playback; Chrome restart; Safari; permission revoked.

## 14. Milestones and acceptance criteria

| | Deliverable | Done when |
|---|---|---|
| **M1** | SwiftPM skeleton, `HSCore` passthrough, `TapManager`, `ProcessResolver`, `SessionController`, watchdog, sleep/wake + device change + service restart + idle, minimal menu (on/off) | Chrome & Safari audio passes through with the original muted; **verified**: `kill -9` behaviour (Plan A/B decided), bundle-ID tap coverage, live tap-description update, measured app latency, device switch to AirPods and back, sleep/wake. Fable review. |
| **M2** | HPF, EQ, de-esser, leveler, limiter, param atomics, per-stage bypass, CLI renderer v1 | unit tests green, renders of the de/en corpus, bench < 1 % for M2 stages. Fable review. |
| **M3** | IR generator, convolver + tail worker, reverb stage, presets | RT60 tests, convolver correctness, bench Standard ≤ 5 % total. Fable review **before** starting (convolver) + after. |
| **M4** | DFN3 + (conditional) RNNoise, worker, rings, fallback, Qualität mode | ≤ 12 % (60 s mean) / ≤ 80 ms measured; **0 xruns** in a 10-min live run with Qualität on (browser lecture playback); German listening test done; RNNoise kept or removed. Fable review. |
| **M5** | Full UI, A/B, meters, presets, persistence, hotkey, login item, de/en strings, onboarding | manual checklist. Fable review. |
| **M6** | Tests complete, bench, corpus scripts + Zoom-like simulation, bilingual evaluation (§11.4) + listening pairs, `build.sh` → .app + DMG, README, LICENSE (MIT), THIRD_PARTY_NOTICES | one-command build from a clean clone; REPORT.md with per-language results and flags. Fable review incl. bilingual results. |

## 15. Open items to verify in M1 (not assumed)
1. ~~Mute release on SIGKILL~~ → verified, Plan A (D-007).
2. `bundleIDs` taps on macOS 26+: coverage of Chromium helpers and WebKit.GPU.
3. `kAudioTapPropertyDescription` live update while the aggregate is running.
4. Whether the aggregate accepts a 256-frame buffer with an AirPods clock device.
5. Real tap-path latency (§9.1).
6. ~~Whether another process can see our private tap/aggregate~~ → it can't; Plan B is moot (D-007).
7. Whether the tap delivers the browser's audio before or after the browser's own output-device selection (Chrome can route to a non-default device; then we must follow that device, or the feature is limited to the default output).
