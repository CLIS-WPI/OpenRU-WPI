# Roadmap

OpenRU is an open O-RAN split-7.2 radio unit. The v1 low PHY runs on CPU (FFTW + ESTIMATE); a CUDA low-PHY is an
optional backend for higher antenna counts and future in-RU processing. Hardware work proceeds in three stages,
each with an explicit acceptance point.

## Hardware stages

| Stage | Radio | Band / bandwidth | Goal |
|---|---|---|---|
| **1** | **N310 + FEM**, cabled UE | n78, 20 MHz 2×2 (40 MHz 2×2 second) | first real-air split-7.2 link: DU → ProtO-RU → N310 → cabled UE; close the loop with the recorded-golden gates on real hardware |
| **2** | **open LMS7002M boards** | 40 MHz | open-source RF front end replacing the commercial SDR; same 7.2 split and test harness |
| **3** | **custom ADRV9026 board** | 100 MHz | in-house wideband radio; 100 MHz is not validated on the current host and is unlocked here |

Stage 1 is the immediate work: the bench host (i5-13600KF, X710, N310-10) and the x86-64-v3 image/release flow are
ready — see [`BENCH_BUNDLE.md`](BENCH_BUNDLE.md).

## Next steps

1. **First cabled bench test** — N310-10 → RM520N, 20 MHz 2×2; `make BENCH=1 bench-preflight`, live `smoke-fh`
   2×600 s, then `replay-golden` on the bench host (mandatory: v3 bit-exactness is only proven on the AVX-512
   server).
2. **Virtual UE suite with srsUE** — DU → ProtO-RU (ZMQ) → srsUE, added to the test framework
   (see [`TESTS.md`](TESTS.md)).
3. **UL/PRACH harness** — deterministic UL and PRACH checks (energy/leakage gates, PRACH detection) in the suite.
4. **Jetson Orin Nano compute test** — run the CUDA low-PHY path on the target-class GPU; report compute-only
   numbers separately from the H100 (no H100 figures reused).
5. **Single-chain RF bench** — one TX/RX chain end-to-end (cabled), before the full 2×2 / 4×4 matrix.
6. **4T4R in software** — 4-layer DL / 4-port UL profile and its golden (N310 RF0–RF3; UE side: ANT2/ANT0 TX+RX,
   ANT1/ANT3 RX-only).

## Measurement rules

Every number in reports is tagged `[MEASURED]`, `[DATASHEET]`, `[DERIVED]`, `[ASSUMPTION]` or `[UNVERIFIED]`;
compute-only timings are never presented as fronthaul delay profiles. See [`BENCH_BUNDLE.md`](BENCH_BUNDLE.md) and
[`AGENTS.md`](../AGENTS.md).
