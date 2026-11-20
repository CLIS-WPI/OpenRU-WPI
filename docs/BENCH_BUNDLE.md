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
| ProtO-RU real-time threads | `2-7` (`PROTORU_CPUSET`; three physical cores) |
| ProtO-RU non-real-time threads | E-core `12` (container cpuset `PROTORU_CONTAINER_CPUSET=2-7,12`) |
| DU real-time threads | `8-11` (`DU_CPUSET`; two physical cores) |
| DU non-real-time threads | E-core `13` (container cpuset `DU_CONTAINER_CPUSET=8-11,13`) |

Cores plan accepted 2026-11-20 (previously RU `2-5`, DU `6-11`). Per-thread map, applied by the
profiles plus a post-start step (see [Thread plan and real-time health](#thread-plan-and-real-time-health)):

| CPU | Thread(s) |
|---|---|
| 2 / 3 | RU `ru_timing` / `ru_emu_#0` (busy poller) |
| 4 / 5 | RU `ru_rx_#0` / `ru_ofh_tx_#0` |
| 6 / 7 | RU `ru_phy_tx_#0` + `ru_phy_hp_#0` / `ru_phy_rx_#0` |
| 8 / 9 | idle / DU `ru_timing` (its HT sibling stays idle) |
| 10 / 11 | DU `ru_txrx_#0` / DU `main_pool#0` |
| 12 | RU `uhd_ctrl_ep0001` (UHD control, polls a full core), `ru_radio_#0`, main, gRPC, loggers |
| 13 | DU main thread, `io_broker_epoll`, loggers |

`docker/bench.env` carries this map (plus `MARCH=x86-64-v3`, `OPENRU_TAG=v1-candidate-v3`, fronthaul iface and
USRP serial). Nothing here is host-specific secret state; the GPU-UUID-style values stay in `docker/lab.env` on
GPU hosts only.

## Kernel / real-time isolation (REQUIRED, fail closed)

```text
isolcpus=2-11 nohz_full=2-11 rcu_nocbs=2-11 irqaffinity=0-1,12-19 intel_idle.max_cstate=1 processor.max_cstate=1
```

Set via GRUB (`/etc/default/grub`, then `update-grub` + reboot). Why: without isolation the scheduler, the timer
tick and RCU disturb the DU/RU RT threads, which is what made the b100 golden impossible on the shared server
(`docs/reports/B100_SENDER.md`). The two `*_max_cstate=1` arguments keep the CPUs out of deep idle states, which
otherwise add wake-up latency on the order of tens of microseconds.

**`hwlatdetect` is not an isolation test.** It measures *hardware* latency sources — firmware/SMI (System
Management Interrupt) handlers, memory/bus contention and C-state exit — none of which `isolcpus`/`nohz_full`
change. If it stays above 20 µs after the cmdline is applied, check these BIOS settings on the bench host:

- CPU C-states: **disabled** (C1E, C3, C6, C7, package C-states) and "C-State limit" = `C0`;
- "Power Technology"/"Energy Efficient Turbo"/EIST: **Maximum Performance** (no frequency scaling surprises);
- SMI/legacy sources: "Legacy USB Support" **disabled** (USB SMI), "PCIe ASPM" **disabled**, "HPET" enabled;
- "Memory Frequency"/XMP: keep the validated profile (memory contention shows up as SMI latency);
- firmware: BIOS/ME updates per the vendor's low-latency guidance.

The cmdline arguments are listed for the operator; `bench-preflight` enforces the isolation trio and `irqaffinity`
but does not fail on the `*_max_cstate` values (a BIOS that disables C-states makes them redundant).

### Kernel NMI watchdog (measured on the bench host)

`hwlatdetect` reported **42 µs events** that were traced to the **kernel NMI watchdog**, not to SMIs: the SMI
count was unchanged (**324 → 324 over 60 s**), while disabling the watchdog removed the events. With
`kernel.nmi_watchdog=0` the bench host shows **0 samples above 10 µs over 120 s and 0 SMIs**. The 20 µs gate
stays.

Make it persistent on the bench host (root):

```bash
cd <openru-sw checkout>   # the snippet needs scripts/sysctl_raise.sh
{
  printf '%s\n' \
    '# OpenRU bench real-time profile: the NMI watchdog adds ~40 us hwlatdetect' \
    '# events (it is not an SMI; the SMI counter does not move).' \
    'kernel.nmi_watchdog = 0' \
    '# UHD socket buffers for 30.72 Msps at MTU 9000. RAISE-ONLY: each line is' \
    '# max(current, 33554432), so the host rmem_max=50000000 is preserved.'
  scripts/sysctl_raise.sh net.core.wmem_max net.core.rmem_max
} > /etc/sysctl.d/90-openru-rt.conf
sysctl --system
```

`scripts/sysctl_raise.sh` reads each key with `sysctl -n` and writes **`max(current, 33554432)`**, so re-running it
never lowers a value the host already has. `tests/sysctl-raise/test.sh` checks the above-floor and below-floor cases
with a fake current value (`SYSCTL_RAISE_CURRENT`).

`make bench-preflight` fails if `/proc/sys/kernel/nmi_watchdog` is not `0` and records the kernel version
(`uname -r`) in its log, because the hwlatdetect figures are only comparable per kernel. It also **fails when
`net.core.wmem_max` or `net.core.rmem_max` is below 33554432** (UHD UDP socket buffers); it only checks, it never
writes sysctl values, and it never asks for a lower value than the host already has.

`scripts/bench_preflight.sh` (via `make bench-preflight`) fails closed when:

- the P/E classification does not match 12 P + 8 E, or `PROTORU_CPUSET`/`DU_CPUSET` are not P-core-only;
- `isolcpus`, `nohz_full`, `rcu_nocbs` do not cover `2-11`, or `irqaffinity` does not keep IRQs off `2-11`;
- `enp5s0f1np1` is missing / not `i40e` / not link-up at 10 Gb/s / missing `192.168.10.1/24`;
- MTU on the fronthaul port is not 9000;
- `hwlatdetect` reports ≥ 20 µs over a 60 s window (`BENCH_HWLAT_SECS` to change; `BENCH_SKIP_HWLAT=1` only before
  the cmdline reboot);
- the container UHD version does not match the N310 MPM generation: the bench image
  `openru/protoru:v1-candidate-v3-uhd411` ships **UHD 4.11.0.0** for an N310 MPM 4.x/filesystem (MPM 3.x needs
  UHD 3.x). Preflight reads the container UHD version (must be `4.11.0.0`) and then runs `uhd_usrp_probe`
  inside the image; an incompatible N310 must be updated with `uhd_images_downloader` +
  `usrp_n3xx_fs_updater --type filesystem` (or the image rebuilt) before any run;
- `REF=external` (opt-in; see the clock note below) and the in-container UHD-API
  check does not report `ref_locked` true (`"unlocked"`, missing sensor, probe
  error, or `BENCH_SKIP_USRP=1`). The helper reads
  `get_mboard_sensor("ref_locked").to_bool()`, because the real value string is
  `locked` / `unlocked` and `uhd_usrp_probe` may list names without values.
  `REF=internal` is the current default and skips the lock requirement;
- the USRP is not visible to host UHD once `BENCH_USRP_REQUIRED=1` (until the N310 address is known this is a
  warning).

The hwlatdetect result parser has unit tests with captured pass/fail output,
including `Max Latency: Below threshold` with 0 samples (treated as 0 us, a PASS
under the 20 µs gate):
`python3 -m unittest discover -s tools/bench -p 'test_*.py' -v`.

Other required host settings: MTU 9000 on the fronthaul port, `PROTORU_SHM_SIZE` ≥ the profile dump size, and
`tcpdump` on the host for captures (`make capture`).

## Images

| Tag | Config | Provenance |
|---|---|---|
| `openru/protoru:bench-<short-sha>` / `bench-latest` | FFTW + ESTIMATE, `MARCH=x86-64-v3` (AVX2), **UHD 4.11.0.0** | **the bench image**, built by `make bench-release` from a pushed clean commit; provenance labels (`org.openru.git.commit`, `org.openru.git.submodule`, `org.openru.build.date`, `org.openru.uhd`, `org.openru.march`) |
| `openru/core:bench-<short-sha>` / `bench-latest` | Open5GS core image | rebuilt at release time (needs network for the Open5GS clone) with the same `org.openru.git.commit` / `git.submodule` / `build.date` labels as ProtO-RU |
| `openru/protoru:v1-candidate` | FFTW + ESTIMATE, `MARCH=x86-64-v4` (AVX-512) | v1 reference for the GPU-server milestone runs, not for this host |

The GPU-server-only v3 image (`openru/protoru:v1-candidate-v3`) is documented in
`docs/reports/V3_CANDIDATE.md`; it is **not** part of the bench bundle — its UHD does not match the N310 MPM.

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
| **n310-10** | `192.168.10.2` (mgmt same) | `enp5s0f1np1` `192.168.10.1/24`, MTU 9000 | **stage 1** (default) |
| n310-20 | `192.168.20.2`, serial `33CF5B2` | `enp5s0f2np2` `192.168.20.1/24` | 2x2 stage (used 2026-11-20) |
| n310-30 | `192.168.30.2` | `enp5s0f3np3` | later stage [UNVERIFIED: never run, serial unknown] |

**Selecting the radio:** `make BENCH=1 up BENCH_RADIO=n310-20 ...` (also `restart-ru`,
`bench-preflight`). `scripts/radio_env.sh` loads `docker/radios/<radio>.env` after
`docker/bench.env`; it sets the radio NIC, host address, serial, device address, macvlan
subnet/gateway, RU address and probe address. The default stays `n310-10`.
`up`/`restart-ru` always write the local ProtO-RU profile copy, with `addr`/`mgmt_addr`
patched from the selected radio. (`RADIO` keeps its meaning `uhd|null`; the radio unit is
`BENCH_RADIO`.) `tests/radio-select/test.sh` checks the overlay without a radio. Before
using n310-30, set its serial in `docker/radios/n310-30.env`.

- **N310 software:** MPM 4.11.0.0-g0d7ed3b1 (MPM version 7.0), FPGA 8.2, filesystem 20260908111319.
- **Clock / PPS:** N310-10 **REF IN** and **PPS IN** are cabled to the GPS-disciplined
  OctoClock: `10 MHz OUT -> REF IN` and `1 PPS OUT -> PPS IN` (50 Ω coax). The
  OctoClock is on the lab LAN (`192.168.60.2`); its GPS antenna needs sky view and
  a GPS lock before a run.

  **"Internal" has two different meanings here.** The OctoClock runs its **own
  internal oscillator, disciplined by GPS** (the GPS antenna is on the
  OctoClock). `REF=internal` means the **N310** ignores the OctoClock and runs
  from its own onboard oscillator.

  The bench profiles currently default to `REF=internal`
  (`clock_source=internal,time_source=internal`) until the bench confirms OFH
  with the external frequency reference. `REF=external` is opt-in and selects
  **only the 10 MHz frequency reference**:
  `clock_source=external,time_source=internal` in `device_args`, with
  `clock_source: external` / `sync_source: internal` in the YAML.

  **Why not external time/PPS today:** with `time_source=external` UHD calls
  `set_time_unknown_pps()` and resets radio time at the next PPS. ProtO-RU aligns
  its slots to the host wall clock, so that reset broke the alignment and OFH
  never came up (RX_TOTAL=0, TX_TOTAL=0 for 8 minutes on the bench). A correct
  PPS mode would set radio time at the next PPS to the host's GPS-disciplined
  second, with the host clock disciplined to the same GPS; that is **not
  implemented now**. The PPS cable stays connected for that future mode.
- **Host UHD must not be used by the container.** The host has both a 4.10.0 distro package and a 4.11.0
  source build installed; the image ships its own UHD and the preflight probes **inside the container**.
- **Image:** `openru/protoru:v1-candidate-v3-uhd411` — UHD **4.11.0.0** (matching the N310 MPM), FFTW +
  ESTIMATE, `MARCH=x86-64-v3`, `OPENRU_CUDA=OFF`. Built with
  `make BENCH=1 build-protoru` (`UHD_VERSION=4.11.0.0` from `docker/bench.env`). UHD 4.11 needs
  Protobuf **and gRPC** (`libprotobuf-dev protobuf-compiler libgrpc++-dev protobuf-compiler-grpc`) in the
  builder base and `libprotobuf32 libgrpc++1.51 libabsl20220623t64` at runtime — added in
  `docker/Dockerfile.protoru`; without them `uhd_config_info`/`uhd_usrp_probe` die on a missing `.so`.
  The image also ships `uhd_ref_check`, built from `docker/bench/uhd_ref_check.cpp`.
- **Preflight** (`make bench-preflight`) verifies the container UHD version equals `4.11.0.0`, then runs
  `uhd_usrp_probe --args addr=192.168.10.2[,mgmt_addr=192.168.10.2]` **inside the container**
  (`--network host`) and **fails** on any MPM/filesystem incompatibility, on a missing serial `33A6E56`, or on
  a probe error. When `REF=external` the separate `scripts/ref_check.sh` check
  requires `ref_locked` true through the UHD API helper `uhd_ref_check`
  (`get_mboard_sensor("ref_locked").to_bool()`); the real sensor prints
  `locked` / `unlocked`. The helper's `--self-test` uses those real formats and
  runs during the image build; `tests/ref-select/test.sh` covers the overlay and
  the locked/unlocked decision without a radio. `bench-preflight` rejects
  `BENCH_SKIP_USRP=1` for external, because the lock cannot then be verified.

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

### Startup timeline and the NG Setup gate (2026-11-19)

From `~/openru-artifacts/du-slow-start-20261119/gnb-first5min.log`:

| Time | Event |
|---|---|
| `16:48:59.668` | `Built in Release mode` (first log) |
| `16:49:01.693` | last pre-DU log: `GTP-U Tunnel added. teid=0` |
| `16:51:30.592` | first DU log (PRACH/PUCCH overlap warning) |
| `16:51:30.596` | `DU created successfully` |
| `16:51:30.630` | OFH interfaces `ofh0` opened |
| `16:51:30.715` | `Starting CU-CP...` |
| `16:51:30.722` | `Rx PDU: NGSetupResponse` |

That is **151.1 s** from `Built` to NG Setup; the gap from GTP-U setup to the first DU log is **148.9 s**.
The gap is inside `create_flexible_o_du_unit` (`apps/gnb/gnb.cpp:517`), at
`flexible_o_du_factory.cpp:247` (`odu_low_factory.create`), before the first DU-high/O-DU-low log. The
`ru_txrx` thread is an idle 1 µs executor (`worker_manager.cpp:472-480`) and `ru_timing` is idle, so this is
not OFH/RF work and not an AMF wait: the CU-CP is not started until after DU construction. The exact inner
O-DU-low/upper-PHY call is not visible in the log; do not change that path blind. The operational rule is
what matters: **never judge OFH before NG Setup**.

`make BENCH=1 up STACK=e2e` now starts the core, starts the DU, polls the AMF log for `gNB-N2 accepted` (6 min
timeout, progress every 30 s), and only then starts ProtO-RU and reports the stack up. `STACK=core` does the
same. `restart-ru` waits after `RESTART_DU=1`; an RU-only restart keeps the existing NG association. The
same rule is repeated in `docs/reports/PRACH_FIRSTLIGHT.md`.

### External-reference runs (2026-11-19)

| Run | Configuration | Verdict |
|---|---|---|
| 10 MHz-only | `clock_source=external`, `time_source=internal`, OctoClock lock true | **judged too early**. RX/TX zero was sampled before the DU reached NG Setup; it is not evidence of an external-clock failure. Repeat after NG Setup. |
| clock+time external (PPS) | `clock_source=external`, `time_source=external` | **MEASURED FAIL**: waited 8 minutes, still RX_TOTAL=0 / TX_TOTAL=0. PPS time remains unsupported; see `reports/REF_EXTERNAL_10MHZ.md`. |

The bench profiles stay at `REF=internal` until the bench confirms external 10 MHz after NG Setup.

### Evidence redaction

Bench evidence collectors pipe logs through `scripts/redact_secrets.sh` (smoke-fh, smoke-core, capture,
replay, batch copies); the Open5GS entrypoint also prints `SUBSCRIBER_DB=<redacted>` instead of the
credential. Dashboard and replay redaction masks the same value before rendering. Do not copy raw
`SUBSCRIBER_DB` lines into `docs/reports/**`.

## Wiring by module pin (2x2 stage, n310-20, current since 2026-11-20)

**Label every cable by the RM520N module's own antenna pin** (printed on the module, visible with the
enclosure open), not by the enclosure's connector labels. On modem A the enclosure's "ANT0" was the
module's **ANT2** [DERIVED from the `AT+QRSRP` readings below]; modem B's enclosure labels are
[UNVERIFIED] until it is opened.

One modem (A), no antennas, all cabled. Modem B stays at `AT+CFUN=4`.

| Module pin (modem A) | Path | N310 port | Role |
|---|---|---|---|
| ANT2 (TX0 / PRX) | 4-way divider input; Out1 → 30 dB | RF0 TX/RX | DL port 0 (SSB, PDCCH, PDSCH layer 0) |
| ANT2 (same divider) | Out2 → 20 dB + 20 dB | RF0 RX2 | UL (the RU receives on RF0 RX2) |
| ANT1 (PRX MIMO) | 30 dB | RF1 TX/RX | DL port 1 (PDSCH layer 1, CSI-RS port 1) |
| ANT0, ANT3 | unconnected | – | – |

Divider Out3/Out4 capped. Expected: DL port 0 about 7 dB weaker than port 1 at the modem (divider loss).
UE at full power (p_max 10 dBm) reaches RF0 RX2 at about 10 − 7 − 40 = **−37 dBm** [DERIVED], below the
−15 dBm RX maximum [DATASHEET]. With this cabling PUSCH SNR was ~30 dB and UL MCS 27 [MEASURED 2026-11-20];
before it (TX0 cabled to RF0 TX/RX only) the RU got the uplink by leakage: SNR −1…−4 dB, UL MCS 0 [MEASURED].

### RM520N-GL antenna roles (n77/n78/n79)

From the Quectel RM520N-GL Hardware Design V1.0, Table 29 (pp. 52–53) [DATASHEET]:

| Module pin | n78 role |
|---|---|
| **ANT2** | **TX0 / PRX** — primary transmit and primary receive |
| ANT0 | TX1 / DRX — second transmit (UL MIMO), diversity receive |
| ANT1 | PRX MIMO — third receive chain |
| ANT3 | DRX MIMO — fourth receive chain |

So the uplink (one layer) leaves on **ANT2**; for 2-layer DL, cable DL port 0 to ANT2 and DL port 1 to
ANT1 (or ANT0).

### Per-antenna readings: `AT+QRSRP` / `AT+QRSRQ` / `AT+QSINR` order

These commands report four values in **receive-chain order PRX, DRX, RX2, RX3**, not ANT0..ANT3. On the
RM520N-GL in n78 that is **module ANT2, ANT0, ANT1, ANT3**:

| Position in reply | Chain | Module pin |
|---|---|---|
| 1 | PRX | ANT2 |
| 2 | DRX | ANT0 |
| 3 | RX2 (MIMO) | ANT1 |
| 4 | RX3 (MIMO) | ANT3 |

Report per-antenna values by module pin. The values are measured on the SSB, which goes out on DL port 0
only, so a chain cabled only to DL port 1 can show only leakage (e.g. −140 dBm seen on 2026-11-20) even
when port 1 works; judge port 1 from the DU's `dl_ri` and throughput instead. At idle the modem may report
only the first two chains.

## Antenna map (divider cabling, superseded 2026-11-20)

Kept for the record; it used **enclosure** labels, which on modem A did not match the module pins (above).

Two RM520N modems (A and B), four 4-way dividers. Each N310 port goes through
**30 dB** into its own divider. **Out1** to modem A through **20 dB**, **Out2**
to modem B through **20 dB**, **Out3** and **Out4** terminated in 50 Ω.
About **57 dB** per path (30 + ~6 dB of a 4-way resistive split plus excess ≈7 dB
+ 20). First test uses **modem A**; leave **modem B in airplane mode**
(`AT+CFUN=4`) so it does not camp.

| Divider | N310 port (UHD name) | Out1 | Out2 | Out3 / Out4 |
|---|---|---|---|---|
| 1 | RF0 TX/RX (`TX/RX`, DL layer 0) | modem A ANT0 | modem B ANT0 | 50 Ω |
| 2 | RF1 TX/RX (`TX/RX`, DL layer 1) | modem A ANT1 | modem B ANT1 | 50 Ω |
| 3 | RF0 RX2 (`RX2`, UL) | modem A ANT2 | modem B ANT2 | 50 Ω |
| 4 | RF1 RX2 (`RX2`, UL) | modem A ANT3 | modem B ANT3 | 50 Ω |

2×2 profiles (`bench-20mhz`, `bench-40mhz`) use **RF0 and RF1 only**. Do not set
`transmission_mode: same-port` (that would copy TX/RX onto the RX chain).

ProtO-RU applies the UHD names from the YAML `sdr.tx_antenna` / `sdr.rx_antenna`
fields in `lib/radio/uhd/radio_uhd_impl.cpp` (`set_tx_antenna` at line 351,
`set_rx_antenna` at line 414). `same_port` mode at lines 424–450 copies the
selected TX antenna onto RX. The UHD wrappers are
`lib/radio/uhd/radio_uhd_device.h` lines 199–217 (`get_rx_antennas`,
`set_rx_antenna`, `get_selected_tx_antenna`, `set_tx_antenna`).

### First-TX gains (UHD gain values, not dBm)

**Measured on the bench host** — in-container `uhd_usrp_probe` on n310-10,
channels 0 and 1, 2026-11-19 (Cursor): **TX gain range 0.0–65.0 dB**, **RX gain
range 0.0–75.0 dB**, **step 0.5 dB**. These are UHD gain settings; do not convert
them to dBm (Ettus N310 datasheet v3 footnote 3: RX/TX path gain does not
correlate with UHD gain settings —
[datasheet](https://www.ettus.com/wp-content/uploads/2019/01/USRP_N310_Datasheet_v3.pdf),
[N300/N310 KB](https://kb.ettus.com/N300/N310)). The datasheet ranges
(−30…+20 dB TX, −40…+30 dB RX) are *generic*; the probe values above are what
this unit reports and take precedence. They are recorded in `docker/bench.env`
(`BENCH_TX_GAIN_MIN/MAX`, `BENCH_RX_GAIN_MIN/MAX`, `BENCH_GAIN_STEP`).

1. Profiles start at the **minimum of the measured TX range**: `tx_gain: 0`.
2. Raise TX gain in **5 dB steps** while watching the modem's **RSRP**. Stop
   when RSRP is **−80 to −90 dBm** (at 0 dB the modem will not see the cell yet —
   raise until the SSB appears, then continue to the target). Record the final
   value in the profile and the run log.
3. The full TX range is safe at ~57 dB path loss (datasheet max **+18 dBm** at
   the port → about **−39 dBm** at the modem).
4. `rx_gain` starts at the **middle** of the measured RX range: **37.5 dB**;
   trim from the DU's uplink SNR. UE `cell_cfg.ul_common.p_max: 10` dBm → about
   **−47 dBm at RX2**, **32 dB below** the −15 dBm RX limit.
5. `make bench-preflight` parses the probe's `Gain range:` lines (falling back
   to the values above when the probe reports none) and **fails** if any
   `profiles/bench-*/protoru.yml` gain lies outside the range or off the 0.5 dB
   step.

### 2x2 stage profile (`bench-20mhz-2t2r`)

Two DL ports (RF0, RF1), **one UL port** (eAxC 0) and one PRACH port (4); `nof_antennas_dl: 2`,
`nof_antennas_ul: 1`, `pdsch.max_rank: 2`, 2-port CSI-RS every 20 ms (needed for the UE to report RI 2).
SSB, PDCCH and pre-CSI PDSCH go out on port 0 only; PDSCH uses two layers once the UE reports RI 2.
`bench-20mhz` itself stays 2 DL / 2 UL ports. `tests/profile-ports/test.sh` checks that DU and ProtO-RU
port lists and antenna counts agree in every bench profile.

```bash
make BENCH=1 up STACK=e2e PROFILE=bench-20mhz-2t2r BENCH_RADIO=n310-20 TX_GAIN=30
```

Measured 2026-11-20 on n310-20 (module-pin cabling, TX gain 30, p_max 10, rx_gain 37.5, one RM520N),
run through a gitignored overlay with the same content as this profile:
- `dl_ri` 2.0 in 119/121 and 179/181 DU UE reports under TCP DL [MEASURED].
- iperf3 TCP DL 109.1 Mbit/s (2T2R) vs 56.9 Mbit/s (1T1R, same cabling) [MEASURED].
- UL `pusch_snr_db` ~30 dB, UL MCS 27, TCP UL ~17 Mbit/s (TDD DDDSU-limited) [MEASURED].
- [UNVERIFIED] not yet run from this committed profile, nor for 60 min.

## ModemManager

ModemManager grabs the modems and rewrites their AT configuration, so it must be
**stopped before AT configuration** (`AT+CFUN=4`, band/DNN settings) and must
**not manage the modems during tests**. On the bench it is stopped but still
*enabled*, so it returns after a reboot:

```bash
sudo systemctl disable --now ModemManager    # persistent; survives reboot
systemctl is-active ModemManager             # must print "inactive"
```

`make bench-preflight` warns when ModemManager is active and warns when it is
still enabled.

`scripts/up.sh` prints the divider map on every bring-up.

### Direct cabling (superseded 2026-11-18)

Kept for the record. This is **not** what is on the bench now.

| | N310 side (all TX **and** RX) | Cabling | UE side (RM520N, n78) |
|---|---|---|---|
| Pair 1 | RF0 | → | ANT2 — TX **and** RX |
| Pair 2 | RF1 | → | ANT0 — TX **and** RX |
| Pair 3 | RF2 | → | ANT1 — **RX only** |
| Pair 4 | RF3 | → | ANT3 — **RX only** |

- N310 RF0–RF3 are all bidirectional; a 4×4 DL would use all four.
- On a single UE, only ANT2 and ANT0 transmit in n78; ANT1 and ANT3 receive only.
- 2×2 on that layout used RF0–RF1 (→ ANT2, ANT0).

## Subscribers (Open5GS)

Bench SIM credentials live only in a local, owner-only file
(`~/Desktop/OpenRU/secrets/subscribers.env`, gitignored by convention and
refused by the script if group/world-readable). `scripts/add_subscriber.sh`
provisions them (IMSI, K, OPc, optional AMF/SST/DNN) into the running core and
never prints the keys; IMSIs, DNN/SST checks and the SQN/AUTS notes are in
[`docs/BENCH_SUBSCRIBERS.md`](BENCH_SUBSCRIBERS.md).

### Modem attach (RM520N, after `make up`)

Only after `make up` has printed the NG Setup and `[rt]` lines; both modems stay at
`AT+CFUN=4` until then.

1. `AT+CFUN=1`; poll `AT+QENG="servingcell"`, `AT+QRSRP`, `AT+C5GREG?` every 30 s (up to 10 min).
2. When `+C5GREG: 0,1` (registered): **`AT+QIACT=1`**. The modems register but do **not**
   bring up the PDU session on their own (2026-11-19: no session after 3 min on either modem;
   `AT+QIACT=1` gave `10.45.0.2` / `10.45.0.3` within seconds) `[MEASURED]`.
3. `AT+QIACT?` / `AT+CGPADDR=1` for the UE address (the SMF log shows
   `UE SUPI[imsi-…] DNN[internet] IPv4[10.45.0.x]`), then `AT+QPING=1,"10.45.0.1",4,4`.
4. STOP: `AT+CFUN=4` on both modems, then `make down`.

## End-to-end stack (core + DU + RU)

```bash
make BENCH=1 up STACK=e2e PROFILE=bench-20mhz     # bench, UHD, REF=internal (default)
make BENCH=1 up STACK=e2e PROFILE=bench-20mhz REF=external  # 10 MHz only
make BENCH=1 up STACK=e2e PROFILE=bench-40mhz
make up STACK=e2e PROFILE=bench-20mhz RADIO=null  # dry run / no radio
make down
```

`REF` is UHD-only. `internal` (current default) uses the N310 onboard
oscillator for both clock and time. `external` is opt-in and uses the OctoClock
10 MHz reference only (`clock_source=external,time_source=internal`); it is
refused unless the UHD API reports `ref_locked`. Do not make external the
default until the bench confirms OFH with clock external / time internal.
`make up` checks the lock before starting containers; `restart-ru` checks it
after stopping the old RU and before recreating ProtO-RU.

Profiles used: `profiles/<profile>/du-core.yml` (NG/N2 to Open5GS **and** OFH),
`protoru.yml` (UHD) or `protoru-null.yml` (dry run). The DU and RU carriers,
PLMN 00101, TAC 7, SST 1, `ul_common.p_max: 10` and n78 628032 come from the
profiles; DNN `internet` comes from the subscriber (see
[`BENCH_SUBSCRIBERS.md`](BENCH_SUBSCRIBERS.md)).

### Thread plan and real-time health

Clean fronthaul counters do **not** prove that the lower PHY meets its deadlines. On 2026-11-19
(1T1R, n310-20, RU on `2-5`) ProtO-RU's `Real-time failure in lower PHY: Downlink data late`
ramped from ~1/s to ~240/s over two minutes while RU and DU OFH late/drop stayed 0; both modems
lost the cell and the UE contexts were released. With the cores plan the same test ran
30 minutes with 0 ping loss and 2 lower-PHY failures `[MEASURED]`.

- **Thread plan.** The profiles pin what the applications can pin (`timing_cpus`, `ru_cpus`
  round-robin, DU `expert_execution`). ProtO-RU's three OFH threads share one `ofh_cpus` mask,
  and UHD's `uhd_ctrl_ep` and other non-real-time threads inherit the container cpuset; on
  isolated CPUs the kernel never spreads them. After start, `scripts/up.sh` and
  `scripts/restart_ru.sh` run `scripts/bench_rt.sh`, which applies `BENCH_RU_THREADS` /
  `BENCH_DU_THREADS` (`docker/bench.env`) with `tools/bench/pin_threads.py`: taskset in a
  throw-away container sharing the target's PID namespace with `CAP_SYS_NICE` (no
  `docker exec`, no sudo). It prints the measured map (thread, policy, CPU, affinity, plan)
  and **fails** if a planned thread is off-plan. `make BENCH=1 pin-check` re-prints it read-only.
- **Real-time health.** `scripts/rt_watch.sh` starts one long-lived follower container
  (`openru-rtwatch`, CPUs `0-1`, `--volumes-from` the RT containers) that greps
  `proto-ru.log` and `gnb.log`; `tools/bench/rt_health.py` counts ProtO-RU
  `Downlink/Uplink data late`, `PUxCH request late`, RF `underflow/overflow/late` and the DU's
  `[OFH] [W]` real-time warnings (missed U-plane, dropped late grids/requests, timing worker
  woke up late, lost messages). `make up` settles 30 s, counts 60 s and prints **WARN** for any
  count, **FAIL** (and tears the stack down) at RU ≥ 6/min or DU ≥ 60/min
  (`RT_FAIL_RU_PER_MIN`, `RT_FAIL_DU_PER_MIN`; `RT_CHECK_SECS=0` skips). During a run:
  `make BENCH=1 rt-watch [SECS=…]` prints the counts every 10 s.
- Accepted baseline `[MEASURED, 1T1R bench-20mhz, n310-20]`: RU 0–2 per 30 min; DU 5.5–8
  warnings/min (bursty, up to ~30/min), 0 ping loss — so a normal stack reports **WARN**, not OK.
- **Do not start containers on a Docker bridge network while the stack runs** `[MEASURED]`.
  2026-11-20, stack idle (no UE), three `docker run --rm alpine true` (default bridge) 25 s
  apart: #1 → 38 missed UL symbols in one second; #2 → the DU missed **every PRACH occasion
  for ~55 s**; #3 → **every UL symbol and PRACH for ~30 s**, then recovery. ProtO-RU logged no
  lower-PHY failures and the RU OFH counters stayed clean, so only the DU-side counters show
  it. A 2026-11-19 burst (217 RF `late`, 41 DU warnings) coincided with bridge-network log
  readers. The mechanism is open. The helpers here (`pin_threads.py`, the `rt_watch.sh`
  follower) use `--network none` and showed no effect; `check_iface` joins the target's
  namespace. `restart_ru.sh`'s N310 release probe still creates a container on the
  `openru_radio` macvlan while the DU runs `[UNVERIFIED impact]`.

The DU real-time warnings did not disappear when the DU's normal threads moved off `ru_timing`'s
HT sibling (5.5/min vs 8.1/min); their cause is open.

### Bounded PRACH-delay measurement mode

The normal bench `protoru.yml` stays at `log.level: info`. The PRACH delay is
measured only in an explicitly named, bounded mode:

```bash
make BENCH=1 PROFILE=bench-20mhz prach-timing SECS=120
```

The target generates `build/local-profiles/bench-20mhz/protoru-prach-timing.yml`
(gitignored), raises only that overlay to `log.level: debug`, runs `smoke-fh` for
`SECS` (10–120 s, default 120) and collects the RU log in
`docs/reports/raw/smoke-fh-ru.log`. It is a measurement mode, **not a soak**.

The debug overlay is expensive because `RU_EMU` logs every OFH packing step:
**~29 GB/h** measured on the null-radio gate (~0.97 GB for 120 s) `[MEASURED,
null-radio; UHD expected similar per-slot, UNVERIFIED]`. The PRACH-only PHY
`window complete` lines are a small fraction (~0.09 GB/h); the volume is dominated
by RU_EMU debug. Keep the run bounded and do not enable this overlay in
`protoru.yml`.

`OCUDU_RU_TRACE` is compile-time in this tree and the RU emulator does not open a
trace file, so it is not used by this mode.

### Networking (explicit)

| Network | Driver | Members | Why |
|---|---|---|---|
| `openru_core` 10.53.1.0/24 | bridge | core 10.53.1.2, DU 10.53.1.6 | N2 (SCTP) to the AMF and N3 to the UPF; plain MTU |
| `openru_fh` 10.54.1.0/24, MTU 9000 | bridge | DU 10.54.1.10, ProtO-RU 10.54.1.20 (fixed MACs from the profiles) | Open Fronthaul eCPRI/U-plane needs jumbo frames; the fixed MACs in `du-core.yml`/`protoru.yml` live on this bridge |
| `openru_radio` 192.168.10.0/24, MTU 9000 | **macvlan** on `enp5s0f1np1` | ProtO-RU 192.168.10.3 | UHD reaches the N310 (`192.168.10.2`) at L2 with no NAT, while the RU keeps its `fh` interface; host networking would remove the `fh` bridge, and a routed bridge would add NAT/latency |

The `restart-ru` claimed-device probe uses the dedicated `BENCH_PROBE_IP`
(`192.168.10.4`) while the RU is stopped, so Docker never auto-assigns `.2`
(the N310) on the macvlan.

No container uses host networking. **Interface names are pinned** with compose
`interface_name` — `ofh0` (fh), `n2` (core), `radio0` (macvlan) — and the
profiles reference `ofh0` in `ru_ofh.cells[].network_interface`; nothing depends
on Docker's network-attachment order (Docker 29 does not guarantee `eth0`/`eth1`
ordering for multi-network containers). `scripts/up.sh` verifies inside each
container (via a **throw-away container sharing the target's network namespace**,
never `docker exec` — on first light an exec into the DU hung ~7 min because the
gnb fully occupies the isolated cpuset 6-11 and the exec is scheduled there)
that `ofh0` carries the fh subnet and `n2` the core subnet (and
`radio0` the radio subnet when UHD is used) and **fails before starting the
radio** if a name is missing or on the wrong subnet, tearing the stack down.
CPU pinning comes from `docker/bench.env` (cores plan, see [Core map](#core-map-bench-map-locked)):
ProtO-RU `2-7` + E-core `12`, DU `8-11` + E-core `13`, core on `CORE_CPUSET` `12-19`,
housekeeping/IRQs on `0-1,12-19`.

The Open5GS database is on a **named volume** (`openru_core-db`, mounted at
`/data/db` — the path the entrypoint's `mongod` actually uses, not
`/var/lib/mongodb` from `mongod.conf`), so bench subscribers survive
`make down`/`make up`; reset with `docker volume rm openru_core-db`. Provisioning
stays explicit (`scripts/add_subscriber.sh`, idempotent upsert) rather than
re-running it from `up.sh`: no key material is needed to start the stack, and a
volume is the normal Docker persistence mechanism.

### Dry run (GPU server, null radio in place of UHD) — 2026-11-19

`core + DU(bench-20mhz/du-core.yml) + ProtO-RU(bench-20mhz/protoru-null.yml)`:
NG Setup Response and `Connected to AMF` (PLMN 00101), cell `pci=1, 20 MHz,
2T2R, dl_arfcn=628032 (n78)`, 60 s window with **zero late/drop** and slot
indication advancing; rates DL U 6774.7/s, DL C 512.5/s, UL C 1800.2/s
(−0.15 / −0.18 / +0.01 % vs the golden-derived expected rates); clean
`make down`. Result JSON:
`docs/reports/runs/bench-e2e/20261119T021918Z-bench-20mhz-null.json`.

Also verified in the same dry run: an **O-RU-only restart** keeps the DU up, the
cell active and the NG connection established, and OFH KPIs resume (no DU
restart needed).

Re-run after the interface-name pinning (2026-11-19, second dry run):
`ofh0`/`n2`/`radio0` present in both containers (DU `ofh0 10.54.1.10`,
`n2 10.53.1.6`; RU `ofh0 10.54.1.20`), NG Setup + cell up, 60 s zero late/drop,
rates 6775.4/512.5/1800.2/s (−0.14/−0.17/+0.01 %); result JSON
`docs/reports/runs/bench-e2e/20261119T023953Z-bench-20mhz-null.json`.

### TX gain step-up (YAML only, RU restart)

`tx_gain` is read from the YAML at ProtO-RU start — changing it requires a
ProtO-RU restart. Use:

```bash
make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=5
make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=5 REF=external  # 10 MHz only
# optional, if the DU must restart too: RESTART_DU=1
```

The target copies the profile to gitignored `build/local-profiles/<profile>/`,
edits `tx_gain` **there** (the committed profile is never modified), recreates
only `protoru` (plus `du` with `RESTART_DU=1`) and keeps the rest of the stack.
The overlay path printed by `scripts/local_profile.sh` is **absolute**, so
compose does not resolve it relative to the compose file. Add `REF=external`
to the same command for the 10 MHz-only external reference; the default is
internal. Raise in 5 dB steps to RSRP −80…−90 dBm as described above.

## Disk space (bench host)

Per release, on the bench host:

| Item | Size |
|---|---|
| Release tarballs (`openru_protoru_bench-<sha>.tar.gz` + `openru_core_…`) | **≈ 2.9 GB** (artifacts location, e.g. `~/openru-artifacts`) |
| Loaded images in Docker's data-root (protoru 4.97 GB + core 2.29 GB) | **≈ 7.3 GB** |
| Peak during `docker load` (extraction temp alongside the images) | **≈ 8 GB free** |

So keep **≥ 20 GB free in Docker's data-root** (two releases' worth of headroom)
and **≥ 5 GB** on the artifacts filesystem. `make bench-preflight` fails early
with a *"root filesystem full"* message when `/` has less than **5 GiB** free —
a full root filesystem also breaks `lscpu`/cpufreq reads (this happened on the
bench: P/E classification returned "no cpufreq/lscpu max frequency").

### Proposal: move Docker's data-root to `/home` (not applied)

The bench root filesystem is small; `/home` has the space. On the bench host
(root), **only after draining containers**:

```bash
sudo systemctl stop docker docker.socket
sudo mkdir -p /home/docker
sudo rsync -aHAX --numeric-ids /var/lib/docker/ /home/docker/
printf '%s\n' '{"data-root": "/home/docker"}' | sudo tee /etc/docker/daemon.json
sudo systemctl start docker
docker info --format '{{.DockerRootDir}}'          # expect /home/docker
docker image ls | grep openru || true             # images are preserved by the rsync
```

If the images are not rsynced, they must be re-loaded
(`scripts/bench_load.sh <release-dir>`). Verify with `df -h /home` before and
after; keep the artifacts directory on the same filesystem if possible so the
`docker load` peak does not cross filesystems.

`bench_load.sh` writes its observed image set with `flush()`+`fsync()` before
`load_verify` reads it (a plain write left an empty file on the bench).

## Release → ship → load → preflight

Bench image artifacts live **only on this server** (never in git).

```bash
# 1. release (refuses on a dirty tree or unpushed HEAD; builds from HEAD)
make bench-release
#    -> openru/protoru:bench-<short-sha> + bench-latest; openru/core:bench-<short-sha> + bench-latest
#    -> hard arch check: builder log -DMARCH and image label org.openru.march must both be
#       x86-64-v3 (mismatch removes the bench tags and stops before smoke/export)
#    -> smoke: container uhd_config_info == 4.11.0.0; replay-golden baseline PASS (null radio)
#    -> <artifact-root>/bench-<short-sha>/{*.tar.gz,RELEASE.json,SHA256SUMS}
#       (<artifact-root> is OPENRU_ARTIFACTS_DIR in gitignored docker/bench.local.env)
#    -> keeps the last 5 releases (BENCH_RELEASE_KEEP); never deletes the in-use tag

# 2. ship (rsync over SSH; prints manual steps when unreachable)
make bench-ship                     # HOST from docker/bench.local.env, or HOST=<bench-host>

# 3. load on the bench host (verifies SHA256SUMS, loads, checks IDs vs RELEASE.json)
scripts/bench_load.sh ~/openru-artifacts/bench-<short-sha>

# 4. run
OPENRU_TAG=bench-latest make BENCH=1 bench-preflight
OPENRU_TAG=bench-latest BENCH=1 PROFILE=bench-20mhz PROTORU_PROFILE=uhd make smoke-fh
```

`RELEASE.json` records: git commit (+ branch, short sha), submodule commit, build date/host,
UHD/MARCH/FFTW/CUDA configuration, the `march_check` values (builder log + image label),
smoke results, every image (`repo_tag`, image ID,
`RepoDigests`, size), and every tarball (bytes, SHA-256); `SHA256SUMS` covers the tarballs.

`bench_load.sh` verifies the tarball SHA-256, then the **content**: the config digest read from the tarball
(`manifest.json` or OCI `index.json`) plus the provenance labels recorded in RELEASE.json. Docker 29 with the
containerd image store assigns different image IDs on `docker load` than the build host had, so loaded IDs are
**recorded in `LOAD-REPORT.json` but not required to match**; identity is the config digest. It prints the release
commit and tags `bench-latest` locally. `bench-preflight`
then compares the image's `org.openru.git.commit` label with the checked-out repo HEAD and
**warns** when they differ (an older release is a supported state; the warning makes it visible).

First end-to-end check (2026-11-18, this server): `make bench-release` produced `bench-a8998ce`
(commit `a8998ce`, submodule `d8d2097894`; 2.1 GB protoru + 0.79 GB core tarballs, SHA-256 in
`SHA256SUMS`); the tags were removed and `scripts/bench_load.sh` re-loaded the release with matching
image IDs (`c72090b0365e`, `d0b9d41bde6d`), and `bench-preflight` reported `ok container UHD 4.11.0.0`
and `ok image commit matches repo HEAD`. The refusal paths were exercised too (dirty tree, branch with no
`origin/<branch>`), and `make bench-ship` printed the manual copy steps when the bench host was not
reachable in SSH batch mode from the build server.

`docker/bench.env` uses `OPENRU_TAG=bench-latest`; pin a specific release with
`OPENRU_TAG=bench-<short-sha>` when a campaign must stay on one image. The bench SSH target
lives in gitignored `docker/bench.local.env` (see `docker/bench.local.env.example`).
`make bench-ship` falls back to printing the manual `rsync`/`tar | ssh` copy commands when
batch SSH is unavailable.

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
