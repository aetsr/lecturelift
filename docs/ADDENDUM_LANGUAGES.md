# Addendum: Lectures in German or English

Lectures can be in **German or English**. Each lecture is in one language. The app must work equally well for both.

## Language independence
- The entire processing chain must be **language-agnostic**: no language detection, no per-language presets, no switching logic. The same chain and settings must sound right for German and English lectures.
- In Phase 0, check every speech model you evaluate (DeepFilterNet3, its forks, RNNoise, any other candidate) for language bias: what language(s) it was trained on, and whether it degrades on German speech. Document the findings in `docs/PRIOR_ART.md`.
- Reject any component that is English-only or measurably worse on German.

## DSP considerations
- German has many strong fricatives and sibilants ("sch", "ch", "s", "z", "pf"). The presence boost (+2.5 dB @ 3 kHz) and the high shelf can make them harsh.
- Add an optional, gentle **de-esser** stage (split-band, ~5–8 kHz, max 3–4 dB reduction) after the EQ and before the leveler. Default ON at a mild setting. Individually bypassable like every other stage.
- Make sure the denoiser does not smear or cut fricatives and plosives. Listen for this specifically in German test material.

## Test material
- Build a small test corpus of **openly licensed** German and English speech, e.g. Mozilla Common Voice (CC0) for both `de` and `en`, and public-domain LibriVox recordings in both languages.
- Create **simulated "Zoom-like" versions** of these clips so the chain is tested on realistic input:
  - band-limit
  - add light codec-like artifacts
  - apply aggressive noise suppression
  - add level swings
  - Document how you generated them.
- Store only the generation scripts and source URLs in the repo, not large audio files. The scripts download and prepare the corpus reproducibly.

## Evaluation
- Run the offline renderer over the full corpus with every preset.
- Report per language:
  - CPU / real-time factor
  - integrated loudness (LUFS) before and after
  - an objective non-intrusive speech quality score (e.g. DNSMOS or a comparable metric, only if its license is compatible), so German and English results can be compared side by side
- Flag any preset where German and English results differ noticeably. Ask Fable to review the bilingual evaluation results as part of the M6 review.
- Generate A/B listening pairs (original vs. processed) for both languages into `eval/listening/` so I can check them by ear.

## UI
- The UI is already bilingual (German default, English). Make sure all tooltips, onboarding and error messages exist in both languages.
