# Contributing to LectureLift

> **Project status: frozen.** LectureLift is published as-is and not actively maintained. Issues and pull
> requests may go unanswered; the best way to continue the work is a fork (MIT). The rules below still apply
> if you do send a PR or work on a fork.

Bug reports, test reports from other Macs and listening feedback are still useful for others who find the repo.

## Ground rules

- **Real-time code** (`Sources/HSCore`, everything reachable from `hs_ioproc`): no allocation, no locks, no
  logging, no Swift/ObjC calls, no system calls except `semaphore_signal`. Allocate in `prepare()`; hand over
  objects through the lock-free queues; free on a control thread. If in doubt, ask in the issue first.
- **Never leave the user in silence.** Any change to the tap/aggregate lifecycle (`Sources/HSAudio`) must keep
  the fail-safe behaviour: no muting before the permission is confirmed; teardown restores the original audio.
- **Licences:** only MIT/BSD/Apache-compatible code and data. Never copy GPL code (we used FineTune as a
  *behaviour* reference only).
- Keep the UI bilingual: every user-visible string goes into `Sources/HSApp/Resources/Localizable.xcstrings`
  with German and English (a test enforces this).

## Building and testing

```sh
swift build && swift test                 # 85 tests; denoiser tests skip without libDF
./scripts/build_libdf.sh                  # optional, enables the DeepFilterNet3 tests and mode
./scripts/build.sh                        # app bundle + DMG
$(swift build -c release --show-bin-path)/lecturelift-render in.wav out.wav --preset clarity [--bench]
```

Live tests that need a human (sound, sleep, `sudo`) are in `scripts/m1_live_tests.sh`; they only tap a test
tone process, never your browser.

## Pull requests

- One topic per PR; include tests for DSP or lifecycle changes.
- `swift test` and `swiftlint lint` must pass (0 errors).
- Describe how you verified the change (unit test, offline render, live test).
- For larger design changes, add an entry to `docs/DECISIONS.md` explaining the why.
