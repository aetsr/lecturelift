# Offline restoration research (time-boxed, 2026-11-16)

**Question:** could an *offline* mode (process a downloaded lecture file, not live) give the "wow" improvement the
real-time chain could not? The measured problems of the owner's clips are **distance / room reverb, a muffled
tone and level swings**; noise is already low (D-018, D-022).

**Method and limits:** web and repository research only; no installation, no model downloads, no listening, no
measurements on this Mac (owner's instruction). Licences were checked in the repositories / model cards (GitHub
API, Hugging Face API) on 2026-11-16. **All M1 speed figures are my estimates** from parameter counts and
published GPU numbers. Treat them as an order of magnitude, not a measurement.

## Why offline can do more than real time

Real-time processing must be causal, light (≤ 12 % of a core) and below 80 ms latency, so it can only *filter*
what is there. The strongest restoration models are **generative**: they analyse the degraded speech and
re-synthesise a clean, close-miked version (dereverberated, full-band, level-even). That is exactly the
"headset mic" effect the owner wants, and it needs look-ahead, large models and many times the compute. Offline,
none of that matters. The price is a new failure mode: a generative model can **change the voice or invent and
mangle sounds** (hallucination), and this risk grows for languages it saw less of in training.

## Comparison

| Candidate | What it does | Quality evidence | Licence (code / weights) | Runs on M1? | Est. time per 90-min lecture on M1 | Size / setup | Artefact risk | German |
|---|---|---|---|---|---|---|---|---|
| **Sidon** (U Tokyo, 2025) | Generative speech restoration: w2v-BERT 2.0 feature cleaning + HiFi-GAN vocoder → "studio-quality" speech; removes noise, reverb, band-limiting | Paper: comparable to Google's in-house **Miipher/Miipher-2**; English WER 0.045 vs Miipher 0.047, speaker similarity 0.971; multilingual (FLEURS, 100 langs) DNSMOS 3.39, speaker sim 0.979 | **MIT / MIT** (sidon-v0.1 on HF) | PyTorch; authors assume CUDA; CPU/MPS not documented but plausible (standard ops) | GPU RTF ≈ 0.002 (H200). **M1 estimate: ~10–50 min** (MPS lower end, CPU upper) | ~250 M params (+ w2v-BERT 2.0 base, ~600 M, MIT); Python + torch ≥ 2.8 + uv; "partially smoke-checked" port | Medium: resynthesis; paper reports **no** hallucination analysis; multilingual CER rose slightly vs the input (0.084 → 0.090) | **Trained on 104 languages** (FLEURS-R, which includes German), the best fit of all candidates |
| **Resemble Enhance** | Denoiser + latent flow-matching "enhancer" (bandwidth extension, restoration), 44.1 kHz | Widely used; demos convincing on noisy speech; dereverberation **not** a documented goal | **MIT / MIT** | PyTorch (CUDA/CPU); community **MLX port** for Apple Silicon | Hosted T4 ≈ 45 s per clip; **M1 estimate: ~1–6 h** (iterative sampler) | ~810 MB weights; pip install | Medium–high: generative; known to over-brighten and occasionally alter timbre | English-centric training; German untested |
| **VoiceFixer** (2021/22) | General speech restoration: noise, **reverb**, clipping, low bandwidth → 44.1 kHz via neural vocoder | Paper: leading results on restoration incl. dereverberation (at its time) | **MIT / MIT** | PyTorch, CPU mode documented | **M1 estimate: ~30–90 min** | small–medium; pip install | **High**: vocoder "robotic"/smeared sound and voice changes are commonly reported; older generation | Trained on English (VCTK); German risk |
| **SGMSE+ (EARS-Reverb 48 kHz)** / **StoRM** (U Hamburg) | Diffusion-based **dereverberation** (dedicated checkpoints) | Strong dereverb benchmarks (EARS-Reverb, WSJ0-Reverb) | **MIT / MIT** | PyTorch; CPU/MPS possible but slow | 30–50 diffusion steps → **M1 estimate: many hours** (StoRM faster than SGMSE+) | ~1.3 GB (HF repo); research code | Medium: diffusion can "fill in" speech in hard cases | English (EARS, WSJ0) training; German untested |
| **AnyEnhance-v1** (2025) | Unified masked-generative voice enhancement (noise, reverb, bandwidth…) | Baseline of the CCF-AATC 2025 restoration challenge | **MIT** (code; weights released per challenge paper) | PyTorch | unknown (likely ≥ 1 h) | research code | Medium–high (generative) | Chinese/English-centred; unknown |
| **nara_wpe** (WPE, classical) | Statistical **dereverberation** (weighted prediction error); no neural network | Standard method; single-channel gains are modest (removes late reverb, keeps the voice) | **MIT** | NumPy, CPU | **M1 estimate: a few minutes** | tiny; pip | **Very low**: cannot invent speech; can leave some "phasiness" | Language-independent |
| **ClearerVoice-Studio** (Alibaba): MossFormer2_SE_48K + _SR_48K | 48 kHz denoising + separate super-resolution | Good denoising; **dereverb not confirmed** for the 48 kHz model | **Apache-2.0 / Apache-2.0** | PyTorch; MLX port of the SE model exists | SE: est. 15–45 min; SR model (2.2 GB) slower | 222 MB + 2.2 GB | Low (SE) / medium (SR) | Unknown |
| **UVR "DeEcho-DeReverb"** (Ultimate Vocal Remover) | Music-vocal de-reverb/de-echo models, often used on speech | Anecdotal | GUI **MIT**; **weights' licence unstated** | Yes (UVR GUI, MPS) | est. 5–20 min | GUI app | Medium; trained on singing | Language-independent-ish |
| Open-Miipher-2 | Re-implementation of Google's Miipher-2 | — | MIT code, **no pretrained weights** | — | — | — | — | — |
| *Reference (not open): Adobe Podcast Enhance Speech v2* | Cloud generative restoration (noise, **reverb**, music) | The de-facto "wow" benchmark; users report v2 better than v1, with mixed opinions | proprietary, cloud | upload | minutes (server) | browser | Medium (generative; occasional voice change) | Works multilingual in practice |
| *Reference: iZotope RX Dialogue De-reverb, Supertone Clear, Waves Clarity Vx* | Commercial local plug-ins | Industry standard | proprietary (paid) | local | fast | install | Low–medium | language-independent |

