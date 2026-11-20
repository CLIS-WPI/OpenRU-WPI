# UL and PRACH replay harness — design note

Status: **design only.** This stage adds this file and no code. Stop here for review
before Stage 2.

Scope: extend the existing downlink replay harness to deterministic uplink (PUSCH)
and PRACH, one PR per stage. Rules in force: own worktree, no release/ship/prune
commands, no access to `ran`, core, radios or modems, transmit nothing.

Evidence tags follow `docs/BRIEF_PHASE1.md`: `[MEASURED]`, `[DERIVED]`,
`[ASSUMPTION]`, `[UNVERIFIED]`.

## 0. Decision summary (what the reviewer is approving)

1. **Feed:** extend the null radio with a DU-slot-anchored, contiguous RX feed
   (`rx_feed` + `rx_start_du_slot` + `rx_start_marker`). The anchor is the same
   `slot_of_du()`/stable-Δ mechanism already used by the TX dump.
2. **Scheduling:** generate a small **synthetic UL C-plane pcap** with the OCUDU
   C-plane builder instead of relying on the existing capture. The stored
   `baseline` capture is a no-UE cell (`docs/reports/M1.md`), so it cannot be
   assumed to contain PUSCH UL C-plane.
3. **Reference:** synthesized signals with a known answer. PUSCH: a deterministic
   QPSK grid per (slot, symbol, port, RE) turned into time-domain samples by the
   generator. PRACH: the OCUDU `prach_generator` (ZC sequence, TS 38.211).
4. **Comparator:** a Python wire/IQ comparator plus a tiny C++ PRACH detector that
   reuses the DU's `prach_detector`. It checks captured **RU→DU** UL U-plane:
   wire slot/symbol/eAxC exactly, section coverage exactly, IQ with a stated
   tolerance, and PRACH detection + timing.
5. **Stages:** Stage 2 = 20 MHz PUSCH feed + comparator + CI target + deliberate
   corruption test. Stage 3 = 40 MHz + PRACH.

Open decisions are in §12; the most important is item 1 there (synthetic pcap vs a
new live capture).

## 1. Existing DL path (what we build on)

```
pcap (DU→RU) ──fh_replay──▶ ProtO-RU ──null radio TX──▶ portN.cf32 + tx_index
   │                          ▲
   │                          └── low-PHY DL: grid → IFFT+CP → ci16
   └── window.py anchors start_du to the first DL C-plane after 2 frames
```

Facts that matter:

- `scripts/replay_iq_dump.sh` starts ProtO-RU alone (no DU), replays the pcap onto
  the `fh` bridge, dumps TX IQ, and tears down.
- The null radio's clock advances only in `receive()`; `slot_of_du()` derives the
  GPS/OFH wire slot from wall time. The TX dump gate waits for a marker and for a
  constant `du_abs − radio_abs` residual, then starts at the pcap's `start_du`.
- `tools/golden/window.py` records `start_du`, `lead_us`, DL U-plane slots and
  ports. `tools/golden/ofh_scan.py` is a dependency-free pcap/pcapng reader with
  OFH header + wire-slot + direction parsing (direction 0 = uplink).
- The null radio already has an **RX feed** (`rx_feed=/path/to/dir`), read
  sequentially from `portN.cf32` from the first `receive()`; there is no slot
  anchor and no RU→DU capture today.

## 2. Target UL path

```
synthetic pcap (DU→RU)  ──fh_replay──▶ ProtO-RU ── low-PHY UL ──▶ UL U-plane (RU→DU)
        ▲                    │                  ▲                        │
        │                    │                  │                        ▼
  gen_cplane.py              │            null radio RX feed       tcpdump/scapy sniff
  (known sections)           │            (known IQ, slot-anchored)  on the fh bridge
                             │                  ▲                        │
                    rx_start_marker ────────────┘                 ul_compare.py
                                                                   ├─ wire + IQ checks
                                                                   └─ prach_detect (C++,
                                                                      reuses DU detector)
```

The DU is not running. The replayer container holds the DU MAC and is therefore a
natural capture point for RU→DU frames.

