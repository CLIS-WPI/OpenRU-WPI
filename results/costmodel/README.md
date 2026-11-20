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
- `../../scripts/costmodel/run_costmodel.sh` — locked, core-pinned measurement run.
- `../../scripts/costmodel/merge_costmodel.py` — merge raw CSVs into the table.
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

## Method

- CPU rows: single core, `taskset -c 0-15`, core 8 by default, `-O3 -march=native`
  harness linked against `build/ocudu-avx2` (x86-64-v3) or `build/ocudu-avx512`
  (x86-64-v4). Timed backends are the native ones (`avx2` / `avx512`); OFDM uses
  the FFTW fast DFT factory in both builds.
- GPU rows: H100 NVL `GPU-509d8ab3` (index 1; index 0 is reserved). Timings are
  device-side kernel time after warmup; H2D/D2H are separate `cudaMemcpyAsync`
  measurements and are reported, not included in compute time.
- Warm-up: CPU runs **5** untimed calls per configuration; GPU runs **3** untimed
  H2D + kernel + D2H rounds followed by `cudaStreamSynchronize`. The timed loop
  follows those warm-ups.
- GPU clocks are **not locked** (no `nvidia-smi -lgc` / application clocks /
  persistence). The numbers are at the GPU's default clocks. If they are cited in
  the RFC, record `nvidia-smi -q -d CLOCK` with the run and do not compare across
  clock states.
- Correctness gates run before timing and must pass for a row to be reported:
  - OFDM vs generic DFT: max LSB ≤ 1 and error ≤ −60 dB.
  - BFP vs generic compressor: byte-identical.
  - Precoding vs scalar golden: max error ≤ 1e-3.
- A run holds `/tmp/openru-measure.lock`, refuses to start if it is held, and
  records `uptime`, top CPU consumers, and `docker ps` in `raw/<UTC>/load.txt`.
- 200 iterations per configuration; p50/p99 over those iterations.

## Notes

- GPU is ISA-independent; it was measured once and appears in the `gpu` rows.
- AVX-512 is not uniformly faster here: the AVX-512 Cat-B precoder is slower than
  the AVX2 one on this EPYC 9354 for every tested size. The table reports the
  measurement as-is; it is a property of the current OCUDU AVX-512 implementation,
  not of the harness.
- Raw numbers are tied to this host and to the `bench/costmodel-data` build of
  `external/proto-ru` (`5e925626f0`).
- The recorded run was **not on a quiet host**: `load.txt` shows load
  1.21/1.81/1.48 with `opencode` at 70.7% and other containers active (see
  `raw/20261120T214744Z/load.txt`). CPU p50 is usable for the harness comparison;
  CPU p99 outliers must not be presented as isolated-core RFC numbers. Rerun on an
  idle host before citing p99.
- Headline numbers are the ones in `costmodel.md` / `costmodel.csv`, not any
  earlier PR blurb.
