# External reference bench status (2026-11-19)

## 10 MHz-only external clock

The run that set only `clock_source=external` in the radio device args was **judged too early**: the
RX/TX counters were sampled before the DU had reached AMF NG Setup. The DU startup timeline in
`BENCH_BUNDLE.md` shows ~151 s from `Built in Release` to `NGSetupResponse`, with the first 149 s spent
inside O-DU-low construction, before CU-CP is started. A zero OFH counter in that window is not a
clock failure.

**Verdict:** inconclusive; the run must be repeated after `gNB-N2 accepted` / `make up STACK=e2e`
returns. The bench profiles stay at `REF=internal` until that repeat passes.

## Clock + time external (PPS)

The run with `clock_source=external,time_source=external` waited **8 minutes** and still had
`RX_TOTAL=0`, `TX_TOTAL=0`.

**Verdict:** **MEASURED FAIL**. PPS time is not supported by the current wall-clock slot alignment:
UHD `set_time_unknown_pps()` sets radio time at the next PPS, which is not synchronized to the host's
GPS-disciplined second. Do not enable `time_source=external` in the bench profiles.

## What to do next on the bench

1. `make BENCH=1 up STACK=e2e PROFILE=bench-20mhz`.
2. Wait for `[ng] AMF accepted the DU NG Setup` (the command itself waits; 6 min timeout).
3. Then run only the 10 MHz-only external case (`REF=external` with `sync_source=internal`) and compare
   OFH traffic against the internal-clock baseline.