## 3. Null-radio uplink feed

### 3.1 New device args

Keep the existing key/value `device_args` string; add:

| arg | meaning |
|---|---|
| `rx_feed` / `rx_feed_dir` | existing: directory with `portN.cf32` |
| `rx_start_du_slot` | wire DU slot (mod 5120) at which playback starts; `-1` = legacy, play immediately |
| `rx_start_marker` | optional file; playback is disarmed until it exists (fh_replay creates it) |

### 3.2 Playback semantics

- Before the start condition, `receive()` returns zeros and does **not** consume
  the file. This keeps the file's sample 0 aligned to the first sample of
  `rx_start_du_slot`.
- On the first `receive()` whose `slot_of_du(ts)` equals `rx_start_du_slot` (and
  marker seen), playback begins. Samples are consumed at exactly the per-symbol
  sizes the lower PHY asks for, so file offset ↔ `ts − feed_start_ts`.
- At EOF, return zeros and set `rx_eof` (existing behaviour).
- `pace=realtime` is required for any timing claim; `pace=free` stays
  throughput-only and is labelled as such.

This reuses the TX dump's existing `slot_of_du()`, stable-Δ and marker plumbing;
the only new logic is the start condition and the pre-start zero fill.

### 3.3 File layout and size

- One `portN.cf32` per radio RX port (2 ports at 20/40 MHz), interleaved float32
  I/Q, `ci16`-quantized values written as floats (see §3.4).
- Contiguous symbols from the first sample of `rx_start_du_slot`; non-scheduled
  symbols are zeros. No JSON on the real-time path.
- 20 MHz, 400 slots, 2 ports: `400 × 11520 × 2 × 4 B × 2 = 73.7 MB` (tmpfs).
  A 100-slot Stage-2 window is 18.4 MB.
- `iq_meta.json` gains an `rx` block: start slot, file bytes, EOF/dropped counts,
  and the marker/slot actually used.

### 3.4 Quantization is part of the known answer

The null radio converts feed `cf32` → `ci16` with `to_ci16()` before the lower PHY
sees it. The generator therefore quantizes to `ci16` first and writes those exact
values back as floats. The reference is computed from the quantized samples, so a
pass is not an artifact of a floating-point round trip.

## 4. Scheduling: synthetic C-plane pcap

### 4.1 Why not the stored capture

`docs/reports/M1.md` describes the stored profiles as a **no-UE cell** (PDSCH is
single-layer on port 0). The stored `baseline.pcapng` therefore cannot be assumed
to contain PUSCH UL C-plane; a live capture with a UE needs core/UE access that
this task explicitly forbids. The golden pcap is also gitignored and fetched.

### 4.2 Synthetic pcap

A new `tools/ul_harness/gen_cplane.py` writes a minimal pcap containing:

- one DL C-plane message to anchor the replay marker/window (and, if needed, a
  DL U-plane message so the environment resembles the DL path),
- UL C-plane sections for PUSCH eAxC 0/1 at chosen slots,
- PRACH C-plane sections for eAxC 4/5 at the derived occasion (Stage 3).

Messages are Ethernet + IPv4 + UDP + eCPRI + OFH, with the same MAC/VLAN rewrite
that `fh_replay` already performs. Field semantics come from
`external/proto-ru/lib/ofh/serdes/ofh_cplane_message_builder_impl.cpp` and the
decoder; the layout is already partially decoded in `tools/golden/ofh_scan.py`.
Prefer using `ocudu::ofh::create_ofh_control_plane_static_compression_message_builder()`
in a small helper over hand-rolling bytes; if hand-rolled, add a unit test that feeds one
generated message through the RU decoder.

### 4.3 20 MHz Stage-2 schedule

Profile `baseline`/new `ul-20mhz`: 51 RB, 30 kHz SCS, 768-point DFT, 11520
samples/slot, TDD period 5 (slots 0–2 DL, slot 3 special with 2 UL symbols, slot 4
UL-only) `[DERIVED]` from `profiles/baseline/du-fh.yml`.

