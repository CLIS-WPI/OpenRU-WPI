# Suite: cuda-pipeline (device-resident low-PHY chain)

Runs `src/cuda/standalone` `test_pipeline` — the device-resident DL/UL chain
(BFP decompress → grid → OFDM → ci16 D2H and the UL reverse) validated against
the standalone kernel sequence, plus sustained-throughput and latency
measurement. **Compute-only** on the H100; no fronthaul/radio.

| | |
|---|---|
| Coverage | DL/UL chain byte-identity vs standalone kernels (all profiles × 2/4 ports); sustained slots; latency p50/p99/max |
| Inputs | `build/ocudu` (Release, generic DFT); `--sustained 4000 --latency-iters 200 --cpu-core 8` |
| Pass criteria | DL/UL mismatches = 0 vs the standalone kernel path (exit code of `test_pipeline`) |
| Runtime | ~3–5 min run; first-time build ~10–20 min |
| Host needs | GPU 1 (pinned via CUDA_VISIBLE_DEVICES), nvcc; holds `/tmp/openru-measure.lock`; CPU core 8 (NUMA0, outside reserved cores) for the OCUDU CPU path |
| Shared libs | `tests/lib/cuda.sh` |

## Profiles

- `default` — as `src/cuda/standalone/RESULTS.md`.

## Command

```bash
make test SUITE=cuda-pipeline
```

Reference numbers: `src/cuda/standalone/RESULTS.md` §"Device-resident pipeline".
