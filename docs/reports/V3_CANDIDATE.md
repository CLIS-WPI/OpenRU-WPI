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

Replay of `testdata/pcap/baseline.pcapng` with **`openru/protoru:v1-candidate-v3` (image `c88dc855d7de`)** against the
stored **v4** golden (`OPENRU_REPLAY_TAG=v1-candidate-v3`; the run log names the image and its ID):

- dump gate: `golden-check: PASS` — 513/513 expected DL slots non-empty, per-port energy ok (p0: 513, p1: 100), no
  UL leakage; `du_align` offset 0 slots; 4000/4000 slots overlap.
- bit-exact compare: `port0.cf32: all 4000 overlapping DU slots PASS (n=46,080,000)` and the same for `port1.cf32`
  — 0 differing samples vs the v4 golden.

**Claim, scoped: bit-exact on the AVX-512 server; to be confirmed on the bench host.** This server has AVX-512, and
both libraries select SIMD paths **at runtime**, not from `MARCH`:

- OCUDU dispatches on CPU features: `cpu_supports_feature(cpu_feature::avx512f/avx512bw/avx2/fma)` in
  `lib/phy/generic_functions/precoding/precoding_factories.cpp:29-31`,
  `lib/phy/generic_functions/generic_functions_factories.cpp:137`,
  `lib/phy/upper/channel_modulation/channel_modulation_factories.cpp` — the `_avx512` objects are compiled on any
  x86-64 build, so on this server the v3 image still executes AVX-512 paths where they exist.
- FFTW comes from the distro package (`libfftw3-dev`, Ubuntu 24.04) and picks its codelets (AVX2/AVX-512) from the
  CPU at plan time — again independent of `MARCH`.

So this run does **not** prove x86-64-v3-image bit-exactness on a non-AVX-512 host; it proves that the v3 build
configuration did not change the output on this host. `docs/BENCH_BUNDLE.md` therefore makes
`replay-golden baseline` a **mandatory** bench-host step; only that run can promote the claim. If it differs there,
build the v3 golden set under `GOLDEN_ROOT=testdata/golden-v3` and record `image: v1-candidate-v3` in its MANIFEST.
Until then `testdata/golden/*/MANIFEST.json` stays as is (it records `v1-candidate`).

## Artifacts

Raw evidence is **not committed** (~8.3 MB of logs/KPI dumps): it lives under the local
artifact root (`OPENRU_ARTIFACTS_DIR` in gitignored `docker/bench.local.env`) at
`<artifact-root>/v3-smoke-evidence/docs/reports/raw/v3-smoke/` with checksums in
`docs/reports/raw/v3-smoke/MANIFEST.sha256` (verify with `cd <that dir> && sha256sum -c <repo>/docs/reports/raw/v3-smoke/MANIFEST.sha256`).
Layout: `v1-candidate-v3-{baseline,b40}-r{1,2}/` with `run.log`, `smoke-fh-kpi.json`,
`smoke-fh-late-hist.csv`, `smoke-fh-du.log`, `smoke-fh-ru.log`, `smoke-fh-hostcheck{,-pre}.json`;
`replay-golden-baseline/{run.log,check.json}`. The 704 MB IQ dump stays in
`docs/reports/raw/replay-golden-baseline/` (gitignored).

## Unverified

- b40 with v3 on isolated P-cores (bench host) — 600 s ×2, required before calling v3 b40-validated.
- v3-image bit-exactness against the golden on a host **without AVX-512** — `replay-golden baseline` on the bench
  host (mandatory step in `docs/BENCH_BUNDLE.md`); the AVX-512 server cannot answer this because FFTW/OCUDU dispatch
  at runtime.
- 100 MHz with v3 — not run (b100 golden remains deferred; 100 MHz is not validated on this host for v4 either).
- The N310 MPM/filesystem vs container UHD compatibility — resolved for the bench host: N310-10 (serial
  `33A6E56`, `192.168.10.2`) has MPM 4.11.0.0-g0d7ed3b1 / FPGA 8.2 / filesystem 20260908111319, and the bench
  image `openru/protoru:v1-candidate-v3-uhd411` ships UHD 4.11.0.0 (`e2e955360db9`); `make bench-preflight` runs
  `uhd_usrp_probe` inside that image and fails on any MPM incompatibility (`docs/BENCH_BUNDLE.md`).
- The first live N310 run (20 MHz 2×2, `profiles/bench-20mhz`) — pending the bench-host campaign.