Stage 2 schedules, for a 100-slot window:

| field | value |
|---|---|
| eAxC | 0 and 1 (UL ports `[0,1]`) |
| slots | UL-only slot index 4 in each TDD period |
| symbols | 0–13 (full UL slot) |
| PRBs | full band 0–50 (612 RE) |
| compression | BFP, 9-bit, static header (matches profile) |

Stage 3 adds the PRACH occasion. Config index 159 in the FR1 **unpaired** table
gives format **C0**, `x=4`, `y=1`, reference slot 9 (15 kHz) → common 30 kHz slot
**19** (short-preamble rule `scs_ratio=2`, one PRACH slot per subframe), starting
symbol **2**, 6 occasions × 2 symbols = **12 symbols**, `L_RA=139`, 12 RB with
`k_bar=2`, eAxC 4/5 `[DERIVED]` from
`external/proto-ru/lib/ran/prach/prach_configuration.cpp`,
`lib/scheduler/common_scheduling/prach_scheduler.cpp`, and
`lib/ran/prach/prach_frequency_mapping.cpp`. The note about "PRACH format B4" in
`docs/BRIEF_PHASE1.md` is a documentation mismatch to resolve (`[UNVERIFIED]`
which format the v1 bench profiles actually use; the harness must derive it from
OCUDU, never hard-code it).

## 5. Reference outputs

| signal | known answer | how the comparator gets it |
|---|---|---|
| PUSCH | deterministic QPSK RE grid `g(slot, symbol, port, re)` from a fixed PRBS seed | `gen_ul_feed.py` writes the grid and the time-domain feed from the same function; the expected after the RU chain is computed with the OCUDU `ofdm_symbol_demodulator` (same profile/scale) and stored as `.npz` |
| PRACH | ZC sequence from `ocudu::prach_generator` (root 1, zero-correlation zone 0, preamble index chosen by the test) | `gen_ul_feed.py` calls the same generator semantics (via the helper) and maps it with `prach_frequency_mapping_get`; the expected `prach_buffer` is stored |
| determinism | two cold runs bit-identical | `determinism_check.sh` over the captured pcap payload bytes, as for DL |

The fork carries PRACH generator/detector unit tests but no stored IQ vectors, so
the "test vector" is the spec-derived `prach_generator` output plus the synthesized
PUSCH grid, not a checked-in capture. The comparator stores the expected data
next to each run so a reviewer can recompute it.

Known-answer gate vs determinism gate are separate:

- **Known answer:** decoded UL REs track the injected grid. This is the primary
  correctness claim.
- **Determinism:** two cold runs produce identical captured payloads. This is the
  regression claim (the same two-gate idea as M1 + M2).

## 6. Comparator

### 6.1 Inputs

- Captured `ru_to_du.pcapng` (all frames with `ether src 02:00:00:00:00:20`).
- The synthetic pcap / expected `.npz`.
- The profile YAML and the UL plan.

### 6.2 Wire checks (exact)

For every captured UL U-plane message:

1. Direction is uplink (OFH `data_direction=0`).
2. `(SFN, slot, symbol)` equals an expected scheduled section.
3. `eAxC` equals the expected port (0/1 for PUSCH, 4/5 for PRACH).
4. Section PRB range / number of symbols match; no missing and no extra sections.
5. Message ordering is monotonic in `(slot, symbol)`; duplicates are reported.
6. PRACH messages use section type 1, `start_symbol=2`, 12 symbols, 12 RB.

### 6.3 IQ checks (stated tolerance)

- Decode the U-plane with the OFH layout, decompress BFP 9-bit.
- PUSCH: compare each RE against the expected grid. **Target gate: BFP payload
  byte-identical** to a reference produced by compressing the expected grid with
  the same 9-bit BFP. If the first measured run shows a deterministic mismatch
  caused by a documented scale/quantization difference, the gate becomes
  **EVM ≤ −35 dB and max |ΔRE| ≤ 1 BFP LSB**, and the reason is recorded in the
  report. The gate is fixed before the corruption test, never tuned afterwards.
