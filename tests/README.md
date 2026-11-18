# OpenRU test framework

Every part of the project can be re-tested on its own with one command, the same way every time:

```bash
make test SUITE=<suite> PROFILE=<profile>   # run one suite/profile
make test-list                              # list suites and profiles
```

Existing targets (`make smoke-fh`, `make smoke-core`, `make replay-golden`, ...) remain as aliases and
are unchanged; each `tests/<suite>/run.sh` wraps them.

## Layout

```
tests/
  <suite>/
    README.md          what it tests, inputs, pass criteria, runtime, host needs
    run.sh             the single entry point (lock, quiet-host, timeout rules inside)
    profiles/<name>/   env defaults (OPENRU_TAG, timings) and suite-profile inputs
  lib/
    common.sh          env loading, /tmp/openru-measure.lock, result writing
    quiet_host.sh      shared quiet-host check (every suite that measures)
    uplane_rate.py     shared U-plane rate check (every suite that measures rates)
    golden_energy.sh   shared golden energy check (every suite that replays IQ)
    cuda.sh            OCUDU/test-binary builds and GPU pinning for the cuda-* suites
    write_result.py    the common result-JSON writer
```

## Result schema

One JSON per run at `docs/reports/runs/<suite>/<date>-<profile>.json`
(`schema: openru-test-result/1`): `suite`, `profile`, `status`
(`PASS` | `FAIL` | `INVALID` | `SKIPPED`), `skip_reason`
(`host_limited` | `deferred`), `image` (tag + digest), `submodule_commit`,
`repo_commit`, `host`, `isolation`, `start`/`end`, `metrics`, `evidence`.
Run evidence is copied under `docs/reports/runs/<suite>/evidence/<date>-<profile>/`
so later runs never overwrite a recorded run's artifacts.

## Exit codes (every run.sh)

- `0` PASS or SKIPPED
- `1` FAIL
- `3` INVALID — quiet-host violation, or `/tmp/openru-measure.lock` already held

## Rules every run.sh follows

- Sources `docker/versions.env` + `docker/lab.env` and fails closed if `lab.env` is missing.
- Runs that measure latency / late ratios (and every cuda-* timed run) hold
  `/tmp/openru-measure.lock` for their duration and remove it on failure too.
- Quiet-host suites run `tests/lib/quiet_host.sh` before and during the measurement;
  a busy host is INVALID, never FAIL (failed measurements are neither PASS nor FAIL).
- Long steps are wrapped in `timeout` (per-profile `TIMEOUT_SECS`).
- Never starts a measurement while a docker build is running.
