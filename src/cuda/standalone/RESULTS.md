# Validation Results

Environment:

- GPU: NVIDIA H100 NVL, compute capability 9.0 ([MEASURED])
- CUDA: 12.5, cuFFT from the same toolkit
- Reference: OCUDU `external/proto-ru` at `8937cab`, Release build, generic DFT
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
