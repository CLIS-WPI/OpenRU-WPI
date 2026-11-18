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

## Host-latency finding (step 4 re-run)

The accurate C sender exposed a host problem that the slow Python sender had masked. With `OPENRU_REPLAY_SENDER=c`
the **baseline** two cold replays differed at **2 DU slots** (port0 28.0 and 140.0); with the committed Python sender
the same baseline pcap gives two clean replays (0 differing) because its parse lag is deterministic — it is
reproducible but late, not the live timing. `quiet_host.py` reports `valid: true` (average CPU), but the host has
**no `isolcpus`/`nohz_full`** and `sched_rt_runtime_us=950000`, so a fast sender sees random 1–3 ms preemptions
(12/55,157 frames standalone, 36/55,157 with the RU). Those preemptions are what make the two runs differ.

Consequence: on this host, **0-differing** is achievable only with the deterministic (slow) Python sender for the
low-rate profiles. The b100 requirement (0 differing **and** 0 late DL grids) needs both an isolated core (to remove
the random preemption) and a fast DFT (the FFTW image removes the RU backpressure). The host currently provides
neither.

State after this step:
- `testdata/golden/baseline` regenerated from the new MTU-9000 capture with the Python sender: 513/513 expected
  slots, two cold replays 0 differing, MANIFEST `image=m2`, `sender=python`.
- `testdata/golden/b40` unchanged (image m2, sender python; pcap and golden consistent).
- `testdata/golden/b100` remains `status: deferred`.
- `make replay-golden` reads each golden's `image`/`sender` from its MANIFEST and skips deferred profiles.

## b40 golden reproducibility (v1-candidate)

The b40 golden is the pair of two clean cold replays with `v1-candidate` (check 256/256, 0 differing). A fresh
`make replay-golden` on this host occasionally starts the dump ~194 slots off (the Python sender's pcap-head/parse in
the first seconds), reported as 194 missing/extra and 150 UL-slot leaks; rerunning the cold pair yields two clean runs
again. The stored golden is the clean pair; the fresh-run flake is recorded here, not hidden. This is the same
host-latency limitation, independent of the image.

## b40 fresh-replay +1 slot: root cause and host limit (2026-11-17)

**Mechanism (evidence, item 2a).** The failing Python b40 replay starts the dump at the correct DU slot
(`first_du=146.0`, `dump_start_du_slot=2920`; the check's start test passes), but its first **non-empty** slot is
`146.1` (window offset **+1**) while the pcap window expects offset 0; the check reports 194 missing/extra because
the whole expected set is shifted by exactly one slot (`expected ∩ (expected+1)` differs by 194 of 256), not because
the dump started 194 slots late.

Two Python-sender effects cause it:
1. `_align_target` rounded the 2235 us C-plane lead to 4 whole slots (2000 us). That puts the **next** C-plane
   235 us earlier than the DU's T1a, and
2. the Python per-frame send jitter (p99 ~710 us at b40) pushes the tail of the U-plane burst across that next
   C-plane; the RU then labels the tail U-plane into the next slot (+1).

The baseline's +/-11-slot tolerance hides the same +1; b40's +/-6 exposes it. The C sender uses the exact lead and
its first non-empty slot is `146.0` (offset 0; check PASS). Its 6 differing slots vs the stored Python golden are the
exact-vs-quantized C-plane/U-plane timing, not a slot shift.

**Fix at the cause (item 2b).** `fh_replay.py:_align_target` no longer rounds the lead: it returns the exact C-plane
deadline (`air - lead_us`, with a 50 ms startup margin) and the caller offsets the first frame from it. The C sender
already did this. The b40 Python path now starts at offset 0 (with the residual jitter still possible on a loaded
host). Goldens were **not** regenerated: the C sender's two cold baseline replays differ at **59** DU slots and b40
at **26** send events >1 ms (p99 232 us, max 1.5 ms) on this host, so the "two cold, 0 differing" bar is not met.

**Host limit (item 2c).** `quiet_host.py` reports no foreign offenders, but the replay core still takes
softirq/scheduler preemptions; the residual is the host, not the alignment or the sender code. **The requested 5x0
consecutive PASS for baseline and b40 is not achieved on this shared host**; it needs the bench host's isolated
`isolcpus`/`nohz_full`/`rcu_nocbs` cores (`docs/BENCH_BUNDLE.md`, `docs/OPEN_QUESTIONS.md`). No tolerance was widened
and no run was retried to green. The stored baseline/b40 goldens remain the previously validated Python two-cold
pairs; no new golden was installed.
