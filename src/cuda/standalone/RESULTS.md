# Validation Results

Environment:

- GPU: NVIDIA H100 NVL, compute capability 9.0 ([MEASURED])
- CUDA: 12.5, cuFFT from the same toolkit
- Reference: OCUDU `external/proto-ru` at `8937cab`, Release build, generic DFT. Still valid through `790b899`: no changes in `lib/ofh/compression`, `lib/phy/lower/modulation`, `generic_functions`, or `phy/support` between those commits.
- Host buffers: pinned memory, 3 warm-up iterations, 30 measured iterations
- Command: `CUDA_VISIBLE_DEVICES=GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058 ./build/test_lowphy --iters 30`
- Measurement lock: `/tmp/openru-measure.lock` was absent immediately before the build and before the GPU run.

DFT sizes are derived from the sampling rate, not hard-coded:
`sampling_rate::from_Hz(srate).get_dft_size(scs)`.

| Profile | Sampling rate | Bandwidth | DFT |
|---|---|---:|---:|
| 20 MHz | 23.04 MHz | 51 PRB | 768 |
| 40 MHz | 46.08 MHz | 106 PRB | 1536 |
| 100 MHz | 122.88 MHz | 273 PRB | 4096 |

The harness fails if the sampling rate is not a multiple of the subcarrier spacing or if
the cuFFT plan cannot be created; no profile is skipped.

## BFP correctness

Values are maximum mismatches over all profiles, ports, symbols and PRBs. A value of 0
means the GPU stream is byte-identical to the CPU stream.

| Width | Max compress byte mismatch | Max decompress bf16 mismatch | Max AVX2 compress mismatch | Max AVX2 decompress mismatch |
|---:|---:|---:|---:|---:|
| 8 | 0 | 0 | 0 | 0 |
| 9 | 0 | 0 | 0 | 0 |
| 10 | 0 | 0 | 0 | 0 |
| 12 | 0 | 0 | 0 | 0 |
| 16 | 0 | 0 | 0 | 0 |

## OFDM correctness

Measured over the two slots of the subframe, all ports. "Mod diff" counts `ci16` samples
that differ at all; "Mod max LSB" is the largest absolute difference. "Demod max LSB" is
`|gpu - cpu| * 32767` on the unquantised `cf32` grid; "Demod diff" counts samples whose
error is at least 0.5 LSB. "Error" is `10 log10(sum |gpu-cpu|^2 / sum |cpu|^2)`.

| Profile | DFT | Ports | Mod diff | Mod max LSB | Mod error | Demod max LSB | Demod diff | Demod error | Pass |
|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 20 MHz | 768 | 2 | 58 | 1 | -103.29 dB | 0.0066 | 0 | -129.98 dB | PASS |
| 20 MHz | 768 | 4 | 116 | 1 | -103.27 dB | 0.0080 | 0 | -129.98 dB | PASS |
| 40 MHz | 1536 | 2 | 294 | 1 | -102.40 dB | 0.0110 | 0 | -128.87 dB | PASS |
| 40 MHz | 1536 | 4 | 590 | 1 | -102.39 dB | 0.0114 | 0 | -128.89 dB | PASS |
| 100 MHz | 4096 | 2 | 1172 | 1 | -104.80 dB | 0.0209 | 0 | -128.91 dB | PASS |
| 100 MHz | 4096 | 4 | 2282 | 1 | -104.90 dB | 0.0209 | 0 | -128.91 dB | PASS |

All profiles meet the acceptance bounds: modulation `<= 1` LSB and `<= -60 dB` error
power; demodulation `< 1` LSB and `<= -60 dB` error power.

### Radix-2 test-only reference

The original radix-2 kernel is retained in `tests/` and is not part of the library. It
only supports power-of-two DFT sizes, so it runs for the 100 MHz profile as an
independent spot check.

| Profile | DFT | Ports | Mod max LSB |
|---|---:|---:|---:|
| 100 MHz | 4096 | 2 | 1 |
| 100 MHz | 4096 | 4 | 1 |

## Timing

Times are milliseconds per slot and include all ports. The kernel columns are
compute-only; the host-to-device and device-to-host columns are reported separately.
BFP widths 9 and 16 are shown because only those two widths take the AVX2 CPU path; the
GPU kernel handles all widths with the same code.

### BFP width 9

