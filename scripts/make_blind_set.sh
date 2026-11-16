#!/bin/sh
# Blind listening set (D-018): renders variants of one clip, loudness-matches them and gives them
# random names X1…Xn. The key goes to KEY.txt (open it only after picking).
# Usage: scripts/make_blind_set.sh CLIP.wav OUTDIR [LUFS]
set -eu
cd "$(dirname "$0")/.."
IN=$1; OUT=$2; TARGET=${3:--20}
R="$(swift build -c release --show-bin-path)/lecturelift-render"
mkdir -p "$OUT"; rm -f "$OUT"/X*.wav "$OUT"/KEY.txt
TMP=$(mktemp -d)
render() { name=$1; shift; "$R" "$IN" "$TMP/$name.wav" "$@" > /dev/null; }
render "Clarity"                        --preset clarity
render "Clarity+Hall-wet04-pre10"   --preset hall --wet 0.04 --predelay 10
render "Clarity+Hall-wet07-pre10"   --preset hall --wet 0.07 --predelay 10
render "Clarity+Hall-wet10-pre10"   --preset hall --wet 0.10 --predelay 10
render "Clarity+Seminar-wet05"      --preset seminar --wet 0.05
render "Clarity+Seminar-wet08"      --preset seminar --wet 0.08
render "Clarity+DFN3-8dB"               --preset clarity --denoise 8
i=1
for f in $(ls "$TMP"/*.wav | while read -r l; do echo "$(od -An -N4 -tu4 /dev/urandom | tr -d ' ') $l"; done | sort -n | cut -d' ' -f2-); do
  "$R" --normalize "$TARGET" "$f" "$OUT/X$i.wav" > /dev/null
  echo "X$i = $(basename "$f" .wav)" >> "$OUT/KEY.txt"
  i=$((i + 1))
done
rm -rf "$TMP"
echo "blind set: $OUT (X1…X$((i - 1))), key in $OUT/KEY.txt"
