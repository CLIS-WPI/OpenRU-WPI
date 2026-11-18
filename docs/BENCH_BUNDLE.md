# Bench bundle

The **bench bundle** is the reproducible, measurement-grade deployment of OpenRU on the dedicated bench host. The
development server may relax host-only items; the bench bundle must fail closed when they are missing.

## Bench host (identified 2026-11-18)

| | |
|---|---|
| CPU | Intel Core i5-13600KF — 6 P-cores with HT + 8 E-cores, 20 logical CPUs, **no AVX-512** |
| RAM | 31 GB |
| NIC | Intel X710 4-port 10 GbE SFP+: `enp5s0f1np1` = N310 IQ/management link (`192.168.10.1/24`, MTU 9000, 10 Gb/s) |
| OS | Ubuntu, kernel 7.0.0-28-generic, Docker 29.6.1; no isolation on the cmdline yet |
| Radio | **N310-10**, serial `33A6E56`, IQ over SFP1 at `192.168.10.2` (mgmt same); MPM 4.11.0.0-g0d7ed3b1 (MPM 7.0), FPGA 8.2, filesystem 20260908111319 |
| GPU | none — ProtO-RU runs the CPU configuration |

Because the host has no AVX-512, images are built for **`x86-64-v3`** (`v1-candidate-v3`): FFTW + ESTIMATE + AVX2,
same source/config as `v1-candidate` (`x86-64-v4`), see "Images" below.

## Core map (bench map, locked)

Measured topology of the i5-13600KF: P-core logical CPUs `0-11` with HT **on**
(siblings 0/1, 2/3, …, 10/11), E-cores `12-19`. Every isolated core has **both
HT siblings** inside `isolcpus=2-11`, so no sibling of an RT core is left to
the scheduler.

| Role | CPUs |
|---|---|
| housekeeping, Open5GS, IRQs | `0-1` + `12-19` (`irqaffinity`; core containers `12-19` via `CORE_CPUSET`) |
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
- `enp5s0f1np1` is missing / not `i40e` / not link-up at 10 Gb/s / missing `192.168.10.1/24`;
- MTU on the fronthaul port is not 9000;
- `hwlatdetect` reports ≥ 20 µs over a 60 s window (`BENCH_HWLAT_SECS` to change; `BENCH_SKIP_HWLAT=1` only before
  the cmdline reboot);
- the container UHD major does not match the N310 MPM/filesystem generation (N310 MPM 3.x ↔ UHD 3.x FS,
  MPM 4.x ↔ UHD 4.x FS). The images ship UHD 4.7.0.0; a 3.x-MPM N310 must be updated with
  `uhd_images_downloader` + `usrp_n3xx_fs_updater --type filesystem` (or the image rebuilt) before any run;
- the USRP is not visible to host UHD once `BENCH_USRP_REQUIRED=1` (until the N310 address is known this is a
  warning).

The hwlatdetect result parser has unit tests with captured pass/fail output:
`python3 -m unittest discover -s tools/bench -p 'test_*.py' -v`.

Other required host settings: MTU 9000 on the fronthaul port, `PROTORU_SHM_SIZE` ≥ the profile dump size, and
`tcpdump` on the host for captures (`make capture`).

## Images

| Tag | Config | Provenance |
|---|---|---|
| `openru/protoru:v1-candidate-v3-uhd411` | FFTW + ESTIMATE, `MARCH=x86-64-v3` (AVX2), **UHD 4.11.0.0** | bench image, built on the dev server 2026-11-18, submodule `d8d2097894`, image `e2e955360db9` |
| `openru/protoru:v1-candidate-v3` | FFTW + ESTIMATE, `MARCH=x86-64-v3` (AVX2), UHD 4.7.0.0 | built on the dev server 2026-11-18, submodule `d8d2097894`, image `c88dc855d7de` |
| `openru/protoru:v1-candidate` | FFTW + ESTIMATE, `MARCH=x86-64-v4` (AVX-512) | v1 reference (GPU-server milestone runs) |

The AVX-512 kernel variants inside OCUDU (`_avx512` objects) are guarded by runtime CPU-feature selection, so a
v3 image is safe on a non-AVX-512 host; the reverse is not.

