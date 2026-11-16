#!/bin/sh
# Reproducible build of libDF (DeepFilterNet Plus) as a dylib + the DFN3 model for LectureLift's
# opt-in "Qualität" mode. Output (git-ignored): vendor/libdf/lib/libdf.dylib, vendor/libdf/models/.
# Pinned: Rust toolchain, DeepFilterNet Plus commit, model checksum.
# Env: DFN_SRC=<local clone> reuses an existing checkout instead of cloning from GitHub.
set -eu
cd "$(dirname "$0")/.."
TOOLCHAIN=1.88.0
REPO=https://github.com/ismailivanov/DeepFilterNetPlus.git
COMMIT=2dc5273d16e1e3769527ad0740654c5ccde581cc
MODEL=DeepFilterNet3_onnx.tar.gz
MODEL_SHA256=c94d91f70911001c946e0fabb4aa9adc37045f45a03b56008cb0c8244cb63616
OUT=vendor/libdf
export PATH="$HOME/.cargo/bin:$PATH"

command -v rustup > /dev/null || { echo "rustup missing: https://rustup.rs (toolchain $TOOLCHAIN)"; exit 1; }
rustup toolchain list | grep -q "^$TOOLCHAIN" || rustup toolchain install "$TOOLCHAIN" --profile minimal

SRC="$OUT/src"
if [ -n "${DFN_SRC:-}" ]; then
  rm -rf "$SRC"; git clone -q "$DFN_SRC" "$SRC"
elif [ ! -d "$SRC/.git" ]; then
  git clone -q "$REPO" "$SRC"
fi
git -C "$SRC" fetch -q origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout -q --force "$COMMIT"
git -C "$SRC" clean -qfd
for p in "$OUT"/patches/*.patch; do git -C "$SRC" apply "$(pwd)/$p"; done

(cd "$SRC" && cargo "+$TOOLCHAIN" build --locked --release -p deep_filter --features capi --lib --target aarch64-apple-darwin)
mkdir -p "$OUT/lib" "$OUT/models"
cp "$SRC/target/aarch64-apple-darwin/release/libdf.dylib" "$OUT/lib/libdf.dylib"
install_name_tool -id "@rpath/libdf.dylib" "$OUT/lib/libdf.dylib"
cp "$SRC/models/$MODEL" "$OUT/models/$MODEL"
echo "$MODEL_SHA256  $OUT/models/$MODEL" | shasum -a 256 -c -
cp "$SRC/LICENSE-MIT" "$OUT/LICENSE-MIT"; cp "$SRC/LICENSE-APACHE" "$OUT/LICENSE-APACHE"
echo "libDF ready: $OUT/lib/libdf.dylib ($(du -h "$OUT/lib/libdf.dylib" | cut -f1)), model $MODEL"
