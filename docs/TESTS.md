# TESTS — OpenRU test catalogue

Part of the modular test framework (`tests/README.md`). One suite per testable
part of the project; one command per suite/profile:

```bash
make test SUITE=<suite> PROFILE=<profile>
make test-list
```

Status vocabulary: PASS / FAIL / INVALID (quiet-host or lock violation) /
SKIPPED(host_limited | deferred). Results: `docs/reports/runs/<suite>/`.

| Suite | Profile | Coverage | Pass criteria | Host requirements | Runtime | Command | Last result |
|---|---|---|---|---|---|---|---|
| smoke-fh | emulator | M0 OFH gate: DU + ProtO-RU emulator, late/drop, slot advance, U-plane rates | drop=0, late/(rx+tx)<1e-5 after warm-up, rates ±2% | GPU 1, quiet host (cores 32–55) | ~3 min | `make test SUITE=smoke-fh PROFILE=emulator` | `20261118T025137Z` PASS (late 0, rates −0.7/−0.7/−0.6%) |
| smoke-fh | null | M1/v1 null-radio gate (CPU+null baseline 7.094e-6) | same gate as emulator; gate vs CPU+null baseline | GPU 1, quiet host | ~3 min | `make test SUITE=smoke-fh PROFILE=null` | `20261118T025600Z` PASS (late 0, rates −0.1/−0.2/+0.0%) |
| smoke-core | default | NG Setup against Open5GS, PLMN compare | NGSetupResponse in DU log | docker only | ~3 min | `make test SUITE=smoke-core` | `20261118T030517Z` PASS (NGSetupResponse, ALIGN: OK) |
| replay-golden | baseline | fh_replay vs v1-candidate CPU golden, 4000 slots, bit-exact | golden energy check PASS + 0 differing slots | GPU 1, docker | ~10 min | `make test SUITE=replay-golden PROFILE=baseline` | `20261118T033955Z` PASS (golden energy + 0 differing slots) |
| replay-golden | b40 | fh_replay vs b40 golden, 2000 slots | same | GPU 1, docker; golden is host_limited | ~10 min | `make test SUITE=replay-golden PROFILE=b40` | `20261118T031125Z` SKIPPED(host_limited) |
| replay-golden | b100 | fh_replay vs b100 golden | same | golden deferred → SKIPPED(deferred) | — | `make test SUITE=replay-golden PROFILE=b100` | `20261118T031445Z` SKIPPED(deferred) |
| cuda-standalone | default | CUDA BFP + OFDM kernels vs OCUDU CPU reference (20/40/100 MHz, 2/4 ports) | BFP byte-identical; OFDM ≤1 LSB, ≤−60 dB | GPU 1 + nvcc; measure lock | ~2 min (+first build) | `make test SUITE=cuda-standalone` | `20261118T031829Z` PASS |
| cuda-pipeline | default | Device-resident DL/UL chain vs standalone kernels; sustained + latency | 0 mismatches | GPU 1 + nvcc; measure lock | ~5 min (+first build) | `make test SUITE=cuda-pipeline` | `20261118T032126Z` PASS |
| cuda-scaling | default | GPU vs FFTW+AVX-512 CPU baseline across port counts; TDD/FDD core budgets | per-row correctness gates | GPU 1 + nvcc; measure lock | ~10 min (+first build) | `make test SUITE=cuda-scaling` | `20261118T033555Z` PASS |

Unit tests (host-independent, no GPU/docker) stay as before:

```bash
python3 -m unittest discover -s tools/iq_compare -p 'test_*.py' -v
python3 -m unittest discover -s tools/golden -p 'test_*.py' -v
```

Notes:

- `replay-golden` (all profiles at once) and the other legacy aliases
  (`make smoke-fh`, `make smoke-core`, ...) keep their previous behaviour.
- The b100 golden is **deferred**; b100 is NOT v1-validated on this host
  (see `docs/reports/M2.md`, `docs/reports/V1_SMOKE.md`).
- The next session adds `tests/virt-ue` (OCUDU DU → ProtO-RU ZMQ → srsUE).
