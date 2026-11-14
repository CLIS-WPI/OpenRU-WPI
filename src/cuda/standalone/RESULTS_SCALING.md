# Scaling study — CPU cores needed vs antenna ports (Task 4)

Profile: **100 MHz**, **30 kHz SCS**, slot duration **0.5 ms**.
Label: **[MEASURED] H100 compute-only** (no fronthaul, no radio). The target embedded GPU
(Jetson) will be slower; **no Jetson numbers are claimed**.

Chain (device-resident):

- DL: compressed **layers** H2D → BFP decompress → **Category-B precoding** (layers→ports, per PRB) → OFDM mod → ci16 D2H
- UL: ci16 H2D → OFDM demod → **combining** (Wᴴ, ports→layers) → BFP compress → D2H

CPU baseline: FFTW DFT + AVX-512 BFP, one isolated core (10).

## CPU precoding (PR #4 review fixes)

### How OCUDU production calls the precoder

`lib/phy/support/resource_grid_mapper_impl.cpp:245-263`:

- Weights are **pre-stored** in `precoding_configuration` and fetched with
  `precoding.get_prg_coefficients(i_prg)` — not rebuilt per call.
- For each PRG: `re_buffer_reader_view` / `re_buffer_writer_view` over contiguous REs,
  then `precoder->apply_precoding(output_re_prg, input_re_prg, prg_weights)`.
- Inner kernel: `channel_precoder_avx512.cpp:221-269` (`apply_precoding_port`),
  capped at `MAX_NOF_PORTS = 4` (`precoding_constants.h:24`).

### What was wrong in the first harness

