# v3 candidate run evidence — moved out of git

The raw artifacts of the `v1-candidate-v3` verification (4×600 s `smoke-fh` runs and the
`replay-golden baseline` run, 2026-11-18) are **not committed**: they are logs and KPI dumps
(~8.3 MB / ~40k lines). They live on the build server at:

```
<artifact-root>/v3-smoke-evidence/docs/reports/raw/v3-smoke/
```

(`<artifact-root>` is `OPENRU_ARTIFACTS_DIR` in gitignored `docker/bench.local.env`.)

`MANIFEST.sha256` lists every file with its SHA-256 and the same repo-relative path, so the
artifact tree is verifiable against this directory:

```bash
cd <artifact-root>/v3-smoke-evidence
sha256sum -c /path/to/openru-sw/docs/reports/raw/v3-smoke/MANIFEST.sha256
```

## Runs and results (summary — see `docs/reports/V3_CANDIDATE.md`)

| Run | Profile | RU lates | late frac | drop | Gate |
|---|---|---|---|---|---|
| `v1-candidate-v3-baseline-r1` | baseline (20 MHz 2×2, null) | 0 | 0 | 0 | PASS |
| `v1-candidate-v3-baseline-r2` | baseline | 6 | 4.08e-07 | 0 | PASS |
| `v1-candidate-v3-b40-r1` | b40 (40 MHz 2×2) | 177 (all in 2 s) | 1.20e-05 | 0 | **FAIL** |
| `v1-candidate-v3-b40-r2` | b40 | 4 | 2.73e-07 | 0 | PASS |
| `replay-golden-baseline` | baseline replay vs the v4 golden | — | — | — | PASS (0 differing samples, 4000 slots × 2 ports) |

Each run directory holds `run.log`, `smoke-fh-kpi.json`, `smoke-fh-late-hist.csv`,
`smoke-fh-du.log`, `smoke-fh-ru.log`, `smoke-fh-hostcheck.json`, `smoke-fh-hostcheck-pre.json`;
`replay-golden-baseline/` holds `run.log` and `check.json`.
