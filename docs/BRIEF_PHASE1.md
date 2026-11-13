# OpenRU Agent Brief: Phase 1 — GPU-native ProtO-RU on H100 (Docker)

Nov 13, 2026 · @Milad Natanzi

## Mission and scope

Phase 1 delivers a GPU-accelerated, 4T4R-capable fork of ProtO-RU that runs end to end inside Docker on an H100 host, with no radio and no physical UE. Everything is validated against recorded fronthaul traffic and a software UE, so that the only remaining step before hardware is a one-week latency measurement on a USRP N310 with a Quectel RM520N.

Context the agent must hold: OpenRU is an open-hardware, GPU-native O-RAN radio unit. The long-term product is a board whose PCB design is public, that runs this software inside, and plugs into an OCUDU or OAI DU over 10/25G fiber. ProtO-RU (NUS, [github.com/NUS-CIR/ProtO-RU](https://github.com/NUS-CIR/ProtO-RU), branch `proto-ru`, based on OCUDU 26.04, AGPLv3) already implements the split-7.2 O-RU software on CPU with a USRP as RF front end. We build on it rather than rewriting it.

In scope for Phase 1:

- Reproducible Docker build of OCUDU + ProtO-RU with CUDA on an H100 host.
- An eCPRI replay harness that drives ProtO-RU from pcap files and dumps IQ, with CPU outputs as golden references.
- A CUDA port of the low-PHY hot path (iFFT/FFT, CP handling, BFP compression/decompression), bit-exact or within a stated tolerance against the CPU path.
- 4T4R support in the OFH and low-PHY data structures.
- A virtual radio backend plus a software UE (OAI nrUE or srsUE) and a Sionna channel, so a UE attaches and passes iperf with no hardware.
- M-plane and energy-state hooks ported from the OpenRU-X6 simulator (CLIS-WPI/OpenRU).

Out of scope for Phase 1 (do not start these):

- Any PCB, RF front end, antenna, FPGA or RFSoC work.
- Real-time delay-profile claims (T2a/Ta3). Compute-time numbers may be reported, labeled as such.
- Category B features (precoding in the RU), DPD, ISAC algorithms.
- Jetson deployment. Kernels must compile for sm\_87 as well as sm\_90, but nothing is tested on Jetson in Phase 1.

## Ground rules for the agent

Work milestone by milestone, in order, and do not start a milestone until the previous one's acceptance criteria pass in CI. Each milestone ends with a short written report (`docs/reports/M<n>.md`) stating what was measured, how, and what is still unverified.

- Evidence tagging: every number in a report carries one of `[MEASURED]`, `[DATASHEET]`, `[DERIVED]`, `[ASSUMPTION]`, `[UNVERIFIED]`. Never present a compute-only timing as a fronthaul delay profile.
- No fabrication: if a build fails, a test cannot be made to pass, or a dependency is unavailable, say so in the report and stop that line of work. Do not patch a test to make it green.
- Upstream first: changes to ProtO-RU/OCUDU code go in a fork with clean, separable commits (one feature per branch) so they can be offered upstream. Keep the AGPLv3 license headers; OpenRU-specific code that is not derived from ProtO-RU may use BSD-3 but must be in a separate directory.
- Do not modify the OCUDU DU timing parameters beyond what ProtO-RU's `INTEGRATION_NOTES.md` already requires, except in Milestone 2 where the goal is to tighten them; document every change.
- Reproducibility: everything runs from `make` targets or `docker compose` commands documented in `README.md`. A new machine with Docker, an NVIDIA driver and the repo must reach the Milestone 1 state in one command.
- Secrets and licenses: no NVIDIA Aerial SDK code or binaries in the repo. Use only cuFFT, CUDA runtime and open-source libraries.
- When blocked by a decision only the human can make (band, hardware choice, license), write the question in `docs/OPEN_QUESTIONS.md` and continue on the next independent task.

## Milestone 0: Docker infrastructure on H100

Goal: one `docker compose up` brings up OCUDU DU, ProtO-RU and the 5G core on the H100 host, with the GPU visible inside the ProtO-RU container.

**GPU lane (this lab host): use GPU 1 only.** Do not use `--gpus all` or GPU 0. Pin by UUID so the wrong device cannot be selected if indices shift:

- Host index: `1`
- UUID: `GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058`
- Forbidden (GPU 0): `GPU-96b18ccc-7894-5e31-0ad6-a74b5b79ac28`
- Compose: `gpus.device_ids: [<GPU1 UUID>]` and `deploy.resources.reservations.devices.device_ids: [<GPU1 UUID>]`
- Runtime env: `NVIDIA_VISIBLE_DEVICES=<GPU1 UUID>`
- **Do not set `privileged: true` on `protoru`** — privileged containers see every host GPU and ignore the device pin. Use `cap_add` (`SYS_NICE`, `IPC_LOCK`, `NET_ADMIN`, `NET_RAW`) instead.
- Preflight: `make gpu-check` / `scripts/gpu1_preflight.sh` must fail closed if GPU 0 is visible inside the container.

Host prerequisites (verify, do not assume; record versions in `docs/reports/M0.md`):

- Ubuntu 24.04 preferred (this host may be 22.04 — record actual), NVIDIA driver supporting CUDA 12.x, `nvidia-container-toolkit` installed, `docker run --rm --gpus device=GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058 nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi` prints the H100 with that UUID only.
- Docker Compose v2.
- For the later hardware week only: a NIC with hardware PTP timestamping and a PREEMPT\_RT kernel. Not needed for Phase 1; note their absence.

Images (`docker/` directory, multi-stage builds):

| Image | Base | Contents | Used by |
| --- | --- | --- | --- |
| `openru/base` | `nvidia/cuda:12.6.0-devel-ubuntu24.04` | OCUDU build deps per [docs.ocudu.org installation guide](https://docs.ocudu.org/user_manual/installation/), UHD 4.x, cuFFT, cmake, ninja, clang-tidy | all below |
| `openru/du` | `openru/base` | OCUDU 26.04 built as gNB/DU with Open Fronthaul enabled | DU container |
| `openru/protoru` | `openru/base` | ProtO-RU fork built with `-DOPENRU_CUDA=ON` and `-gencode arch=compute_90,code=sm_90 -gencode arch=compute_87,code=sm_87` | RU container |
| `openru/core` | official `open5gs` image | 5G SA core with a preprovisioned test subscriber | core container |
| `openru/ue` | `openru/base` | OAI nrUE (rfsimulator build) and srsUE; used from Milestone 4 | UE container |

Compose topology (`docker/compose.yml`):

- Network `fh` (bridge) carries OFH between `du` and `protoru`; network `core` carries N2/N3 between `du` and `core`. For Phase 1 the fronthaul runs over AF\_PACKET on the bridge; DPDK is optional and off by default.
- `protoru` gets `deploy.resources.reservations.devices` for **GPU 1 only** (UUID above), `cap_add: [SYS_NICE, IPC_LOCK]`, `ulimits.rtprio: 99`, and `cpuset` pinning to a fixed core range (prefer NUMA node 1). Record which cores. Never attach a GPU to `du` or `core`.
- Config files for DU and ProtO-RU start from ProtO-RU's `proto-ru/conf-files/` TDD n78, 30 kHz SCS, 2x2, 40 MHz pair, with the delay-profile adjustment from `INTEGRATION_NOTES.md` applied. Keep these as the `baseline` profile; every later milestone adds a new profile, never edits `baseline`.
- A `make smoke` target runs `du` and `protoru` for 60 s with ProtO-RU in its stock emulator mode and checks the DU log for a steady slot indication and zero late-packet counters.

Also in this milestone: PTP is not required (same host), but write `docs/TIME_SYNC.md` describing how the two-host PTP setup from ProtO-RU's `TIME_SYNC.md` will be reproduced in the hardware week.

Done when: `make smoke` passes on a clean clone; `nvidia-smi` inside `protoru` shows the H100; images rebuild deterministically from pinned commit hashes of OCUDU and ProtO-RU recorded in `docker/versions.env`.

## Milestone 1: eCPRI replay harness and golden outputs

Goal: drive ProtO-RU from recorded fronthaul traffic instead of a live DU, and capture its IQ output, so every later change can be checked offline without a radio or a UE.

Tasks:

1. Capture. Run the Milestone 0 stack with the DU in its test mode (OCUDU `ru_emulator` flow) for 10 s per profile and record the OFH traffic on the `fh` bridge with `tcpdump` into `testdata/pcap/<profile>.pcapng`. Profiles: `baseline` (2x2, 40 MHz, DDDSU), `b20` (2x2, 20 MHz), and later `4t4r`. Also record the DU's C-plane and U-plane packet counters for the same window.
2. Null radio backend. Add a radio backend to the ProtO-RU fork (`lib/radio/null/`) that implements the same interface as the UHD backend: it accepts transmit buffers with timestamps, writes them to a binary IQ file (`.cf32`, one file per antenna port, with a sidecar `.json` of sample rate, start timestamp and port count), and feeds receive buffers from an input file or zeros. Select it by config: `radio: {backend: null, tx_dump: ..., rx_feed: ...}`.
3. Replay driver (`tools/fh_replay`). A C++ or Python tool that reads a pcapng, rewrites MACs/VLAN to match the ProtO-RU config, and sends the packets onto the `fh` bridge with the original inter-packet timing, scaled by a factor (1.0 = real time; 0 = as fast as possible for throughput tests). Use `scapy` or `libpcap`; DPDK is not needed.
4. Golden set. With the stock CPU low-PHY, run `fh_replay` for each profile and store the IQ dumps as `testdata/golden/<profile>/port<n>.cf32`, with a `SHA256SUMS` file and the exact fork commit in `MANIFEST.json`. Golden files are large; store them with Git LFS or a `make fetch-golden` script from an S3/WPI share, not in plain git.
5. Comparison tool (`tools/iq_compare`). Computes, per port and per slot, max absolute error, EVM-style RMS error in dB relative to the golden signal, and the first sample index where the two differ. Exit code non-zero above a configurable threshold.
6. Timing probes. Add `OPENRU_TRACE` instrumentation (lightweight, off by default) that timestamps: U-plane packet arrival, decompression done, iFFT done, buffer handed to radio. Emit as a CSV per slot. This is the compute-time view only and must be labeled so.

Done when: for `baseline` and `b20`, two consecutive replays of the CPU path produce IQ identical to the golden (`iq_compare` reports 0 differing samples), and the CI job `replay-golden` does this on every push in under 10 minutes on the H100 host.

## Milestone 2: CUDA low-PHY port with bit-exact validation

Goal: move the per-slot low-PHY hot path of ProtO-RU to the GPU behind the same interfaces, validated against the Milestone 1 golden set, with compute latency per slot measured.

Scope of the port, in this order (each step passes `iq_compare` before the next starts):

1. Downlink iFFT + CP insertion for all ports of a slot in one cuFFT batched plan (`cufftPlanMany`), input resource grid in pinned host memory, output OFDM samples in pinned host memory. One CUDA stream per slot, double-buffered.
2. BFP decompression (downlink) and compression (uplink) as CUDA kernels operating on the U-plane payload before/after the FFT stage.
3. Uplink CP removal + FFT, same structure as step 1.
4. Zero-copy path: replace host staging with `cudaHostRegister` on ProtO-RU's existing buffers (resource grid pool, frame pool) so no extra memcpy is added by the port.

Engineering constraints:

- Keep the CPU implementation selectable at runtime (`low_phy: {backend: cpu|cuda}`); CI runs both.
- Fixed-point behaviour: ProtO-RU/OCUDU low-PHY uses float internally; match its FFT scaling exactly. A difference up to 1 LSB of the 16-bit BFP output is acceptable only if documented and justified; the target is 0 differing samples after BFP.
- Kernels must build for `sm_90` and `sm_87`. No HBM-specific tuning, no NVLink, no MIG assumptions, so the same code later runs on Jetson.
- Use Nsight Systems on the replay run to measure, per slot: H2D copy, kernel time, D2H copy, and end-to-end time from U-plane arrival to buffer handed to the radio backend. Report p50/p99 for `baseline` and `4t4r` profiles. These are compute-time figures `[MEASURED]` on H100; state explicitly that the fronthaul delay profile (T2a/Ta3) is still `[UNVERIFIED]` until the hardware week.
- Any overlap of copy and compute is done with streams and events, never by spinning a CPU thread.

Done when: `cuda` backend produces 0 differing samples versus golden on `baseline` and `b20`; p99 end-to-end compute time per slot on H100 is reported and is below one 30 kHz slot (500 microseconds) for `baseline`; the 60 s live `make smoke` still passes with `low_phy.backend: cuda`.

## Milestone 3: 4T4R support

Goal: ProtO-RU handles four eAxC ports in both directions with the CUDA backend, validated by replay. ProtO-RU today is validated only up to 2x2; this milestone removes that limit in software.

Tasks:

1. Configure the OCUDU DU for 4 antenna ports (4 DL layers, 4 UL ports) in a new `4t4r` profile and confirm it starts in test mode. Record the eAxC IDs it uses.
2. Audit ProtO-RU's OFH and low-PHY data structures for hard-coded port counts: the resource-grid pool (symbol x subcarrier x port), the DL/UL/PRACH repositories, C-plane section parsing per eAxC, the frame pool, and the radio buffer layout. Make port count a config value with a compile-time maximum of 8.
3. Capture a `4t4r` pcap in DU test mode, generate its CPU golden, and run the CUDA backend against it.
4. Measure CUDA compute time per slot for 4 ports and compare with 2 ports; report scaling.
5. Write `docs/4T4R.md` listing every code location changed, so the diff can be offered upstream as one feature branch.

Done when: `4t4r` replay passes `iq_compare` with 0 differing samples on both backends; p99 compute time for 4 ports is reported; the DU log shows no late or dropped U-plane packets over a 60 s live run with `low_phy.backend: cuda`.

## Milestone 4: virtual radio, software UE and Sionna channel

Goal: a commercial-free end-to-end run. A software UE attaches through ProtO-RU, with the air interface replaced by a channel model on the same H100, and iperf traffic flows. ProtO-RU's README states ZMQ is not supported in this release, so this backend is new work.

Architecture: `du` sends OFH to `protoru`; `protoru` uses a new `virt` radio backend that streams timestamped IQ over shared memory or a local socket to a `channel` process; `channel` applies a Sionna (or NumPy, as fallback) channel per antenna pair, adds AWGN at a configured SNR, and delivers IQ to the UE container, which runs OAI nrUE in rfsimulator mode or srsUE over ZMQ. Uplink is the reverse path.

Tasks:

1. `virt` radio backend in the ProtO-RU fork: same interface as `null`, but bidirectional over a POSIX shared-memory ring with timestamps, one ring per direction. Define the frame format in `docs/VIRT_RADIO.md`.
2. `channel` service (Python, `tools/channel/`): reads TX rings, applies a channel, writes RX rings. First version: static TDL-C or a simple multipath with configurable SNR, CPU NumPy. Second version: Sionna on GPU for 4x4 MIMO with a time-varying channel. Keep the interface identical so either can run.
3. UE adapter: bridge the `channel` output to OAI nrUE's rfsimulator socket protocol (preferred, since OAI is also the alternative DU) or to srsUE's ZMQ. Pick one, justify in the report, and leave the other as a documented stub.
4. Timing: the UE and DU must agree on slot timing. The `virt` backend's timestamps drive the UE's sample clock; document the latency budget and set the DU's delay profile for this profile (`virt`) separately from `baseline`.
5. End-to-end test (`make e2e-virt`): core up, DU up, ProtO-RU (`cuda`, 4 ports) up, channel up, UE up; assert UE registration in the core, then iperf3 downlink and uplink for 30 s; record throughput and ping RTT. Compare 2x2 vs 4x4 throughput at the same SNR.

Done when: `make e2e-virt` completes with UE registered and iperf3 running on both backends and both port counts; results are in `docs/reports/M4.md` with SNR, channel model and all timing parameters listed.

## Milestone 5: M-plane and energy-state hooks

Goal: give the RU a management interface and the control hooks that the OpenRU-X6 simulator already models, so the simulator's self-healing and energy-state logic has a real target. ProtO-RU has no M-plane today.

Tasks:

1. Minimal M-plane daemon (`openru-mpd`, C++ or Python, separate process in the `protoru` container) exposing a NETCONF-like YANG subset over a local gRPC/REST API first: read-only state (ports, carrier config, slot counters, late-packet counters, CUDA backend status, compute-time p50/p99), and a small writable set (`tx_enable` per port, `carrier_state: active|sleep`, `low_phy.backend`). Map names to O-RAN WG4 M-plane YANG where a match exists and document the mapping; full NETCONF/SSH transport is a later phase.
2. Energy states: implement `active`, `micro_sleep` (skip low-PHY for symbols the C-plane marks unused), and `deep_sleep` (carrier off, OFH still answering) as RU-side states with measured entry/exit time per state from the trace probes. Report GPU power via NVML during each state as `[MEASURED]` on H100, clearly noting that Jetson numbers will differ.
3. Safety veto: a single hardware-independent `rf_mute` flag that any component (watchdog timeout, M-plane command, over-temperature placeholder) can assert and that forces the radio backend to transmit zeros. This is the software end of the interlock designed in the OpenRU H2 hardware branches; keep its semantics identical so the FEM board can wire to it later.
4. Simulator bridge: a thin adapter so OpenRU-X6's controller can drive the real `openru-mpd` API instead of its in-process model, for one closed-loop scenario (for example, carrier sleep on low load) run on the Milestone 4 virtual stack.

Done when: the M-plane API is documented with examples; the three energy states transition on command with entry/exit times reported; `rf_mute` asserted mid-run produces all-zero IQ in the dump within one slot; one closed-loop simulator scenario runs end to end on the virtual stack.

## Acceptance criteria

| Milestone | CI job | Pass condition | Report |
| --- | --- | --- | --- |
| M0 Docker | `smoke` | `make smoke` 60 s run, GPU visible, zero late packets | `docs/reports/M0.md` with host and image versions |
| M1 Harness | `replay-golden` | CPU replay = golden, 0 differing samples, baseline and b20, under 10 min | M1.md with capture method and golden manifest |
| M2 CUDA | `replay-cuda` | CUDA = golden, 0 differing samples; p99 compute per slot under 500 us on baseline | M2.md with Nsight figures p50/p99, labeled compute-only |
| M3 4T4R | `replay-4t4r` | both backends = golden on 4t4r; 60 s live run with no late packets | M3.md with scaling 2 vs 4 ports and list of changed code paths |
| M4 Virtual E2E | `e2e-virt` | UE registered; iperf3 DL/UL 30 s on cpu and cuda, 2x2 and 4x4 | M4.md with SNR, channel, timing parameters, throughput, RTT |
| M5 M-plane | `mplane` | API examples pass; energy-state transitions measured; rf\_mute zeros within one slot; one closed-loop scenario | M5.md with state timings and NVML power |

Every report ends with an `Unverified` list naming what still needs hardware, at minimum: fronthaul delay profile, PRACH timing against a real clock, one-hour stability, and OTA EVM.

## Repository layout, branching, CI

Work in a new repository `CLIS-WPI/openru-sw` (software only); the existing `CLIS-WPI/OpenRU` keeps the simulator and hardware branches, and its README gets one paragraph pointing here. Suggested layout:

```markdown
openru-sw/
  README.md              one-command quickstart, milestone status table
  docker/                Dockerfiles, compose.yml, versions.env
  external/proto-ru/     git submodule: our fork of NUS-CIR/ProtO-RU (branch openru/main)
  patches/               only if a submodule cannot carry a change
  src/cuda/              low-PHY CUDA kernels + wrapper (AGPLv3, derived from ProtO-RU)
  src/radio/{null,virt}/ radio backends
  src/mpd/               M-plane daemon (BSD-3, independent code)
  tools/{fh_replay,iq_compare,channel}/
  testdata/pcap/         small captures in git; golden via LFS or fetch script
  profiles/{baseline,b20,4t4r,virt}/   DU + RU + core config per profile
  docs/                  reports/, OPEN_QUESTIONS.md, VIRT_RADIO.md, 4T4R.md, TIME_SYNC.md
  Makefile               smoke, replay-golden, replay-cuda, replay-4t4r, e2e-virt, mplane, fetch-golden
```

Branching: `main` is always green; one branch per milestone (`m1-harness`, `m2-cuda`, ...) merged by PR with the CI job for that milestone passing; inside the ProtO-RU fork, one feature branch per upstreamable change (`feat/null-radio`, `feat/cuda-lowphy`, `feat/4t4r`, `feat/virt-radio`).

CI: a self-hosted GitHub Actions runner on the H100 host (`runs-on: [self-hosted, gpu]`), jobs named as in the acceptance table, each under 15 minutes, artifacts = reports and `iq_compare` summaries. A nightly job runs the full chain M0 to M4.

Licensing note: ProtO-RU is AGPLv3; anything linked into it or derived from it stays AGPLv3. Keep `src/mpd/` and `tools/` free of ProtO-RU code so they can be BSD-3 and reused on the future FPGA/Jetson build.

## Known constraints and open questions

Constraints the agent must respect:

- ProtO-RU v26.04 fork supports only Category A, per-slot C-plane, PRACH format B4, 15/30 kHz SCS, up to 2x2 validated. Do not add Category B.
- ProtO-RU needs a larger delay profile than stock OCUDU accepts; the `INTEGRATION_NOTES.md` patch is applied once in `baseline` and documented.
- H100 figures are not RU figures. The target embedded GPU is a Jetson AGX Orin/Thor; design for it, measure on H100, label everything.
- Band for all profiles is n78 (3.3 to 3.8 GHz, TDD). Nothing in Phase 1 depends on the band, but all configs use n78 so the hardware week needs no changes.

Questions for the human (write answers into `docs/OPEN_QUESTIONS.md`; proceed with the stated default):

- [ ] Software UE: OAI nrUE (default) or srsUE for Milestone 4?
- [ ] Golden storage: Git LFS on GitHub (default) or a WPI file share?
- [ ] Hardware week: USRP N310 and Quectel RM520N-GL are assumed available; confirm, plus a 10 GbE NIC with PTP timestamping.
- [ ] Upstreaming: open a discussion with the ProtO-RU maintainers (Discord/issue tracker) once Milestone 2 passes, or wait for Milestone 3? Default: after Milestone 2.
- [ ] Repository name: `openru-sw` (default) or keep everything in `CLIS-WPI/OpenRU`?
