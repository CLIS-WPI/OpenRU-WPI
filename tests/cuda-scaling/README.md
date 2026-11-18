# Suite: cuda-scaling (GPU vs fair CPU baseline vs antenna ports)

Runs `src/cuda/standalone` `test_scaling` — the scaling study: GPU chain
(precoding included) vs the **fair** CPU baseline (FFTW DFT + AVX-512 BFP,
OCUDU built with `ENABLE_FFTW=ON -DMARCH=x86-64-v4` in `build/ocudu-fair`)
across antenna-port counts, reporting TDD/FDD core budgets. **Compute-only**.

| | |
|---|---|
| Coverage | GPU DL/UL chain vs CPU chain per port count (2…64, layers 2/4); precoding/combining correctness (max \|gpu−cpu\| ≤ 1e-3); cores-needed TDD/FDD |
| Inputs | `build/ocudu-fair` (FFTW + x86-64-v4) + `build/ocudu`; `--latency-iters 80 --cpu-core 10` |
| Pass criteria | Per-row correctness gates inside `test_scaling` (exit code), CSV written |
| Runtime | ~5–10 min run; first-time builds (both OCUDU trees) ~20–40 min |
| Host needs | GPU 1, nvcc; holds `/tmp/openru-measure.lock` for the whole run; CPU core 10 (NUMA0) |
| Shared libs | `tests/lib/cuda.sh` |

## Profiles

- `default` — as `src/cuda/standalone/RESULTS_SCALING.md`.

## Command

```bash
make test SUITE=cuda-scaling
```

Reference numbers: `src/cuda/standalone/RESULTS_SCALING.md` and
`src/cuda/standalone/scaling_results.csv`.
