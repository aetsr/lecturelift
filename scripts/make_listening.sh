#!/bin/sh
# Builds loudness-matched A/B listening files (offline, nothing is tapped or played).
# Usage: scripts/make_listening.sh INPUT.wav OUTDIR [TARGET_LUFS]
#   OUTDIR/A_original.wav, OUTDIR/B_<preset>.wav for clarity, seminar, hall, auditorium,
#   all normalised to TARGET_LUFS (default −18) so the comparison is about sound, not level.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product lecturelift-render > /dev/null
R="$(swift build -c release --show-bin-path)/lecturelift-render"
make_set() {
  in="$1"; out="$2"; target="${3:--18}"
  mkdir -p "$out"; tmp=$(mktemp -d)
  "$R" --normalize "$target" "$in" "$out/A_original.wav"
  for p in clarity seminar hall auditorium; do
    "$R" "$in" "$tmp/$p.wav" --preset "$p" > /dev/null
    "$R" --normalize "$target" "$tmp/$p.wav" "$out/B_$p.wav"
  done
  rm -rf "$tmp"
}
[ $# -ge 2 ] || { echo "usage: scripts/make_listening.sh INPUT.wav OUTDIR [TARGET_LUFS]"; exit 1; }
make_set "$1" "$2" "${3:--18}"
