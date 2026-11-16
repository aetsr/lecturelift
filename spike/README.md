# spike/

Throw-away experiments that informed the design; not part of the app.

- `run_dfn_spike.sh` + `dfn_bench.c`: DeepFilterNet3 CPU/latency spike (D-003).
- `killtest/`: Core Audio test tool (tone player, tap, process listing) and the kill -9 ear test (D-007);
  `scripts/m1_live_tests.sh` builds it automatically.
- `build_rnnoise.sh`: builds the RNNoise core; the backend was never integrated (kept for reference).
