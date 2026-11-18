# v3 candidate (`v1-candidate-v3`) — 600 s live verification [MEASURED]

Purpose: build the v1 CPU configuration for **x86-64-v3** (no AVX-512) for the i5-13600KF bench host, and verify it
live on the GPU-server quiet host: `smoke-fh` 2×600 s for `baseline` and `b40`, plus `replay-golden baseline`.

## Image

| | |
|---|---|
| Tag | `openru/protoru:v1-candidate-v3` (image `c88dc855d7de`) |
| Build config | `MARCH=x86-64-v3`, `EXTRA_CMAKE_ARGS="-DENABLE_FFTW=ON -DOPENRU_CUDA=OFF -DOPENRU_FFTW_ESTIMATE=ON"` |
| Provenance | built on the GPU-server 2026-11-18, submodule `d8d2097894`, `NUM_JOBS=32` |
| Build log | `logs/build-v1-candidate-v3.log` — builder line shows `-DMARCH=x86-64-v3 … -DENABLE_FFTW=ON -DOPENRU_CUDA=OFF -DOPENRU_FFTW_ESTIMATE=ON` |

AVX-512 kernel objects (ldpc/precoder/modulator) are compiled per-file with `-mavx512*` and selected at runtime by
CPU-feature detection, so the v3 image is safe on a non-AVX-512 host.

## Conditions of every run

GPU-server, quiet host (hostcheck `valid: true`, 0 offenders, no foreign process on the reserved cores in any run),
`/tmp/openru-measure.lock` held for the whole run, MTU 9000 on `openru_fh`, `PROTORU_PROFILE=null` (CPU+null radio),
`SMOKE_SECS=600`. Gate: after warm-up `drop == 0` and `late/(rx+tx) < 1e-5` at the RU. Reference gates: emulator
`2.096e-6`, CPU+null `7.094e-6` (600 s).

## Results

| Run | Profile | RU lates | late frac | drop | DL/UL C-plane, UL rate (/s) | DU UL late | Gate |
|---|---|---|---|---|---|---|---|
| r1 | baseline | 0 | 0.0 | 0 | 6773.5 / 512.4 / 1799.6 | 0 / 9.31 M | **PASS** |
| r2 | baseline | 6 | 4.08e-07 | 0 | 6773.2 / 512.4 / 1799.5 | 36 / 9.30 M | **PASS** |
| r1 | b40 | 177 | **1.20e-05** | 0 | 6773.5 / 512.4 / 1799.6 | 3 / 9.33 M | **FAIL** |
| r2 | b40 | 4 | 2.73e-07 | 0 | 6771.9 / 512.3 / 1799.1 | 26 / 9.32 M | **PASS** |

DU config verified from the DU log: `channel_bandwidth_MHz: 40` for b40, `20` for baseline (40 MHz = 106 PRB @ 30 kHz).
Rates match the 600 s v1 baselines (DL U 6773 vs 6784.6 expected, C 512.4 vs 513.4, UL 1799 vs 1800 — all within
0.2%); the packet counts are slot-driven and do not change with bandwidth.

### b40 verdict

**v3 does not reliably pass b40 on this host: 1/2 runs PASS.** The failure is burst-limited, not systematic: all 177
lates of r1 fall in two seconds (`t+93`: 14, `t+401`: 163). r2 has 4 lates in the whole 600 s. The DU-side UL late
ratio stays ≤3.9e-6 in all four runs. This is the same host-scheduling signature recorded in the b40 golden MANIFEST
(`host_limited`: 4/5 cold replays), so the b40 verdict is **pending the bench host with isolated P-cores**
(`docs/BENCH_BUNDLE.md`) — not a property of the v3 code path. No tolerance was widened.

## replay-golden baseline (image-specific goldens)

Replay of `testdata/pcap/baseline.pcapng` with the v3 image against the stored **v4** golden
(`OPENRU_REPLAY_TAG=v1-candidate-v3`):

- dump gate: `golden-check: PASS` — 513/513 expected DL slots non-empty, per-port energy ok (p0: 513, p1: 100), no
  UL leakage; `du_align` offset 0 slots; 4000/4000 slots overlap.
- bit-exact compare: `port0.cf32: all 4000 overlapping DU slots PASS (n=46,080,000)` and the same for `port1.cf32`
  — **0 differing samples vs the v4 golden**.

**Consequence: no v3 golden set is needed.** The x86-64-v3 image reproduces the v4 golden bit-exactly, so
`testdata/golden/*/MANIFEST.json` stays as is (it records `v1-candidate`), and the bench bundle evaluates v3 against
the same goldens. If a future v3/v4 divergence appears, `OPENRU_REPLAY_TAG` + `GOLDEN_ROOT` (Makefile) allow a v3
set in `testdata/golden-v3/` with its own MANIFEST.

## Artifacts

`docs/reports/raw/v3-smoke/v1-candidate-v3-{baseline,b40}-r{1,2}/`: `run.log`, `smoke-fh-kpi.json`,
`smoke-fh-late-hist.csv`, `smoke-fh-du.log`, `smoke-fh-ru.log`, `smoke-fh-hostcheck{,-pre}.json`.
Replay: `docs/reports/raw/v3-smoke/replay-golden-baseline/{run.log,check.json}`; the 704 MB IQ dump stays in
`docs/reports/raw/replay-golden-baseline/` (gitignored).

## Unverified

- b40 with v3 on isolated P-cores (bench host) — 600 s ×2, required before calling v3 b40-validated.
- 100 MHz with v3 — not run (b100 golden remains deferred; 100 MHz is not validated on this host for v4 either).
- The N310 MPM/filesystem vs container UHD 4.7.0.0 compatibility — device address/version pending
  (`docs/OPEN_QUESTIONS.md`).
