# Scaling study — CPU cores needed vs antenna ports (Task 4)

Profile: **100 MHz**, **30 kHz SCS**, slot duration **0.5 ms**.
Label: **[MEASURED] H100 compute-only** (no fronthaul, no radio). The target embedded GPU
(Jetson) will be slower; **no Jetson numbers are claimed**.

Chain (device-resident):

- DL: compressed **layers** H2D → BFP decompress → **Category-B precoding** (layers→ports, per PRB) → OFDM mod → ci16 D2H
- UL: ci16 H2D → OFDM demod → **combining** (Wᴴ, ports→layers) → BFP compress → D2H

CPU baseline: FFTW DFT + AVX-512 BFP, one isolated core (10). Precoding:

- Ports ≤ 4: OCUDU `channel_precoder` avx512 — factory in
  `lib/phy/generic_functions/precoding/precoding_factories.cpp:32–33`,
  `apply_precoding` in `channel_precoder_impl.cpp:9–51`,
  port cap `precoding_constants.h:24` (`MAX_NOF_PORTS = 4`).
- Ports > 4: labeled **reference** matching
  `channel_precoder_generic.cpp:9–30` (OCUDU does not support >4 ports).

GPU precoding: custom CUDA Cat-B kernel (`kernels/precoding.cu`).

Measurement lock held; `CUDA_VISIBLE_DEVICES=GPU-509d8ab3-…`.
Command: `./build/test_scaling --latency-iters 80 --cpu-core 10 --csv scaling_results.csv`

Correctness: GPU vs CPU precoding/combining in float after bf16 round-trip; pass if
max \|error\| ≤ 1e-3. All listed configs **PASS**.

## Results table

| Ports | Layers | GPU DL p50/p99/max | GPU UL p50/p99/max | CPU DL p50/p99/max | CPU UL p50/p99/max | GPU p99/p50 DL\|UL | CPU p99/p50 DL\|UL | cores_needed (DL+UL) | GPU frac slot DL\|UL |
|---:|---:|---|---|---|---|---|---|---:|---|
| 2 | 2 | 0.0576/0.0660/0.0660 | 0.0631/0.0745/0.0745 | 0.4922/0.5091/0.5091 | 0.5483/0.5603/0.5603 | 1.15\|1.18 | 1.03\|1.02 | 3 | 0.132\|0.149 |
| 4 | 2 | 0.0649/0.0726/0.0726 | 0.0779/0.0866/0.0866 | 0.8654/1.4563/1.4563 | 0.8293/0.8401/0.8401 | 1.12\|1.11 | 1.68\|1.01 | 5 | 0.145\|0.173 |
| 4 | 4 | 0.0773/0.0935/0.0935 | 0.0844/0.0977/0.0977 | 1.1218/1.1463/1.1463 | 1.3317/1.3506/1.3506 | 1.21\|1.16 | 1.02\|1.01 | 5 | 0.187\|0.195 |
| 8 | 2 | 0.0857/0.0958/0.0958 | 0.0783/0.0868/0.0868 | 2.3464/4.9264/4.9264 | 1.4529/1.4739/1.4739 | 1.12\|1.11 | 2.10\|1.01 | 13 | 0.192\|0.174 |
| 8 | 4 | 0.0954/0.1335/0.1335 | 0.0905/0.1007/0.1007 | 3.0111/3.0774/3.0774 | 2.2723/2.2939/2.2939 | 1.40\|1.11 | 1.02\|1.01 | 11 | 0.267\|0.201 |
| 16 | 2 | 0.1248/0.1359/0.1359 | 0.1194/0.1264/0.1264 | 4.6594/4.8790/4.8790 | 2.7666/2.7903/2.7903 | 1.09\|1.06 | 1.05\|1.01 | 16 | 0.272\|0.253 |
| 16 | 4 | 0.1376/0.1462/0.1462 | 0.1233/0.1385/0.1385 | 5.9794/6.0947/6.0947 | 4.2478/4.2693/4.2693 | 1.06\|1.12 | 1.02\|1.01 | 21 | 0.292\|0.277 |
| 32 | 2 | 0.2273/0.2383/0.2383 | 0.2087/0.2205/0.2205 | 9.3547/9.4802/9.4802 | 5.6691/5.7486/5.7486 | 1.05\|1.06 | 1.01\|1.01 | 31 | 0.477\|0.441 |
| 32 | 4 | 0.2383/0.2460/0.2460 | 0.2155/0.2243/0.2243 | 12.0218/12.2716/12.2716 | 8.5974/8.6737/8.6737 | 1.03\|1.04 | 1.02\|1.01 | 42 | 0.492\|0.449 |
| 64 | 2 | 0.4196/0.4268/0.4268 | 0.3784/0.3868/0.3868 | 19.4266/19.7857/19.7857 | 12.0893/12.3652/12.3652 | 1.02\|1.02 | 1.02\|1.02 | 65 | 0.854\|0.774 |

`cores_needed = ceil((CPU_DL_p99 + CPU_UL_p99) / 0.5 ms)`.
`GPU frac slot = GPU_p99 / 0.5 ms`.
Layers=4 skipped when layers > ports. Ports=64 / layers=4 not run: stopped after 64/2.

## Thresholds

- **(a) One CPU core misses p99** (DL p99, UL p99, or sum > 0.5 ms): first at **2 ports**
  (Cat-B chain already exceeds a single 0.5 ms slot on the fair CPU baseline).
- **(b) GPU exceeds 50% of the slot** (DL or UL **p50** > 0.25 ms): first at **64 ports**
  (32 ports is ~49% of the slot on DL p50; 64 ports is ~84%).
- Stopped further growth after 64/2: both GPU DL and UL **p50** exceed 50% of the slot;
  additional ports are not meaningful for realtime on this profile. Device memory at 64 ports
  remains modest (~100 MB working set).

## Plot CSV

`scaling_results.csv` — columns include `ports`, `layers`, `cores_needed_dl_ul`,
`gpu_frac_slot_dl`, `gpu_frac_slot_ul`, and full p50/p99/max for GPU and CPU.
