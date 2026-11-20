# OpenRU low-PHY cost model (per slot) — clean run `clean-20261120T232220Z`

Run id: `clean-20261120T232220Z`. Raw CSVs: `results/costmodel/raw/clean-20261120T232220Z/final`.

Per-slot latency in ms; p50/p99 over the configured iterations. CPU rows are single-core (`taskset`), GPU rows exclude warmup. GPU is ISA-independent and was measured on `GPU-509d8ab3` (H100 NVL).


## Conditions

- Reserved cores: `[19, 21, 31]` on NUMA node `0`; benchmark core `19`; GPU on NUMA `0`; threads/core `1` (SMT off => one logical CPU per physical core).
- Rejection rule: a run fails only if another process used a reserved core (threshold 5.0% of a core) or another process used the GPU.
- Per-backend core evidence: avx2: max foreign {'19': 1.71, '21': 0.0, '31': 0.0}%, freq 3.8000 GHz; avx512: max foreign {'19': 2.41, '21': 0.0, '31': 0.0}%, freq 3.8000 GHz; gpu: max foreign {'19': 4.3, '21': 0.0, '31': 0.0}%, freq 3.8000 GHz.
- GPU `GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058`: SM 345.0-1785.0 MHz (median 1785.0), memory 2619.0 MHz, power 63.42-93.3 W, pstate ['P0'].
- Host-wide load (information only): avx2 3.38 / 2.53 / 2.02 -> 3.38 / 2.53 / 2.02; avx512 3.38 / 2.53 / 2.02 -> 3.35 / 2.54 / 2.03; gpu 3.35 / 2.54 / 2.03 -> 3.35 / 2.54 / 2.03.
- p50 is the headline. p99 still contains isolated host-scheduler outliers (no RT priority is available to the benchmark on this shared host).