| Profile | Ports | Comp H2D | Comp kernel | Comp D2H | Dec H2D | Dec kernel | Dec D2H |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 0.0082 | 0.0106 | 0.0097 | 0.0089 | 0.0100 | 0.0116 |
| 20 MHz | 4 | 0.0114 | 0.0099 | 0.0094 | 0.0100 | 0.0095 | 0.0124 |
| 40 MHz | 2 | 0.0137 | 0.0092 | 0.0111 | 0.0137 | 0.0087 | 0.0126 |
| 40 MHz | 4 | 0.0181 | 0.0133 | 0.0118 | 0.0142 | 0.0101 | 0.0146 |
| 100 MHz | 2 | 0.0189 | 0.0117 | 0.0124 | 0.0167 | 0.0105 | 0.0165 |
| 100 MHz | 4 | 0.0336 | 0.0157 | 0.0146 | 0.0237 | 0.0110 | 0.0229 |

### BFP width 16

| Profile | Ports | Comp H2D | Comp kernel | Comp D2H | Dec H2D | Dec kernel | Dec D2H |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 0.0103 | 0.0101 | 0.0106 | 0.0107 | 0.0092 | 0.0112 |
| 20 MHz | 4 | 0.0100 | 0.0107 | 0.0098 | 0.0124 | 0.0090 | 0.0109 |
| 40 MHz | 2 | 0.0107 | 0.0112 | 0.0111 | 0.0106 | 0.0102 | 0.0120 |
| 40 MHz | 4 | 0.0199 | 0.0125 | 0.0140 | 0.0202 | 0.0107 | 0.0154 |
| 100 MHz | 2 | 0.0198 | 0.0115 | 0.0147 | 0.0201 | 0.0096 | 0.0167 |
| 100 MHz | 4 | 0.0317 | 0.0132 | 0.0210 | 0.0352 | 0.0117 | 0.0229 |

### OFDM

One pre launch, one cuFFT execution and one post launch cover the whole slot. "Compute"
is `pre + cuFFT + post`.

| Profile | DFT | Ports | Mod H2D | Mod pre | Mod cuFFT | Mod post | Mod D2H | Mod compute | Demod H2D | Demod pre | Demod cuFFT | Demod post | Demod D2H | Demod compute |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 768 | 2 | 0.0083 | 0.0065 | 0.0067 | 0.0067 | 0.0089 | 0.0199 | 0.0091 | 0.0068 | 0.0066 | 0.0062 | 0.0102 | 0.0196 |
| 20 MHz | 768 | 4 | 0.0114 | 0.0120 | 0.0068 | 0.0067 | 0.0103 | 0.0254 | 0.0125 | 0.0104 | 0.0068 | 0.0062 | 0.0134 | 0.0234 |
| 40 MHz | 1536 | 2 | 0.0110 | 0.0074 | 0.0073 | 0.0075 | 0.0121 | 0.0222 | 0.0120 | 0.0079 | 0.0074 | 0.0069 | 0.0167 | 0.0222 |
| 40 MHz | 1536 | 4 | 0.0183 | 0.0097 | 0.0074 | 0.0075 | 0.0171 | 0.0247 | 0.0192 | 0.0134 | 0.0074 | 0.0069 | 0.0199 | 0.0278 |
| 100 MHz | 4096 | 2 | 0.0192 | 0.0149 | 0.0081 | 0.0103 | 0.0181 | 0.0333 | 0.0242 | 0.0134 | 0.0081 | 0.0094 | 0.0228 | 0.0310 |
| 100 MHz | 4096 | 4 | 0.0336 | 0.0120 | 0.0081 | 0.0104 | 0.0274 | 0.0305 | 0.0387 | 0.0133 | 0.0081 | 0.0095 | 0.0361 | 0.0309 |

## Notes

- The transform is a batched cuFFT plan per `(dft_size, nof_ports)` and direction. The
  pre/post kernels are hand-written CUDA; only the DFT itself is cuFFT.
- All timings are on the H100 NVL and are not directly comparable to the CPU reference,
  which was not timed here.
- The two BFP correctness columns for AVX2 compare the AVX2 CPU implementation against
  the generic CPU implementation, not the GPU against AVX2; the GPU match column already
  covers the generic path byte-for-byte.

---

# Device-resident pipeline (Task 3)

Environment:

- GPU: NVIDIA H100 NVL, compute capability 9.0 ([MEASURED])
- Host CPU: AMD EPYC 9354 32-Core Processor; CPU path pinned to core 8 (NUMA0, in 0–15)
- CUDA: 12.5; OCUDU Release at `8937cab`, AVX2 BFP width 9
- Host buffers: preallocated then `cudaHostRegister`; two CUDA streams, double-buffered by slot
- Command: `CUDA_VISIBLE_DEVICES=GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058 ./build/test_pipeline --sustained 4000 --latency-iters 200 --cpu-core 8`
- Measurement lock: `/tmp/openru-measure.lock` held for the full run; cores 32–63 unused
- Label: **compute-only** (no fronthaul, no radio)

DL chain (device-resident): compressed U-plane H2D once → BFP decompress → grid → OFDM
pre → cuFFT → post → ci16 D2H once. UL is the reverse with cf32→cbf16 before BFP compress.

