# Bench bundle

The **bench bundle** is the reproducible, measurement-grade deployment of OpenRU on the dedicated bench host. The
development server may relax host-only items; the bench bundle must fail closed when they are missing.

## Bench host (identified 2026-11-18)

| | |
|---|---|
| CPU | Intel Core i5-13600KF — 6 P-cores with HT + 8 E-cores, 20 logical CPUs, **no AVX-512** |
| RAM | 31 GB |
| NIC | Intel X710 4-port 10 GbE SFP+; `enp5s0f0np0` link up, f1–f3 down |
| OS | Ubuntu, kernel 7.0.0-28-generic, Docker 29.6.1; no isolation on the cmdline yet |
| Radio | UHD installed on the host; USRP serial `32E0FC4` (N310; exact address/model confirmation pending) |
| GPU | none — ProtO-RU runs the CPU configuration |

Because the host has no AVX-512, images are built for **`x86-64-v3`** (`v1-candidate-v3`): FFTW + ESTIMATE + AVX2,
same source/config as `v1-candidate` (`x86-64-v4`), see "Images" below.

## Core map (proposed; the human locks it)

Measured: P-core logical CPUs `0-11` (HT siblings 0/1, 2/3, …, 10/11), E-cores `12-19`.

| Role | CPUs |
|---|---|
| housekeeping, IRQs | `0-1` + `12-19` (irqaffinity) |
| Open5GS / core containers | `12-19` (`CORE_CPUSET`) |
| ProtO-RU real-time threads | `2-5` (`PROTORU_CPUSET`) |
| DU real-time threads | `6-11` (`DU_CPUSET`) |

`docker/bench.env` carries this map (plus `MARCH=x86-64-v3`, `OPENRU_TAG=v1-candidate-v3`, fronthaul iface and
USRP serial). Nothing here is host-specific secret state; the GPU-UUID-style values stay in `docker/lab.env` on
GPU hosts only.

## Kernel / real-time isolation (REQUIRED, fail closed)

```text
isolcpus=2-11 nohz_full=2-11 rcu_nocbs=2-11 irqaffinity=0-1,12-19
```

Set via GRUB (`/etc/default/grub`, then `update-grub` + reboot). Why: without isolation the scheduler, the timer
tick and RCU disturb the DU/RU RT threads, which is what made the b100 golden impossible on the shared server
(`docs/reports/B100_SENDER.md`).

`scripts/bench_preflight.sh` (via `make bench-preflight`) fails closed when:

- the P/E classification does not match 12 P + 8 E, or `PROTORU_CPUSET`/`DU_CPUSET` are not P-core-only;
- `isolcpus`, `nohz_full`, `rcu_nocbs` do not cover `2-11`, or `irqaffinity` does not keep IRQs off `2-11`;
- `enp5s0f0np0` is missing / not `i40e` / not link-up at 10 Gb/s;
- MTU on the fronthaul port is not 9000;
- `hwlatdetect` reports ≥ 20 µs over a 60 s window (`BENCH_HWLAT_SECS` to change; `BENCH_SKIP_HWLAT=1` only before
  the cmdline reboot);
- the container UHD major does not match the N310 MPM/filesystem generation (N310 MPM 3.x ↔ UHD 3.x FS,
  MPM 4.x ↔ UHD 4.x FS). The images ship UHD 4.7.0.0; a 3.x-MPM N310 must be updated with
  `uhd_images_downloader` + `usrp_n3xx_fs_updater --type filesystem` (or the image rebuilt) before any run;
- the USRP is not visible to host UHD once `BENCH_USRP_REQUIRED=1` (until the N310 address is known this is a
  warning).

Other required host settings: MTU 9000 on the fronthaul port, `PROTORU_SHM_SIZE` ≥ the profile dump size, and
`tcpdump` on the host for captures (`make capture`).

## Images

| Tag | Config | Provenance |
|---|---|---|
| `openru/protoru:v1-candidate-v3` | FFTW + ESTIMATE, `MARCH=x86-64-v3` (AVX2) | built on the dev server 2026-11-18, submodule `d8d2097894`, image `c88dc855d7de` |
| `openru/protoru:v1-candidate` | FFTW + ESTIMATE, `MARCH=x86-64-v4` (AVX-512) | v1 reference (GPU-server milestone runs) |

The AVX-512 kernel variants inside OCUDU (`_avx512` objects) are guarded by runtime CPU-feature selection, so a
v3 image is safe on a non-AVX-512 host; the reverse is not.

`docker/compose.cpu.yml` is the bundle overlay for the GPU-less host: it removes the protoru GPU pin, the
`nvidia-smi` precheck and the NVIDIA env vars, and pins core containers to `CORE_CPUSET`.

```bash
docker compose --env-file docker/bench.env \
  -f docker/compose.yml -f docker/compose.cpu.yml --profile fh up -d
```

## Goldens are image-specific

Goldens record the image in `testdata/golden/<profile>/MANIFEST.json` (`image`). If the v3 image produces IQ that
differs from the v4 goldens, a v3 golden set is generated (two cold replays, 0 differing samples) and its MANIFEST
records `image: v1-candidate-v3`. Never present a v4 golden as validation of the v3 image.

## Run order (start → last)

1. 20 MHz 2×2 — `baseline` (the reference profile).
2. 40 MHz 2×2 — `b40`.
3. 4×4 at 40/100 MHz — **last** (new profile; not yet created, requires radio config + golden per profile).

For each stage: `make bench-preflight`, then live `smoke-fh` 2×600 s on a quiet host, then `replay-golden`, then
record the result in the milestone/campaign report with `[MEASURED]` tags.

## Open items

- USRP N310 exact model/address and the device MPM/filesystem version (needed to lock the UHD compatibility check
  and the radio profile).
- 4×4 profile definition and its golden.
- X710 PTP timestamping support for the capture path (see `docs/OPEN_QUESTIONS.md`).
- Core-map lock by the human (`docs/OPEN_QUESTIONS.md`).
