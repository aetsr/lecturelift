#!/bin/sh
# Reproducible build of the RNNoise core (xiph, BSD-3-Clause) as a dylib for LectureLift's optional
# light denoiser backend (kept only if it passes the German listening test, D-003).
# Output (git-ignored): vendor/rnnoise/lib/librnnoise.dylib. Pinned commit + model checksum.
# Env: RNNOISE_SRC=<local clone> reuses an existing checkout.
set -eu
cd "$(dirname "$0")/.."
REPO=https://github.com/xiph/rnnoise.git
COMMIT=70f1d256acd4b34a572f999a05c87bf00b67730d
OUT=vendor/rnnoise
SRC="$OUT/src"
if [ -n "${RNNOISE_SRC:-}" ]; then rm -rf "$SRC"; git clone -q "$RNNOISE_SRC" "$SRC"
elif [ ! -d "$SRC/.git" ]; then git clone -q "$REPO" "$SRC"; fi
git -C "$SRC" fetch -q origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q --force "$COMMIT"
HASH=$(cat "$SRC/model_version")
MODEL="rnnoise_data-$HASH.tar.gz"
mkdir -p "$OUT/cache"
[ -f "$OUT/cache/$MODEL" ] || curl -fsSL -o "$OUT/cache/$MODEL" "https://media.xiph.org/rnnoise/models/$MODEL"
echo "$HASH  $OUT/cache/$MODEL" | shasum -a 256 -c -
tar -xzmf "$OUT/cache/$MODEL" -C "$SRC"
mkdir -p "$OUT/lib"
( cd "$SRC/src" && clang -O3 -fPIC -dynamiclib -arch arm64 -fvisibility=hidden -DRNNOISE_BUILD \
    -I../include -I. -o "../../lib/librnnoise.dylib" -install_name @rpath/librnnoise.dylib \
    denoise.c rnn.c pitch.c kiss_fft.c celt_lpc.c nnet.c nnet_default.c parse_lpcnet_weights.c \
    rnnoise_data.c rnnoise_tables.c -lm )
cp "$SRC/COPYING" "$OUT/COPYING"
nm -gU "$OUT/lib/librnnoise.dylib" | grep -q _rnnoise_process_frame
echo "RNNoise ready: $OUT/lib/librnnoise.dylib"