The first scaling harness rebuilt a `precoding_weight_matrix` and converted bf16→cf
**per PRB × symbol**, then called `apply_precoding` on 12 REs. That overhead — not the
~1.1×10⁶ FLOPs — drove CPU 100 MHz / 2-port DL from **0.20 ms** (PR #3, no precoding)
to **0.49 ms**.

### Timed CPU path (all port counts)

- **Single implementation** for the whole curve: AVX-512 Cat-B strip
  (`cpu_catb_precoding.h`), same math as `apply_precoding_port`, weights pre-built in
  `WeightBank`, layers converted to `cf_t` once. Ports > 4 use the same kernel (no
  scalar fallback on the timed path).
- **Scalar reference** (`channel_precoder_generic.cpp:9-30`) is correctness-only.
- **OCUDU PRG-view path** (production call pattern, including 4-port blocks when
  ports > 4) is still timed as `ocudu_prg_precode_p50` for contrast: Cat-B with
  1-PRB PRGs pays ~273×14 virtual calls of 12 REs and cannot amortize AVX.

### Precoding stage alone (2 ports / 2 layers) [MEASURED]

| Path | p50 | FLOPs | Effective |
|---|---:|---:|---:|
| CPU AVX-512 Cat-B | **0.120 ms** | 1.101×10⁶ | 9.2 GFLOP/s |
| OCUDU PRG views (1 PRB) | 0.511 ms | same | 2.2 GFLOP/s |
| GPU CUDA Cat-B | **0.0063 ms** | same | ~175 GFLOP/s |

CPU stage is still above a few hundredths of a ms: Cat-B forces a weight change every
12 REs, so the inner loop cannot run long contiguous AVX strips. The important fix is
removing harness rebuild/copy overhead and using one vectorized implementation for all
ports. Full-chain CPU DL at 2×2 is **0.28 ms** (was 0.49 ms).

## Correctness tolerance

- **Pass quantity:** max \|gpu − cpu\| over complex values after bf16→float
  (`hypot(Δre, Δim)`).
- **Pass threshold:** **1×10⁻³** absolute. Rows with 1–3 mismatches at the diagnostic
  tripwire still PASS when max \|err\| ≤ 1×10⁻³.
- **Diagnostic tripwire:** count REs with \|err\| > **1×10⁻⁵** (reported as
  `precode_mismatches` / `combine_mismatches`; not the pass gate).
- Optimized CPU vs scalar reference uses the same 1×10⁻³ max-\|err\| gate.

Measurement lock held; `CUDA_VISIBLE_DEVICES=GPU-509d8ab3-…`.
Command: `./build/test_scaling --latency-iters 80 --cpu-core 10 --csv scaling_results.csv`

## Results table

| Ports | Layers | GPU DL p50/p99/max | GPU UL p50/p99/max | CPU DL p50/p99/max | CPU UL p50/p99/max | GPU p99/p50 DL\|UL | CPU p99/p50 DL\|UL | cores_needed (DL+UL) | GPU frac slot DL\|UL |
|---:|---:|---|---|---|---|---|---|---:|---|
| 2 | 2 | 0.0571/0.0648/0.0648 | 0.0632/0.0711/0.0711 | 0.2824/0.3099/0.3099 | 0.3423/0.3550/0.3550 | 1.14\|1.12 | 1.10\|1.04 | 2 | 0.130\|0.142 |
| 4 | 2 | 0.0638/0.0760/0.0760 | 0.0845/0.0895/0.0895 | 0.5012/0.8391/0.8391 | 0.5673/0.5820/0.5820 | 1.19\|1.06 | 1.67\|1.03 | 3 | 0.152\|0.179 |
| 4 | 4 | 0.0778/0.0897/0.0897 | 0.0836/0.0908/0.0908 | 0.5753/0.6000/0.6000 | 0.8357/0.8568/0.8568 | 1.15\|1.09 | 1.04\|1.03 | 3 | 0.179\|0.182 |
| 8 | 2 | 0.0846/0.0996/0.0996 | 0.0782/0.0934/0.0934 | 0.9281/2.5194/2.5194 | 1.0668/1.0857/1.0857 | 1.18\|1.19 | 2.71\|1.02 | 8 | 0.199\|0.187 |
| 8 | 4 | 0.0919/0.1008/0.1008 | 0.0896/0.0959/0.0959 | 1.0289/1.0591/1.0591 | 1.4836/1.5018/1.5018 | 1.10\|1.07 | 1.03\|1.01 | 6 | 0.202\|0.192 |
| 16 | 2 | 0.1284/0.1346/0.1346 | 0.1194/0.1334/0.1334 | 1.7998/1.8230/1.8230 | 1.9896/2.1764/2.1764 | 1.05\|1.12 | 1.01\|1.09 | 8 | 0.269\|0.267 |
| 16 | 4 | 0.1391/0.1446/0.1446 | 0.1225/0.1389/0.1389 | 1.9636/2.0074/2.0074 | 2.7891/2.8437/2.8437 | 1.04\|1.13 | 1.02\|1.02 | 10 | 0.289\|0.278 |
| 32 | 2 | 0.2278/0.2342/0.2342 | 0.2092/0.2120/0.2120 | 3.6592/3.7234/3.7234 | 4.2481/4.3468/4.3468 | 1.03\|1.01 | 1.02\|1.02 | 17 | 0.468\|0.424 |
| 32 | 4 | 0.2371/0.2423/0.2423 | 0.2212/0.2237/0.2237 | 3.8930/3.9527/3.9527 | 5.7334/5.8427/5.8427 | 1.02\|1.01 | 1.02\|1.02 | 20 | 0.485\|0.447 |
| 64 | 2 | 0.4189/0.4259/0.4259 | 0.3787/0.3904/0.3904 | 8.4944/8.6321/8.6321 | 10.7501/11.1107/11.1107 | 1.02\|1.03 | 1.02\|1.03 | 40 | 0.852\|0.781 |

`cores_needed = ceil((CPU_DL_p99 + CPU_UL_p99) / 0.5 ms)`.
`GPU frac slot = GPU_p99 / 0.5 ms`.
Layers=4 skipped when layers > ports. Ports=64 / layers=4 not run: stopped after 64/2.

## Thresholds (recomputed from fixed CPU numbers)

- **(a) One CPU core misses p99** (DL p99, UL p99, or **DL+UL p99** > 0.5 ms): first at
  **2 ports**. Individually DL and UL are each under a slot at 2×2 (0.31 / 0.36 ms), but
  their sum (0.66 ms) still exceeds one 0.5 ms slot on a single core.
- **(b) GPU exceeds 50% of the slot** (DL or UL **p50** > 0.25 ms): first at **64 ports**
  (32 ports is ~47% of the slot on DL p50; 64 ports is ~84%).
- Stopped further growth after 64/2: both GPU DL and UL **p50** exceed 50% of the slot.
  Device memory at 64 ports remains modest (~100 MB working set).

## Plot CSV

`scaling_results.csv` — columns include stage-only `gpu_precode_p50_ms`,
`cpu_precode_p50_ms`, `ocudu_prg_precode_p50_ms`, `precode_flops`, max errors, and full
p50/p99/max for GPU and CPU chains.
