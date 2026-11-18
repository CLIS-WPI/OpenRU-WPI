# OpenRU

OpenRU is an open O-RAN split-7.2 radio unit built on [ProtO-RU](https://github.com/NUS-CIR/ProtO-RU) (NUS-CIR; AGPLv3; based on OCUDU 26.04), plugging into an OCUDU or OAI DU over fronthaul. See `NOTICE`.

The v1 configuration runs the **low PHY on CPU** (FFTW + ESTIMATE) and is validated at 20/40 MHz. A **CUDA low-PHY** exists as an optional backend for higher antenna counts and future in-RU processing. The development/validation host is the **GPU server** (null radio, recorded goldens); the **bench host** runs the real radio (N310). The original H100/GPU-first brief is kept as history in `docs/BRIEF_PHASE1.md`; current plans are in [`docs/ROADMAP.md`](docs/ROADMAP.md).

Repository: [CLIS-WPI/OpenRU-WPI](https://github.com/CLIS-WPI/OpenRU-WPI). ProtO-RU fork: [CLIS-WPI/ProtO-RU](https://github.com/CLIS-WPI/ProtO-RU) (`openru/main`).

## Current status (2026-11-18)

- **M0 and M1 closed** — Docker/GPU lane, fronthaul gate, null radio, capture/replay.
- **v1 CPU configuration locked for 20/40 MHz** (`openru/protoru:v1-candidate`, FFTW + ESTIMATE + `x86-64-v4`; see
  `docs/reports/V1_SMOKE.md`). **100 MHz is not validated on this host.**
- **Goldens:** `baseline` (20 MHz) and `b40` (40 MHz) are v1-validated; **`b100` is deferred** (MANIFEST
  `status: deferred`, never presented as validated).
- **Bench bundle and image-release flow ready** — x86-64-v3 bench image (UHD 4.11.0.0), `docker/compose.cpu.yml`,
  fail-closed `make bench-preflight`, and `make bench-release` → ship → load → preflight.
- **Next: the first cabled bench test** on the bench host (N310-10 → RM520N), starting at 20 MHz 2×2.

Documentation: [`docs/TESTS.md`](docs/TESTS.md) (test catalogue, `make test SUITE=…`),
[`docs/BENCH_BUNDLE.md`](docs/BENCH_BUNDLE.md) (bench host, radio, release flow),
[`docs/OPEN_QUESTIONS.md`](docs/OPEN_QUESTIONS.md) (decisions and open items).

## Lab setup (required)

Host-specific GPU UUID and CPU pins live in `docker/lab.env` (gitignored). Copy the example and edit:

```bash
cp docker/lab.env.example docker/lab.env
# set OPENRU_GPU_UUID, FORBIDDEN UUID, PROTORU_CPUSET, DU_CPUSET, MARCH
make preflight
```

`make preflight` fails closed if `lab.env` is missing. Compose has **no** host UUID/cpuset defaults.

## Quickstart (Milestone 0+)

```bash
git clone --recurse-submodules https://github.com/CLIS-WPI/OpenRU-WPI.git
cd OpenRU-WPI
cp docker/lab.env.example docker/lab.env   # then edit
make preflight
make build          # Open5GS + ProtO-RU/OCUDU (long)
make smoke-fh       # M0 fronthaul gate (emulator mode)
make smoke-core     # NG Setup (required before M4)
```

## Status

| Area | State |
| --- | --- |
| Milestones (M0–M2) | M0, M1 closed; M2 CUDA results are compute-only (not an acceptance) — see `docs/reports/` |
| Low PHY (v1) | CPU, FFTW + ESTIMATE, validated at 20/40 MHz; CUDA low-PHY optional backend |
| Bench | bundle + image-release flow ready; first cabled test pending |
| Plan | [`docs/ROADMAP.md`](docs/ROADMAP.md) — stages 1–3 and next steps |

## Bench host quickstart

The bench host runs the real radio (N310-10 → RM520N); release artifacts are built on the development server and
never committed.

```bash
make bench-release                      # build + smoke + export (server)
make bench-ship HOST=ran                # rsync; manual copy instructions if unreachable
scripts/bench_load.sh bench-<short-sha> # on the bench host
OPENRU_TAG=bench-latest make BENCH=1 bench-preflight
```

See [`docs/BENCH_BUNDLE.md`](docs/BENCH_BUNDLE.md) for the core map, radio/antenna wiring, kernel isolation and
the full release → ship → load → preflight flow.

## License

AGPLv3 — see `LICENSE` and `NOTICE`.