| BW | ports | kernel | CPU AVX2 p50 | CPU AVX2 p99 | CPU AVX-512 p50 | CPU AVX-512 p99 | GPU p50 | GPU p99 | GPU H2D p50 | GPU D2H p50 | pass |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 20 | 1 | OFDM | 0.0114 | 0.0190 | 0.0108 | 0.0188 | 0.0134 | 0.0166 | 0.0074 | 0.0188 | PASS |
| 20 | 1 | BFP | 0.0054 | 0.0128 | 0.0042 | 0.0108 | 0.0059 | 0.0062 | 0.0067 | 0.0127 | PASS |
| 20 | 1 | PREC | 0.0202 | 0.0301 | 0.0221 | 0.0316 | 0.0056 | 0.0058 | 0.0067 | 0.0138 | PASS |
| 20 | 2 | OFDM | 0.0233 | 0.0302 | 0.0205 | 0.0284 | 0.0179 | 0.0222 | 0.0099 | 0.0210 | PASS |
| 20 | 2 | BFP | 0.0108 | 0.0186 | 0.0083 | 0.0150 | 0.0108 | 0.0120 | 0.0098 | 0.0173 | PASS |
| 20 | 2 | PREC | 0.0388 | 0.0510 | 0.0607 | 0.0747 | 0.0109 | 0.0116 | 0.0097 | 0.0185 | PASS |
| 20 | 4 | OFDM | 0.0477 | 0.0566 | 0.0450 | 0.0560 | 0.0205 | 0.0220 | 0.0134 | 0.0273 | PASS |
| 20 | 4 | BFP | 0.0217 | 0.0286 | 0.0166 | 0.0243 | 0.0109 | 0.0119 | 0.0137 | 0.0180 | PASS |
| 20 | 4 | PREC | 0.0919 | 0.0998 | 0.1444 | 0.1514 | 0.0105 | 0.0118 | 0.0139 | 0.0221 | PASS |
| 20 | 8 | OFDM | 0.1007 | 0.1068 | 0.0918 | 0.1053 | 0.0185 | 0.0200 | 0.0208 | 0.0382 | PASS |
| 20 | 8 | BFP | 0.0432 | 0.0521 | 0.0331 | 0.0436 | 0.0100 | 0.0151 | 0.0206 | 0.0230 | PASS |
| 20 | 8 | PREC | 0.1700 | 0.1807 | 0.2763 | 0.2849 | 0.0105 | 0.0146 | 0.0139 | 0.0316 | PASS |
| 40 | 1 | OFDM | 0.0284 | 0.0378 | 0.0271 | 0.0383 | 0.0206 | 0.0240 | 0.0099 | 0.0194 | PASS |
| 40 | 1 | BFP | 0.0080 | 0.0145 | 0.0084 | 0.0150 | 0.0111 | 0.0120 | 0.0098 | 0.0167 | PASS |
| 40 | 1 | PREC | 0.0409 | 0.0518 | 0.0462 | 0.0563 | 0.0105 | 0.0118 | 0.0098 | 0.0189 | PASS |
| 40 | 2 | OFDM | 0.0563 | 0.0684 | 0.0556 | 0.0679 | 0.0222 | 0.0234 | 0.0137 | 0.0255 | PASS |
| 40 | 2 | BFP | 0.0156 | 0.0220 | 0.0166 | 0.0282 | 0.0107 | 0.0119 | 0.0139 | 0.0185 | PASS |
| 40 | 2 | PREC | 0.0790 | 0.0874 | 0.1259 | 0.1342 | 0.0102 | 0.0114 | 0.0141 | 0.0224 | PASS |
| 40 | 4 | OFDM | 0.1178 | 0.1268 | 0.1161 | 0.1240 | 0.0202 | 0.0209 | 0.0213 | 0.0366 | PASS |
| 40 | 4 | BFP | 0.0313 | 0.0409 | 0.0334 | 0.0435 | 0.0099 | 0.0151 | 0.0212 | 0.0236 | PASS |
| 40 | 4 | PREC | 0.1897 | 0.2007 | 0.3011 | 0.3143 | 0.0088 | 0.0135 | 0.0212 | 0.0322 | PASS |
| 40 | 8 | OFDM | 0.2415 | 0.2528 | 0.2336 | 0.2443 | 0.0229 | 0.0246 | 0.0365 | 0.0593 | PASS |
| 40 | 8 | BFP | 0.0640 | 0.0764 | 0.0678 | 0.0789 | 0.0151 | 0.0163 | 0.0363 | 0.0315 | PASS |
| 40 | 8 | PREC | 0.3886 | 0.4006 | 0.6039 | 0.6146 | 0.0092 | 0.0151 | 0.0213 | 0.0480 | PASS |
| 100 | 1 | OFDM | 0.0796 | 0.0892 | 0.0748 | 0.0898 | 0.0261 | 0.0279 | 0.0159 | 0.0318 | PASS |
| 100 | 1 | BFP | 0.0218 | 0.0318 | 0.0212 | 0.0294 | 0.0109 | 0.0119 | 0.0157 | 0.0196 | PASS |
| 100 | 1 | PREC | 0.1093 | 0.1182 | 0.1262 | 0.1352 | 0.0100 | 0.0108 | 0.0159 | 0.0250 | PASS |
| 100 | 2 | OFDM | 0.1557 | 0.1662 | 0.1387 | 0.1489 | 0.0241 | 0.0284 | 0.0261 | 0.0460 | PASS |
| 100 | 2 | BFP | 0.0439 | 0.0549 | 0.0427 | 0.0566 | 0.0090 | 0.0102 | 0.0254 | 0.0263 | PASS |
| 100 | 2 | PREC | 0.2020 | 0.2189 | 0.3232 | 0.3348 | 0.0076 | 0.0090 | 0.0256 | 0.0362 | PASS |
| 100 | 4 | OFDM | 0.3166 | 0.3387 | 0.2785 | 0.2899 | 0.0270 | 0.0293 | 0.0453 | 0.0746 | PASS |
| 100 | 4 | BFP | 0.0950 | 0.1062 | 0.0921 | 0.0983 | 0.0132 | 0.0148 | 0.0450 | 0.0368 | PASS |
| 100 | 4 | PREC | 0.4906 | 0.5094 | 0.7764 | 0.7905 | 0.0104 | 0.0119 | 0.0451 | 0.0595 | PASS |
| 100 | 8 | OFDM | 0.6867 | 0.7083 | 0.5556 | 0.9627 | 0.0282 | 0.0307 | 0.0726 | 0.1225 | PASS |
| 100 | 8 | BFP | 0.1863 | 0.2027 | 0.1782 | 0.1927 | 0.0182 | 0.0207 | 0.0724 | 0.0667 | PASS |
| 100 | 8 | PREC | 0.9212 | 1.5490 | 1.4815 | 1.4997 | 0.0117 | 0.0147 | 0.0452 | 0.0964 | PASS |

## Cat-B AVX2 vs AVX-512 (diagnostic)

The harness calls `apply_precoding` once per PRB (12 REs). AVX-512 vectorizes
8 REs (`AVX512_CF_SIZE=8`) and runs a 4-RE scalar tail; AVX2 vectorizes all
12 REs. The AVX-512 `ps_to_cbf16` also uses the non-BF16 integer fallback
(the file is built with `-mavx512f -mavx512bw`, not `-mavx512bf16`).
This is an implementation/granularity effect; the diagnostic below repeats
[100 MHz precoding p50 ms] with the implementation selected independently of
the build, and records the benchmark core frequency for both. Source:
`channel_precoder_avx512.cpp` (`AVX512_CF_SIZE=8`),
`channel_precoder_avx2.cpp` (`AVX2_CF_SIZE=4`), and
`src/cuda/standalone/tests/cpu_catb_precoding.h:294` (per-PRB call).

| ports | avx2 build/avx2 impl | avx2 build/avx512 impl | avx512 build/avx2 impl | avx512 build/avx512 impl |
|---:|---:|---:|---:|---:|
| 4 | 0.4936 | 0.7765 | 0.4638 | 0.7760 |
| 8 | 0.9209 | 1.4795 | 0.8980 | 1.4792 |

Benchmark-core frequency (sysfs median kHz): avx2_prec_avx2=3799990.5, avx512_prec_avx512=3799991

Conclusion: the AVX-512 implementation is slower for the production
12-RE-per-PRB call; frequency is not the cause (all four diagnostic runs
report ~3.80 GHz), and the build is not the cause (swapping the
implementation between builds keeps the ordering). The busy-host run
`raw/20261120T214744Z/` is kept only as a labelled comparison in
`COMPARISON.md`.
