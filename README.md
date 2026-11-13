# openru-sw

GPU-native ProtO-RU / OpenRU software stack (Phase 1). Runs on this lab host **only on H100 GPU 1**.

## One-command GPU lane check

```bash
make gpu-check
```

Authorized device UUID (fail-closed): `GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058` (host index 1).  
GPU 0 must never be visible inside OpenRU containers.

## Quickstart (Milestone 0)

```bash
make preflight
make build          # builds Open5GS + OCUDU/ProtO-RU (long)
make smoke-fh       # M0 gate: DU(no_core)+ProtO-RU emulator, 60 s
make smoke-core     # NG Setup only (required before M4)
make smoke          # alias for smoke-fh
```

Compose file: `docker/compose.yml`. Pinned commits: `docker/versions.env`. Report: `docs/reports/M0.md`.

## Milestone status

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 Docker + GPU1 | soft-fail | Caps/GPU1/emulator OK; smoke-fh late=10/60s [MEASURED]; smoke-core PASS; ROHC skipped |
| M1 eCPRI replay | not started | |
| M2 CUDA low-PHY | not started | |
| M3 4T4R | not started | |
| M4 virt UE | not started | |
| M5 M-plane | not started | |

## Host notes

- This machine is Ubuntu 22.04 (brief assumed 24.04). Container OS is Ubuntu 24.04.
- NVIDIA driver 580.x, CUDA driver API 13.0; images use CUDA 12.6 toolkit/runtime.
- ProtO-RU submodule: `external/proto-ru` @ `proto-ru` branch.
