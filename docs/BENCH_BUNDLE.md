# Bench-bundle requirements

Requirements the **bench bundle** must satisfy. The development server may relax host-only items (marked DEV); the
bench image/host must fail closed when they are missing.

## Kernel / real-time isolation (REQUIRED)

The bench host kernel **must isolate the DU and RU cores** so neither the scheduler, the timer tick, nor RCU runs on
them:

```text
isolcpus=managed_irq,<DU_CPUSET>,<PROTORU_CPUSET>
nohz_full=<DU_CPUSET>,<PROTORU_CPUSET>
rcu_nocbs=<DU_CPUSET>,<PROTORU_CPUSET>
```

`make preflight` (scripts/gpu1_preflight.sh) checks that the union of `PROTORU_CPUSET` and `DU_CPUSET` from
`docker/lab.env` is covered by all three kernel parameters. Set `OPENRU_REQUIRE_ISOLATION=1` on the bench host to make
the check fail closed; on the shared development server the same check only warns.

Why: an accurate replay sender (p99 ~12 us) still shows random 1-3 ms preemptions without isolation, which makes a
bit-identical b100 golden impossible. See `docs/reports/B100_SENDER.md`.

## Other bench requirements

- Bench host architecture: aarch64 (Jetson AGX Orin 64 GB or DGX Spark; pending), bundle built on this x86-64 server.
- 10 GbE NIC with PTP timestamping (open item; see `docs/OPEN_QUESTIONS.md`).
- `docker/lab.env` with the bench GPU UUID and cpusets; `make preflight` must pass with `OPENRU_REQUIRE_ISOLATION=1`.
- MTU 9000 on `openru_fh`; `PROTORU_SHM_SIZE` >= the profile dump size.
- The v1 reference image recorded in each `testdata/golden/<profile>/MANIFEST.json` (`image`, `sender`).
