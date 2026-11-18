# Open questions

Defaults from the Phase 1 brief; update when a human decides.

- [ ] Golden storage: Git LFS on GitHub, a WPI file share, or **Zenodo with a DOI**? **Proposal:** Zenodo record *OpenRU Phase 1 golden IQ — M1* (`baseline`, `b40`, `b100`), concept DOI + per-milestone version DOI, `openru-goldens-m1.tar.zst` (~2.11 GiB uncompressed), verified against in-tree `MANIFEST.json`/`SHA256SUMS` via `OPENRU_GOLDEN_URL=… make fetch-golden`. License AGPL-3.0 (decided, see *Resolved*). Not uploaded yet; a human creates the Zenodo record. See `docs/reports/M1.md` appendix.
- [ ] **10 GbE NIC with PTP timestamping** for the capture path.
- [ ] **Real-time host:** `isolcpus`/`nohz_full`/`rcu_nocbs` on cores 32-63 would allow the b100 golden here; needs a reboot of the shared server (human/lab decision).

- [ ] **Null-radio dump label.** The null radio labels TX buffers by the radio TX sample clock (`external/proto-ru/lib/radio/null/radio_null_session.cpp:234-245`), not by the DU slot of the grid; under replay timing a correct grid N can be labelled N+1 in `tx_index`/`iq_meta`. The RU writes U-plane by its header slot (`ofh_uplane_rx_symbol_data_flow_writer.cpp:17`) and drops late data (no wrong-slot writes). Open: take the dump label from the grid/upper-PHY `tx_request` slot.
- [ ] Upstreaming: discuss with ProtO-RU maintainers after Milestone 2 (default) or wait for Milestone 3?
- [ ] Repository: keep [CLIS-WPI/OpenRU-WPI](https://github.com/CLIS-WPI/OpenRU-WPI) (current) vs rename?

## Lab constraints

- GPU pin and cpusets: `docker/lab.env` (see `lab.env.example`). Not in git.
- Host OS Ubuntu 22.04.5; containers Ubuntu 24.04; kernel **not** PREEMPT_RT.
- ROHC **skipped, not needed for Phase 1**.
- ProtO-RU fork: [CLIS-WPI/ProtO-RU](https://github.com/CLIS-WPI/ProtO-RU) `openru/main` @ `45dbc958`.

## M1 closure — open item

- [ ] **CI runner hosting:** register an ephemeral self-hosted runner (dedicated VM, unprivileged user, rootless Docker) for `replay-golden`, or keep the workflow `workflow_dispatch`-only/inert through M2? No runner is registered today (`total_count=0`). **Default:** keep inert; manual `make replay-golden` is the gate.

## Upstream candidate: OCUDU PRG-view precoding path [MEASURED]

`lib/phy/support/resource_grid_mapper_impl.cpp:245-263` calls the precoder through
per-PRG views (`precoding.get_prg_coefficients`, `re_buffer_reader_view` /
`re_buffer_writer_view`, `apply_precoding`) with 1-PRB PRGs. At 2x2 / 2 layers
(100 MHz, 30 kHz) that production path measures **0.511 ms** per slot vs **0.120 ms**
for a plain AVX-512 Cat-B strip on the same core — **~4x slower**. Upstream candidate:
hoist/cache the PRG weights and widen the inner kernel beyond 12 REs. [MEASURED]
Artifacts: `src/cuda/standalone/RESULTS_SCALING.md` (PR #4), `scaling_results.csv`.

## Backlog (hardware week): UHD ATR / TDD switching

**Do not start until the hardware week / FEM bench.**

Backlog item for the hardware week: Cursor found that ProtO-RU defaults to
`transmission_mode: continuous` (`ru_sdr_config.h:25`), so UHD never sends end-of-burst
and N310 ATR cannot drive TDD switching. For the FEM bench: implement `feat/uhd-atr` per
`hardware/n78/H1_TDD_GPIO.md` §4 (OpenRU repo, `hw/n78-fem`), switch to discontinuous
transmission with `power_ramping_time_us >= 2` (prefer 5-10), then rerun
`replay-golden` and the 600 s null `smoke-fh` to confirm DL IQ and late ratio are
unchanged by the mode change.

## Resolved decisions

Moved here when a decision landed; the commit that resolved it is listed.

| Decision | Resolved by |
|---|---|
| Software UE = **srsUE over ZMQ** (M4) | `8d24d30` |
| OCUDU ZMQ radio with ProtO-RU's SDR path: M4 only (`--device_driver zmq`; ProtO-RU README calls ZMQ unsupported) — not used in M1/M2/M3 | `8d24d30` |
| Golden-record **license: AGPL-3.0** (storage/Zenodo upload remains open) | `58d343c` |
| M1 goldens **regenerated with the N=100 Δ gate**: null radio waits for N=100 stable slots and the next SFN 0, `first_du=0.0` on every cold replay; baseline/b40/b100 = 4000/2000/800 slots, two cold replays each, `max_abs=0`; strict full-range `iq_compare` kept; gate not retuned to −1052 | `8d24d30` |
| **M2 CUDA vs CPU golden criteria**: BFP byte-identical; OFDM `ci16` max \|diff\| ≤ 1 LSB and error power ≤ −60 dB per port/slot; "0 differing samples" stays the CPU-vs-CPU bar | `8d24d30` (merge `8a3e2c0`) |
| **Late-packet threshold**: hard fail if `drop > 0` or `late/(rx+tx) > 1e-5` after warm-up; always report the ratio and absolute counts; M0 emulator reference `2.096e-6` (600 s), M2 gate vs the M1 CPU+null `7.094e-6` | `07e6a70` |
| **CPU topology / pinning (dev server)**: SMT off, 32–63 not siblings of 0–31; a NUMA0 OFH pin raised the 600 s late ratio ~4.9e-6 → ~6.6e-5, so NUMA1 `PROTORU=32-47` / `DU=48-55` is kept and recorded in `docker/lab.env.example` | `07e6a70` |
| **Hardware week availability**: N310, RM520N-GL and a programmable SIM available; bench host is x86-64 (i5-13600KF, no AVX-512, no GPU); build server produces x86-64-v3 images | `2797fbf` |
| **Bench host core map + P/E pinning (LOCKED)**: ProtO-RU `2-5`, DU `6-11`, housekeeping/Open5GS/IRQs `0-1,12-19`; `isolcpus=2-11 nohz_full=2-11 rcu_nocbs=2-11 irqaffinity=0-1,12-19 intel_idle.max_cstate=1 processor.max_cstate=1`; HT on with both siblings isolated; isolation trio enforced by `make bench-preflight` (`hwlatdetect` measures firmware/SMI/C-state latency — BIOS checklist in `docs/BENCH_BUNDLE.md`) | `2797fbf`, locked in `e014149`, cstate args added in this PR |
| **Bench N310 identity**: n310-10, serial `33A6E56`, IQ/mgmt `192.168.10.2` over `enp5s0f1np1` (host `192.168.10.1/24`, MTU 9000); MPM 4.11.0.0-g0d7ed3b1 (MPM 7.0), FPGA 8.2, FS 20260908111319; image ships UHD 4.11.0.0, preflight probes in-container; day 1 internal clock, OctoClock (`192.168.60.2`) later | `2797fbf` |