- PRACH: compare the 139-RE sequences (offset `k_bar=2`) to the generated ZC
  sequence with the same EVM tolerance, and additionally run the detector (§6.4).

### 6.4 PRACH detection and timing

`tools/ul_harness/prach_detect.cpp` (small, built against the installed OCUDU
headers/libs in the `openru/protoru` image):

1. Build `create_prach_buffer_short(2 ports, 6 TD occasions, 1 FD occasion)`.
2. Fill `get_symbol(port, td_occasion, fd_occasion, symbol)` from the decoded
   PRACH messages (6 TD occasions × 2 symbols).
3. Call `ocudu::prach_detector::detect()` with root sequence 1, format C0,
   zero-correlation zone 0, `ra_scs=30 kHz`, 2 RX ports.
4. Emit JSON: detected preamble indices, `time_advance`, metric, RSSI,
   `time_resolution`.

Pass: exactly one detected preamble matching the injected index, and
`|time_advance| ≤ 1 time_resolution` (i.e. no timing offset). A deliberate
`prach_shift` corruption (§8) must move the reported TA by the injected number of
samples within one resolution unit.

This is the DU's own detector run offline; no DU is needed at run time.

### 6.5 Exit codes

`0` pass; `1` mismatch (with a machine-readable JSON naming the first failing
section and the reason); `2` usage/parse error; `3` measurement invalid (lock or
host).

## 7. Existing code reused

| reuse | path | role |
|---|---|---|
| null radio | `external/proto-ru/lib/radio/null/radio_null_session.{h,cpp}` | add RX start gate; reuse `slot_of_du()`/marker/stable-Δ |
| replay | `tools/fh_replay/fh_replay.py` (`fh_replay_c.c`) | DU→RU replay; add `--capture-ul` sniffer thread or run tcpdump beside it |
| pcap/OFH scan | `tools/golden/ofh_scan.py` | frame iteration, wire slot, direction; extend with C-plane sections and U-plane payload |
| window/replay glue | `tools/golden/window.py`, `prep_config.py`, `manifest_mode.py` | window/lead/marker; inject `rx_*` args |
| orchestration | `scripts/replay_iq_dump.sh`, `scripts/capture_ofh.sh` | RU-only bring-up, MTU check, capture pattern |
| test harness | `tests/replay-golden/run.sh`, `tests/lib/common.sh`, `tests/lib/golden_energy.sh` | lock, evidence, `make test` integration |
| OFH decode/decompress | `ocudu::ofh::create_{static,dynamic}_compr_method_ofh_user_plane_packet_decoder`, `create_iq_decompressor` | exact DU-side wire semantics (C++ helper) |
| UL DSP | `ocudu::create_ofdm_symbol_demodulator`, `phase_compensation_lut` | expected REs from the synthesized feed |
| PRACH | `ocudu::prach_generator`, `ocudu::prach_detector`, `create_prach_buffer_short` | known answer + detection/timing |
| PRACH config | `prach_configuration_get`, `get_prach_duration_info`, `prach_frequency_mapping_get` | derive occasion, symbols, RB mapping; never hard-code |
| IQ compare | `tools/iq_compare/iq_compare.py` | conventions for per-slot metrics/JSON (reuse where it fits) |

## 8. Deliberate corruption test (Stage 2, required)

The comparator must fail on purpose. Add `tools/ul_harness/corrupt.py` (or a
`--corrupt` mode in the generator) producing these cases; each runs the full
comparator and asserts a non-zero exit **and** the expected diagnostic:

| mode | mutation | expected failure |
|---|---|---|
| `re_bump` | add +1 BFP LSB to one RE | IQ check names that RE |
| `slot_shift` | shift the feed by one slot | wire mismatch / missing expected sections |
| `drop_symbol` | zero one PUSCH symbol | zero-energy/missing section |
| `port_swap` | swap `port0.cf32`/`port1.cf32` | IQ mismatch per port |
| `drop_message` | remove one captured U-plane message | coverage failure |
| `prach_shift` | delay the PRACH preamble by N samples | detector TA ≠ 0 |
| `prach_drop` | no preamble in the occasion | no detection |

