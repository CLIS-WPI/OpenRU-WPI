# Open questions

Defaults from the Phase 1 brief; update when a human decides.

- [ ] Software UE: OAI nrUE (default) or srsUE for Milestone 4?
- [ ] Golden storage: Git LFS on GitHub (default) or a WPI file share?
- [ ] Hardware week: USRP N310 and Quectel RM520N-GL available? 10 GbE NIC with PTP timestamping?
- [ ] Upstreaming: discuss with ProtO-RU maintainers after Milestone 2 (default) or wait for Milestone 3?
- [ ] Repository name: `openru-sw` (default) or keep everything in `CLIS-WPI/OpenRU`?

## Lab constraints recorded

- OpenRU Phase 1 on this host is pinned to **GPU 1** only (`GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058`). GPU 0 is reserved for other workloads.
- Host OS is Ubuntu 22.04.5; container builds use Ubuntu 24.04.
- Host kernel is **not** PREEMPT_RT (`6.8.0-138-generic`).
- ROHC is **skipped, not needed for Phase 1** (`rohc-lib.org` unreachable; OFH/low-PHY path does not require ROHC).

## Proposed smoke-fh late-packet threshold (needs human OK)

`make smoke-fh` on this non-RT host measured **late=10, drop=0 over 60 s** (**rate ≈ 0.17 late/s**) with emulator-mode ProtO-RU and GPU1. [MEASURED]

Proposal (do not treat as pass until agreed):

- **Hard fail:** any `RX_ERR_DROP` > 0, or late_rate > **2.0 /s** over the 60 s window, or late_sum > **120** per 60 s.
- **Soft / report-only (M0 on non-RT):** late_sum ≤ **120** and drop = 0 → record `[MEASURED]` counts/rate in `docs/reports/M0.md`, exit code 2 from `parse_smoke_fh.py` / `make smoke-fh`.
- **Hard pass (zero late):** only on a PREEMPT_RT host or after timing/cpuset tuning brings late_sum to 0.

Until a threshold is agreed, M0 fronthaul is **soft-fail with evidence**, not a silent green.
