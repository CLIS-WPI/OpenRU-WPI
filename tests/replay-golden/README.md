# Suite: replay-golden (CPU replay vs stored golden)

Wrap of the existing `make replay-golden`, one golden per profile. The replay
settings (`lead_mode`, `lead_us`, `sender`) are read from the golden
`MANIFEST.json` by the make target — the mode mismatch is impossible by
construction (`tools/golden/manifest_mode.py`).

| | |
|---|---|
| Coverage | fh_replay of the stored pcap against ProtO-RU null radio; dump gate at the golden window slot; per-port DL U-plane energy; UL-slot leakage; non-empty slot count; bit-exact IQ compare (`0 differing samples`) |
| Inputs | `testdata/pcap/<profile>.pcapng`, `testdata/golden/<profile>/{MANIFEST.json,window.json,port*.cf32}`, MTU 9000 on `openru_fh` |
| Pass criteria | `tools/golden/check.py` PASS (shared `tests/lib/golden_energy.sh`) **and** `tools/iq_compare/iq_compare.py --by-slot --threshold 0` PASS (0 differing slots/samples) |
| Runtime | ~5–10 min per profile (replay + dump + compare) |
| Host needs | GPU 1 for ProtO-RU, docker; the replay is deterministic (rate 1.0, bit-exact gate) so quiet-host is not a pass criterion |
| Shared libs | `tests/lib/golden_energy.sh` |

## Profiles and skip semantics

- `baseline` — default golden (v1-candidate, 4000 slots). Runs.
- `b40` — 2000 slots; golden is `host_limited` (see MANIFEST) → **SKIPPED(host_limited)**
  unless `RUN_HOST_LIMITED=1`.
- `b100` — 800 slots; golden is **deferred** → SKIPPED(deferred). Never presented as v1-validated.

## Command

```bash
make test SUITE=replay-golden PROFILE=baseline
make test SUITE=replay-golden PROFILE=b40
make test SUITE=replay-golden PROFILE=b100
```