## Pipeline correctness vs standalone kernels

Byte-identical match of the device-resident chain against the same standalone kernel
sequence (no intermediate host round-trips).

| Profile | DFT | Ports | DL mismatches | UL mismatches | Pass |
|---|---:|---:|---:|---:|:---:|
| 20 MHz | 768 | 2 | 0 | 0 | PASS |
| 20 MHz | 768 | 4 | 0 | 0 | PASS |
| 40 MHz | 1536 | 2 | 0 | 0 | PASS |
| 40 MHz | 1536 | 4 | 0 | 0 | PASS |
| 100 MHz | 4096 | 2 | 0 | 0 | PASS |
| 100 MHz | 4096 | 4 | 0 | 0 | PASS |

## GPU vs CPU per-slot latency (ms) [MEASURED] compute-only

Wall time from H2D start to D2H done (GPU) vs OCUDU CPU chain on one pinned core (BFP
AVX2 decompress + OFDM modulate; UL reverse). 200 iterations after warm-up.

| Profile | Ports | Dir | GPU p50 | GPU p99 | GPU max | CPU p50 | CPU p99 | CPU max | Speedup (p50) |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | DL | 0.0316 | 0.0469 | 0.0470 | 0.0593 | 0.1836 | 0.1913 | 1.88x |
| 20 MHz | 2 | UL | 0.0333 | 0.0426 | 0.0481 | 0.0711 | 0.0784 | 0.0790 | 2.14x |
| 20 MHz | 4 | DL | 0.0343 | 0.0499 | 0.0500 | 0.1189 | 0.1257 | 0.1287 | 3.47x |
| 20 MHz | 4 | UL | 0.0345 | 0.0518 | 0.0521 | 0.1495 | 0.1598 | 0.1608 | 4.33x |
| 40 MHz | 2 | DL | 0.0344 | 0.0499 | 0.0502 | 0.1367 | 0.1477 | 0.1516 | 3.97x |
| 40 MHz | 2 | UL | 0.0422 | 0.0580 | 0.0581 | 0.1533 | 0.1663 | 0.1667 | 3.64x |
| 40 MHz | 4 | DL | 0.0456 | 0.0548 | 0.0548 | 0.2737 | 0.2855 | 0.2923 | 6.00x |
| 40 MHz | 4 | UL | 0.0527 | 0.0596 | 0.0596 | 0.3102 | 0.3229 | 0.3267 | 5.88x |
| 100 MHz | 2 | DL | 0.0559 | 0.0634 | 0.0647 | 0.4107 | 0.4295 | 0.4548 | 7.35x |
| 100 MHz | 2 | UL | 0.0580 | 0.0701 | 0.0702 | 0.4383 | 0.4531 | 0.4570 | 7.56x |
| 100 MHz | 4 | DL | 0.0676 | 0.0813 | 0.0874 | 0.8275 | 0.8403 | 0.8582 | 12.24x |
| 100 MHz | 4 | UL | 0.0752 | 0.0893 | 0.0894 | 0.8808 | 0.8973 | 0.8975 | 11.71x |

## GPU sustained throughput (4000 slots, 2 streams, double-buffered) [MEASURED]

| Profile | Ports | Dir | Wall ms/slot | Event p50 | Event p99 | Event max |
|---|---:|---|---:|---:|---:|---:|
| 20 MHz | 2 | DL | 0.0201 | 0.0358 | 0.0510 | 0.0646 |
| 20 MHz | 2 | UL | 0.0195 | 0.0361 | 0.0457 | 0.0544 |
| 20 MHz | 4 | DL | 0.0208 | 0.0391 | 0.0542 | 0.0654 |
| 20 MHz | 4 | UL | 0.0223 | 0.0407 | 0.0523 | 0.0597 |
| 40 MHz | 2 | DL | 0.0218 | 0.0403 | 0.0507 | 0.0644 |
| 40 MHz | 2 | UL | 0.0234 | 0.0437 | 0.0528 | 0.0631 |
| 40 MHz | 4 | DL | 0.0269 | 0.0513 | 0.0607 | 0.0763 |
| 40 MHz | 4 | UL | 0.0274 | 0.0512 | 0.0612 | 0.0756 |
| 100 MHz | 2 | DL | 0.0290 | 0.0545 | 0.0679 | 0.0693 |
| 100 MHz | 2 | UL | 0.0326 | 0.0624 | 0.0707 | 0.0897 |
| 100 MHz | 4 | DL | 0.0377 | 0.0727 | 0.0798 | 0.0948 |
| 100 MHz | 4 | UL | 0.0413 | 0.0807 | 0.0862 | 0.0979 |
