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

## Antenna map (divider cabling, on the bench now)

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

## End-to-end stack (core + DU + RU)

```bash
make BENCH=1 up STACK=e2e PROFILE=bench-20mhz     # bench, UHD radio
make BENCH=1 up STACK=e2e PROFILE=bench-40mhz
make up STACK=e2e PROFILE=bench-20mhz RADIO=null  # dry run / no radio
make down
```

Profiles used: `profiles/<profile>/du-core.yml` (NG/N2 to Open5GS **and** OFH),
`protoru.yml` (UHD) or `protoru-null.yml` (dry run). The DU and RU carriers,
PLMN 00101, TAC 7, SST 1, `ul_common.p_max: 10` and n78 628032 come from the
profiles; DNN `internet` comes from the subscriber (see
[`BENCH_SUBSCRIBERS.md`](BENCH_SUBSCRIBERS.md)).

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
CPU pinning comes from `docker/bench.env`: ProtO-RU `2-5`, DU `6-11`, core on
`CORE_CPUSET` `12-19`, housekeeping/IRQs on `0-1,12-19`.

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
# optional, if the DU must restart too: RESTART_DU=1
```

The target copies the profile to gitignored `build/local-profiles/<profile>/`,
edits `tx_gain` **there** (the committed profile is never modified), recreates
only `protoru` (plus `du` with `RESTART_DU=1`) and keeps the rest of the stack.
Raise in 5 dB steps to RSRP −80…−90 dBm as described above.

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
