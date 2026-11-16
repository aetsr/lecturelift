#!/bin/sh
# Labelled (not blind) listening set for the "noise-cancelling headset" goal (D-022).
# Usage: scripts/make_headset_set.sh CLIP.wav OUTDIR [LUFS]
set -eu
cd "$(dirname "$0")/.."
IN=$1; OUT=$2; T=${3:--20}
R="$(swift build -c release --show-bin-path)/lecturelift-render"
mkdir -p "$OUT"; rm -f "$OUT"/*.wav
TMP=$(mktemp -d)
r() { name=$1; shift; "$R" "$IN" "$TMP/$name.wav" "$@" > /dev/null; "$R" --normalize "$T" "$TMP/$name.wav" "$OUT/$name.wav" > /dev/null; }
"$R" --normalize "$T" "$IN" "$OUT/01_A_original.wav" > /dev/null
r 02_Klarheit                              --preset clarity
r 03_DFN12_Klarheit                        --preset clarity --denoise 12
r 04_DFN18_Klarheit                        --preset clarity --denoise 18
r 05_DFNvoll_Klarheit                      --preset clarity --denoise 100
r 06_LevelerStark_Klarheit                 --preset clarity --set levelstrength=1
r 07_KANDIDAT_DFN18_LevelerStark           --preset clarity --denoise 18 --set levelstrength=1
r 08_KANDIDAT_plus_Raum3                   --preset seminar --denoise 18 --set levelstrength=1 --wet 0.03 --predelay 10
r 09_KANDIDAT_plus_Raum5                   --preset seminar --denoise 18 --set levelstrength=1 --wet 0.05 --predelay 10
rm -rf "$TMP"
echo "labelled set: $OUT"
