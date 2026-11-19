# PRACH DU receive-window deadline — progress

Work in progress. This file is the resume point if the session ends early.

## Goal

The RU can only build the PRACH U-plane reply after the 12-symbol PRACH occasion is captured (~3 ms after the
C-plane on the null radio, ~8.8 ms on the N310/UHD). The DU closes the PRACH receive window at the next slot's
symbol 0 (+0.5 ms), so the reply is dropped. Add a DU-side `ru_ofh.prach_rx_extra_slots` option that delays only the
PRACH pop, validate it against the PRACH context ring, gate it on this server with the null radio, and ship it in the
bench profiles.

Evidence tags follow `docs/BRIEF_PHASE1.md`; every number below is `[MEASURED]`, `[DERIVED]`, `[ASSUMPTION]` or
`[UNVERIFIED]`.

## Where the work lives

- ProtO-RU fork: `CLIS-WPI/ProtO-RU`, branch `feat/prach-rx-extra-slots`, based on `9da3456aed` (the head of PR #1,
  which contains both PRACH tracing commits).
- OpenRU-WPI: branch `feat/prach-rx-extra-slots` (based on `origin/main` after #25 and #26), submodule bump +
  bench profiles + this report.

## Status

| # | Item | Status |
|---|------|--------|
| 1 | Config path `ru_ofh.prach_rx_extra_slots` -> sector -> receiver -> closed window | implemented in fork (`774837ebc4`) |
| 2 | Ring validation (`1 + extra <= repo_size - 2`) with `report_error` | implemented in fork (`774837ebc4`) |
| 3 | 600 s null-radio gate on this server; record value + RU reply delay | recorded: clean windows 0/0 at extra=0; 600 s INVALID (host-stall bursts); server value 0 |
| 4 | Bench profiles: server value + margin, `[UNVERIFIED]` on UHD, RU traces on | done: `prach_rx_extra_slots: 20`, UHD `log.level: debug` |
| 5 | OpenRU-WPI PR with submodule bump, profiles and gate evidence | pending fork PR #2 merge; profiles/evidence committed on `feat/prach-rx-extra-slots` |
| 6 | Tag `v0.1.6-bench` + `make bench-release` (after human merge) | pending |

## Item 1-2 design (fork)

- CLI11: `--prach_rx_extra_slots` (unsigned, default `0`) in
  `apps/units/flexible_o_du/split_7_2/helpers/ru_ofh_config_cli11_schema.cpp`.
- YAML writer emits the same key in `ru_ofh.cells[]`.
- Translator copies it to `ofh::sector_configuration::prach_rx_extra_slots`.
- `ofh_factories.cpp` copies it to `ofh::receiver_config`; `ofh_receiver_impl.cpp` copies it to
  `closed_rx_window_handler_config`.
- `ofh_closed_rx_window_handler.cpp` pops `symbol_point.get_slot() - 1 - prach_rx_extra_slots` at
  `symbol_index == 0`; the uplink grid window is untouched.
- Ring validation in the translator:
  `repository_size = ofh::calculate_repository_size(scs, max_processing_delay_slots * 4)`.
  At 30 kHz with `max_proc_delay=10` this is **40** slots `[DERIVED]`; the rule is
  `1 + extra <= repository_size - 2`, i.e. up to **37** extra slots, and a larger value fails with
  `report_error` naming the value, the limit and the ring size. The ring is not grown.

## Gate prerequisite found: RU emulator wire-SFN wrap (fork `de42c330f2`)

Screening at 30 s exposed a second, unrelated miss: exactly one PRACH occasion every 2.56 s, always at wire slot
`<sfn>.19`, and with no PRACH U-plane reply sent by the RU for it. The cause is the RU emulator's PRACH lookback:
the O-DU wire slots wrap at 256 frames, but `slot_point` subtraction wraps at the 1024-frame hyperframe, so
`ofh_slot - lookback` turns wire slot `0.1` into `1023.19` at every 256-frame wrap and the request recorded for wire
slot `255.19` is never matched. No value of `prach_rx_extra_slots` can fix that (the DU context for `255.19` never
receives data), so the fork now subtracts the lookback modulo the wire period
(`ru_emulator_tti_orchestrator.cpp`, test added). This is a gate prerequisite, not part of the DU deadline change.

## Item 3 gate (in progress)

Planned: null-radio e2e stack, 600 s, quiet host, `/tmp/openru-measure.lock` held. Start from
`prach_rx_extra_slots=0` and increase until 600 s shows 0 missed PRACH contexts and 0
`sequence identifier from the past` drops for eAxC 4/5. Expected 6-8 slots; the smallest passing value is the one
that goes into the profiles. Record the RU reply delay from the PRACH traces.

## Item 4 bench profiles (pending)

Add the server value plus a documented margin to `profiles/bench-20mhz` and `profiles/bench-40mhz`
(`du-core.yml` and `du-fh.yml`), set `log.level: debug` in the UHD `protoru.yml` so the PRACH timestamps are
collected, and mark the UHD numbers `[UNVERIFIED]`. The first-light UHD delay of 8.8 ms (~18 slots at 30 kHz
`[DERIVED]`) must fit inside the configured limit.

## UHD ~6 ms (proposal only, not implemented)

To be filled before the PR: where the extra ~6 ms between null radio and UHD could come from (RX buffer policy,
UHD recv frame size, RU cpuset 2-5 shared with UHD threads) and how the bench run should measure it.

## Item 3 gate data (this server, null radio)

Image `openru/protoru:prach-extra` (`de42c330f2`), `bench-20mhz/du-core.yml` + `protoru-null.yml`, e2e
core+DU+RU, 600 s, `/tmp/openru-measure.lock` held, `quiet_host.py` valid. Gate window excludes the shutdown drain.

| extra | 600 s window | missed PRACH | seq-id-from-past (all / eAxC 4-5) | RU window complete |
|---|---|---|---|---|
| 0 | 05:31:33–05:41:33Z | 11 | 678 / 80 | 59,996 |

All 11 misses and 670 of the 678 past drops fall in **two host-stall bursts** (`05:32:11`, ~592 drops;
`05:36:38`, ~82 drops). The drops cover eAxC 0/1 as well as 4/5, so they are DU OFH receive stalls, not PRACH
lateness. The 11 missed PRACH contexts are 10 + 1 frames inside those two bursts; the ring limit (37 extra slots
= 18.5 ms) cannot cover a ~120 ms burst. In clean 30 s and 60 s windows the same image gives **0 missed / 0 past**
at `extra=0`. The periodic 2.56 s misses at wire SFN 255 are gone after `de42c330f2`.

RU reply delay (10 s debug run, `extra=0`): `PRACH window complete` -> `PRACH U-plane send` median **0.040 ms**,
p95 **0.056 ms**, max **0.152 ms** `[MEASURED]`. The null radio is already inside the default next-slot window, so the
smallest extra value that is *needed* on the null path is **0**; the UHD path is why the bench profile carries a
non-zero value. This is reported rather than forcing a non-zero server value.

## Item 4 bench profiles

- `profiles/bench-20mhz` and `profiles/bench-40mhz`: `prach_rx_extra_slots: 20` in `du-core.yml` and `du-fh.yml`.
  The first-light UHD delay is 8.8 ms ≈ **17.6 slots** at 30 kHz `[DERIVED]`; 20 leaves ~2 slots of margin and is
  below the ring limit of 37. The UHD number is `[UNVERIFIED]` on this server.
- UHD `protoru.yml`: `log.level: debug` so the PRACH request/window/send timestamps are collected during the bench
  run. (The `ru_tracer` instant events are compile-time `OCUDU_RU_TRACE`; the runtime-configurable path is the
  debug log. State this in the report.)

## Resume point

- Fork branch `feat/prach-rx-extra-slots` @ `de42c330f2`; fork PR **#2**
  (`feat(ofh): add ru_ofh.prach_rx_extra_slots and fix the RU PRACH lookback wrap`), base `feat/null-radio`.
  Fork PR #1 is still open on GitHub even though the task said it was merged; PR #2 is stacked on it and its
  description says to merge #1 first.
- OpenRU-WPI branch `feat/prach-rx-extra-slots` contains this report, the bench profiles and
  `docs/reports/runs/prach-gate/*.json`. The submodule pointer is **not** bumped yet.
- Next: human merges fork PR #2, then bump `PROTORU_GIT_COMMIT` in `docker/versions.env` to that merge commit,
  open the OpenRU-WPI PR (base `main`), and after that merge tag `v0.1.6-bench` and run `make bench-release`.
- Gate caveat: this GPU server is not a quiet real-time host. Two 600 s null-radio runs show host-stall bursts
  that drop eAxC 0/1 too; the 37-slot ring cannot cover a ~120 ms burst. Clean 10 s/30 s windows at `extra=0`
  show 0 missed / 0 past. The UHD value 20 is `[UNVERIFIED]` until the bench run.

## UHD ~6 ms — proposal only (not implemented)

The null path completes the PRACH window and sends the U-plane reply within ~0.2 ms of the window end, so the
first-light UHD 8.8 ms must be added before the lower-PHY PRACH worker sees the samples, or in the UHD receive
path. The bench run should locate it before changing any buffer/cpuset parameter:

1. **Timestamp both sides of the UHD receive path.** In `lib/radio/uhd/radio_uhd_impl.cpp::receive()`, record the
   host time before and after `recv()` and the UHD RX metadata `time_spec`/`error_code`; emit an
   `OPENRU_TRACE` CSV row (`radio_handoff` already exists for the TX path). Compare the PRACH `window complete`
   log time with the slot's expected air time. If `recv()` returns late or the metadata reports `OVERFLOW`,
   the ~6 ms is in UHD/socket buffering, not in the PRACH demod.
2. **RX buffer policy.** A/B the UHD device args `recv_frame_size`, `num_recv_frames` and `recv_buff_size`:
   current defaults vs `recv_frame_size=8820` (MTU 9000), `num_recv_frames=512`, `recv_buff_size=50000000`.
   Keep the host `net.core.rmem_max`/`wmem_max` raise-only (the bench host is at 50,000,000) and record
   `ERROR_CODE_OVERFLOW` / `O` counts. If overflows disappear but the delay remains, the buffer is not the cause.
3. **UHD recv frame size.** Compare the default (1472/8000) with 8820/9000-byte frames. Larger frames reduce
   receive interrupts and per-frame syscalls; measure the PRACH `complete` time, not throughput.
4. **RU cpuset 2-5 shared with UHD threads.** On the bench, `PROTORU_CPUSET=2-5` holds UHD RX/TX, the lower-PHY
   DL/UL workers and the OFH threads. Use `ps -L -o tid,comm,psr,prio -p <ru_pid>` (or `top -H`) to list
   `uhd`/`ru_phy_*`/`ru_ofh_*` threads and their cores. A/B: (a) current `2-5`; (b) UHD RX/TX on 2-3, lower PHY
   on 4-5; (c) expand to `2-6` (still P-cores, DU keeps 6-11). Keep the measured `PROTORU_CPUSET` rule unless the
   600 s late ratio improves.
5. **Acceptance for the bench run.** At the profile value, 600 s with `log.level: debug` must show 0 missed PRACH
   contexts and 0 past-seq drops for eAxC 4/5, and the measured `window complete` -> `send` plus the UHD receive
   lead must fit inside `prach_rx_extra_slots` (20 slots = 10 ms at 30 kHz).
