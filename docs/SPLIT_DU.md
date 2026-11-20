# Two-host split: DU on the core host, ProtO-RU on the bench host

The bench host runs only ProtO-RU (and the radio). The OCUDU DU and Open5GS run on the "core" host.
The fronthaul crosses the direct fibre between the two hosts on **macvlans** (never a Docker bridge),
MTU 9000. Both sides keep the single-host addresses and MACs (DU `10.54.1.10` / `02:00:00:00:00:10`,
RU `10.54.1.20` / `02:00:00:00:00:20`).

| Piece | File |
|---|---|
| fh network as macvlan on `SPLIT_FH_IFACE`, MTU 9000 | `docker/compose.split.yml` |
| core host: NIC, cpusets, DU thread plan | `docker/split-core.env` |
| bench host: NIC (RU cpusets/thread plan from `docker/bench.env`) | `docker/split-ran.env` |
| DU with core-host pins (2 DL / 2 UL ports) | `profiles/bench-split-20mhz` |
| DU with core-host pins, 2T2R DL / 1 UL port (Phase D) | `profiles/bench-split-20mhz-2t2r` |
| bring-up per host | `scripts/split.sh <core|ran> <up|check|down>` |
| config test (no hardware) | `tests/split/test.sh` |

## Core host CPU plan

i9-10900X, 10 cores / 20 threads (HT siblings `n` and `n+10`), `isolcpus=6-9,16-19`,
`irqaffinity=0-5,10-15`, `multi-user.target`. One busy DU thread per physical core; the HT siblings
16–19 stay idle.

| CPU | Use |
|---|---|
| 6 | DU `ru_timing` |
| 7 | DU `ru_txrx_#0` |
| 8 | DU `main_pool#0` |
| 9, 16–19 | idle (isolated) |
| 5 | DU non-real-time threads (`*=5`) |
| 0–4, 10–15 | Open5GS (`CORE_CPUSET`), host, IRQs; rt follower on 0–1 |

## Time

Each side aligns its slots to its own system clock, so the core host's clock follows the bench host's
over PTP on the same fibre:

- bench host: `ptp4l` master, **software timestamps** (the X710 port gives no RX hardware timestamps),
  `serverOnly 1`, L2, E2E, `logSyncInterval -3`; system clock = reference (NTP on).
- core host: E810 `ptp4l` `clientOnly 1` with hardware timestamps, then
  `phc2sys -s ran_link -c CLOCK_REALTIME -w -R 8 -u 8`; NTP off.
- Units `openru-ptp4l` (both) and `openru-phc2sys` (core). `scripts/split.sh … up` refuses on core if
  `openru-phc2sys` is not active and on the bench host if `openru-ptp4l` is not active.

Measured 2026-11-19 23:38 – 2026-11-20 00:38 (America/New_York), core host journal [MEASURED]:

| Window | ptp4l offset rms / max | phc2sys rms / max |
|---|---|---|
| 60 min overall | 2529 ns / 15949 ns | 1571 ns / 8763 ns |
| bench host idle (5-min bins) | 254–353 ns / 4.1–6.7 µs | 173–342 ns / 0.7–1.8 µs |
| single-host stack running on the bench host | 2.2–3.7 µs / 13–16 µs | 1.7–2.3 µs / 6.3–8.8 µs |

Software timestamping on the bench host is about 10x worse while the bench host is loaded. That is well
inside the OFH windows here (T1a/Ta4 up to 5000 µs), but it is the reason to move PTP to genuine Intel
NICs with hardware timestamps on both ends (later work).

## Phase C: null radio (no RF)

```bash
# core host (first): Open5GS, wait healthy, DU, NG Setup, DU thread plan
scripts/split.sh core up
# bench host: ProtO-RU with the null radio, RU thread plan
RADIO=null scripts/split.sh ran up
# both hosts at the same time, after both are up: rt follower for the local side, settle 120 s,
# then 60 s windows until two in a row pass (at most 5)
scripts/split.sh ran check 60
scripts/split.sh core check 60
# down: bench host first, then core
scripts/split.sh ran down
scripts/split.sh core down
```

### Phase C result (2026-11-20 00:49–01:20 America/New_York; 05:49–06:20 UTC)

`bench-split-20mhz`, null radio, no UE. Both hosts down afterwards (0 containers, 0 networks).

| Item | Value |
|---|---|
| NG Setup | 30 s after DU start [MEASURED] |
| Thread plans | DU 6 threads on plan (core host), RU 11 threads on plan (bench host) [MEASURED] |
| First 60 s check (after 30 s settle) | RU 0 failures; DU 1 (timing late) → WARN [MEASURED] |
| RU OFH receive (DU→RU over the fibre), 30 min | 16.82 M packets: late 362 (2.2e-5), early 154, seq err 118 U/C + 55 PRACH, corrupt 0, error drop 0 [MEASURED] |
| RU OFH late per minute after start | 2–64 of ~545 k [MEASURED] |
| RU lower-PHY real-time failures | 7558 in the start-up minute (05:49 UTC, before the DU link), then 3 in 30 min [MEASURED] |
| RU timing worker late | 159 in the start-up minute, then 3–23/min [MEASURED] |
| DU OFH warnings (core host), 30 min | 77 = 2.6/min: missed UL 58 symbols (7 slots), timing late 17, missed PRACH 1; worst minute 20 (06:09 UTC) [MEASURED] |
| DU timing late coinciding with an RU timing late (±2 ms) | 0/18 (single host: 82/85, 117/123, 15/15) [MEASURED] |
| PTP during the run (core host) | ptp4l rms 2.6 µs, max 17.1 µs; phc2sys rms 1.1 µs, max 6.8 µs [MEASURED] |