`docker/compose.cpu.yml` is the bundle overlay for the GPU-less host: it removes the protoru GPU pin, the
`nvidia-smi` precheck and the NVIDIA env vars, and pins core containers to `CORE_CPUSET`.

```bash
# one switch for every make target (compose env file + CPU overlay + preflight)
BENCH=1 make bench-preflight     # includes the in-container N310 probe
BENCH=1 make build-protoru       # UHD 4.11.0.0 image (docker/bench.env)
BENCH=1 PROFILE=bench-20mhz PROTORU_PROFILE=uhd make smoke-fh   # live 60 s gate
BENCH=1 PROFILE=bench-20mhz PROTORU_PROFILE=uhd SMOKE_SECS=600 make smoke-fh
BENCH=1 OPENRU_REPLAY_TAG=v1-candidate-v3-uhd411 make replay-golden
make up                          # prints the core map + antenna map
```

`BENCH=1` makes the Makefile use `docker/bench.env`, add `docker/compose.cpu.yml`, and
point `preflight` at the bench env (CPU-only mode skips the GPU check). Equivalent raw
compose form:

```bash
docker compose --env-file docker/bench.env \
  -f docker/compose.yml -f docker/compose.cpu.yml --profile fh up -d
```

Transfer the image from the build server once: `docker save openru/protoru:v1-candidate-v3 |
ssh bench docker load` (and `openru/core:m0` for `smoke-core`).

## Goldens are image-specific

Goldens record the image in `testdata/golden/<profile>/MANIFEST.json` (`image`). If the v3 image produces IQ that
differs from the v4 goldens, a v3 golden set is generated (two cold replays, 0 differing samples) and its MANIFEST
records `image: v1-candidate-v3`. Never present a v4 golden as validation of the v3 image.

## Radio (stage 1: N310-10 only)

| Radio | Address | NIC (host) | Use |
|---|---|---|---|
| **n310-10** | `192.168.10.2` (mgmt same) | `enp5s0f1np1` `192.168.10.1/24`, MTU 9000 | **stage 1** |
| n310-20 | `192.168.20.2` | `enp5s0f2np2` | later stage |
| n310-30 | `192.168.30.2` | `enp5s0f3np3` | later stage |

- **N310 software:** MPM 4.11.0.0-g0d7ed3b1 (MPM version 7.0), FPGA 8.2, filesystem 20260908111319.
- **Clock:** sources available are `internal`, `external`, `gpsdo`. Day 1 uses
  `clock_source=internal,time_source=internal`; the OctoClock on the LAN (`192.168.60.2`) provides the
  10 MHz/PPS reference for a later external-clock stage.
- **Host UHD must not be used by the container.** The host has both a 4.10.0 distro package and a 4.11.0
  source build installed; the image ships its own UHD and the preflight probes **inside the container**.
- **Image:** `openru/protoru:v1-candidate-v3-uhd411` — UHD **4.11.0.0** (matching the N310 MPM), FFTW +
  ESTIMATE, `MARCH=x86-64-v3`, `OPENRU_CUDA=OFF`. Built with
  `make BENCH=1 build-protoru` (`UHD_VERSION=4.11.0.0` from `docker/bench.env`). UHD 4.11 needs
  Protobuf **and gRPC** (`libprotobuf-dev protobuf-compiler libgrpc++-dev protobuf-compiler-grpc`) in the
  builder base and `libprotobuf32 libgrpc++1.51 libabsl20220623t64` at runtime — added in
  `docker/Dockerfile.protoru`; without them `uhd_config_info`/`uhd_usrp_probe` die on a missing `.so`.
- **Preflight** (`make bench-preflight`) verifies the container UHD version equals `4.11.0.0`, then runs
  `uhd_usrp_probe --args addr=192.168.10.2[,mgmt_addr=192.168.10.2]` **inside the container**
  (`--network host`) and **fails** on any MPM/filesystem incompatibility, on a missing serial `33A6E56`, or on
  a probe error. `BENCH_SKIP_USRP=1` is a dev-only escape hatch.

### ProtO-RU device args (bench profile)

`profiles/bench-20mhz/protoru.yml` (20 MHz 2×2, stage 1):

```text
type=n3xx,addr=192.168.10.2,mgmt_addr=192.168.10.2,clock_source=internal,time_source=internal,master_clock_rate=122.88e6
```

