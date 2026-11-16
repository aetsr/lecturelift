"""Noise / hiss / crackle / level-swing / reverb table for one or more files (D-022).
Usage: python3 -I scripts/noise_report.py a.wav [b.wav …]"""
import importlib.util
import os
import sys

import numpy as np

spec = importlib.util.spec_from_file_location("ac", os.path.join(os.path.dirname(os.path.abspath(__file__)), "analyze_clip.py"))
ac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ac)


def clicks_per_min(m, sr):
    """Impulsive HF transients: 1 ms peaks in the > 3 kHz band more than 12× the surrounding 40 ms RMS."""
    f = np.fft.rfftfreq(len(m), 1 / sr)
    hf = np.fft.irfft(np.fft.rfft(m) * (f > 3000), len(m))
    w = int(0.001 * sr)
    n = len(hf) // w
    pk = np.abs(hf[:n * w]).reshape(n, w).max(axis=1)
    rms = np.sqrt((hf[:n * w] ** 2).reshape(n, w).mean(axis=1))
    ctx = np.sqrt(np.convolve(rms ** 2, np.ones(40) / 40, mode="same"))
    hits = (pk > 12 * np.maximum(ctx, 1e-6)) & (pk > 10 ** (-60 / 20))
    return float(np.sum(np.diff(hits.astype(int)) == 1) / (len(m) / sr / 60))


print(f"{'file':40s} {'floor':>6s} {'hiss':>6s} {'clicks':>6s} {'rng3s':>6s} {'drift10':>7s} {'mod':>5s} {'decay':>6s}")
print(f"{'':40s} {'dB re speech':>13s} {'/min':>6s} {'dB':>6s} {'dB':>7s} {'':>5s} {'dB/s':>6s}")
for p in sys.argv[1:]:
    x, sr = ac.read_wav(p)
    m = x.mean(axis=1)
    st = ac.analyse(p)
    pw = ac.stft_power(m); fr = np.fft.rfftfreq(2048, 1 / sr)
    fdb = ac.db(pw.sum(axis=1) / 2048)
    sp_lvl = np.percentile(fdb, 95)
    nonsp = fdb < np.percentile(fdb, 30)
    hiss = ac.db(pw[nonsp][:, (fr > 4000) & (fr < 12000)].sum(axis=1).mean() / 2048) - sp_lvl
    print(f"{os.path.basename(p)[:40]:40s} {st['nonspeech_p50'] - sp_lvl:6.1f} {hiss:6.1f} {clicks_per_min(m, sr):6.1f} "
          f"{st['range_db']:6.1f} {st['drift10_db']:7.1f} {np.mean(list(st['mod'].values())):5.2f} {st['decay2_dbps']:6.0f}")
