#!/bin/sh
# M1 live tests. Uses ONLY our own tone process (spike/out/killtest play) as the tap target via
# LECTURELIFT_PIDS — never a browser. Plays a quiet 440 Hz tone on the default output.
# Plays sound and taps a test tone; run it when you can listen.  Usage: scripts/m1_live_tests.sh [watchdog|kill9|permission|all|sleepwake|coreaudiod]
# sleepwake / coreaudiod are interactive (owner action) and NOT part of "all".
set -u
cd "$(dirname "$0")/.."
# Test hooks (LECTURELIFT_PIDS, LECTURELIFT_DEBUG_STALL_AT) exist only in DEBUG builds.
LECTURELIFT_NO_DMG=1 ./scripts/build.sh --debug > /dev/null 2>&1 || { echo "build failed"; exit 1; }
APP="build/LectureLift.app/Contents/MacOS/LectureLift"
T=spike/out/killtest
# the test-tone tool (also used for the tap tests)
[ -x "$T" ] || { mkdir -p spike/out && swiftc -O -o "$T" spike/killtest/killtest.swift && codesign -s - -f "$T" > /dev/null 2>&1; } || { echo "cannot build $T"; exit 1; }
WHICH=${1:-all}
cue() { say "$1"; }
logs() { /usr/bin/log show --last "$1" --info --style compact --predicate 'subsystem == "io.github.aetsr.lecturelift"' 2>/dev/null |
         sed -E 's/^[0-9-]+ ([0-9:.]+) .*\] /\1 /' | grep -E 'state=|session g|watchdog|TEST HOOK|create failed|telemetry|willSleep|didWake|coreaudiod' | cut -c1-170; }
tone() { "$T" play 440 "$1" default > /tmp/hs_tone.log 2>&1 & sleep 1; awk '/PLAY/{split($2,a,"=");print a[2]}' /tmp/hs_tone.log; }
stop_all() { pkill -x LectureLift 2>/dev/null; pkill -f "killtest play" 2>/dev/null; sleep 1; }

if [ "$WHICH" = watchdog ] || [ "$WHICH" = all ]; then
  echo "== Watchdog: simulated IOProc stall 4 s after start → expect teardown, retry after 1 s, new generation"
  P=$(tone 20)
  LECTURELIFT_PIDS=$P LECTURELIFT_ENABLE=1 LECTURELIFT_DEBUG_STALL_AT=4 "$APP" > /dev/null 2>&1 &
  sleep 12; logs 13s; stop_all
fi

if [ "$WHICH" = kill9 ] || [ "$WHICH" = all ]; then
  echo "== kill -9 of LectureLift itself while it mutes the tone (by ear: the tone must come back)"
  P=$(tone 20)
  LECTURELIFT_PIDS=$P LECTURELIFT_ENABLE=1 "$APP" > /dev/null 2>&1 & H=$!
  sleep 3; cue "LectureLift is running. You hear the tone through LectureLift."; sleep 2
  kill -9 $H; sleep 1; cue "LectureLift was killed. The tone must still be audible."; sleep 4
  stop_all
fi

if [ "$WHICH" = permission ] || [ "$WHICH" = all ]; then
  echo "== Permission: reset the grant → tap runs unmuted (tone stays audible), onboarding after 5 s"
  echo "   (macOS will show the permission prompt again; you may deny it for this test, then re-allow)"
  tccutil reset AudioCapture io.github.aetsr.lecturelift
  defaults delete io.github.aetsr.lecturelift permissionConfirmed 2>/dev/null
  P=$(tone 25)
  # Launch via LaunchServices so LectureLift (not Terminal) is the responsible process for TCC.
  open -n "build/LectureLift.app" --env LECTURELIFT_PIDS=$P --env LECTURELIFT_ENABLE=1
  sleep 20; logs 21s; stop_all
fi
verdict() {   # $1 = marker that must have happened; afterwards a new session must be up and callbacks must flow
  L=$(/usr/bin/log show --last 10m --info --style compact --predicate 'subsystem == "io.github.aetsr.lecturelift"' 2>/dev/null)
  echo "$L" | grep -q "$1" || { echo "RESULT: no '$1' seen — test not performed?"; return; }
  after=$(echo "$L" | sed -n "/$1/,\$p")
  if echo "$after" | grep -q "session g" && echo "$after" | grep -q "telemetry" && echo "$after" | tail -1 | grep -q "cb="; then
    echo "RESULT: PASS — after '$1' a new session came up and audio callbacks are flowing:"
  else
    echo "RESULT: CHECK — see the log lines below:"
  fi
  echo "$after" | sed -E 's/^[0-9-]+ ([0-9:.]+) .*\] /\1 /' | grep -E 'session g|state=|telemetry|willSleep|didWake|coreaudiod' | cut -c1-150 | tail -8
}

if [ "$WHICH" = sleepwake ]; then
  echo "== Sleep/wake (owner action). The tone plays through LectureLift."
  P=$(tone 300)
  open -n "build/LectureLift.app" --env LECTURELIFT_PIDS=$P --env LECTURELIFT_ENABLE=1
  sleep 4
  echo ">>> NOW: Apple menu → Ruhezustand (or close the lid), wait ~10 s, wake the Mac and log in."
  echo ">>> The script waits up to 5 minutes for the wake-up."
  i=0; until /usr/bin/log show --last 6m --info --style compact --predicate 'subsystem == "io.github.aetsr.lecturelift"' 2>/dev/null | grep -q didWake || [ $i -ge 60 ]; do sleep 5; i=$((i+1)); done
  sleep 8; verdict didWake
  cue "Test finished. Was the tone back after wake-up?"; stop_all
fi

if [ "$WHICH" = coreaudiod ]; then
  echo "== Core Audio restart (owner action). The tone plays through LectureLift; all audio stops for ~1 s."
  P=$(tone 300)
  open -n "build/LectureLift.app" --env LECTURELIFT_PIDS=$P --env LECTURELIFT_ENABLE=1
  sleep 4
  echo ">>> NOW, in another terminal tab:   sudo killall coreaudiod"
  echo ">>> The script waits up to 5 minutes."
  i=0; until /usr/bin/log show --last 6m --info --style compact --predicate 'subsystem == "io.github.aetsr.lecturelift"' 2>/dev/null | grep -q "coreaudiod restarted" || [ $i -ge 60 ]; do sleep 5; i=$((i+1)); done
  sleep 8; verdict "coreaudiod restarted"
  cue "Test finished. Was the tone back after the restart?"; stop_all
fi
echo "done"
