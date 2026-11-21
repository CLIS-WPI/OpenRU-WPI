# OpenRU low-PHY cost model

Per-slot cost of the OpenRU low-PHY kernels used by the NeoRU RFC:

- OFDM modulation: IFFT + CP insertion + phase compensation + `cf_t`→`ci16_t`
  conversion, one slot (14 symbols).
- BFP compression: 9-bit BFP, one slot, all ports.
- Cat-B precoding: `MAX_NOF_LAYERS` layers → ports, one slot, all PRBs.

Profiles: 20 MHz / 51 RB, 40 MHz / 106 RB, 100 MHz / 273 RB; SCS 30 kHz;
slots are 0.5 ms, so a kernel that takes 0.5 ms consumes the whole slot.

## Layout

- `../../src/cuda/standalone/tests/test_costmodel.cpp` — harness.
- `../../scripts/costmodel/build_costmodel.sh` — configure/build both ISA trees.
- `../../scripts/costmodel/run_costmodel_clean.sh` — detached clean run: reserved cores,
  per-core gate, GPU clock/power capture, Cat-B diagnostic, retries.
- `../../scripts/costmodel/pick_cores.py`, `core_watch.py`, `gpu_apps_watch.py`,
  `gpu_trace_summary.py` — clean-run helpers.
- `../../scripts/costmodel/run_costmodel.sh` — earlier busy-host run (kept for comparison).
- `../../scripts/costmodel/merge_costmodel.py` — merge raw CSVs into the table.
- `../../scripts/costmodel/variance.py` — aggregate repeated runs into median/range
  (`costmodel.md`, `costmodel.csv`, `costmodel-variance.csv`).
- `raw/<UTC>/` — harness output (`load.txt`, `avx2.csv`, `avx512.csv`, `gpu.csv`, logs).
  Workspace paths in the committed logs are replaced with `<worktree>`.
- `costmodel.csv` — merged rows; `costmodel.md` — summary table.

## Build

The harness links two OCUDU static builds from the submodule
(`external/proto-ru`). From the repo root:

```bash
FFTW_PREFIX="${FFTW_PREFIX:-$HOME/.local/fftw3}"
MBEDTLS_PREFIX="${MBEDTLS_PREFIX:-$HOME/.local/mbedtls}"
CONDA_PREFIX="${CONDA_PREFIX:-$HOME/miniconda3}"

for isa in avx2:x86-64-v3 avx512:x86-64-v4; do
  name="${isa%%:*}"; march="${isa#*:}"
  cmake -S external/proto-ru -B "build/ocudu-$name" \
    -DCMAKE_BUILD_TYPE=Release -DMARCH="$march" \
    -DENABLE_FFTW=ON -DOPENRU_FFTW_ESTIMATE=ON \
    -DDISABLE_SCTP=ON -DENABLE_DPDK=OFF -DENABLE_LIBNUMA=OFF \
    -DFFTW3F_INCLUDE_DIR="$FFTW_PREFIX/include" \
    -DFFTW3F_LIBRARY="$FFTW_PREFIX/lib/libfftw3f.so" \
    -DCMAKE_PREFIX_PATH="$MBEDTLS_PREFIX;$CONDA_PREFIX"
  cmake --build "build/ocudu-$name" -j"${NUM_JOBS:-16}" --target \
    fmt ocudulog ocudu_support ocudu_support_math ocudu_instrumentation \
    ocuduvec ocudu_ran ocudu_phy_support ocudu_dft ocudu_lower_phy_modulation \
    ocudu_ofh_compression ocudu_channel_precoder
done
```

Then configure the harness for each tree:

```bash
cmake -S src/cuda/standalone -B build/cm-avx2 \
  -DOCUDU_BUILD="$PWD/build/ocudu-avx2" -DOCUDU_FAIR_BUILD="$PWD/build/ocudu-avx2" \
  -DFFTW3F_ROOT="$FFTW_PREFIX" -DYAML_CPP_LIBRARY="$CONDA_PREFIX/lib/libyaml-cpp.so"
cmake --build build/cm-avx2 -j"${NUM_JOBS:-16}" --target test_costmodel
```

