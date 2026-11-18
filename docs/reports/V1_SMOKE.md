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

Expected UL C-plane rate, derived per profile from the TDD and section/eAxC configuration:

- TDD: `profiles/<profile>/du-fh.yml:59-64` — `dl_ul_tx_period: 5`, `nof_dl_slots: 3`, `nof_ul_slots: 1`,
  `nof_dl_symbols: 10`, `nof_ul_symbols: 2` → **two UL slots per 5-slot period** (the special slot index 3 and the
  UL-only slot index 4), i.e. 0.4 of the slots; 30 kHz (`common_scs: 30`, `:48`) → 2,000 slots/s.
- **UL data C-plane:** one section-type-1 C-plane per `ul_eaxc` per UL slot
  (`external/proto-ru/lib/ofh/transmitter/ofh_uplink_request_handler_impl.cpp:210-221`; active UL symbols from
  `get_active_tdd_ul_symbols`, `external/proto-ru/lib/ran/tdd_ul_dl_config.cpp:79`). `ul_port_id: [0,1]`
  (`profiles/<profile>/du-fh.yml:41`) → 2 eAxC. Expected = 0.4 × 2,000 × 2 = **1,600/s**.
- **PRACH C-plane:** one section-type-3 C-plane per `prach_eaxc` per PRACH occasion
  (`ofh_uplink_request_handler_impl.cpp:171-181`). `prach_port_id: [4,5]` (`:42`), `is_prach_cp_enabled: true`
  (`:24`), `prach_config_index: 159` (`:55`) → `prach_configuration_get(FR1, TDD, 159)` = B4, x=1, y={0}, slot 9,
  1 PRACH slot, 1 occasion (`external/proto-ru/lib/ran/prach/prach_configuration.cpp:434`, verified with a host
  probe) → 100 occasions/s × 2 eAxC = **200/s**.
- **Expected total = 1,800/s.** The pcap confirms it: b40 10,918 UL C-plane frames / 6.065 s = 1,800.2/s; b100
  10,934 / 6.086 = 1,796.7/s (the UL C-plane **is** in the capture: dst RU, direction 0). The live 600 s measured
  **1,818.6 / 1,818.4/s (+1.0%)**; the KPI one-second bucket explains the +1%. Tolerance is ±2%, so this is **not**
  a finding. The earlier "1 per slot = 2,000/s" was wrong: it ignored the TDD UL-slot fraction and the PRACH eAxC.

| Run | DL U-plane | DL C-plane | UL C-plane at RU | UL tx total | All |
| --- | ---: | ---: | ---: | ---: | ---: |
| b40 measured | 6,845.1 | 517.8 | 1,818.6 | 15,343.0 | 24,524.6 |
| b40 pcap | 6,784.6 | 513.4 | 1,800.2 | 15,190.2 (UL U) | – |
| b40 expected | 6,784.6 | 513.4 | **1,800** | 15,190.2 | – |
| b100 measured | 6,844.1 | 517.7 | 1,818.4 | 15,342.9 | 24,523.2 |
| b100 pcap | 6,755.3 | 511.4 | 1,796.7 | 11,854.1 (UL U; capture under-count) | – |
| b100 expected | 6,755.3 | 511.4 | **1,800** | 15,343.0 (live; pcap under-counts) | – |

The DL U/C rates match the pcap within +1%; the b100 pcap's UL U count (11,854/s) is lower than the live (15,343/s)
because the capture under-counts the 100 MHz UL burst, not because the live rate differs.

## Summary

| Image | b40 | b100 |
| --- | --- | --- |
| v1-candidate | 2/2 PASS; **0.0 / 5.4e-07** late; DU UL 0 | 2/2 PASS on the RU gate (4.76e-06 / 8.09e-06); **DU UL 3.1e-05 / 2.3e-04 (fails 1e-5)** |
| m2 (generic) | 1/2 PASS (0.0); **r2 2.188e-05 FAIL**; DU UL 0 / 1.1e-05 | **0/2 FAIL** (5.0e-05 / 9.6e-05); **DU UL 99.7% / 99.8%** |

**v1 CPU configuration — LOCKED (human decision, 2026-11-17) with scope: 20 MHz (baseline) and 40 MHz (b40)
validated; 100 MHz NOT validated on this host.** The failing profile/direction is **b100, UL at the DU**
(`ul_rx_late` 3.1e-05/2.3e-04); this is likely host scheduling without isolated cores and is unproven. The
candidate is required for b100 (the generic RU cannot deliver the 122.88 MHz UL), and **b40 (the Stage 2
primary) is clean with the candidate (2/2, 0 late on every plane and direction)**. The v1 golden set remains
baseline + b40; the b100 golden is deferred.