## Assessment for these lectures

- The owner's clips are **already noise-suppressed, codec-limited (12 kHz), reverberant laptop/camera-mic speech**.
  Only the **generative restorers** (Sidon, Resemble Enhance, VoiceFixer, AnyEnhance, Adobe) can turn that into
  a close, dry, full-band voice. Filters (WPE, DFN3, our EQ) only reduce part of the reverb.
- **Sidon** is the strongest open candidate on paper: newest, Miipher-level, MIT incl. weights, **trained on 104
  languages including German**, and the fastest (one forward pass, no diffusion), so a 90-min lecture is
  plausible in tens of minutes on an M1. Main risks: an unproven "ported" codebase, CUDA-oriented setup (MPS/CPU
  path not documented), and resynthesis artefacts that nobody has evaluated systematically. The slight CER
  increase on multilingual data means intelligibility can occasionally get *worse* even when it sounds cleaner.
- **Resemble Enhance** is the established alternative, but English-centric, slow on an M1 and not made for reverb.
- **nara_wpe** is the **safe baseline**: no hallucination, language-independent, minutes per lecture, but its
  improvement on single-channel lecture audio will be modest. It would not produce the "wow".
- Everything generative needs a **German listening check on fricatives and technical terms** (same concern as
  D-003/§11), plus a look at speaker identity over a long lecture.