Compared with single host (DU on the bench host, UHD radio, 2026-11-20 runs): DU steady state
1–3/min there vs 2.6/min here, and no start-up burst here. On the single host, DU timing-late events
coincide with RU timing-late events (host-wide stalls on the bench host); on the core host they do
not. [UNVERIFIED] not like-for-like: null radio and no UE here, UHD and UE there.
RU OFH late ratio 2.2e-5 vs the single-host M1 CPU+null baseline 7.094e-6 (different host; macvlan
over fibre instead of a bridge) [DERIVED].

## Phase D: real radio on the split (transmits; needs the human's go)

Prerequisites:
1. Subscribers in Open5GS on the core host (provisioned 2026-11-20; the `openru_core-db` volume keeps
   them and `split.sh core down` does not remove it). To provision again (human step: the subscribers
   file is a secret, and agents do not copy it):
   ```bash
   # core host, in the deployed split checkout; same file format as on the bench host.
   # A fresh clone needs the submodule first (open5gs.env lives in external/proto-ru):
   git submodule update --init
   install -d -m 700 ~/OpenRU/secrets
   install -m 600 /dev/null ~/OpenRU/secrets/subscribers.env   # then copy the content in; mode stays 600
   scripts/split.sh core up --core-only                         # Open5GS only: no DU, no fronthaul macvlan
   BENCH=1 scripts/add_subscriber.sh --dry-run ~/OpenRU/secrets/subscribers.env   # validates, prints IMSIs only
   BENCH=1 scripts/add_subscriber.sh ~/OpenRU/secrets/subscribers.env
   scripts/split.sh core down
   ```
2. Cabling as in `docs/BENCH_BUNDLE.md` "Wiring by module pin" (n310-20, modem A, no antennas). Modem B
   disconnected (one-modem stage) or at `AT+CFUN=4`.
3. Both hosts down (`docker ps -a --filter name=openru` empty on both), PTP units active. On the core
   host, `journalctl -u openru-ptp4l --since -2min` shows rms below 1 µs.
4. `make BENCH=1 bench-preflight BENCH_RADIO=n310-20` passes on the bench host (UHD 4.11, serial).

Procedure (limits: TX gain 30, p_max 10, rx_gain 37.5; the script refuses TX gain > 30):

```bash
# 1. core host
PROFILE=bench-split-20mhz-2t2r scripts/split.sh core up        # expect NG Setup ~30 s, "pin: OK"
# 2. bench host (starts transmitting once ProtO-RU prints "Running.")
RF_SPLIT_OK=1 RADIO=uhd BENCH_RADIO=n310-20 TX_GAIN=30 PROFILE=bench-split-20mhz-2t2r scripts/split.sh ran up
# 3. both hosts at the same time: real-time gate (settle 120 s, two passing 60 s windows in a row;
#    RU below 6/min, DU below 60/min)
scripts/split.sh ran check      # bench host
scripts/split.sh core check     # core host
# 4. core host: iperf3 server inside the Open5GS container (UPF is on the core host now)
docker exec -d openru-core-1 iperf3 -s -B 10.45.0.1 -D
# 5. bench host: attach modem A and bring up its host data path
python3 tools/bench/modem_attach.py up <modem-A-serial>         # prints IF=… UE=…
iperf3 -c 10.45.0.1 -B <UE> -R -t 300                            # DL, then:
iperf3 -c 10.45.0.1 -B <UE> -t 60                                # UL
```

Compare with the single-host 2T2R run (2026-11-20, TCP DL 109.1 Mbit/s): `dl_ri` (DU log on the core
host), DL/UL throughput, `pusch_snr_db`, DU warnings/min (`scripts/rt_watch.sh watch` on the core host),
RU late counts (bench host), PTP offset during the run.

STOP on any of: UHD/ProtO-RU error, container restart, RU RF overflow/underflow, lower-PHY late above
6/min, DU warnings above 60/min, modem detached more than 2 min, `/` below 3 GB on either host.

STOP / end, in this order:
```bash
python3 tools/bench/modem_attach.py down <modem-A-serial>       # bench host: host path down, CFUN=4
scripts/split.sh ran down                                         # bench host: TX off first
scripts/split.sh core down                                        # core host
docker ps -a --filter name=openru ; docker network ls --filter name=openru   # empty on both hosts
```

Nothing persistent changes on either host besides Docker volumes (logs, Open5GS DB on the core host).
