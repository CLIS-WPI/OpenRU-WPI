# OpenRU

OpenRU is an open-hardware, GPU-native O-RAN split-7.2 radio unit that plugs into an OCUDU or OAI DU over fronthaul.

**Phase 1** delivers a GPU-accelerated, 4T4R-capable software stack that runs end to end in Docker on an H100 host (no radio, no physical UE), validated against recorded fronthaul traffic and a software UE. It builds on [ProtO-RU](https://github.com/NUS-CIR/ProtO-RU) (NUS-CIR; AGPLv3; based on OCUDU 26.04) rather than rewriting the O-RU from scratch. See `NOTICE` and `docs/BRIEF_PHASE1.md`.

Repository: [CLIS-WPI/OpenRU-WPI](https://github.com/CLIS-WPI/OpenRU-WPI). ProtO-RU fork: [CLIS-WPI/ProtO-RU](https://github.com/CLIS-WPI/ProtO-RU) (`openru/main`).

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
| M1 eCPRI replay | in progress | Null radio in fork; capture/replay/golden next |
| M2 CUDA low-PHY | not started | Late ratio must be ≤ CPU baseline |
| M3 4T4R | not started | |
| M4 virt UE | not started | |
| M5 M-plane | not started | |

## License

AGPLv3 — see `LICENSE` and `NOTICE`.
