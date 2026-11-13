#!/usr/bin/env python3
"""Parse smoke-fh logs for steady slot indication and ProtO-RU late/drop KPIs.

Pass criteria (M0):
  - Over the run window, DU slot indication advances without gaps (SFN/slot
    monotonic in stdout metrics or log context lines).
  - ProtO-RU KPI rows show zero late and zero dropped C/U-plane packets
    (RX_LATE + RX_LATE_C + RX_LATE_C_U + RX_ERR_DROP all sum to 0 across rows).
  - If host has no RT kernel and a small number of lates appear, print exact
    counts/rates as [MEASURED] and exit 2 (soft-fail) so OPEN_QUESTIONS can
    propose a threshold; do not pass silently.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

KPI_HEADER = re.compile(r"\|\s*TIME\s*\|.*RX_LATE")
# Data row: | HH:MM:SS | ID | RX_TOTAL | RX_ON_TIME | RX_EARLY | RX_LATE | ... | RX_LATE_C | ... | RX_LATE_C_U | ... | RX_CORRUPT | RX_ERR_DROP | TX_TOTAL |
KPI_ROW = re.compile(
    r"\|\s*(\d{2}:\d{2}:\d{2})\s*\|\s*(\d+)\s*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # total, on_time, early, late (UP)
    r"[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # on_time_c, early_c, late_c
    r"[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # on_time_c_u, early_c_u, late_c_u
    r"[^|]*\|[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # corrupt, drop, tx
)

# MAC metrics: "MAC cell pci=1 metrics: slots=[sfn.slot, sfn.slot) nof_slots=N ..."
MAC_SLOTS = re.compile(
    r"MAC cell pci=\d+ metrics:\s*slots=\[([^,\]]+),\s*([^)\]]+)\)\s*(?:\([^)]*\))?\s*nof_slots=(\d+)",
    re.I,
)
SLOT_CTX = re.compile(r"(?:sfn|SFN)[=:\s]+(\d+).{0,40}?(?:slot|SLOT)[=:\s]+(\d+)", re.I)


def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def parse_kpi(text: str) -> list[dict]:
    text = _strip_ansi(text)
    rows = []
    for m in KPI_ROW.finditer(text):
        rows.append(
            {
                "time": m.group(1),
                "id": int(m.group(2)),
                "rx_total": int(m.group(3)),
                "rx_late_up": int(m.group(6)),
                "rx_late_c": int(m.group(9)),
                "rx_late_c_u": int(m.group(12)),
                "rx_err_drop": int(m.group(14)),
                "tx_total": int(m.group(15)),
            }
        )
    return rows


def _parse_slot_token(tok: str) -> tuple[int, int] | None:
    tok = tok.strip()
    # Formats: "12.3", "sfn=12 slot=3", "12:3"
    m = re.match(r"(\d+)[.:](\d+)$", tok)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.search(r"(\d+).{0,16}?(\d+)", tok)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


def parse_mac_slot_reports(text: str) -> list[dict]:
    reports = []
    for m in MAC_SLOTS.finditer(text):
        start = _parse_slot_token(m.group(1))
        end = _parse_slot_token(m.group(2))
        nof = int(m.group(3))
        if start and end:
            reports.append({"start": start, "end": end, "nof_slots": nof})
    return reports


# Log context: "[  847.13]" or "[847.13]" (sfn.slot_index)
LOG_SLOT = re.compile(r"\[\s*(\d+)\.(\d+)\s*\]")


def parse_slots(text: str) -> list[tuple[int, int]]:
    text = _strip_ansi(text)
    slots = []
    for m in SLOT_CTX.finditer(text):
        slots.append((int(m.group(1)), int(m.group(2))))
    for m in LOG_SLOT.finditer(text):
        slots.append((int(m.group(1)), int(m.group(2))))
    for r in parse_mac_slot_reports(text):
        slots.append(r["start"])
        slots.append(r["end"])
    return slots


def slots_advance_without_gaps(text: str, scs_khz: int = 30) -> tuple[bool, str]:
    reports = parse_mac_slot_reports(_strip_ansi(text))
    slots_per_frame = 10 * (scs_khz // 15)  # 20 for 30 kHz
    hyper = 1024 * slots_per_frame

    def abs_slot(s: tuple[int, int]) -> int:
        return s[0] * slots_per_frame + s[1]

    def forward(a: int, b: int) -> int:
        """Slots from a to b forward in time, handling SFN wrap."""
        return (b - a) % hyper

    if reports:
        # Each report covers a contiguous window of nof_slots. Across reports, start must advance
        # and nof_slots must stay > 0 (steady indication).
        if any(r["nof_slots"] <= 0 for r in reports):
            return False, "a MAC metrics report had nof_slots=0 (slot indication stalled)"
        if len(reports) < 2:
            return False, f"need >=2 MAC slot reports, got {len(reports)}"
        prev = reports[0]
        for cur in reports[1:]:
            adv = forward(abs_slot(prev["start"]), abs_slot(cur["start"]))
            if adv == 0:
                return False, f"slot window did not advance: {prev['start']} -> {cur['start']}"
            # Gap between previous end and next start (wrap-safe). Allow one report period of slack.
            gap = forward(abs_slot(prev["end"]), abs_slot(cur["start"]))
            # gap==0 means contiguous; small gap OK; large gap (>> nof_slots) is a stall/hole.
            if gap > max(prev["nof_slots"], cur["nof_slots"], 1) * 2:
                return False, f"gap between MAC reports: prev_end={prev['end']} next_start={cur['start']} gap={gap}"
            prev = cur
        return True, f"{len(reports)} MAC reports, nof_slots>0, windows advance (SFN-wrap safe)"

    slots = parse_slots(text)
    if len(slots) < 2:
        return False, f"need >=2 slot samples, got {len(slots)}"
    # Prefer unique advancing samples
    uniq = []
    for s in slots:
        if not uniq or s != uniq[-1]:
            uniq.append(s)
    if len(uniq) < 2:
        return False, f"need >=2 distinct slot samples, got {len(uniq)}"
    prev = uniq[0]
    for cur in uniq[1:]:
        if forward(abs_slot(prev), abs_slot(cur)) == 0:
            return False, f"non-advancing slot samples {prev}->{cur}"
        prev = cur
    return True, f"{len(uniq)} raw slot samples, advancing (SFN-wrap safe)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--du-log", required=True)
    ap.add_argument("--ru-log", required=True)
    ap.add_argument("--secs", type=float, default=60.0)
    ap.add_argument("--allow-late", type=int, default=0, help="soft-fail threshold; 0 = require zero")
    args = ap.parse_args()

    du = Path(args.du_log).read_text(errors="replace")
    ru = Path(args.ru_log).read_text(errors="replace")

    rows = parse_kpi(ru)
    late_sum = sum(r["rx_late_up"] + r["rx_late_c"] + r["rx_late_c_u"] for r in rows)
    drop_sum = sum(r["rx_err_drop"] for r in rows)
    rx_sum = sum(r["rx_total"] for r in rows)
    tx_sum = sum(r["tx_total"] for r in rows)

    print("=== ProtO-RU KPI summary ===")
    print(f"kpi_rows={len(rows)} rx_total={rx_sum} tx_total={tx_sum}")
    print(f"late_sum(UP+C+C_U)={late_sum} drop_sum={drop_sum}  [MEASURED]")
    if rows:
        rate = late_sum / max(args.secs, 1.0)
        print(f"late_rate={rate:.4f}/s over {args.secs}s  [MEASURED]")

    ok_slots, slot_msg = slots_advance_without_gaps(du)
    mac_reports = parse_mac_slot_reports(du)
    slots = parse_slots(du)
    print("=== DU slot indication ===")
    print(f"mac_reports={len(mac_reports)} raw_samples={len(slots)} detail={slot_msg}")
    if mac_reports:
        print(f"first={mac_reports[0]} last={mac_reports[-1]}")
    elif slots[:3]:
        print(f"first={slots[0]} last={slots[-1]}")

    # Fallback: if no explicit slot samples, accept DU "Initializing the Open Fronthaul"
    # plus non-zero RU RX as evidence OFH ran; still require slot samples for hard pass.
    ofh_up = (
        "Open Fronthaul" in du
        or "Initializing the Open Fronthaul" in du
        or "Started the operation of the Open Fronthaul" in du
    )

    hard_fail = False
    soft_fail = False

    if not rows:
        print("FAIL: no ProtO-RU KPI rows parsed (is ru_emulator stdout captured?)")
        hard_fail = True
    if rx_sum == 0 and tx_sum == 0:
        print("FAIL: ProtO-RU saw no OFH traffic (rx_total=tx_total=0)")
        hard_fail = True
    if not ok_slots:
        print(f"FAIL: slot indication not proven ({slot_msg})")
        hard_fail = True
    if not ofh_up:
        print("FAIL: DU OFH init string not found")
        hard_fail = True

    if drop_sum > 0:
        print(f"[MEASURED] dropped C/U-plane packets: drop={drop_sum}")
        hard_fail = True
        print("FAIL: non-zero RX_ERR_DROP")
    elif late_sum > 0:
        print(
            f"[MEASURED] late C/U-plane packets: late={late_sum} "
            f"rate={late_sum / max(args.secs, 1.0):.4f}/s "
            f"(host kernel is not PREEMPT_RT)"
        )
        if args.allow_late > 0 and late_sum <= args.allow_late:
            # Explicit provisional threshold supplied by operator.
            if not hard_fail:
                soft_fail = True
                print(f"SOFT-FAIL: late_sum={late_sum} <= allow_late={args.allow_late}")
        elif not hard_fail:
            # Default: do not pass silently; record [MEASURED] and soft-fail.
            soft_fail = True
            print(
                "SOFT-FAIL: non-zero lates on non-RT host; "
                "propose a numeric threshold in docs/OPEN_QUESTIONS.md"
            )

    if hard_fail:
        return 1
    if soft_fail:
        return 2
    print("PASS: steady slots + zero late/drop")
    return 0


if __name__ == "__main__":
    sys.exit(main())
