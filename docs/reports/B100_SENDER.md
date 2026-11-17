# b100 replay sender measurement (2026-11-17)

## Diagnosis (step 1)

The b100 replay failures are case **(a)**: the RU **discards late downlink resource grids**. During a failing
800-slot dump the null-radio RU logged **1246 `Downlink data late`** and 416 `PUxCH request late` from
`lib/ru/sdr/ru_lower_phy_error_adapter.h:26`; the dump contained 1/103 expected DL slots. The RU's O-RAN reception
window drop is correct. No frame was written into a slot other than its U-plane header slot (no wrong-slot bug).

## Sender measurements (step 3)

All runs on `openru_fh` (MTU 9000), DL-only frames (55,157 of 127,298), b100 pcap span **6.085 s**.

| sender | p50 | p90 | p99 | max | >200 us | >1 ms | notes |
|---|---:|---:|---:|---:|---:|---:|---|
| tcpreplay 4.4.4 `--preload-pcap --multiplier=1.0` | – | – | – | – | – | – | 55,157 frames in **6.25 s** vs 6.085 s (165 ms, 2.7% drift); no GPS anchor / U-plane delay |
| committed Python (`fh_replay.py`, streaming dpkt) | 311.2 us | 798.3 us | 1506.7 us | 1920.2 us | 35,378 | 2,892 | parse inside the real-time loop |
| C `fh_replay_c` (pre-built frames, busy-wait), no RU | 3.1 us | 3.4 us | 7.0 us | 2129.8 us | 12 | 12 | host/kernel preemption |
| C `fh_replay_c`, full b100 dump (generic m2 RU) | 5.2 us | 7.4 us | 11.9 us | 2724.7 us | 60 | 36 | RU still logs **738 Downlink data late**; dump 90/103 |

The C sender (`tools/fh_replay/fh_replay_c.c`, `OPENRU_REPLAY_SENDER=c`) meets the C-plane→U-plane margin
(p99 12 us << 200 us). The remaining 1–3 ms outliers are host/kernel preemption: `quiet_host.py` is valid
(offenders=0) but the host has **no isolcpus/nohz_full** and `sched_rt_runtime_us=950000`.

## Step 4 status: blocked

`make replay-golden` for b100 cannot meet "two cold replays, 0 differing samples, 0 late U-plane frames at the RU"
with the **generic-DFT** image: even with the C sender at p99 12 us the RU reports 738 late DL grids, because the
generic DFT + the 1.9 GB/s dump exceed the 100 MHz real-time budget on the current cores. The sender is not the
bottleneck. Options (pending decision):

1. Generate the b100 golden with `openru/protoru:m2-golden-fftw-estimate`, record its tag in
   `testdata/golden/b100/MANIFEST.json`, and make `replay-golden` use each golden's MANIFEST tag (baseline/b40 stay
   generic). The FFTW+ESTIMATE plan is deterministic and the earlier b100 live smoke had 0 late.
2. Isolate host cores (`isolcpus`/`nohz_full`) and keep the generic image; the host currently has neither.
3. Keep b100 deferred and ship the baseline+b40 goldens for v1.

Reproduce the measurements:

```bash
# C sender, standalone (no RU)
OPENRU_REPLAY_SENDER=c OPENRU_REPLAY_CPUSET=52 OPENRU_REPLAY_UPLANE_DELAY_US=0 \
  OPENRU_WINDOW_JSON=$PWD/testdata/pcap/b100.window.json \
  scripts/replay_iq_dump.sh b100 testdata/pcap/b100.pcapng /tmp/b100-c
# send_error_us line in the replay log; RU late counts in /tmp/b100-c/ru.log
```
