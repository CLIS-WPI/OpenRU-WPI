# Open questions

Defaults from the Phase 1 brief; update when a human decides.

- [ ] Software UE: OAI nrUE (default) or srsUE for Milestone 4?
- [ ] Golden storage: Git LFS on GitHub (default) or a WPI file share?
- [ ] Hardware week: USRP N310 and Quectel RM520N-GL available? 10 GbE NIC with PTP timestamping?
- [ ] Upstreaming: discuss with ProtO-RU maintainers after Milestone 2 (default) or wait for Milestone 3?
- [ ] Repository: keep [CLIS-WPI/OpenRU-WPI](https://github.com/CLIS-WPI/OpenRU-WPI) (current) vs rename?

## Lab constraints

- GPU pin and cpusets: `docker/lab.env` (see `lab.env.example`). Not in git.
- Host OS Ubuntu 22.04.5; containers Ubuntu 24.04; kernel **not** PREEMPT_RT.
- ROHC **skipped, not needed for Phase 1**.
- ProtO-RU fork: [CLIS-WPI/ProtO-RU](https://github.com/CLIS-WPI/ProtO-RU) `openru/main` @ `45dbc958`.

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

From **M2 on**, every CUDA run uses the same method; M2 requires CUDA late **ratio ≤ 2.096e-6** (this baseline). A regression blocks M2.

## CPU topology (this host) — pinning decision

See `docs/reports/cpu-topology.md`.

- SMT **off** (`Thread(s) per core: 1`); `thread_siblings_list` is a singleton — **32–63 are not SMT siblings of 0–31** (SMT re-pin clause does not apply).
- GPU0 and GPU1 PCI are both on **NUMA0**. Optional NUMA0 OFH pin (`16-27`/`28-31`) raised 600 s late ratio **~4.9e-6 → ~6.6e-5** \[MEASURED\] (`smoke-fh-10m-numa0-*`). **Kept NUMA1** `PROTORU=32-47`, `DU=48-55` for the Phase 1 CPU baseline.
- Recorded in `docker/lab.env.example` with this reasoning.