`scripts/costmodel/build_costmodel.sh` wraps the last two steps and accepts
`FFTW3F_ROOT` / `YAML_CPP_LIBRARY` from the environment.

## Method (clean run)

- **Reserved cores, not a whole-server rule.** `pick_cores.py` samples every CPU
  for 20 s and selects the least bursty physical cores on one NUMA node; the run
  pins the benchmark to one of them and checks the reserved set before, during and
  after. The #47 single run used cores `19,21,31` on NUMA 0. During the variance
  runs the shared host had no 3-core window free of other processes, so each
  variance run reserved one physical core (SMT off, so no HT sibling): core `6`
  (NUMA 0), `43` (NUMA 1), and `12` (NUMA 0). The same per-core/GPU gate applied.
- **Rejection rule.** A backend is rejected only if another process used a
  reserved core (peak foreign CPU > 5% of that core) or another process used the
  GPU (`nvidia-smi --query-compute-apps`). Host-wide load is recorded for
  information only. The runner retries with a new core selection if a run is
  rejected.
- CPU rows: single reserved core, `-O3 -march=native`, linked against
  `build/ocudu-avx2` (x86-64-v3) or `build/ocudu-avx512` (x86-64-v4). Timed
  backends are the native ones (`avx2` / `avx512`); OFDM uses the FFTW fast DFT
  factory in both builds.
- GPU rows: H100 NVL `GPU-509d8ab3` (index 1; index 0 is reserved), host process
  on the GPU's NUMA node. Device-side kernel time after warmup; H2D/D2H are
  separate `cudaMemcpyAsync` measurements and are not included in compute time.
- Warm-up: CPU runs **5** untimed calls per configuration; GPU runs **3** untimed
  H2D + kernel + D2H rounds followed by `cudaStreamSynchronize`.
- GPU clocks/power are recorded before, after and every 500 ms during the GPU run.
  The clean run: SM 1785 MHz median (345–1785), memory 2619 MHz, 63–93 W, P0.
  Clocks are **not locked**; do not compare across clock states.
- Correctness gates run before timing and must pass for a row to be reported:
  - OFDM vs generic DFT: max LSB ≤ 1 and error ≤ −60 dB.
  - BFP vs generic compressor: byte-identical.
  - Precoding vs scalar golden: max error ≤ 1e-3.
- 200 iterations per configuration; p50/p99 over those iterations. The published
  table is the median [min-max] of three runs. p50 is the headline; p99 still
  contains isolated host-scheduler outliers because the benchmark cannot take RT
  priority on this shared host, and the range makes that visible.
- A run holds `/tmp/openru-measure.lock` and records per-backend `load.*.txt`,
  `*.cores.json`, `*.nvidia-smi.*` and `*.gpu_apps.json` under
  `raw/<run-id>/final/`.

## Notes

- The published table is the 3-run variance `var-A-20261120T235619Z`,
  `var-B-20261121T000700Z`, `var-C-20261121T001717Z` (median [min-max] per row;
  `costmodel.md`). It supersedes the #47 single-run table. The busy-host run
  `raw/20261120T214744Z/` is kept only as a labelled comparison in
  `COMPARISON.md`; its numbers are provisional and must not be cited.
- GPU is ISA-independent; it was measured in each of the three runs.
- Cat-B AVX-512 is slower than AVX2 because the harness calls `apply_precoding`
  once per PRB (12 REs): AVX-512 vectorizes 8 REs and runs a 4-RE scalar tail,
  while AVX2 vectorizes all 12. It also uses the non-BF16 conversion fallback
  (`-mavx512f -mavx512bw`, no `-mavx512bf16`). The diagnostic in `costmodel.md`
  swaps the implementation between builds and records ~3.80 GHz in all four
  cases, so this is implementation/granularity, not frequency or measurement.
- Raw numbers are tied to this host and to submodule `5e925626f0`.
- Headline numbers are the ones in `costmodel.md` / `costmodel.csv`.
