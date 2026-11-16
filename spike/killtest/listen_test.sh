#!/bin/sh
# Ear test for M1: does the tapped audio come back after the tapping process is SIGKILLed?
# Plays a quiet 440 Hz tone on the DEFAULT output (headphones), with spoken cues.
set -u
T="$(cd "$(dirname "$0")/../out" && pwd)/killtest"
cue() { say "$1"; }
run() { # $1 = private flag
  "$T" play 440 40 default > /tmp/hs_play.log 2>&1 &
  sleep 1; P=$(awk '/PLAY/{split($2,a,"=");print a[2]}' /tmp/hs_play.log)
  cue "Phase A. The tone should be audible now."; sleep 3
  "$T" tap "$P" "$1" > /tmp/hs_tap.log 2>&1 & TP=$!
  sleep 1; cue "Phase B. Tapped. The tone should be muted now."; sleep 3
  kill -9 $TP; sleep 1
  cue "Phase C. Process killed. Is the tone back?"; sleep 4
  if [ "$1" = 0 ]; then "$T" sweep > /dev/null; cue "Phase D. Cleaned up. Is the tone there now?"; sleep 4; fi
  kill $(pgrep -f "killtest play") 2>/dev/null
}
cue "Test one, private tap."; run 1
cue "Test two, public tap."; run 0
cue "Done."
echo "Please note: test 1 phase C (tone yes/no); test 2 phases C and D (yes/no)."