The clean case must pass in the same job; a test that only checks "fails when
corrupted" is not enough.

## 9. CI target

- New `tests/ul-harness/run.sh`, modelled on `tests/replay-golden/run.sh`.
- `make ul-harness PROFILE=ul-20mhz`; add `ul-harness` to `SUITES` in the
  Makefile. Do **not** add a GitHub `pull_request` trigger: per `docs/CI.md` the
  self-hosted runner workflow is `push`/`workflow_dispatch` only and currently
  inert. The local/CI gate runs through `make test`.
- Evidence under `docs/reports/runs/ul-harness/` (`metrics.json`, captured pcap,
  comparator JSON, logs); measurement lock via `tests/lib/common.sh`; no Docker
  build while the lock is held.
- Runtime target: under 10 minutes on the H100 host for 20 MHz, matching the
  `replay-golden` budget.
- Reports label every number and end with an `Unverified` list.

## 10. Stage plan

**Stage 1 (this PR):** this design note. No code. Stop for review.

**Stage 2 (next PR):** 20 MHz PUSCH only.
1. Null-radio RX start gate + `iq_meta` fields.
2. `gen_ul_feed.py`, `gen_cplane.py` (or the live-capture variant, §12.1).
3. `ul_compare.py` + `prach_detect.cpp` skeleton reused for PUSCH-only decode.
4. `tests/ul-harness` + Makefile target + evidence.
5. Corruption test (`re_bump`, `slot_shift`, `drop_symbol`, `port_swap`,
   `drop_message`), clean run passes.

**Stage 3 (next PR):** 40 MHz + PRACH.
1. 40 MHz feed/schedule (106 RB, 1536 DFT).
2. PRACH occasion at slot 19, symbols 2–13, eAxC 4/5.
3. `prach_detect.cpp` full detection/timing gate and `prach_shift`/`prach_drop`
   corruption cases.
4. Report with PRACH timing numbers and the `Unverified` list.

## 11. What the comparator deliberately does not check

- RF/OTA accuracy, EVM against a constellation, or channel effects.
- DU-side PRACH scheduling or RACH procedure (no core/UE involved).
- Fronthaul delay profile T2a/Ta3 (still `[UNVERIFIED]` without hardware).
- Absolute wall-clock latency; only slot alignment and intra-harness timing.

## 12. Open questions for the reviewer

1. **Synthetic C-plane vs live capture.** Recommended: synthetic pcap (§4), because
   the stored baseline is no-UE and this task forbids core/UE access. A live
   capture with a UE would be more realistic but not hermetic. Approve synthetic?
2. **BFP bit-exactness.** Target is byte-identical; fallback EVM ≤ −35 dB / 1 LSB
   if the first run shows a documented scale difference. Approve the fallback
   rule?
3. **PUSCH PRB scope.** Full 51 RB vs a 12-RB subset. Recommended: full band for a
   stronger test; the feed is still small (18 MB for 100 slots).
4. **Window length.** 100 slots (50 ms) for Stage 2, 400 slots (200 ms) for PRACH
   to cover 5 occasions. Fine for CI?
5. **PRACH format mismatch.** Config index 159 maps to C0 in the FR1 unpaired
   table, while `docs/BRIEF_PHASE1.md` says B4. The harness derives the format at
   runtime; the doc should be corrected separately. Confirm no profile change is
   intended.

## 13. Unverified

- Whether the RU accepts a synthetic C-plane pcap without a live DU (expected:
  yes, the receiver only needs valid OFH sections) `[UNVERIFIED]`.
- Whether UL BFP output is byte-identical to the reference with `iq_scaling=1.0`
  `[UNVERIFIED]`; measured in Stage 2.
- Host-jitter sensitivity of the slot-anchored RX feed under the measurement lock
  `[UNVERIFIED]`; same class of risk as the DL dump gate.
- Real-clock PRACH timing and OTA EVM remain `[UNVERIFIED]` by design.