## Recommendation

1. **Sidon** as the one candidate worth a short, controlled experiment: run it offline on the existing 60 s
   clip (and the type-(a) headset clip once captured), loudness-match, A/B blind against Klarheit. Measure time
   per minute on the M1 (CPU vs MPS) and check German consonants and terms. Only if it clearly wins: design an
   offline mode (file in → restored file out → play in a local player), never in the live path.
2. **nara_wpe + Klarheit** as the low-risk comparison in the same experiment (cheap; tells whether "less
   reverb" alone already helps).
3. Not worth pursuing now: SGMSE+/StoRM (too slow on an M1 for 90-min files), VoiceFixer (older, robotic
   artefacts), UVR (weights' licence unclear, trained on singing), Open-Miipher-2 (no weights), cloud tools
   (privacy/terms, see below).

**Verdict:** *probably* worth one experiment, not yet worth building. The experiment needs installs and model
downloads (~1–5 GB: Python env, torch, Sidon weights + w2v-BERT 2.0), so it needs the owner's go.

## Legal

Check your institution's rules before saving or processing lecture recordings.

## Sources

- Sidon: paper [arXiv 2509.17052](https://arxiv.org/html/2509.17052v2), code [sarulab-speech/Sidon](https://github.com/sarulab-speech/Sidon) (MIT; weights `sarulab-speech/sidon-v0.1`, MIT), samples [HF space](https://wataru-sidonsamples.static.hf.space/index.html)
- Resemble Enhance: [GitHub](https://awesome.ecosyste.ms/projects/github.com%2Fresemble-ai%2Fresemble-enhance) (MIT), [Replicate timing](https://replicate.com/resemble-ai/resemble-enhance), [MLX port](https://huggingface.co/smcleod/resemble-enhance-mlx)
- VoiceFixer: [arXiv 2109.13731](https://arxiv.org/pdf/2109.13731), [arXiv 2204.05841](https://arxiv.org/pdf/2204.05841), [GitHub](https://github.com/haoheliu/voicefixer) (MIT)
- SGMSE+/StoRM: [sp-uhh/sgmse](https://www.github.com/sp-uhh/sgmse), [HF model card](https://huggingface.co/sp-uhh/speech-enhancement-sgmse), [StoRM paper](https://arxiv.org/pdf/2212.11851), [sp-uhh/storm](https://github.com/sp-uhh/storm) (MIT)
- AnyEnhance: [arXiv 2501.15417](https://arxiv.org/abs/2501.15417), [CCF AATC 2025 challenge](https://arxiv.org/html/2509.12974)
- Miipher-2: [arXiv 2505.04457](https://arxiv.org/pdf/2505.04457), [Open-Miipher-2](https://github.com/yukara-ikemiya/Open-Miipher-2)
- nara_wpe: [docs](https://nara-wpe.readthedocs.io/), [PyPI](https://pypi.org/project/nara_wpe)
- ClearerVoice-Studio: [PyPI](https://pypi.org/project/clearvoice/), [MossFormer2_SE_48K card](https://huggingface.co/alibabasglab/MossFormer2_SE_48K/blame/main/README.md)
- UVR: [Anjok07/ultimatevocalremovergui](https://github.com/Anjok07/ultimatevocalremovergui), [weights licence note](https://huggingface.co/thepatch/uvr-vr-GGUF)
- Generative SE hallucination / language dependency: [URGENT 2025](https://arxiv.org/pdf/2505.23212), [PASE](https://arxiv.org/pdf/2511.13300), [metrics paper](https://vde-verlag.de/proceedings-de/456164052.html)
- Adobe Enhance Speech v2: [Adobe community](https://community.adobe.com/t5/adobe-podcast-discussions/enhance-speech-v2-is-here/m-p/14997748/highlight/true), [ProVideo Coalition test](https://www.provideocoalition.com/adobe-enhance-speech-v2-tested/)
