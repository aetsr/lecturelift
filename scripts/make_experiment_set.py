"""One blind listening set for experiments E1 (corrective EQ 50/75/100 %), E2 (room tone at 3 levels)
and E4 (leveler off / de-esser off), D-021. Offline only; nothing is tapped or played.

Usage: python3 -I scripts/make_experiment_set.py CLIP.wav OUTDIR [LUFS]

The experimental EQ is applied here (zero-phase, FFT domain, magnitude of RBJ biquads) before the
unchanged Klarheit chain with its own EQ neutralised. A real implementation would use minimum-phase
biquads; for gentle broad EQ the audible difference is negligible. The room tone is synthesised here
(added after the chain, constant), its level set relative to the measured speech loudness."""

import os
import random
import struct
import subprocess
import sys
import tempfile

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = (
    subprocess.run(
        ["swift", "build", "-c", "release", "--show-bin-path"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    + "/lecturelift-render"
)


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
    assert fmt[0] in (3, 0xFFFE) and fmt[5] == 32, fmt
    return np.frombuffer(raw, dtype="<f4").reshape(-1, fmt[1]).astype(np.float64), fmt[
        2
    ]


def write_wav(path, x, sr):
    x = np.asarray(x, dtype="<f4")
    ch = x.shape[1]
    data = x.tobytes()
    hdr = (
        b"RIFF"
        + struct.pack("<I", 36 + len(data))
        + b"WAVE"
        + b"fmt "
        + struct.pack("<IHHIIHH", 16, 3, ch, sr, sr * ch * 4, ch * 4, 32)
    )
    open(path, "wb").write(hdr + b"data" + struct.pack("<I", len(data)) + data)


def rbj(kind, fs, f0, q, g):
    A = 10 ** (g / 40)
    w = 2 * np.pi * f0 / fs
    c, s = np.cos(w), np.sin(w)
    if kind == "peak":
        al = s / (2 * q)
        b = [1 + al * A, -2 * c, 1 - al * A]
        a = [1 + al / A, -2 * c, 1 - al / A]
    else:  # shelves, q = slope S
        al = s / 2 * np.sqrt((A + 1 / A) * (1 / q - 1) + 2)
        k = 2 * np.sqrt(A) * al
        if kind == "low":
            b = [
                A * ((A + 1) - (A - 1) * c + k),
                2 * A * ((A - 1) - (A + 1) * c),
                A * ((A + 1) - (A - 1) * c - k),
            ]
            a = [
                (A + 1) + (A - 1) * c + k,
                -2 * ((A - 1) + (A + 1) * c),
                (A + 1) + (A - 1) * c - k,
            ]
        else:
            b = [
                A * ((A + 1) + (A - 1) * c + k),
                -2 * A * ((A - 1) + (A + 1) * c),
                A * ((A + 1) + (A - 1) * c - k),
            ]
            a = [
                (A + 1) - (A - 1) * c + k,
                2 * ((A - 1) - (A + 1) * c),
                (A + 1) - (A - 1) * c - k,
            ]
    return np.array(b), np.array(a)


def mag(b, a, freqs, fs):
    z = np.exp(-1j * 2 * np.pi * freqs / fs)
    return np.abs((b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z))


def correction(x, sr, amount):
    """E1 correction scaled by `amount`: low shelf 250 Hz −5 dB, bell 3 kHz +9 dB (Q 0.7), high shelf 6 kHz +4 dB."""
    n = len(x)
    nfft = 1 << int(np.ceil(np.log2(n + 8192)))
    f = np.fft.rfftfreq(nfft, 1 / sr)
    h = np.ones_like(f)
    for kind, f0, q, g in [
        ("low", 250, 1.0, -5),
        ("peak", 3000, 0.7, 9),
        ("high", 6000, 1.0, 4),
    ]:
        h *= mag(*rbj(kind, sr, f0, q, g * amount), f, sr)
    y = np.fft.irfft(np.fft.rfft(x, nfft, axis=0) * h[:, None], nfft, axis=0)[:n]
    return y


def room_tone(n, sr, seed):
    """Lecture-hall room tone: ~−5 dB/oct above 200 Hz, extra roll-off above 5 kHz, HP 50 Hz,
    coherent below 300 Hz and decorrelated above, slow ±1.5 dB drift."""
    rng = np.random.default_rng(seed)
    f = np.fft.rfftfreq(n, 1 / sr)
    shape = np.where(f < 200, 1.0, (np.maximum(f, 1.0) / 200.0) ** (-5 / 6.02))
    shape *= 1 / np.sqrt(1 + (f / 5000.0) ** 4)
    shape *= (f / 50.0) ** 2 / (1 + (f / 50.0) ** 2)
    xf = np.clip((f - 200) / 200, 0, 1)  # 200→400 Hz crossfade coherent → independent
    spec = lambda: rng.standard_normal(len(f)) + 1j * rng.standard_normal(len(f))
    common, l, r = spec(), spec(), spec()
    L = np.fft.irfft(shape * ((1 - xf) * common + xf * l), n)
    Rr = np.fft.irfft(shape * ((1 - xf) * common + xf * r), n)
    t = np.arange(n) / sr
    drift = 10 ** (
        1.5
        * np.sin(2 * np.pi * 0.03 * t + rng.uniform(0, 6.28))
        * np.sin(2 * np.pi * 0.011 * t)
        / 20
    )
    return np.stack([L * drift, Rr * drift], axis=1)


def lufs(path):
    out = subprocess.run([R, "--measure", path], capture_output=True, text=True).stdout
    return float(out.split(":")[1].split("LUFS")[0])


def render(src, dst, *opts):
    subprocess.run([R, src, dst, *opts], check=True, capture_output=True)


def main():
    clip, out = sys.argv[1], sys.argv[2]
    target = float(sys.argv[3]) if len(sys.argv) > 3 else -20.0
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.startswith("X") and f.endswith(".wav") or f == "KEY.txt":
            os.remove(os.path.join(out, f))
    x, sr = read_wav(clip)
    tmp = tempfile.mkdtemp()
    neutral = ["--preset", "clarity", "--set", "debox=0", "--set", "presence=0"]
    variants = {}
    # E1
    render(clip, f"{tmp}/K.wav", "--preset", "clarity")
    variants["E1 Klarheit (as is)"] = f"{tmp}/K.wav"
    for amt in (0.5, 0.75, 1.0):
        pre = f"{tmp}/pre{int(amt * 100)}.wav"
        write_wav(pre, correction(x, sr, amt), sr)
        render(pre, f"{tmp}/C{int(amt * 100)}.wav", *neutral)
        variants[
            f"E1 correction {int(amt * 100)} % (shelf 250 Hz −5, bell 3 kHz +9, shelf 6 kHz +4, ×{amt})"
        ] = f"{tmp}/C{int(amt * 100)}.wav"
    # E2: C75 + room tone
    c75, _ = read_wav(f"{tmp}/C75.wav")
    speech = lufs(f"{tmp}/C75.wav")
    tone = room_tone(len(c75), sr, 7)
    tone *= 0.05 / np.sqrt(np.mean(tone ** 2))   # measurable level (raw tone is below the −70 LUFS gate)
    write_wav(f"{tmp}/tone.wav", tone, sr)
    tone_l = lufs(f"{tmp}/tone.wav")
    assert np.isfinite(tone_l) and np.isfinite(speech), (tone_l, speech)
    for rel in (-55, -50, -45):
        g = 10 ** ((speech + rel - tone_l) / 20)
        write_wav(f"{tmp}/T{-rel}.wav", c75 + g * tone, sr)
        variants[f"E2 correction 75 % + room tone {rel} LU re speech"] = (
            f"{tmp}/T{-rel}.wav"
        )
    # E4: C75 with leveler off / de-esser off
    pre75 = f"{tmp}/pre75.wav"
    render(pre75, f"{tmp}/NL.wav", *neutral, "--set", "level=0")
    variants["E4 correction 75 %, leveler OFF"] = f"{tmp}/NL.wav"
    render(pre75, f"{tmp}/ND.wav", *neutral, "--set", "deess=0")
    variants["E4 correction 75 %, de-esser OFF"] = f"{tmp}/ND.wav"
    # blind: shuffle, loudness-match
    names = list(variants)
    random.SystemRandom().shuffle(names)
    with open(os.path.join(out, "KEY.txt"), "w") as key:
        for i, name in enumerate(names, 1):
            subprocess.run(
                [
                    R,
                    "--normalize",
                    str(target),
                    variants[name],
                    os.path.join(out, f"X{i}.wav"),
                ],
                check=True,
                capture_output=True,
            )
            key.write(f"X{i} = {name}\n")
    subprocess.run(
        [R, "--normalize", str(target), clip, os.path.join(out, "A_original.wav")],
        check=True,
        capture_output=True,
    )
    print(f"{len(names)} blind files + A_original in {out}; key in {out}/KEY.txt")


if __name__ == "__main__":
    main()
