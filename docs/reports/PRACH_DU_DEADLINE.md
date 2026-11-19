# PRACH DU receive-window deadline — progress

Status: implementation, bench profiles and the OpenRU-WPI PR are ready; tag/release waits for the human merge.

## Goal

The RU can only build the PRACH U-plane reply after the 12-symbol PRACH occasion is captured (~3 ms after the
C-plane on the null radio, ~8.8 ms on the N310/UHD). The DU closes the PRACH receive window at the next slot's
symbol 0 (+0.5 ms), so the reply is dropped. Add a DU-side `ru_ofh.prach_rx_extra_slots` option that delays only the
PRACH pop, validate it against the PRACH context ring, gate it on this server with the null radio, and ship it in the
bench profiles.

Evidence tags follow `docs/BRIEF_PHASE1.md`; every number below is `[MEASURED]`, `[DERIVED]`, `[ASSUMPTION]` or
`[UNVERIFIED]`.

## Where the work lives

- ProtO-RU PR **#1** (`feat(ru): timestamp the PRACH window completion and U-plane hand-off`) merged as
  `2cd60991ec`; PR **#2** (`feat(ofh): add ru_ofh.prach_rx_extra_slots and fix the RU PRACH lookback wrap`) merged
  as `a91c9917b5` into `feat/null-radio`.
- OpenRU-WPI branch `feat/prach-rx-extra-slots`: submodule bumped to `a91c9917b5`, bench profiles, bounded timing
  mode, gate evidence and this report. Base `main` includes merged #25/#26.

## Status

| # | Item | Status |
|---|------|--------|
| 1 | Config path `ru_ofh.prach_rx_extra_slots` -> sector -> receiver -> closed window | done (`774837ebc4`, merged in `a91c9917b5`) |
| 2 | Ring validation (`1 + extra <= repo_size - 2`) with `report_error` | done (`774837ebc4`, merged in `a91c9917b5`) |
| 3 | 600 s null-radio gate on this server; record value + RU reply delay | recorded: clean windows 0/0 at extra=0; 600 s INVALID (host-stall bursts); server value 0 |
| 4 | Bench profiles: server value + margin, `[UNVERIFIED]` on UHD, measurement mode | done: `prach_rx_extra_slots: 20`, normal `log.level: info`, bounded `prach-timing` mode |
| 5 | OpenRU-WPI PR with submodule bump, profiles and gate evidence | open: https://github.com/CLIS-WPI/OpenRU-WPI/pull/28 |
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

## Gate prerequisite: RU emulator wire-SFN wrap (`de42c330f2`)

Screening at 30 s exposed a second, unrelated miss: exactly one PRACH occasion every 2.56 s, always at wire slot
`<sfn>.19`, with no PRACH U-plane reply sent by the RU for it. The O-DU wire slots wrap at 256 frames, but
`slot_point` subtraction wraps at the 1024-frame hyperframe, so `ofh_slot - lookback` turned wire slot `0.1` into
`1023.19` at every 256-frame wrap and the request recorded for wire slot `255.19` was never matched. No value of
`prach_rx_extra_slots` can fix that, so the fork subtracts the lookback modulo the wire period
(`ru_emulator_tti_orchestrator.cpp`, test added). This is a gate prerequisite, not part of the DU deadline change.

## Item 3 gate data (this server, null radio)

Image `openru/protoru:prach-extra` (`de42c330f2`, merged into `a91c9917b5`), `bench-20mhz/du-core.yml` +
`protoru-null.yml`, e2e core+DU+RU, 600 s, `/tmp/openru-measure.lock` held, `quiet_host.py` valid. Gate window
excludes the shutdown drain.

| extra | 600 s window | missed PRACH | seq-id-from-past (all / eAxC 4-5) | RU window complete |
|---|---|---|---|---|
| 0 | 05:31:33–05:41:33Z | 11 | 678 / 80 | 59,996 |
| 8 | 05:53:33–06:03:33Z | 79 | 3376 / 444 | 59,964 |

All misses and past drops fall in **host-stall bursts** (`05:32:11`, ~592 drops; `05:36:38`, ~82 drops in the
`extra=0` run; more frequent bursts in the `extra=8` run). The drops cover eAxC 0/1 as well as 4/5, so they are DU
OFH receive stalls, not PRACH lateness. The ring limit (37 extra slots = 18.5 ms) cannot cover a ~120 ms burst.
In clean 10 s/30 s windows the same image gives **0 missed / 0 past** at `extra=0`; the periodic 2.56 s misses at
wire SFN 255 are gone after `de42c330f2`.

RU reply delay (10 s debug run, `extra=0`): `PRACH window complete` -> `PRACH U-plane send` median **0.040 ms**,
p95 **0.056 ms**, max **0.152 ms** `[MEASURED]`. The null radio is already inside the default next-slot window, so the
smallest extra value that is *needed* on the null path is **0**; the UHD path is why the bench profile carries a
non-zero value. The 600 s result is reported as INVALID, not as a value failure.

## Item 4 bench profiles and measurement mode

- `profiles/bench-20mhz` and `profiles/bench-40mhz`: `prach_rx_extra_slots: 20` in `du-core.yml` and `du-fh.yml`.
  The first-light UHD delay is 8.8 ms ≈ **17.6 slots** at 30 kHz `[DERIVED]`; 20 leaves ~2 slots of margin and is
  below the ring limit of 37. The UHD number is `[UNVERIFIED]` on this server.
- The normal UHD `protoru.yml` stays at **`log.level: info`**. `log.level` only reaches the `RU_EMU` logger; the
  PHY/OFH `logger.debug` PRACH lines on the real-time path are not controlled by it, and `OCUDU_RU_TRACE` is a
  compile-time switch.
- A separate, explicitly named **bounded measurement mode** (`make BENCH=1 PROFILE=bench-20mhz prach-timing
  SECS=120`) generates a debug overlay in `build/local-profiles/` (gitignored), runs `smoke-fh` for 10–120 s and
  collects `docs/reports/raw/smoke-fh-ru.log`. It is not used by the normal bench profile and is not a soak.
  At debug the RU emulator logs every OFH packing step: **~29 GB/h** measured on the null-radio gate, i.e.
  **~0.97 GB for a 120 s run** `[MEASURED, null-radio; UHD expected similar per-slot, UNVERIFIED]`. The PHY
  `PRACH window complete` lines alone are ~0.09 GB/h.

## Resume point

- ProtO-RU `feat/null-radio` head is `a91c9917b5`; `docker/versions.env` pins `PROTORU_GIT_COMMIT=a91c9917b5` and
  the submodule pointer is at the same merge commit.
- OpenRU-WPI PR #28 (base `main`) carries the submodule bump, profiles, bounded mode, gate evidence and this
  report. After the human merge: `git tag v0.1.6-bench` and `make bench-release`; report the release directory and
  `SHA256SUMS`.
- Gate caveat: this GPU server is not a quiet real-time host. The 600 s null-radio runs are `INVALID_HOST_STALLS`;
  clean windows at `extra=0` show 0 missed / 0 past. The UHD value 20 is `[UNVERIFIED]` until the bench run.

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
5. **Acceptance for the bench run.** At the profile value, 600 s on the normal `info` profile must show 0 missed
   PRACH contexts and 0 past-seq drops for eAxC 4/5. Use the bounded `prach-timing` mode for the
   `window complete` -> `send` delay, and check that delay plus the UHD receive lead fits inside
   `prach_rx_extra_slots` (20 slots = 10 ms at 30 kHz).
