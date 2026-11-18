# Suite: cuda-standalone (BFP + OFDM CUDA kernels vs OCUDU CPU reference)

Runs `src/cuda/standalone` `test_lowphy` — the validation harness for the
standalone CUDA low-PHY kernels (`kernels/bfp_kernels.cu`,
`kernels/ofdm_cufft.cu`) against the production OCUDU static libraries
(`build/ocudu`, generic DFT reference).

| | |
|---|---|
| Coverage | BFP compress/decompress byte-identity (widths 8/9/10/12/16, GPU and AVX2 CPU); OFDM modulator `ci16` and demodulator correctness per profile (20/40/100 MHz, 2/4 ports) |
| Inputs | OCUDU build tree `build/ocudu` (Release, `ENABLE_FFTW=OFF`); FFTW3F + yaml-cpp host libs; CUDA 12.5 |
| Pass criteria | BFP mismatches = 0; OFDM mod ≤ 1 LSB and ≤ −60 dB error power; demod < 1 LSB and ≤ −60 dB (exit code of `test_lowphy`) |
| Runtime | ~1–2 min run; first-time builds of `build/ocudu` + test binaries (~10–20 min) |
| Host needs | GPU 1 (CUDA_VISIBLE_DEVICES pinned to lab.env UUID), nvcc + nvidia-smi; holds `/tmp/openru-measure.lock` for the timed run; no isolated cores needed |
| Shared libs | `tests/lib/cuda.sh` (builds + GPU pin) |

## Profiles

- `default` — `test_lowphy --iters 30` (as `src/cuda/standalone/RESULTS.md`).

## Command

```bash
make test SUITE=cuda-standalone
```

Reference numbers: `src/cuda/standalone/RESULTS.md` (H100 NVL, compute-only).
