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
| 3 | 600 s null-radio gate on this server; record value + RU reply delay | in progress (screening) |
| 4 | Bench profiles: server value + margin, `[UNVERIFIED]` on UHD, RU traces on | pending |
| 5 | OpenRU-WPI PR with submodule bump, profiles and gate evidence | pending |
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
