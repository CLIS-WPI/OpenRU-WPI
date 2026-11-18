# OpenRU

OpenRU is an open-hardware, GPU-native O-RAN split-7.2 radio unit that plugs into an OCUDU or OAI DU over fronthaul.

**Phase 1** delivers a GPU-accelerated, 4T4R-capable software stack that runs end to end in Docker on an H100 host (no radio, no physical UE), validated against recorded fronthaul traffic and a software UE. It builds on [ProtO-RU](https://github.com/NUS-CIR/ProtO-RU) (NUS-CIR; AGPLv3; based on OCUDU 26.04) rather than rewriting the O-RU from scratch. See `NOTICE` and `docs/BRIEF_PHASE1.md`.

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

## Milestone status

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 Docker + GPU lane | **closed** | Caps/GPU pin OK; 600 s CPU baseline; smoke-core PASS; ROHC skipped |
| M1 eCPRI replay | **closed** | Null radio, capture/replay/golden (baseline + b40; b100 deferred); PR #6 |
| M2 CUDA low-PHY | compute-only results recorded | `docs/reports/M2.md` — not an acceptance (host-load dependent) |
| M3 4T4R | not started | |
| M4 virt UE | not started | |
| M5 M-plane | not started | |

## License

AGPLv3 — see `LICENSE` and `NOTICE`.