**Master clock rate 122.88 MHz** — the N310 supports only **122.88, 125.0 and 153.6 MHz**
([Ettus KB N300/N310](https://kb.ettus.com/N300/N310): "Configurable sample rates: 122.88, 125, and 153.6 MS/s";
[N300/N310/N320/N321 Getting Started Guide](https://kb.ettus.com/USRP_N300/N310/N320/N321_Getting_Started_Guide):
"the N310 supports the three fixed Master Clock Rates … 122.88 MHz, 125.00 MHz, 153.60 MHz"). The sample rate
must be an integer divisor of the MCR, with even decimation preferred.

| Profile | Sample rate | Decimation | FFT size (30 kHz SCS) |
|---|---|---|---|
| `bench-20mhz` | 30.72 Msps | 122.88 / 30.72 = **4** | 1024 |
| `bench-40mhz` | 61.44 Msps | 122.88 / 61.44 = **2** | 2048 |
| 4×4 / 100 MHz (later) | 122.88 Msps | **1** | 4096 |

These **differ from the null-radio goldens** (23.04 / 46.08 Msps, FFT 768 / 1536), because 23.04 is not an
integer divisor of any N310 MCR (122.88/23.04 = 5.33). That is harmless: the 7.2 split carries
frequency-domain OFH symbols, so the **DU side is unaffected** — DU configs, KPI rates and the `smoke-fh`
gates stay as they are; only the RU's own OFDM sample rate changes. `replay-golden` still replays through the
null radio at the golden rates, so the goldens remain valid for the same image.
`make bench-preflight` checks every `profiles/bench-*/protoru.yml`: the MCR must be one of the three N310
rates and the sample rate an integer divisor of it.

## Antenna map (measured cabling)

| | N310 side (all TX **and** RX) | Cabling | UE side (RM520N, n78) |
|---|---|---|---|
| Pair 1 | RF0 | → | ANT2 — TX **and** RX |
| Pair 2 | RF1 | → | ANT0 — TX **and** RX |
| Pair 3 | RF2 | → | ANT1 — **RX only** |
| Pair 4 | RF3 | → | ANT3 — **RX only** |

- N310 RF0–RF3 are all bidirectional (TX and RX); the 4×4 DL uses all four.
- On the UE side only ANT2 and ANT0 transmit in n78; ANT1 and ANT3 receive only, so a
  4×4 DL has two TX chains and four RX chains.
- 2×2 profiles use **RF0–RF1** (→ ANT2, ANT0 — both bidirectional); 4×4 uses all four.
- `scripts/up.sh` prints this table on every bring-up (with the core map and image tags).

## Run order (start → last)

1. 20 MHz 2×2 — `bench-20mhz` (N310 RF0–RF1; benchmarks against the `baseline` goldens).
2. 40 MHz 2×2 — `bench-40mhz` (61.44 Msps = 122.88/2, FFT 2048; benchmarks against the `b40` goldens).
3. 4×4 at 40/100 MHz — **last** (new profile; not yet created, requires radio config + golden per profile).

For each stage, in this order:

1. `make bench-preflight` (fails closed).
2. Live `smoke-fh` 2×600 s on a quiet host.
3. **`make replay-golden OPENRU_REPLAY_TAG=v1-candidate-v3` — mandatory on the bench host** (baseline runs; b40 and
   b100 skip from their MANIFEST). The v3 image was shown bit-exact against the v4 golden only on the AVX-512 server; FFTW and OCUDU
   select SIMD paths at runtime, so on the non-AVX-512 bench host the golden equality must be re-confirmed
   (0 differing samples). If it differs, build the v3 golden set under `GOLDEN_ROOT=testdata/golden-v3` and record
   `image: v1-candidate-v3` in its MANIFEST.
4. Record the result in the campaign report with `[MEASURED]` tags.

## Open items

- USRP N310 exact model/address and the device MPM/filesystem version (needed to lock the UHD compatibility check
  and the radio profile).
- 4×4 profile definition and its golden.
- X710 PTP timestamping support for the capture path (see `docs/OPEN_QUESTIONS.md`).
- Core-map lock by the human (`docs/OPEN_QUESTIONS.md`).
