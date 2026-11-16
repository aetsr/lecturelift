# Diagnosis of the first real lecture clip + improvement options (D-018)

Clip: `a 60 s clip (`eval/real/clip1.wav`, not in the repo)` (60 s, raw tap input from a Moodle lecture, not in git).
Tool: `python3 -I scripts/analyze_clip.py CLIP [REFERENCE]`. The tonality reference is our clean
German TTS speech (`build/renders/de.stereo.wav`), cross-checked against the typical long-term speech
spectrum (international LTASS, Byrne et al. 1994: about −5 dB at 2 kHz, −9 dB at 3.15 kHz and −10 dB at
4 kHz relative to 1 kHz). Neither reference is the speaker's real voice, so read differences of a few dB
as tendencies, and the large ones (≥ 6 dB) as findings.

## Measurements

| Aspect | Measured | Meaning |
|---|---|---|
| Channels | L/R correlation 1.000 | mono recording |
| Bandwidth | effective cutoff ≈ **12 kHz**, 42 dB brick-wall drop | codec/resampler low-pass (typical of AAC/Opus at a reduced rate); no content above 12 kHz |
| Noise | speech/pause SNR **62 dB** (an upper bound by construction: "pause" = the quietest frames), pause floor **−84 dBFS** | a 66 dB speech-to-floor range is impossible for an unprocessed room → **heavily noise-suppressed/gated** source. The 12 kHz brick wall matches Opus super-wideband → probably WebRTC with browser NS + AGC (AGC pumping not yet tested) |
| Codec "holes" | 2.6 % of bins (reference 2.8 %) | **metric invalid**: it measures the valleys between voice harmonics, not codec holes (Fable, D-019) |
| Room in recording | decay after speech offsets ≈ 125 dB/s | ~~dry, close-miked~~ **undetermined**: the metric is invalid (triggers only near −47 dBFS, smeared by the 43 ms window; the reference gives a nonsensical −73 dB/s). 125 dB/s would actually mean RT60 ≈ 0.5 s, i.e. *not* dry (Fable, D-019) |
| Dynamics | 3 s level range (10–95 pct) **7 dB**, crest 17.8 dB, no clipping | moderate swings; the leveler handles this |
| Low end | < 80 Hz share −30 dB, no hum | fine |
| **Tonality** | vs LTASS (Byrne 1994): **−7.5 dB at 2 kHz, −12 dB at 3.15 kHz, −9.5 dB at 4 kHz**; low end a broad **+4…+6 dB** (the TTS comparison's +10 dB zigzag below 300 Hz is the lecturer's F0 harmonics against a different voice; rows ≥ 10 kHz are invalid because the TTS stops at 10.3 kHz) | **clearly lacking presence, somewhat boomy** (corrected after Fable's review, D-019) |

## What is actually wrong, in plain words

1. **The voice is muffled and somewhat boomy.** Compared with normal speech there is roughly 8–12 dB too little energy
   in 2–4 kHz (where consonants and "presence" live) and a broad 4–6 dB too much below ~300 Hz. **This is the
   biggest measurable problem.** Our current EQ corrects only a fraction: −3 dB at 300 Hz and +2.5 dB at
   3 kHz. That's why Klarheit is better but not "wow".
2. **The pauses are dead.** Noise suppression has removed all room tone; between words the signal drops
   to almost silence. Real rooms are never that quiet. This, more than anything else, makes the result
   sound "processed".
3. **No "air"** above 12 kHz (codec low-pass). That matters less for intelligibility than (1), but it
   adds to the "telephone-ish" impression.
4. **In-head sound on headphones** (whether the recording itself already carries room is undetermined). A mono, close-miked voice on AirPods is localised inside the head.
   A plain stereo reverb tail doesn't fix that; it adds a cloud around a voice that is still in the head.
   That's probably why every room version sounded worse.
5. Codec artifacts and the level swings are minor in this clip.

**Can fix:** (1) tonality (fully, with EQ: the information below 12 kHz is still there), (2) dead pauses
(by adding a natural room tone), (4) in-head localisation on headphones (binaural rendering).
**Partly:** (3) air (synthetic HF can add brightness, not real detail).
**Cannot fix:** content destroyed by the codec or by noise suppression (smeared consonants, missing
>12 kHz detail): that would need generative restoration, which is out of scope for real time.

## Options (proposals, nothing implemented)

| # | Option | Expected effect on this clip | CPU (M1 core) | Latency | Real time |
|---|---|---|---|---|---|
| A | **Adaptive corrective EQ**: measure the incoming long-term speech spectrum (K-weighted, speech-gated, τ ≈ 20 s) and steer a 1/3-octave EQ toward a target speech curve, limited ±9 dB and smoothed in time and frequency | **High**: directly fixes problem 1, and adapts per lecturer/mic | ≈ 0.3–0.6 % | 0 (minimum-phase biquads) | yes |
| A0 | Static "laptop mic" EQ preset (+6 dB broad 2–4 kHz, −4…−6 dB shelf below 250 Hz) | High for this clip, can be wrong for others | ≈ 0.1 % | 0 | yes |
| B | Multiband compressor / dynamic EQ (3–4 bands) | Medium: steadier presence and less boom on loud words | ≈ 0.3 % | 0–1.5 ms | yes |
| C | **Room tone**: a very quiet, natural lecture-hall ambience (synthetic, decorrelated stereo, −45…−55 dB re speech) that fills the gated pauses | **Medium–high for the "live" feel**; risk: perceived as noise if too loud | ≈ 0.05 % | 0 | yes |
| D | **Binaural externalisation for headphones**: render the voice as a source ~5–7 m in front, with HRTF-filtered early reflections and a binaural tail. Two routes: (D1) Apple's `AUSpatialMixer` (HRTF-HQ, no licence issue, possibly personalised Spatial Audio), (D2) our own spherical-head HRTF plus the image-source reflections rendered binaurally | Potentially **large** for "being in the room" on AirPods; no benefit on speakers (needs headphone detection) | D1 ≈ 1–2 %? (to measure); D2 ≈ 0.5–1 % | D1 a few ms; D2 0 | yes (D1: AU render inside the IOProc, configured before start) |
| E | Lightweight bandwidth extension / exciter (synthesise 12–16 kHz "air" from 6–12 kHz) | Low–medium: brighter, more "open"; risk of hiss/sibilance | ≈ 0.1–0.2 % | 0 | yes |
| F | Neural codec/NS-artifact restoration | Could help consonant smearing; no permissively licensed, lightweight real-time model known to me; heavy generative models are out of scope | ≫ budget | ≫ 80 ms | no (offline research only) |
| G | Early-reflections-only room (no long tail), possibly binaural (with D) | Medium: "distance" without the washed-out tail | ≈ 0.1 % | 0 | yes |
| H | DeepFilterNet3 | Low on this clip: the input is already over-cleaned (SNR 62 dB) | ≈ 9 % | +60 ms | yes |

**My recommendation (pending Fable's review):** A first (biggest measurable gain), then C (live feel),
then D1 as an experiment for headphones (largest potential, needs a listening test), optionally E. Keep
the reverb tail low or replace it with G. Keep H off by default for already-cleaned recordings.

## Fable's review (D-019), summary

- Measurements reproduce. Corrections are applied above: low end only +4…+6 dB (shelf); offset-decay and hole metrics invalid; 1 kHz single-band normalisation fragile (use 500 Hz–2 kHz); report 25th/50th percentiles of non-speech frames; add comb-filter (cepstrum) and AGC-pumping checks. **Our Klarheit 8 kHz shelf (0.6 × presence) actually cuts a band that is already 5–9 dB low.**
- Why the rooms failed, additionally: the tail was fed by a 100–600 Hz-heavy spectrum (mud masks the weak consonants); possibly a double room; voice in head + room outside. The test was confounded by the wrong tonality, so it must be repeated after A.
- **A (adaptive EQ): right first step**, with changes: unweighted, feed-forward (pre-EQ) measurement; ≥ 1-octave smoothing, only a shelf below 300 Hz; correct ~60–70 % of the deviation; limit +8 dB (2–5 kHz) / +4 dB (> 6 kHz), nothing above the detected cutoff; cap each band's boost by its speech/pause SNR; converge fast (3–5 s), then slow (60 s) or freeze, re-open on large change; coefficients off the I/O thread; de-esser threshold relative; remove the 8 kHz cut. Risk: +8 dB exposes codec noise, so listen first. A0 = offline proxy only. B: defer.
- **C (room tone): agree**: default −50 dB re speech (slider −60…−42), room-noise spectrum (~−5 dB/oct, little above 4–6 kHz), slow ±1–2 dB drift, coherent LF / decorrelated > 300 Hz, after the leveler, constant (not ducked), faded out when the tab is silent.
- **D:** for a frontal source the direct-path HRTF mostly colours; externalisation comes from lateral early reflections, the direct-to-reverberant ratio and head tracking → **G + D2** (spherical-head HRTF on the reflections, direct path untouched) may give most of the benefit at near-zero cost. D1 (AUSpatialMixer) is feasible on the I/O thread (initialise, MaximumFramesPerSlice, prime, no property changes while running; query its latency); head tracking/personalised HRTF likely need entitlements; beware double spatialisation with macOS "Spatialize Stereo"; headphones vs speakers not reliably detectable over Bluetooth → Auto + manual switch. HRTF data: MIT KEMAR (free with citation), SADIE II (Apache-2.0), HUTUBS (CC BY 4.0) usable; TH Köln KU100 (CC BY-SA) avoid.
- **E:** not worth it at a 12 kHz cutoff. **F:** nothing permissive fits real time (VoiceFixer and resemble-enhance are MIT but offline-heavy; AP-BWE is bandwidth extension only). **H:** keep off.
- **Missed option:** an ablation of our own chain: the "processed" feel may partly come from our leveler/de-esser acting on already-AGC'd audio.
- **Ranked:** 1) A (+ remove the 8 kHz cut, relative de-esser), 2) C, 3) G + D2 with D1 as comparison. **Decide with offline blind experiments first** (AirPods, loudness-matched, ideally a second lecturer clip): E1 Klarheit vs broad correction at 50/75/100 % (low shelf −4 dB, bell +6…+9 dB at 3 kHz, no 8 kHz cut); E2 E1-winner + room tone −55/−50/−45 dB; E3 E2-winner + stereo ER vs spherical-head binaural ER vs AUSpatialMixer, + best with tail at −24 dB; E4 leveler off / de-esser off.
