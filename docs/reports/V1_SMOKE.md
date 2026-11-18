# v1 candidate — live 600 s smoke-fh (b40 and b100)

Reference image: **`v1-candidate`** = `openru/protoru:d22439c6267a` (FFTW + `x86-64-v4`/AVX-512 + ESTIMATE,
submodule `d8d2097894` with the dump gate + flush). Comparison image: **`m2`** = generic DFT + `x86-64-v4`
(`6b630a5c1dab`).

Protocol: `PROTORU_PROFILE=null`, MTU 9000, quiet-host pre/post check, 600 s, two cold runs per profile per image.
The gate uses `late / all_pkts < 1e-5` and `drop = 0`; the RU-side and DU-side planes/directions are reported
separately because the script's aggregate gate counts the RU's DL + UL frames.

## v1 candidate results

| Run | Warm-up | Gate all_pkts | RU late DL U / DL C / UL C | RU late_frac | Full late_frac | Drop |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| b40 r1 | 0 s | 14,714,738 | 0 / 0 / 8 | 5.437e-07 | 5.437e-07 | 0 |
| b40 r2 | 0 s | 14,715,610 | 0 / 0 / 0 | **0.0** | **0.0** | 0 |
| b100 r1 | 0 s | 14,713,488 | 48 / 4 / 18 | 4.758e-06 | 4.758e-06 | 0 |
| b100 r2 | 57 s | 13,281,602 | 36 / 0 / 6 | 3.162e-06 | 8.087e-06 | 0 |

| Run | DU UL rx | DU `ul_rx_late` | DU UL late fraction | DU `nof_late_cp_dl/up_dl/cp_ul` |
| --- | ---: | ---: | ---: | --- |
| b40 r1 | 9,324,248 | 0 | 0.0 | 0 / 0 / 0 |
| b40 r2 | 9,314,056 | 0 | 0.0 | 0 / 0 / 0 |
| b100 r1 | 9,331,434 | **290** | **3.108e-05** | 0 / 0 / 0 |
| b100 r2 | 9,101,119 | **2,085** | **2.291e-04** | 0 / 0 / 0 |

## Rates (frames/s; 600 s window) vs expected

Expected = same-profile OFH pcap frame rate (DL U/C and UL U); the UL C-plane is not present in the capture (the
RU's UL C-plane is transmit-side) and its theoretical rate is 1 per slot = 2,000/s at 30 kHz.

| Run | DL U-plane | DL C-plane | UL C-plane at RU | UL tx total | All |
| --- | ---: | ---: | ---: | ---: | ---: |
| b40 measured | 6,845.1 | 517.8 | 1,818.6 | 15,343.0 | 24,524.6 |
| b40 pcap | 6,784.6 | 513.4 | – (TX-side) | 15,190.2 (UL U) | – |
| b100 measured | 6,844.1 | 517.7 | 1,818.4 | 15,342.9 | 24,523.2 |
| b100 pcap | 6,755.3 | 511.4 | – (TX-side) | 11,854.1 (UL U; capture under-count) | – |

The DL U/C rates match the pcap within +1%; the b100 pcap's UL U count (11,854/s) is lower than the live
(15,343/s) because the capture under-counts the 100 MHz UL burst, not because the live rate differs. The UL
C-plane rate is 9% below 1/slot.

## v1 lock decision

**Not locked (strict per-direction rule).** The candidate passes the script's aggregate gate for b40 and b100
(`drop = 0`, `late_frac_all` 5.4e-07 … 8.1e-06), and **b40 (the Stage 2 primary) is clean on every plane and
direction**. The b100 RU-side gate passes, but the **DU-side UL `ul_rx_late` is 290 (3.1e-05) and 2,085 (2.3e-04)**,
which exceeds the 1e-5 bar in the UL direction. Recorded as the failing profile/direction: **b100, UL at the DU**.
The v1 golden set remains baseline + b40 (b100 golden deferred; no isolated cores on this host).

## Generic-DFT comparison

## Generic-DFT (`m2`) results

| Run | Gate all_pkts | RU late DL U / DL C / UL C | RU late_frac | Drop | DU UL rx | DU `ul_rx_late` | DU UL late fraction |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| b40 r1 | 14,715,822 | 0 / 0 / 0 | **0.0** | 0 | 9,312,480 | 0 | 0.0 |
| b40 r2 | 14,716,058 | 322 / 0 / 0 | **2.188e-05 FAIL** (quiet host, valid) | 0 | 9,300,866 | 100 | 1.075e-05 |
| b100 r1 | 12,389,136 | 477 / 34 / 109 | **5.004e-05 FAIL** (quiet host, valid) | 0 | 6,874,668 | **6,854,956 (99.7%)** | **9.971e-01** |
| b100 r2 | 10,975,401 | 788 / 56 / 206 | **9.567e-05 FAIL** (quiet host, valid) | 0 | 5,585,618 | **5,573,771 (99.8%)** | **9.979e-01** |

The generic b40 r1 matches the candidate (0.0 late, 0 drop, same DL U/C and UL rates). The generic b40 r2 fails the
RU-side gate (322 late, 2.188e-05, quiet host valid) and its DU UL late is 100 (1.1e-05); the generic image is **not
consistently clean even at 40 MHz**. b100 r1 fails catastrophically: the generic RU cannot deliver the 122.88 MHz UL, so the DU marks 99.7% of the UL late (6,854,956 / 6,874,668) in addition to the RU-side 5.0e-05. b100 r2 also fails (9.567e-05; DU UL 99.8%).

## Summary

| Image | b40 | b100 |
| --- | --- | --- |
| v1-candidate | 2/2 PASS; **0.0 / 5.4e-07** late; DU UL 0 | 2/2 PASS on the RU gate (4.76e-06 / 8.09e-06); **DU UL 3.1e-05 / 2.3e-04 (fails 1e-5)** |
| m2 (generic) | 1/2 PASS (0.0); **r2 2.188e-05 FAIL**; DU UL 0 / 1.1e-05 | **0/2 FAIL** (5.0e-05 / 9.6e-05); **DU UL 99.7% / 99.8%** |

**v1 is not locked** under the strict per-plane/per-direction rule: the failing profile/direction is **b100, UL at the
DU**. The v1 candidate is nevertheless clearly required for b100 (the generic RU cannot deliver the 122.88 MHz UL),
and **b40 (the Stage 2 primary) is clean with the candidate (2/2, 0 late on every plane and direction)**.
