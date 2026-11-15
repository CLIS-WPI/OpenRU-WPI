# Open questions

Defaults from the Phase 1 brief; update when a human decides.

- [ ] Software UE: OAI nrUE (default) or srsUE for Milestone 4?
- [ ] Does OCUDU's ZMQ radio work with ProtO-RU's SDR path? If yes, M4 can use srsUE over ZMQ instead of a new virt backend. (`ru_emulator_cli11_schema.cpp` accepts `--device_driver zmq`; ProtO-RU README says ZMQ is unsupported. **Do not use in M1**; test only in M4.)
- [ ] Golden storage: Git LFS on GitHub, a WPI file share, or **Zenodo with a DOI**? **Proposal:** Zenodo record *OpenRU Phase 1 golden IQ — M1* (`baseline`, `b40`, `b100`), concept DOI + per-milestone version DOI, `openru-goldens-m1.tar.zst` (~2.11 GiB uncompressed), AGPL-3.0 or CC-BY-4.0, verified against in-tree `MANIFEST.json`/`SHA256SUMS` via `OPENRU_GOLDEN_URL=… make fetch-golden`. **Not uploaded.** See `docs/reports/M1.md` appendix. Default: keep local file share until a human creates the record.
- [ ] Hardware week: USRP N310 and Quectel RM520N-GL available? 10 GbE NIC with PTP timestamping?
- [ ] Upstreaming: discuss with ProtO-RU maintainers after Milestone 2 (default) or wait for Milestone 3?
- [ ] Repository: keep [CLIS-WPI/OpenRU-WPI](https://github.com/CLIS-WPI/OpenRU-WPI) (current) vs rename?

## Lab constraints

- GPU pin and cpusets: `docker/lab.env` (see `lab.env.example`). Not in git.
- Host OS Ubuntu 22.04.5; containers Ubuntu 24.04; kernel **not** PREEMPT_RT.
- ROHC **skipped, not needed for Phase 1**.
- ProtO-RU fork: [CLIS-WPI/ProtO-RU](https://github.com/CLIS-WPI/ProtO-RU) `openru/main` @ `45dbc958`.

## M1 closure decisions — OPEN

- [x] **Regenerate the goldens with the N=100 Δ gate — DONE.** The null radio waits for N=100 stable slots **and the next SFN 0**, so `first_du=0.0` on every cold replay; the −1052 at DU_end **68.0** is in the preceding period and is excluded. Regenerated baseline/b40/b100 (baseline `baseline.pcapng` 10 s; b40/b100 `_3s`): 4000/2000/800 slots, two cold replays each, `max_abs=0` over the full window. The strict full-range `iq_compare` remains. The gate was **not** retuned to −1052.
- [ ] **CI runner hosting:** register an ephemeral self-hosted runner (dedicated VM, unprivileged user, rootless Docker) for `replay-golden`, or keep the workflow `workflow_dispatch`-only/inert through M2? No runner is registered today (`total_count=0`). **Default:** keep inert; manual `make replay-golden` is the gate.
- [ ] **Golden record license:** AGPL-3.0 (repo-consistent) or CC-BY-4.0 (data)? **Default:** AGPL-3.0.

## M2 CUDA vs CPU golden compare — APPROVED

CUDA low-PHY vs CPU golden passes if **BFP output is byte-identical** and OFDM modulator **`ci16`** has, per port per slot, max \|diff\| ≤ 1 LSB and error power ≤ −60 dB relative to signal power. **"0 differing samples"** remains the bar for **CPU-vs-CPU** determinism (M1 `replay-golden`). Recorded in `docs/BRIEF_PHASE1.md` and `AGENTS.md`.

## Late-packet threshold — APPROVED (ratio, Phase 1 only)

Hard fail if, after warm-up:

- `drop > 0`, or
- `late / (rx_total + tx_total) > 1e-5`

Always report the **ratio** and the absolute late/drop/packet counts.  
Prior 60 s soft-fail counts imply ≈ **6.3e-6** \[DERIVED\] (`10 / (595586+996076)`).

**CPU baseline (confirmed 600 s, NUMA1 pin, warm-up=57 s)** \[MEASURED\]:

- late=28, rx+tx=13 359 426, drop=0 → **ratio = 2.096e-6**
- Full-window (incl. warm-up): late=56, ratio=3.802e-6
- Artifacts: `docs/reports/smoke-fh-10m-kpi.json`, histogram CSV, `M0.md`

**Superseded for M2 live null path:** the M2 late-ratio gate compares **CUDA+null** against the **M1 CPU+null** baseline **7.094e-6** [MEASURED] (*null radio, slot RX buffers, not representative of UHD*), not this emulator **2.096e-6**. Keep both numbers in reports with their labels. Emulator 2.096e-6 remains the M0 reference.

## CPU topology (this host) — pinning decision

See `docs/reports/cpu-topology.md`.

- SMT **off** (`Thread(s) per core: 1`); `thread_siblings_list` is a singleton — **32–63 are not SMT siblings of 0–31** (SMT re-pin clause does not apply).
- GPU0 and GPU1 PCI are both on **NUMA0**. Optional NUMA0 OFH pin (`16-27`/`28-31`) raised 600 s late ratio **~4.9e-6 → ~6.6e-5** \[MEASURED\] (`smoke-fh-10m-numa0-*`). **Kept NUMA1** `PROTORU=32-47`, `DU=48-55` for the Phase 1 CPU baseline.
- Recorded in `docker/lab.env.example` with this reasoning.
