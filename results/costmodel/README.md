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
- `raw/<UTC>/` — unmodified harness output (`load.txt`, `avx2.csv`, `avx512.csv`, `gpu.csv`, logs).
- `costmodel.csv` — merged rows; `costmodel.md` — summary table.

## Method

- CPU rows: single core, `taskset -c 0-15`, core 8 by default, `-O3 -march=native`
  harness linked against `build/ocudu-avx2` (x86-64-v3) or `build/ocudu-avx512`
  (x86-64-v4). Timed backends are the native ones (`avx2` / `avx512`); OFDM uses
  the FFTW fast DFT factory in both builds.
- GPU rows: H100 NVL `GPU-509d8ab3` (index 1; index 0 is reserved). Timings are
  device-side kernel time after warmup; H2D/D2H are separate `cudaMemcpyAsync`
  measurements and are reported, not included in compute time.
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
