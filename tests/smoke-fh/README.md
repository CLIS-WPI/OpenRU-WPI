# Suite: smoke-fh (M0/M1 fronthaul gate)

Wrap of the existing `make smoke-fh`: OCUDU DU + ProtO-RU over the `openru_fh`
bridge, KPI parsing via `scripts/parse_smoke_fh.py`, same exit semantics.

| | |
|---|---|
| Coverage | OFH RX/TX at the RU, slot indication advance, late/drop gate, DU-side UL KPIs |
| Inputs | `profiles/<docker-profile>/du-fh.yml`, `protoru.yml` (emulator) or `protoru-null.yml` (null), `SMOKE_SECS` |
| Pass criteria | After warm-up: `drop == 0` and `late/(rx+tx) < 1e-5`; slot indication advances without gaps; **U-plane rate check within ±2%** of the profile expected rates (`tests/lib/uplane_rate.py`) |
| Runtime | ~60 s measure + ~2 min setup/teardown (`SMOKE_SECS=60`) |
| Host needs | GPU 1 (lab.env), docker; quiet host (cores 32–55 reserved). No isolated cores required on the dev host |
| Shared libs | `tests/lib/quiet_host.sh` (pre + monitor + validate), `tests/lib/uplane_rate.py` |

## Profiles

- `emulator` — M0: `PROTORU_PROFILE=emulator`, image `openru/protoru:m0`, baseline profile.
  Late-ratio baseline (emulator): 2.096e-6 (600 s) [MEASURED].
- `null` — M1/v1: `PROTORU_PROFILE=null`, image `openru/protoru:v1-candidate` (locked CPU config),
  baseline profile. Late-ratio baseline (CPU+null): 7.094e-6 (600 s) [MEASURED],
  label *null radio, slot RX buffers, not representative of UHD*. Gate compares against the
  CPU+null baseline, never the emulator number.

Expected rates (`expected_rates.json`, from the golden pcaps / V1_SMOKE derivation, tolerance ±2%):
DL U-plane ≈ 6,784.6/s, DL C-plane ≈ 513.4/s, UL C-plane ≈ 1,800/s (1,600/s UL data
+ 200/s PRACH).

## Command

```bash
make test SUITE=smoke-fh PROFILE=emulator
make test SUITE=smoke-fh PROFILE=null
```

Overridable env: `SMOKE_SECS`, `OPENRU_TAG`, `RUN_HOST_LIMITED` n/a. Longer runs
(`SMOKE_SECS=600`) reproduce the milestone baselines.
