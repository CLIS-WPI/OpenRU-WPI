# Validation Results

Environment:

- GPU: NVIDIA H100 NVL, compute capability 9.0 ([MEASURED])
- CUDA: 12.5
- Reference: OCUDU `external/proto-ru` at `8937cab`, Release build, generic DFT
- Host buffers: pinned memory, 3 warm-up iterations, 30 measured iterations
- Command: `CUDA_VISIBLE_DEVICES=<H100-UUID> ./build/test_lowphy --iters 30`

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

"Mod ci16 mismatches" and "Mod max abs diff" are the maximum over the two slots of the
subframe. "Demod max abs error" and "Demod max relative error" are measured on the
unquantized `cf32` demodulator output.

| Profile | Ports | Mod ci16 mismatches | Mod max abs diff (LSB) | Demod max abs error | Demod max relative error | Demod exact |
|---|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 28 | 1 | 1.605e-07 | 3.523e-07 | 6.57% |
| 20 MHz | 4 | 57 | 1 | 1.738e-07 | 3.815e-07 | 6.45% |
| 40 MHz | 2 | 90 | 1 | 2.403e-07 | 3.795e-07 | 5.63% |
| 40 MHz | 4 | 175 | 1 | 2.458e-07 | 3.881e-07 | 5.55% |
| 100 MHz | 2 | 329 | 1 | 3.401e-07 | 4.309e-07 | 4.32% |
| 100 MHz | 4 | 644 | 1 | 3.401e-07 | 4.309e-07 | 4.28% |

The modulation mismatches are all 1 LSB and come from the different FFT accumulation
order described in `DESIGN.md`. The demodulator float output is within `4.4e-7`
relative of the CPU reference.

## Timing

Times are milliseconds per slot and include all ports. The kernel columns are
compute-only; the host-to-device and device-to-host columns are reported separately.
BFP widths 9 and 16 are shown because only those two widths take the AVX2 CPU path; the
GPU kernel handles all widths with the same code.

### BFP width 9

| Profile | Ports | Comp H2D | Comp kernel | Comp D2H | Dec H2D | Dec kernel | Dec D2H |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 0.0086 | 0.0102 | 0.0099 | 0.0082 | 0.0098 | 0.0115 |
| 20 MHz | 4 | 0.0126 | 0.0093 | 0.0097 | 0.0104 | 0.0091 | 0.0124 |
| 40 MHz | 2 | 0.0134 | 0.0090 | 0.0099 | 0.0127 | 0.0092 | 0.0123 |
| 40 MHz | 4 | 0.0173 | 0.0134 | 0.0121 | 0.0166 | 0.0096 | 0.0148 |
| 100 MHz | 2 | 0.0196 | 0.0113 | 0.0122 | 0.0166 | 0.0101 | 0.0162 |
| 100 MHz | 4 | 0.0323 | 0.0154 | 0.0147 | 0.0223 | 0.0109 | 0.0223 |

### BFP width 16

| Profile | Ports | Comp H2D | Comp kernel | Comp D2H | Dec H2D | Dec kernel | Dec D2H |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 0.0100 | 0.0099 | 0.0107 | 0.0096 | 0.0094 | 0.0112 |
| 20 MHz | 4 | 0.0116 | 0.0099 | 0.0102 | 0.0143 | 0.0075 | 0.0123 |
| 40 MHz | 2 | 0.0133 | 0.0095 | 0.0113 | 0.0153 | 0.0078 | 0.0123 |
| 40 MHz | 4 | 0.0185 | 0.0128 | 0.0140 | 0.0225 | 0.0100 | 0.0154 |
| 100 MHz | 2 | 0.0203 | 0.0115 | 0.0145 | 0.0208 | 0.0092 | 0.0165 |
| 100 MHz | 4 | 0.0310 | 0.0145 | 0.0210 | 0.0337 | 0.0113 | 0.0236 |

### OFDM

| Profile | Ports | Mod H2D | Mod kernel | Mod D2H | Demod H2D | Demod kernel | Demod D2H |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 MHz | 2 | 0.0075 | 0.0176 | 0.0127 | 0.0113 | 0.0162 | 0.0125 |
| 20 MHz | 4 | 0.0119 | 0.0165 | 0.0138 | 0.0136 | 0.0136 | 0.0161 |
| 40 MHz | 2 | 0.0105 | 0.0226 | 0.0158 | 0.0179 | 0.0226 | 0.0144 |
| 40 MHz | 4 | 0.0180 | 0.0247 | 0.0202 | 0.0246 | 0.0215 | 0.0227 |
| 100 MHz | 2 | 0.0184 | 0.0361 | 0.0174 | 0.0237 | 0.0342 | 0.0225 |
| 100 MHz | 4 | 0.0334 | 0.0350 | 0.0271 | 0.0406 | 0.0356 | 0.0351 |

## Notes

- The modulator/demodulator launch one block per `(port, symbol)`, so the kernel time
  scales with ports and DFT size. A production integration should batch the whole slot
  into one launch.
- All timings are on the H100 NVL and are not directly comparable to the CPU reference,
  which was not timed here.
