# Prior-Art Survey — LectureLift

> **Naming note:** developed under the working title *Hörsaal* (German for "lecture hall"); published as **LectureLift**. Preset IDs were renamed to English for publication: `aus→off`, `klarheit→clarity`, `seminarraum→seminar`, `hoersaal→hall`, `audimax→auditorium`; the German UI labels are unchanged.


Status: Phase 0 complete, reviewed by Fable (D-001 in DECISIONS.md), **awaiting owner decision on the base** (see §6).
Date: 2026-11-16. Survey machine: macOS 27.2 (26B123), Apple Silicon, Xcode 27.1, no Rust toolchain installed.

Method: every repository below was cloned (into a local folder outside the repo) and the audio path read
directly. Repo metadata comes from the GitHub API on the survey date. Claims I could not verify in code
are marked *(unverified)*.

---

## 1. Comparison table — capture / host candidates

| Repo | License | Activity (survey date) | Min macOS | Topology | RT-safety of audio path | Lifecycle (teardown / device change / sleep-wake / crash) | Covers of our reqs |
|---|---|---|---|---|---|---|---|
| **ronitsingh10/FineTune** | GPL-3.0 | 10.2k★, 247 open issues, 15 authors in last 300 commits, last push 2026-07-09 (4 months quiet) | **15.4** (pbxproj `MACOSX_DEPLOYMENT_TARGET = 15.4`) | **One private aggregate = output device(s) as clock subdevice + tap** in `TapList`; one IOProc reads tap input and writes output in the same callback. Correct, single clock, minimal latency. | Mostly good: no locks/allocs/logging in `processAudioCallback`, vDSP biquads, swap-and-defer-free for DSP objects. **Violations:** IOProc block captures `[weak self]` (weak load = atomic refcount traffic every cycle); copies class references (`EQProcessor?`, `LoudnessEqualizer?` …) into locals → retain/release on RT thread; "atomic swap" of Swift class refs via `nonisolated(unsafe)` is a formal data race. All fixable. | Strongest of all candidates: crossfaded device switch, `DeviceIsAlive` listeners, BT sample-rate change → aggregate recreate, periodic health check that recreates silent taps, `CrashGuard` signal handler destroys aggregates (but: calls HAL IPC from a signal handler, which is not async-signal-safe; no alt stack; only ABRT/SEGV/BUS/TRAP, `CrashGuard.swift:32,58-61`), `OrphanedTapCleanup` at next launch (its own comment, L8-9: a crash or `kill -9` leaves aggregates that **keep apps muted**). **No sleep/wake or coreaudiod-restart handling in the audio engine**; `NSWorkspace` sleep/wake only appears in `MediaKeyMonitor.swift:160-162`. The health check has a 5 s eligibility floor (`AudioEngine.swift:1905`), so recovery takes seconds. Open issues show residual edge cases (#369 stays muted, #273 "blast of full volume", #375 stranded taps after monitor wake). | Tap lifecycle ✅, per-app capture ✅, mute ✅, EQ ✅, loudness leveler ✅ (K-weighted), soft limiter ✅, menu-bar UI ✅. Missing: convolution reverb, denoiser, de-esser, HPF stage, latency meter, offline renderer, DE localisation. ~41.6k LOC incl. tests, most of it unrelated (DDC monitor volume, AutoEQ, HUD, media keys, multi-device routing). |
| **loganrooks/tap-n-filter** (now **rookslog/tap-n-filter**, redirect) | MIT | 0★, 10 open issues, effectively 1 author, created 2026-05-21, alpha.2 on 2026-11-13 | 14.4 | **Tap-only aggregate (empty SubDeviceList)** → IOProc → ring buffer → **separate `AVAudioEngine`** (source node / manual-rendering Apple AUs) on the default output. Two independent clocks → drift, extra buffering latency, no shared clock. | **Ring buffer guarded by `OSAllocatedUnfairLock`** (own CHANGELOG: "a genuinely lock-free implementation is deferred"). Logging-heavy init. DSP = Apple AUs (`AVAudioUnitEQ`, `AVAudioUnitReverb` factory presets) via manual rendering. | No sleep/wake or service-restart handling found; output-device follow via `AVAudioEngineConfigurationChange`. Tap uses `mutedWhenTapped`, `isPrivate`. | Per-app capture ✅, menu bar ✅, effect chain concept ✅. Reverb is **algorithmic factory preset, not convolution**. 70.9k LOC incl. ~25k lines of agent-orchestration docs. Two parallel DSP stacks (`Graph/Effects` vs `PlaybackDSP/FixedRender`). |
| **insidegui/AudioCap** | BSD-2-Clause | 513★, last push 2025-08 | 14.4 | Output-device subdevice + tap in one aggregate, `AudioDeviceCreateIOProcIDWithBlock`; ~270-line `ProcessTap.swift`. | Sample code, writes to file; not an effect host. | Clean `invalidate()` order: stop → destroy IOProc → destroy aggregate → destroy tap. No device-change/sleep handling. | Reference only (the canonical pattern). |
| **makeusabrew/audiotee** | MIT (stated in README, **no LICENSE file**) | 93★, last push 2026-03 | 14.2 | Tap-only aggregate → stdout. | CLI, not RT-critical. | Basic. | `TapConfiguration` (mute/exclusive/mono) is a tidy API idea. |
| **obsfx/audiograb** | MIT | 1★, 7 commits, Feb 2026 | 14.4 | System tap + private aggregate + IOProc → file. | — | Minimal. | Ideas only. |
| **sbetko/catap** (Python + C) | MIT | 1★, 1 author, active (2026-11-04), extensive tests | 14.4 (bundle-ID taps 26+) | Tap-only aggregate; native C IOProc + ring. | C IOProc fine. | **Best documentation of edge cases** (`docs/core-audio-notes.md` in the catap repo): permission missing ⇒ HAL delivers *zeroed buffers, no error*; `kAudioTapPropertyDescription` is settable on a live tap (change process list without recreating); `CATapDescription.bundleIDs` + `processRestoreEnabled` (macOS 26+, default true) re-attach a tap when the app restarts; non-mixdown global tap "succeeds" with ID 0. States it does not *reconnect* after sleep/wake (`core-audio-notes.md:40`); whether the tap itself dies is not stated. | Facts to design around. |
| **eqtune** (crates.io 0.7.1, repo `y7nieSEl5/eqtune`) | Apache-2.0 | 1★, last push 2026-09 | 14.2 | Global tap (excluding self) + output subdevice in one aggregate. | Rust + ObjC shim *(audio path not read in depth)*. | Retry/backoff recovery, 10 ms bypass crossfade. **Idle auto-off: tears the engine down while captured audio is silent, restarts on output activity; Low-Power-Mode auto-off.** Its README warns a permanently running aggregate costs noticeable battery even when DSP is idle. | Power-management idea we adopt. |

### Driver-based EQ apps (UI/DSP ideas only — they need a virtual driver, which we exclude)

| Repo | License | Note |
|---|---|---|
| bitgapp/eqMac | Apache-2.0 (GitHub API) | Own HAL driver. Mature UI, nothing reusable for the tap path. |
| SystemEQ for Mac (denzam) | GPL-3.0 | Uses BlackHole. Excluded. |
| SoundMaxx (brimell) / SoundMax (snap-sites) | unclear / MIT | Driver/loopback based *(unverified)*. Ideas only. |
| Torteous44/radioform | GPL-3.0 | Driver-based EQ. Ideas only. |
| tomderham/curve | **AGPL-3.0** | Menu-bar AU host. AGPL ⇒ do not copy code under any license choice except AGPL. |
| jeremicna/AudioFlow | none | Has a convolution reverb, but uses BlackHole and has no license. Unusable. |

## 2. DSP building blocks

| Component | License | Verdict |
|---|---|---|
| **HiFi-LoFi/FFTConvolver** (C++) | **MIT** (header verified; search snippets claiming GPL refer to an older shairport-sync copy) | Uniform-partitioned `FFTConvolver` + non-uniform `TwoStageFFTConvolver` (small head block for low latency, large tail block; has hooks to move tail work to a background thread). All allocation in `init()`; `process()` allocation-free. **But** `TwoStageFFTConvolver` runs the tail convolution synchronously by default (`TwoStageFFTConvolver.cpp` `startBackgroundProcessing`/`waitForBackgroundProcessing` are virtual hooks). We must subclass to move the tail to a worker thread, or tail blocks cause periodic CPU spikes on the I/O thread. `AudioFFT` has an `AUDIOFFT_APPLE_ACCELERATE` vDSP backend. 376★, stable (last push 2023). **Vendor this.** |
| `fft-convolver` (Rust port) | MIT | Not needed if we vendor the C++ original. |
| FineTune `BiquadMath`, `LoudnessEqualizer`, `SoftLimiter` | GPL-3.0 | Good designs; reusable only if we go GPL. |
| RBJ Audio-EQ-Cookbook formulas | public domain-like (formulas) | Write our own biquads with `vDSP_biquad` either way (~150 LOC). |
| ITU-R BS.1770 K-weighting / EBU R128 | spec | Implement directly for the −18 LUFS leveler (no GPL needed). |

## 3. Speech enhancement candidates (incl. language-bias check)

Requirement: same chain for German and English lectures; reject anything English-only or measurably worse on German.

| Model | License (code / weights) | Training speech languages | German risk | Latency | Cost | Verdict |
|---|---|---|---|---|---|---|
| **DeepFilterNet3** (Rikorose, libDF) | MIT/Apache-2.0; **weights explicitly dual-licensed too** (README commit 7b14b89, 2026-11-06) | **Full multilingual DNS4** + PTDB/VCTK ×10 oversampled (DFN3 paper, arXiv 2305.08227 §3). DNS4 personalised clean speech: **874 German talkers** (largest non-English set; ~319 GB `german_speech`), plus fr/es/it/ru and English. | Low on paper — German is well represented. Must still be **listened to** on German fricatives (sch/ch/s/z/pf) in M4. | `fft_size=960, hop=480 @48 kHz`, `conv_lookahead=2, df_lookahead=2` ⇒ **40 ms** algorithmic (paper). | Paper: single-thread RTF **0.19 on i5-8250U**. On an M1 P-core expect roughly 0.06–0.10 ⇒ **6–10 % of a core: above our 5 % total budget** *(estimate, must measure)*. | **Primary choice.** Default OFF / mild limit, as specified. |
| DeepFilterNet3 **LL** (`DeepFilterNet3_ll_onnx`) | same | same | same | lookahead 0/0 ⇒ ~20 ms | `emb_hidden_dim=512` (vs 256), ONNX ≈ 39 MB vs 8.6 MB ⇒ clearly more CPU. | Fallback if the 60 ms budget breaks *and* CPU allows. Probably not. |
| **DeepFilterNet Plus** (ismailivanov) | MIT/Apache-2.0 | same weights as DFN3 | same | same | Fork commit "libDF: remove per-frame heap allocations from the RT path" (2026-08-14), tract ≥0.21.5 stereo fix, non-blocking LADSPA. Upstream `tract.rs::process` still clones tensors / `Vec`s per frame. | **Build libDF from this fork (pinned commit)** rather than upstream. We still run it on its own thread. |
| DPDFNet (Ceva) / HushMic | Apache-2.0 | DNS4 *downsampled to wideband* **+ 4000 h English MLS** (DPDFNet paper) — English-weighted. | Medium: extra data is English-only; no German evaluation published. | 10 ms hop, window latency | `dpdfnet2_48khz_hr` **2.42 GMACs**, ~7× DFN3 (~0.35 GMACs) | **Reject**: CPU budget, and English-weighted training. |
| **RNNoise 0.2** (xiph, BSD-3 core) | BSD-3-Clause (code + shipped model) | `datasets.txt`: ~30 openslr corpora (en accents, es, ca, eu, gl, Indic, African langs) + Hi-Fi TTS (en). **No German.** | Unknown. Its 22-band energy features are coarse and language-agnostic by design, but German sibilant energy above ~8 kHz is not specifically represented. | 10 ms frame, ~0 lookahead | ~1–2 % of a core *(typical, measure)* | Keep as the specified ultra-light fallback; **gate on a German listening test**. Use the BSD core directly, **not** werman/noise-suppression-for-voice (GPL-3 wrapper). |
| werman/noise-suppression-for-voice | GPL-3.0 | = RNNoise | — | — | — | Not used (wrapper only). |

**DFN integration route (preliminary, final call in DESIGN.md):**
- *libDF C API* (`capi` feature → `df_create`, `df_set_atten_lim`, `df_process_frame`): STFT, ERB features, deep filtering and post-filter all included; one static lib (tract inference, pure Rust, no extra runtime). Needs Rust in `scripts/build_libdf.sh` (rustup, pinned toolchain). Not RT-safe ⇒ dedicated thread + SPSC rings either way.
- *ONNX Runtime + DFN3 ONNX*: would require re-implementing the STFT/ERB/deep-filter DSP around three ONNX graphs in Swift plus a ~25 MB runtime dependency. More code, more risk, no benefit.
- ⇒ **libDF C API from DeepFilterNet Plus, pinned.**

## 4. What we reuse from each (if option (b) is chosen)

| Source | How |
|---|---|
| AudioCap (BSD-2) | Pattern + small code fragments for tap → aggregate → IOProc and teardown order (attribution in THIRD_PARTY_NOTICES). |
| FFTConvolver (MIT) | Vendored source for the reverb (`TwoStageFFTConvolver`, vDSP backend). |
| DeepFilterNet Plus libDF (MIT/Apache) + DFN3 weights | Static lib + bundled model tarball. |
| RNNoise core (BSD-3) | Vendored C, built in Xcode. |
| catap (MIT), eqtune (Apache-2.0) | Documented behaviours: permission ⇒ zeroed buffers, live tap-description update, bundle-ID taps with process restore, idle auto-off, Low-Power-Mode handling. Code may be adapted with attribution if useful. |
| FineTune (GPL-3) | **Ideas only, no code**: which events need handling (DeviceIsAlive, BT rate change, health check, crash-signal aggregate cleanup, orphan cleanup, crossfaded switch). We describe behaviours in our own words in DESIGN.md and write new code. |
| tap-n-filter (MIT) | Nothing structural. Possibly the HFP/Bluetooth input-guard observation (ADR-019) as a documented edge case. |

## 5. Options

### (a) Fork FineTune and extend it
- **Gain:** the most battle-tested tap lifecycle available, a working leveler/limiter/EQ, a polished menu-bar UI, 10k users who have hit edge cases already.
- **Cost:** the whole project becomes **GPL-3.0**, and so must every vendored piece (all ours are GPL-compatible, so legally fine). Minimum **macOS 15.4**. We carry ~30k LOC of unrelated features or delete them (deleting them makes upstream merges impossible anyway). The architecture is "one tap per app, per-app volume". Our 6-stage chain with a denoiser thread and a convolver doesn't fit `processMappedBuffers` (interleaved, in-place, synchronous). We would restructure the core callback, and that is where upstream changes land, so "mergeable with upstream" would hold only nominally. The RT-safety fixes listed in §1 are still needed. The upstream maintainer has been quiet for 4 months with 247 open issues.

### (b) Start fresh (MIT) and vendor specific permissive modules  ← **recommended**
- **Gain:** permissive license; a codebase sized to the product (expected ~6–8k LOC); RT-safety designed in from the start (C/C++ render core, no Swift objects on the I/O thread); min macOS 14.4, with macOS 26+ bundle-ID taps when available. The parts that need the most work have no prior implementation in any candidate anyway: convolution reverb, synthetic IRs, DFN thread, de-esser, latency measurement, offline renderer.
- **Cost / risk:** we have to re-earn the tap-lifecycle robustness FineTune already has. Mitigation: the behaviour list in §4, catap's empirical notes, a watchdog with fail-safe unmute. Stopping the IOProc / destroying our aggregate+tap is expected to release `mutedWhenTapped` (*unverified*, test it), but a **crash or SIGKILL can leave the browser muted** (FineTune `OrphanedTapCleanup.swift:8-9`). So we need a uniquely named aggregate, a launch-time orphan sweep, and probably a tiny out-of-process watchdog (LaunchAgent/XPC helper) that destroys our aggregates when the app dies, and explicit sleep/wake + service-restart handlers from day 1. Clean-room discipline (operational): the behaviour spec is written first in DESIGN.md in our own words; FineTune stays closed while coding; no identifiers, comments, constants or control flow are reused, and its magic numbers (0.5 s deferred free, 40 ms gate ramp, 200 ms hold) are re-derived from our own measurements. Implementation sources are recorded as Apple documentation + AudioCap (BSD-2). audiotee has no LICENSE file, so it is used for ideas only. Keeping the DSP core as separate MIT C/C++ preserves later relicensing options.

### (c) Start fresh without vendoring
No reason to. FFTConvolver, libDF and RNNoise are exactly the "don't reinvent" parts.

## 6. Recommendation

**(b) Start fresh under MIT and vendor AudioCap patterns (BSD-2), FFTConvolver (MIT), libDF from DeepFilterNet Plus (MIT/Apache) and the RNNoise core (BSD-3). Use FineTune as a behavioural reference only.**

Reasoning, briefly: the only part a fork really buys is FineTune's tap lifecycle, roughly 3k of its 41k LOC. That alone doesn't justify GPL-3, a 15.4 floor and a 30k-LOC unrelated app. Everything else we need (reverb, denoiser, de-esser, offline renderer, latency metering) is new work in every option. tap-n-filter is permissive but architecturally weaker than what we need: a two-clock output, a lock in the ring buffer, and no convolution.

**License impact:** project = MIT. All dependencies are MIT, Apache-2.0, BSD-2 or BSD-3, and the DFN3 weights are MIT/Apache. IRs are generated in-house. GPL/AGPL code (FineTune, Radioform, curve, werman wrapper) must not enter the tree.

**Main risks (ranked after Fable review, carried into DESIGN.md):**
1. **DFN3 vs. the budgets: this needs a decision, not a mitigation.** At an estimated 6–10 % of a core it breaks the 5 % total alone. Latency: 40 ms lookahead + 10 ms framing + thread hand-off + I/O buffers comes out **above** 60 ms, not at it. Options: (i) explicitly relax the budget in denoiser-on mode only (e.g. ≤12 % CPU, ≤80 ms), or (ii) RNNoise as the in-budget denoiser and DFN3 as an opt-in "quality" mode. Either way: a 1–2 day **spike before DESIGN.md is final** (libDF from DeepFilterNet Plus on this Mac: RTF + end-to-end latency).
2. **Stuck mute after a crash, hang or SIGKILL.** Orphan sweep + out-of-process watchdog; verify mute release with `kill -9` on macOS 14.4, 15 and 26+.
3. **Sleep/wake and coreaudiod restart**: no candidate solves these. We build explicit handlers (`NSWorkspace` will/didSleep, `kAudioHardwarePropertyServiceRestarted`, `DeviceIsAlive`).
4. **Browser helper coverage.** Chrome/Arc/Firefox render audio in helper processes. On 14.4–15 grouping needs the private `responsibility_get_pid_responsible_for_pid` (via `dlsym`) plus a parent-PID walk, which is a notarisation/behaviour risk. On 26+, check whether a `bundleIDs` tap really covers Chromium helpers, whose bundle IDs differ from the main app. Update the tap description live (settable property) when helpers spawn.
5. **Tail-convolution CPU spikes** unless the FFTConvolver tail runs on a worker thread.
6. **German sibilants with RNNoise** (no German training data); DFN3 also gets a German fricative listening check.
7. Smaller items: a missing permission produces silent buffers, not an error; device rate ≠ 48 kHz needs SRC around the denoiser; mono fold before the denoiser; the browser's own output-device selection; DRM/AirPlay outputs.

## 7. Sources
- Repos as listed (cloned 2026-11-16). FineTune: `FineTune/Audio/Engine/ProcessTapController.swift` (aggregate plan L322–413, IOProc L663, callback L1491–1642), `CrashGuard.swift`, `AudioEngine.swift` (device handling L1337–2000). tap-n-filter: `Sources/Capture/TapIOProcReader.swift`, `CHANGELOG.md`, `Sources/FixedRender/FixedRender.mm`. libDF: `libDF/src/capi.rs`, `libDF/src/tract.rs`.
- DFN3 paper: <https://arxiv.org/abs/2305.08227> (training data, 40 ms latency, RTF 0.19).
- ICASSP 2022 DNS Challenge (DNS4) talker counts: <https://arxiv.org/abs/2202.13288>.
- DPDFNet: <https://arxiv.org/abs/2512.16420>, <https://github.com/ceva-ip/DPDFNet>.
- DeepFilterNet Plus: <https://github.com/ismailivanov/DeepFilterNetPlus> (its `docs/DEVELOPER_GUIDE.md#plus-fork-changes`).
- RNNoise datasets: `xiph/rnnoise/datasets.txt`.
- FFTConvolver: <https://github.com/HiFi-LoFi/FFTConvolver>.
- eqtune: <https://docs.rs/crate/eqtune/0.5.0>, <https://github.com/y7nieSEl5/eqtune>.
