# Clean run vs busy-host run

Clean run: `clean-20261120T232220Z` (`raw/clean-20261120T232220Z/final/`), on
reserved cores `19,21,31` (NUMA 0, bench core 19), per-core gate passed.

Busy-host run: `20261120T214744Z` (`raw/20261120T214744Z/`), whole-server
measurement on the shared host with `opencode`/`claude` active. **Provisional;
kept only as a comparison, do not cite.**

## Conditions

| | busy-host (provisional) | clean |
|---|---|---|
| Cores | core 8, no reservation | `19,21,31` reserved; bench `19` |
| NUMA | 0 | 0 (GPU also 0) |
| SMT | off | off (no HT siblings) |
| Rejection rule | none (whole-server load recorded) | foreign process >5%/core or foreign GPU process |
| Host load | 1.21 / 1.81 / 1.48 at start; `opencode` 70.7% | 3.38 / 2.53 / 2.02 (info only) |
| GPU clocks/power | not recorded | SM 1785 MHz median, mem 2619 MHz, 63–93 W, P0 |

The clean run's per-backend peak foreign CPU on the reserved cores was
`avx2 1.71%`, `avx512 2.41%`, `gpu 4.30%`; the only GPU compute PID was the
benchmark.

## 100 MHz, 8 ports (p50 ms; slot = 0.5 ms)

| kernel | busy AVX2 | clean AVX2 | Δ | busy AVX-512 | clean AVX-512 | Δ | busy GPU | clean GPU | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| OFDM | 0.6162 | 0.6867 | +11.4% | 0.6330 | 0.5556 | −12.2% | 0.0277 | 0.0282 | +1.8% |
| BFP | 0.1857 | 0.1863 | +0.3% | 0.1772 | 0.1782 | +0.6% | 0.0177 | 0.0182 | +2.8% |
| PREC | 0.9546 | 0.9212 | −3.5% | 1.4776 | 1.4815 | +0.3% | 0.0113 | 0.0117 | +3.5% |

100 MHz, 4 ports, PREC: AVX2 `0.5125 → 0.4906` (−4.3%); AVX-512
`0.7744 → 0.7764` (+0.3%).

**What changed.** GPU and BFP numbers are stable within ~3%. Cat-B is stable
within ~4%, and the AVX-512/AVX2 ratio is ~1.6x in both runs. The OFDM rows move
in opposite directions (AVX2 up, AVX-512 down): OFDM is the same FFTW path in
both builds, so this is run-to-run core/cache variance on the shared host, not an
ISA effect; the clean run does not make AVX-512 OFDM slower. p99 still contains
isolated host-scheduler outliers (e.g. clean 100 MHz/8p AVX-512 OFDM p99 0.963 ms
vs p50 0.556 ms); p50 is the headline, p99 is host-limited because the benchmark
cannot take RT priority. The clean run's value is the per-core/GPU evidence and
the recorded GPU clocks, not a claim that every p50 moved down.

## Why Cat-B AVX-512 is slower than AVX2

The harness calls `apply_precoding` once per PRB, i.e. 12 REs per call
(`src/cuda/standalone/tests/cpu_catb_precoding.h:294`). The AVX-512
implementation processes 8 REs per iteration (`AVX512_CF_SIZE = 8`) and therefore
runs a 4-RE scalar tail for every PRB; AVX2 processes 4 REs per iteration
(`AVX2_CF_SIZE = 4`) and vectorizes all 12. The AVX-512 file is also built with
`-mavx512f -mavx512bw` but not `-mavx512bf16`, so `ps_to_cbf16` takes the longer
integer conversion fallback instead of `vcvtneps2bf16`.

The diagnostic swaps the implementation independently of the build (100 MHz
precoding p50 ms):

| ports | avx2 build / avx2 impl | avx2 build / avx512 impl | avx512 build / avx2 impl | avx512 build / avx512 impl |
|---:|---:|---:|---:|---:|
| 4 | 0.4936 | 0.7765 | 0.4638 | 0.7760 |
| 8 | 0.9209 | 1.4795 | 0.8980 | 1.4792 |

Benchmark-core frequency during all four diagnostics: **3.7999 GHz** (sysfs
median; the same 3.80 GHz as the main AVX2/AVX-512 runs). So:

- **Not frequency licence/downclocking:** the core runs at the same 3.80 GHz for
  both implementations. (Precise per-ISA licence counters are not available:
  `perf_event_paranoid` disallows CPU events and `turbostat` needs raw MSR
  access; sysfs/`/proc/cpuinfo` are the available evidence.)
- **Not the build:** swapping the implementation between the v3 and v4 builds
  gives the same ordering; the precoder source files carry their own
  `-mavx2`/`-mavx512` compile options.
- **Implementation/granularity:** the 12-RE-per-PRB call makes the AVX-512 8-RE
  vector plus 4-RE scalar tail slower than AVX2's three full 4-RE iterations.
  A whole-PRG or whole-slot call would amortize the tail; that is a change to
  the caller, not to this harness.
