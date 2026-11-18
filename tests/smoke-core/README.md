# Suite: smoke-core (NG Setup against Open5GS)

Wrap of the existing `make smoke-core`.

| | |
|---|---|
| Coverage | PLMN compatibility check, Open5GS core health, DU→AMF SCTP association, NG Setup Response |
| Inputs | `profiles/baseline/du-core.yml`, `external/proto-ru/docker/open5gs/*`, image `openru/core:m0` + `openru/protoru:<OPENRU_TAG>` |
| Pass criteria | `NGSetupResponse` (or equivalent) seen in the DU log within 45 s; PLMN comparison passes |
| Runtime | ~1–3 min (core health wait dominates) |
| Host needs | docker only; no GPU, no radio, no quiet-host requirement (functional, not a timing measurement). Takes the measure lock briefly while compose is up so it never overlaps a measurement |
| Shared libs | none (functional suite) |

## Profiles

- `default` — image tag `m0` (the built `openru/core:m0`); override with `OPENRU_TAG=...`.

## Command

```bash
make test SUITE=smoke-core
```
