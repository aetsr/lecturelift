"""Diagnose a lecture recording (D-018): bandwidth, noise/gating, codec holes, room, dynamics, tonality.
Usage: python3 -I scripts/analyze_clip.py CLIP.wav [REFERENCE.wav]
The reference (clean speech, e.g. build/renders/de.stereo.wav) is only used for the tonality comparison.
numpy only; prints a plain-text report."""

import struct
import sys

import numpy as np


def read_wav(path):
    data = open(path, "rb").read()
    i, fmt, raw = 12, None, None
    while i + 8 <= len(data):
        cid, size = data[i : i + 4], struct.unpack("<I", data[i + 4 : i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", data[i + 8 : i + 24])
        if cid == b"data":
            raw = data[i + 8 : i + 8 + size]
        i += 8 + size + (size & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag in (3, 0xFFFE) and bits == 32:
        x = np.frombuffer(raw, dtype="<f4").astype(np.float64)
    elif bits == 16:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768
    else:
        raise SystemExit(f"unsupported format {fmt}")
    return x.reshape(-1, ch), sr


def stft_power(x, n=2048, hop=512):
    w = np.hanning(n)
    frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * w
    return np.abs(np.fft.rfft(frames, axis=1)) ** 2 / np.sum(w**2)


def db(p):
    return 10 * np.log10(np.maximum(p, 1e-20))


def third_octaves():
    return [f for f in 1000 * 2.0 ** (np.arange(-14, 14) / 3) if 50 <= f <= 20000]


def band_levels(pmean, freqs, centres):
    out = []
    for fc in centres:
        sel = (freqs >= fc / 2 ** (1 / 6)) & (freqs < fc * 2 ** (1 / 6))
        out.append(db(pmean[sel].sum()) if sel.any() else np.nan)
    return np.array(out)


def analyse(path):
    x, sr = read_wav(path)
    st = {"sr": sr, "dur": len(x) / sr}
    st["lr_corr"] = (
        float(np.corrcoef(x[:, 0], x[:, 1])[0, 1])
        if x.shape[1] > 1 and x[:, 0].std() > 0
        else 1.0
    )
    m = x.mean(axis=1)
    st["peak_dbfs"] = float(db(np.max(np.abs(m)) ** 2))
    st["clipped"] = int(np.sum(np.abs(x) >= 0.999))
    st["exact_zero_frac"] = float(np.mean(m == 0))
    p = stft_power(m)
    freqs = np.fft.rfftfreq(2048, 1 / sr)
    frame_db = db(p.sum(axis=1) / 2048)
    floor = np.percentile(frame_db, 10)
    loud = np.percentile(frame_db, 95)
    speech = frame_db > max(floor + 15, loud - 30)
    pause = frame_db < floor + 6
    st.update(
        speech_frac=float(speech.mean()), floor_db=float(floor), loud_db=float(loud)
    )
    ps, pp = (
        p[speech].mean(axis=0),
        (p[pause].mean(axis=0) if pause.any() else np.full_like(freqs, 1e-20)),
    )
    st["freqs"], st["ltass"], st["pause_spec"] = freqs, ps, pp
    # effective bandwidth: highest frequency whose speech level is within 40 dB of the 1–4 kHz mean
    ref = db(ps[(freqs >= 1000) & (freqs <= 4000)].mean())
    above = np.where(db(ps) > ref - 40)[0]
    st["cutoff_hz"] = float(freqs[above[-1]]) if len(above) else 0.0
    # steepness right at the cutoff (brick-wall low-pass = codec / resampling)
    c = st["cutoff_hz"]
    lo = db(ps[(freqs > c * 0.8) & (freqs < c * 0.95)].mean()) if c > 0 else np.nan
    hi = (
        db(ps[(freqs > c * 1.05) & (freqs < min(c * 1.25, sr / 2))].mean())
        if c * 1.05 < sr / 2
        else np.nan
    )
    st["cutoff_drop_db"] = (
        float(lo - hi) if np.isfinite(lo) and np.isfinite(hi) else np.nan
    )
    # SNR: speech vs pause spectra (broadband) and pause floor
    st["snr_db"] = float(db(ps.sum()) - db(pp.sum()))
    st["pause_floor_dbfs"] = float(db(pp.sum() / 2048))
    # gating: how often pauses fall to (near) digital silence
    st["gated_frac"] = float(np.mean(frame_db < -90))
    # spectral holes in speech frames (codec / aggressive noise suppression → "metallic/underwater")
    band = (freqs >= 1000) & (freqs <= min(8000, c if c > 0 else 8000))
    sp = db(p[speech][:, band])
    k = 9
    env = np.apply_along_axis(
        lambda r: np.convolve(r, np.ones(k) / k, mode="same"), 1, sp
    )
    st["hole_frac"] = float(np.mean(sp < env - 15))
    # temporal flux of the 4–8 kHz band in speech (warbling / musical noise indicator)
    hb = (freqs >= 4000) & (freqs <= min(8000, sr / 2))
    hf = db(p[:, hb].sum(axis=1))
    st["hf_flux_db"] = (
        float(np.median(np.abs(np.diff(hf)[speech[1:] & speech[:-1]])))
        if hb.any()
        else np.nan
    )
    # decay after speech offsets (room in the recording vs dry/gated): dB/s over the first 80 ms
    hop_s = 512 / sr
    rates = []
    for i in range(1, len(frame_db) - 8):
        if speech[i - 1] and not speech[i] and frame_db[i - 1] - frame_db[i] > 3:
            seg = frame_db[i - 1 : i + 7]
            t = np.arange(len(seg)) * hop_s
            rates.append(-np.polyfit(t, seg, 1)[0])
    st["offset_decay_dbps"] = float(np.median(rates)) if rates else np.nan
    st["offsets"] = len(rates)
    # dynamics: 3 s windows over speech (loudness-range proxy) and crest factor
    win = int(3 / hop_s)
    lv = [
        db(p[i : i + win][speech[i : i + win]].sum(axis=1).mean() / 2048)
        for i in range(0, len(frame_db) - win, win // 3)
        if speech[i : i + win].mean() > 0.3
    ]
    st["range_db"] = (
        float(np.percentile(lv, 95) - np.percentile(lv, 10)) if len(lv) > 3 else np.nan
    )
    rms = np.sqrt(np.mean(m**2))
    st["crest_db"] = float(20 * np.log10(np.max(np.abs(m)) / max(rms, 1e-12)))

    # hum: 50/100 Hz peaks vs neighbourhood in pauses
    def peak(f0):
        s = (freqs > f0 - 3) & (freqs < f0 + 3)
        n = ((freqs > f0 - 30) & (freqs < f0 - 10)) | (
            (freqs > f0 + 10) & (freqs < f0 + 30)
        )
        return (
            float(db(pp[s].max()) - db(pp[n].mean())) if s.any() and n.any() else np.nan
        )

    st["hum50_db"], st["hum100_db"] = peak(50), peak(100)
    st["sub80_rel_db"] = float(db(ps[freqs < 80].sum()) - db(ps.sum()))
    # ---- metrics added in D-022 (mic type: headset vs distant laptop mic) ----
    # envelope modulation depth 2–8 Hz per octave band (dry speech ≈ deep modulation; reverb flattens it)
    hop2 = int(0.005 * sr)
    env_fs = sr / hop2
    st["mod"] = {}
    for fc in (250, 500, 1000, 2000, 4000):
        fr = np.fft.rfftfreq(len(m), 1 / sr)
        spec = np.fft.rfft(m)
        band = np.fft.irfft(spec * ((fr > fc / np.sqrt(2)) & (fr < fc * np.sqrt(2))), len(m))
        e = np.sqrt(np.convolve(band ** 2, np.ones(hop2) / hop2, mode="valid")[::hop2])
        e = e - e.mean()
        es = np.abs(np.fft.rfft(e * np.hanning(len(e)))) ** 2
        ef = np.fft.rfftfreq(len(e), 1 / env_fs)
        tot = es[(ef > 0.5) & (ef < 32)].sum()
        st["mod"][fc] = float(es[(ef >= 2) & (ef <= 8)].sum() / max(tot, 1e-30))
    # decay after sharp offsets with a 5 ms raster, 500 Hz–4 kHz, from −5 to −25 dB below the onset level
    fr = np.fft.rfftfreq(len(m), 1 / sr)
    mid = np.fft.irfft(np.fft.rfft(m) * ((fr > 500) & (fr < 4000)), len(m))
    ed = 10 * np.log10(np.maximum(np.convolve(mid ** 2, np.ones(hop2) / hop2, mode="valid")[::hop2], 1e-20))
    top = np.percentile(ed, 95)
    rates = []
    for i in range(2, len(ed) - 40):
        if ed[i - 1] > top - 10 and ed[i] < ed[i - 1] - 1 and ed[i - 2] <= ed[i - 1] + 0.5:
            seg = ed[i - 1:i + 40]
            a5 = np.argmax(seg < seg[0] - 5); a25 = np.argmax(seg < seg[0] - 25)
            if a5 > 0 and a25 > a5:
                rates.append(20.0 / ((a25 - a5) / env_fs))
    st["decay2_dbps"] = float(np.median(rates)) if len(rates) > 5 else float("nan")
    st["decay2_n"] = len(rates)
    # low-frequency bursts (plosives / proximity "pops"): 20–150 Hz level jumps vs the 150 Hz–4 kHz level
    lf = np.fft.irfft(np.fft.rfft(m) * ((fr > 20) & (fr < 150)), len(m))
    lfd = 10 * np.log10(np.maximum(np.convolve(lf ** 2, np.ones(hop2) / hop2, mode="valid")[::hop2], 1e-20))
    md = 10 * np.log10(np.maximum(np.convolve(mid ** 2, np.ones(hop2) / hop2, mode="valid")[::hop2], 1e-20))
    n = min(len(lfd), len(md))
    rel = lfd[:n] - md[:n]
    pops = (lfd[:n] > np.percentile(lfd, 99) - 3) & (rel > np.median(rel[md[:n] > top - 30]) + 12)
    st["pops_per_min"] = float(np.sum(np.diff(pops.astype(int)) == 1) / (len(m) / sr / 60))
    # non-speech floor percentiles (Fable D-019) and 10 s level drift (distance changes)
    nonsp = frame_db[~speech]
    st["nonspeech_p25"], st["nonspeech_p50"] = (float(np.percentile(nonsp, 25)), float(np.percentile(nonsp, 50))) if len(nonsp) else (np.nan, np.nan)
    w10 = int(10 / hop_s)
    l10 = [db(p[i:i + w10][speech[i:i + w10]].sum(axis=1).mean() / 2048) for i in range(0, len(frame_db) - w10, w10 // 2) if speech[i:i + w10].mean() > 0.3]
    st["drift10_db"] = float(np.max(l10) - np.min(l10)) if len(l10) > 2 else float("nan")
    return st


def main():
    st = analyse(sys.argv[1])
    ref = analyse(sys.argv[2]) if len(sys.argv) > 2 else None
    print(
        f"file: {sys.argv[1]}  ({st['sr']} Hz, {st['dur']:.1f} s, L/R correlation {st['lr_corr']:.3f})"
    )
    print(
        f"peak {st['peak_dbfs']:.1f} dBFS, clipped samples {st['clipped']}, crest factor {st['crest_db']:.1f} dB"
    )
    print(
        f"speech frames {st['speech_frac'] * 100:.0f} %, frame level 95th pct {st['loud_db']:.1f} dB, 10th pct {st['floor_db']:.1f} dB"
    )
    print(
        f"BANDWIDTH: effective cutoff ≈ {st['cutoff_hz']:.0f} Hz (−40 dB re 1–4 kHz), drop across the edge {st['cutoff_drop_db']:.1f} dB"
    )
    print(
        f"NOISE: speech/pause SNR {st['snr_db']:.1f} dB, pause floor {st['pause_floor_dbfs']:.1f} dBFS, "
        f"frames below −90 dBFS {st['gated_frac'] * 100:.1f} %, exact-zero samples {st['exact_zero_frac'] * 100:.2f} %"
    )
    print(
        f"CODEC/NS: spectral holes (1 kHz…cutoff, >15 dB below local envelope) {st['hole_frac'] * 100:.1f} % of bins; "
        f"4–8 kHz frame-to-frame flux {st['hf_flux_db']:.1f} dB"
    )
    print(
        f"ROOM IN RECORDING: decay after speech offsets {st['offset_decay_dbps']:.0f} dB/s (n={st['offsets']}) "
        f"→ equivalent decay time ≈ {60 / st['offset_decay_dbps'] * 1000 if st['offset_decay_dbps'] > 0 else float('nan'):.0f} ms for 60 dB"
    )
    print("MOD DEPTH 2–8 Hz (share of 0.5–32 Hz envelope energy): " + ", ".join(f"{k} Hz {v:.2f}" for k, v in st["mod"].items()))
    print(f"DECAY (5 ms raster, 0.5–4 kHz, −5→−25 dB after sharp offsets): {st['decay2_dbps']:.0f} dB/s (n={st['decay2_n']})")
    print(f"LF BURSTS (plosive/proximity pops): {st['pops_per_min']:.1f} per minute")
    print(f"NON-SPEECH FLOOR: 25th pct {st['nonspeech_p25']:.1f} dB, median {st['nonspeech_p50']:.1f} dB; 10 s speech-level drift {st['drift10_db']:.1f} dB")
    print(f"DYNAMICS: 3 s speech level range (10–95 pct) {st['range_db']:.1f} dB")
    print(
        f"LOW END: < 80 Hz share {st['sub80_rel_db']:.1f} dB, hum 50 Hz {st['hum50_db']:.1f} dB / 100 Hz {st['hum100_db']:.1f} dB above neighbours (pauses)"
    )
    centres = third_octaves()
    lc = band_levels(st["ltass"], st["freqs"], centres)
    sel = [(500 <= c <= 2000) for c in centres]
    lc -= np.nanmean(lc[sel])
    print(
        "TONALITY (speech LTASS, 1/3 octaves, dB re 1 kHz)"
        + ("   clip − reference" if ref else "")
    )
    if ref:
        lr = band_levels(ref["ltass"], ref["freqs"], centres)
        lr -= np.nanmean(lr[sel])
    for i, fc in enumerate(centres):
        if fc < 80 or fc > st["sr"] / 2:
            continue
        line = f"  {fc:7.0f} Hz  {lc[i]:6.1f}"
        if ref:
            line += f"   {lc[i] - lr[i]:+6.1f}"
        print(line)
    if ref:
        print(
            f"reference: {sys.argv[2]}  cutoff {ref['cutoff_hz']:.0f} Hz, offset decay {ref['offset_decay_dbps']:.0f} dB/s, "
            f"holes {ref['hole_frac'] * 100:.1f} %, flux {ref['hf_flux_db']:.1f} dB"
        )


if __name__ == "__main__":
    main()
