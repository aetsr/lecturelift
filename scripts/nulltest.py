"""Null test: compare two float32 WAV files sample by sample. Usage: python3 -I nulltest.py a.wav b.wav"""
import struct, sys
import numpy as np

def read_f32(path):
    data = open(path, "rb").read()
    i, fmt, out = 12, None, None
    while i + 8 <= len(data):
        cid, size = data[i:i + 4], struct.unpack("<I", data[i + 4:i + 8])[0]
        if cid == b"fmt ": fmt = struct.unpack("<HHIIHH", data[i + 8:i + 24])
        if cid == b"data": out = np.frombuffer(data[i + 8:i + 8 + size], dtype="<f4")
        i += 8 + size + (size & 1)
    assert fmt and fmt[0] in (3, 0xFFFE) and fmt[5] == 32, f"not float32: {fmt}"
    return out.reshape(-1, fmt[1])

a, b = read_f32(sys.argv[1]), read_f32(sys.argv[2])
n = min(len(a), len(b))
same = np.array_equal(a[:n].view(np.uint32), b[:n].view(np.uint32))
diff = np.max(np.abs(a[:n] - b[:n])) if n else 0.0
print(f"frames a={len(a)} b={len(b)} bit_identical={same} max_abs_diff={diff:.3e}")
sys.exit(0 if same and len(a) == len(b) else 1)
