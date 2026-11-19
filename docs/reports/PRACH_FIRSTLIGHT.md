# PRACH U-plane lateness at first light (bench, 2026-11-18) — analysis and proposal

Evidence: `~/openru-artifacts/firstlight-20261118/firstlight-gnb.log` (copied from `ran`), plus the DU and
ProtO-RU container logs in the same directory.

## Symptom

- **10,038** `Sector#0: missed incoming User-Plane PRACH messages for slot '<X>.19'` (all at symbol 19, the
  PRACH occasion of PRACH config index 159), out of ~78 k PRACH log lines.
- ~**19,020** `potentially lost '<N>' messages sent by the RU` and, immediately after each missed window,
  `dropped received Open Fronthaul User-Plane packet for eAxC value '4'/'5' as sequence identifier field is from
  the past` and `no uplink PRACH context was found for slot '<X>.19' and eAxC '4'/'5'`.
- Timing: the missed window is logged at, e.g. `03:28:15.041548`; the stale PRACH packets arrive at
  `.050352` — **≈ 8.8 ms later**. PUSCH eAxC 0/1 are clean (no late/lost for those eAxCs).

## Where the timing is decided (code)

**DU side (the deadline that drops the packets)**
- `lib/ofh/receiver/ofh_closed_rx_window_handler.cpp:94-121` — `handle_prach_context()` runs at **symbol 0 of the
  following slot**, pops the PRACH context for slot N and logs *"missed … PRACH messages"* if the buffer is still
  empty. This is a **fixed next-slot boundary**; it does not use `t1a_min_up`/`t1a_max_up` (those bound the
  ordinary UL U-plane window).
- Late packets are then rejected by the sequence-identifier check
  (`lib/ofh/receiver/ofh_message_receiver_impl.cpp:83-90`, *"from the past"*) and by the PRACH data flow when the
  context is gone (`lib/ofh/receiver/ofh_data_flow_uplane_uplink_prach_impl.cpp:20-80`).

**`ta4` is not the PRACH receive window**
- `apps/units/flexible_o_du/split_7_2/helpers/ru_ofh_config_cli11_schema.cpp:79-82` documents `ta4_min/ta4_max` as
  the **Ta4 value for User-Plane**, i.e. the lead the DU uses when *transmitting* the UL C-plane request so the RU
  can process in time. The DU's *receive* deadline for PRACH is the next-slot boundary above.

**ProtO-RU side (where the ~10 ms is added)**
- `lib/ru/sdr/ru_lower_phy_uplink_request_handler_impl.cpp:13-18` — the PRACH occasion is forwarded to the OFH
  uplink request handler.
- `lib/phy/lower/processors/uplink/prach/prach_processor_impl.h` and `prach_processor_worker.cpp` — the worker
  collects the PRACH window samples in the real-time path and then demodulates; the PRACH buffer is completed
  **after** that processing, and the U-plane message is built only then
  (`lib/ofh/transmitter/ofh_data_flow_uplane_data_impl.cpp:94-145`, `enqueue_prach_message`).

## Verdict

**Both contribute, but the primary cause is ProtO-RU's PRACH path latency; the DU's fixed deadline makes it fatal.**
The measured ≈ **8.8 ms** is **4–6× larger** than both timing budgets the DU configures for uplink:

- `ta4_max` = 1480 µs and `t1a_max_up` = 2215 µs in the first-light config — so no `ta4`/`t1a` setting can
  explain or absorb a 9 ms delay, and the UL C-plane was demonstrably on time (PUSCH clean).
- The DU's PRACH deadline is **not** ta4: it is the next-slot boundary, so *any* RU PRACH latency beyond the slot
  end is discarded, no matter how ta4 is tuned.
- The ≈9–10 ms delay is consistent with the PRACH U-plane leaving the RU **several slots after the occasion**
  (asynchronous demod completion / queueing in the RU's uplink data flow), not with a marginal window miss.

## Proposed fix

1. **ProtO-RU (primary):** complete the PRACH processing and hand the buffer to the OFH uplink data flow **within
   the PRACH slot** — notify from the real-time worker's completion (or process the PRACH symbol(s) synchronously
   in the RT path; it is one symbol per occasion). Add an instant trace (`on_prach_request_*` already exists) with
   the completion timestamp so the latency is measurable.
2. **DU (hardening):** make the PRACH notification deadline configurable — accept the PRACH data up to
   `t1a_max_up` after the slot instead of at the next-slot boundary — so a ≤1-slot overrun is not lost.
3. **Verification:** a PRACH-only offline replay (recorded UL with a PRACH occasion) that asserts the PRACH
   U-plane arrives before the next slot, plus the DU metric `nof_missed_prach_contexts == 0` in a 600 s run.

Unrelated: the `prach_frequency_start=0` PUCCH/PRACH overlap warning is a configuration note, not the cause.
