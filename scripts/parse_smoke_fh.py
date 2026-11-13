#!/usr/bin/env python3
"""Parse smoke-fh logs for steady slots, C/U-plane totals, late/drop KPIs.

Pass criteria (M0, Phase 1 provisional on non-RT host):
  - DU slot indication advances without gaps over the run window.
  - After optional warm-up exclusion: drop == 0 and late/packets < 1e-5.
  - Full-window and post-warm-up counts are always printed as [MEASURED].
  - Per-second late histogram used to detect start-up clustering / warm-up.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# ProtO-RU stdout KPI (per second deltas):
# | TIME | ID | RX_TOTAL | RX_ON_TIME | RX_EARLY | RX_LATE | RX_SEQ_ERR |
# | RX_ON_TIME_C | RX_EARLY_C | RX_LATE_C | RX_SEQ_ERR_C |
# | RX_ON_TIME_C_U | RX_EARLY_C_U | RX_LATE_C_U | RX_SEQ_ERR_C_U |
# | RX_SEQ_ERR_PRACH | RX_CORRUPT | RX_ERR_DROP | TX_TOTAL |
KPI_ROW = re.compile(
    r"\|\s*(\d{2}:\d{2}:\d{2})\s*\|\s*(\d+)\s*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # total, on_time, early, late UP
    r"[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # on_time_c, early_c, late_c
    r"[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # on_time_c_u, early_c_u, late_c_u
    r"[^|]*\|[^|]*\|"
    r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"  # corrupt, drop, tx
)

# DU OFH log metrics (UL at DU):
# OFH sector#0 metrics: ... rx_total=N rx_early=N rx_on_time=N rx_late=N ...
DU_OFH_RX = re.compile(
    r"OFH sector#\d+ metrics:.*?rx_total=(\d+)\s+rx_early=(\d+)\s+rx_on_time=(\d+)\s+rx_late=(\d+)",
    re.I,
)
DU_OFH_TX_KPI = re.compile(
    r"tx_kpis:\s*nof_late_dl_rgs=(\d+)\s+nof_late_ul_req=(\d+)\s+"
    r"nof_late_cp_dl=(\d+)\s+nof_late_up_dl=(\d+)\s+nof_late_cp_ul=(\d+)",
    re.I,
)
DU_UL_DROP_PAST = re.compile(
    r"dropped received Open Fronthaul User-Plane packet.*sequence identifier field is from the past",
    re.I,
)

MAC_SLOTS = re.compile(
    r"MAC cell pci=\d+ metrics:\s*slots=\[([^,\]]+),\s*([^)\]]+)\)\s*(?:\([^)]*\))?\s*nof_slots=(\d+)",
    re.I,
)
SLOT_CTX = re.compile(r"(?:sfn|SFN)[=:\s]+(\d+).{0,40}?(?:slot|SLOT)[=:\s]+(\d+)", re.I)
LOG_SLOT = re.compile(r"\[\s*(\d+)\.(\d+)\s*\]")

# Provisional Phase-1 gate (non-RT host), after warm-up.
LATE_FRAC_LIMIT = 1e-5


def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def _hhmmss_to_s(t: str) -> int:
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def parse_kpi(text: str) -> list[dict]:
    text = _strip_ansi(text)
    rows = []
    for m in KPI_ROW.finditer(text):
        on_up, early_up, late_up = int(m.group(4)), int(m.group(5)), int(m.group(6))
        on_c, early_c, late_c = int(m.group(7)), int(m.group(8)), int(m.group(9))
        on_cu, early_cu, late_cu = int(m.group(10)), int(m.group(11)), int(m.group(12))
        rows.append(
            {
                "time": m.group(1),
                "t_s": _hhmmss_to_s(m.group(1)),
                "id": int(m.group(2)),
                "rx_total": int(m.group(3)),
                "rx_up": on_up + early_up + late_up,
                "rx_c": on_c + early_c + late_c,
                "rx_c_u": on_cu + early_cu + late_cu,
                "rx_late_up": late_up,
                "rx_late_c": late_c,
                "rx_late_c_u": late_cu,
                "rx_err_drop": int(m.group(14)),
                "tx_total": int(m.group(15)),
            }
        )
    return rows


def parse_du_ofh(text: str) -> dict:
    text = _strip_ansi(text)
    rx_total = rx_late = 0
    samples = 0
    for m in DU_OFH_RX.finditer(text):
        samples += 1
        rx_total += int(m.group(1))
        rx_late += int(m.group(4))
    tx = {
        "nof_late_dl_rgs": 0,
        "nof_late_ul_req": 0,
        "nof_late_cp_dl": 0,
        "nof_late_up_dl": 0,
        "nof_late_cp_ul": 0,
    }
    for m in DU_OFH_TX_KPI.finditer(text):
        tx["nof_late_dl_rgs"] += int(m.group(1))
        tx["nof_late_ul_req"] += int(m.group(2))
        tx["nof_late_cp_dl"] += int(m.group(3))
        tx["nof_late_up_dl"] += int(m.group(4))
        tx["nof_late_cp_ul"] += int(m.group(5))
    past_drops = len(DU_UL_DROP_PAST.findall(text))
    return {
        "ofh_metric_samples": samples,
        "ul_rx_total": rx_total,
        "ul_rx_late": rx_late,
        "ul_past_seq_drops": past_drops,
        **tx,
    }


def _parse_slot_token(tok: str) -> tuple[int, int] | None:
    tok = tok.strip()
    m = re.match(r"(\d+)[.:](\d+)$", tok)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.search(r"(\d+).{0,16}?(\d+)", tok)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


def parse_mac_slot_reports(text: str) -> list[dict]:
    reports = []
    for m in MAC_SLOTS.finditer(_strip_ansi(text)):
        start = _parse_slot_token(m.group(1))
        end = _parse_slot_token(m.group(2))
        nof = int(m.group(3))
        if start and end:
            reports.append({"start": start, "end": end, "nof_slots": nof})
    return reports


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
    reports = parse_mac_slot_reports(text)
    slots_per_frame = 10 * (scs_khz // 15)
    hyper = 1024 * slots_per_frame

    def abs_slot(s: tuple[int, int]) -> int:
        return s[0] * slots_per_frame + s[1]

    def forward(a: int, b: int) -> int:
        return (b - a) % hyper

    if reports:
        if any(r["nof_slots"] <= 0 for r in reports):
            return False, "a MAC metrics report had nof_slots=0 (slot indication stalled)"
        if len(reports) < 2:
            return False, f"need >=2 MAC slot reports, got {len(reports)}"
        prev = reports[0]
        for cur in reports[1:]:
            adv = forward(abs_slot(prev["start"]), abs_slot(cur["start"]))
            if adv == 0:
                return False, f"slot window did not advance: {prev['start']} -> {cur['start']}"
            gap = forward(abs_slot(prev["end"]), abs_slot(cur["start"]))
            if gap > max(prev["nof_slots"], cur["nof_slots"], 1) * 2:
                return (
                    False,
                    f"gap between MAC reports: prev_end={prev['end']} "
                    f"next_start={cur['start']} gap={gap}",
                )
            prev = cur
        return True, f"{len(reports)} MAC reports, nof_slots>0, windows advance (SFN-wrap safe)"

    slots = parse_slots(text)
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


def late_per_second(rows: list[dict]) -> list[tuple[int, int, int, int, int]]:
    """Return list of (rel_s, late_up, late_c, late_c_u, late_sum) from first KPI second."""
    if not rows:
        return []
    t0 = rows[0]["t_s"]
    by: dict[int, list[int]] = defaultdict(lambda: [0, 0, 0])
    for r in rows:
        rel = (r["t_s"] - t0) % 86400
        by[rel][0] += r["rx_late_up"]
        by[rel][1] += r["rx_late_c"]
        by[rel][2] += r["rx_late_c_u"]
    out = []
    for rel in sorted(by):
        up, c, cu = by[rel]
        out.append((rel, up, c, cu, up + c + cu))
    return out


def detect_warmup(hist: list[tuple[int, int, int, int, int]], run_secs: float) -> tuple[int, str]:
    """If lates cluster at start, return warm-up seconds to exclude; else 0."""
    total_late = sum(h[4] for h in hist)
    if total_late <= 0:
        return 0, "no lates; warm-up=0"

    # Contiguous prefix from t=0 that holds late events before a quiet gap.
    first_late_s = next((h[0] for h in hist if h[4] > 0), None)
    if first_late_s is None:
        return 0, "no lates; warm-up=0"

    # Candidates: 5, 10, 15, 30, 60 s
    candidates = [5, 10, 15, 30, 60]
    best_w = 0
    best_note = "lates not start-clustered; warm-up=0"
    for w in candidates:
        if w >= run_secs * 0.5:
            continue
        late_w = sum(h[4] for h in hist if h[0] < w)
        late_rest = total_late - late_w
        dens_w = late_w / max(w, 1)
        dens_rest = late_rest / max(run_secs - w, 1)
        frac_w = late_w / total_late
        # Cluster: majority of lates in prefix AND density >> remainder (or remainder empty).
        if frac_w >= 0.5 and (late_rest == 0 or dens_w >= 3.0 * dens_rest):
            # Extend warm-up to just after last late in the prefix cluster.
            last_in = max((h[0] for h in hist if h[0] < w and h[4] > 0), default=w - 1)
            warm = last_in + 1
            best_w = warm
            best_note = (
                f"start-cluster: {late_w}/{total_late} lates in first {w}s "
                f"(dens {dens_w:.4f}/s vs rest {dens_rest:.4f}/s); warm-up={warm}s"
            )
            break
    return best_w, best_note


def rate_per_million(late: int, packets: int) -> float:
    if packets <= 0:
        return float("nan")
    return 1e6 * late / packets


def summarize_window(rows: list[dict], label: str) -> dict:
    rx_up = sum(r["rx_up"] for r in rows)
    rx_c = sum(r["rx_c"] for r in rows)
    rx_c_u = sum(r["rx_c_u"] for r in rows)
    rx_total = sum(r["rx_total"] for r in rows)
    tx_total = sum(r["tx_total"] for r in rows)
    late_up = sum(r["rx_late_up"] for r in rows)
    late_c = sum(r["rx_late_c"] for r in rows)
    late_c_u = sum(r["rx_late_c_u"] for r in rows)
    late_sum = late_up + late_c + late_c_u
    drop = sum(r["rx_err_drop"] for r in rows)
    # DL at RU = all RX (U + C + C_U); UL TX from RU = TX_TOTAL (U-plane UL toward DU).
    dl_pkts = rx_total
    ul_pkts_tx = tx_total
    return {
        "label": label,
        "kpi_rows": len(rows),
        "dl_u_plane_pkts": rx_up,
        "dl_c_plane_pkts": rx_c,
        "ul_c_plane_pkts_at_ru": rx_c_u,
        "dl_rx_total": dl_pkts,
        "ul_tx_total": ul_pkts_tx,
        "late_dl_u_at_ru": late_up,
        "late_dl_c_at_ru": late_c,
        "late_ul_c_at_ru": late_c_u,
        "late_dl_sum_at_ru": late_sum,
        "drop_at_ru": drop,
        "late_per_M_dl": rate_per_million(late_sum, dl_pkts),
        "late_frac_dl": (late_sum / dl_pkts) if dl_pkts else float("nan"),
        # Gate denominator: all OFH packets seen at RU (DL RX + UL TX).
        "all_pkts": dl_pkts + ul_pkts_tx,
        "late_per_M_all": rate_per_million(late_sum, dl_pkts + ul_pkts_tx),
        "late_frac_all": (late_sum / (dl_pkts + ul_pkts_tx)) if (dl_pkts + ul_pkts_tx) else float("nan"),
    }


def print_summary(s: dict) -> None:
    print(f"=== {s['label']} ===")
    print(
        f"kpi_rows={s['kpi_rows']}  "
        f"DL@RU: U={s['dl_u_plane_pkts']} C={s['dl_c_plane_pkts']} "
        f"C_UL={s['ul_c_plane_pkts_at_ru']} rx_total={s['dl_rx_total']}  "
        f"UL@RU tx_total={s['ul_tx_total']}  [MEASURED]"
    )
    print(
        f"late@RU DL: U={s['late_dl_u_at_ru']} C={s['late_dl_c_at_ru']} "
        f"C_UL={s['late_ul_c_at_ru']} sum={s['late_dl_sum_at_ru']}  "
        f"drop={s['drop_at_ru']}  [MEASURED]"
    )
    print(
        f"late_rate@RU DL-only: {s['late_per_M_dl']:.4f}/M  frac={s['late_frac_dl']:.3e}; "
        f"all-pkts (RX+TX): {s['late_per_M_all']:.4f}/M  frac={s['late_frac_all']:.3e}  [MEASURED]"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--du-log", required=True)
    ap.add_argument("--ru-log", required=True)
    ap.add_argument("--secs", type=float, default=60.0)
    ap.add_argument("--warmup", type=int, default=-1, help="-1=auto, 0=none, else seconds")
    ap.add_argument("--json-out", default="")
    ap.add_argument("--hist-out", default="")
    ap.add_argument("--late-frac-limit", type=float, default=LATE_FRAC_LIMIT)
    args = ap.parse_args()

    du = Path(args.du_log).read_text(errors="replace")
    ru = Path(args.ru_log).read_text(errors="replace")
    rows = parse_kpi(ru)
    hist = late_per_second(rows)
    du_ofh = parse_du_ofh(du)

    if args.warmup < 0:
        warm, warm_note = detect_warmup(hist, args.secs)
    else:
        warm = args.warmup
        warm_note = f"warm-up forced={warm}s"

    t0 = rows[0]["t_s"] if rows else 0
    post = [r for r in rows if ((r["t_s"] - t0) % 86400) >= warm] if warm else rows
    full = summarize_window(rows, "FULL WINDOW (incl. warm-up)")
    gated = summarize_window(post, f"GATE WINDOW (after warm-up={warm}s)")

    print("=== ProtO-RU KPI / direction ===")
    print_summary(full)
    print(warm_note)
    print_summary(gated)

    print("=== UL at DU (OFH RX from RU) ===")
    print(
        f"ofh_metric_samples={du_ofh['ofh_metric_samples']} "
        f"ul_rx_total={du_ofh['ul_rx_total']} ul_rx_late={du_ofh['ul_rx_late']} "
        f"ul_past_seq_drops={du_ofh['ul_past_seq_drops']}  [MEASURED]"
    )
    if du_ofh["ul_rx_total"] > 0:
        print(
            f"late_rate@DU UL: {rate_per_million(du_ofh['ul_rx_late'], du_ofh['ul_rx_total']):.4f} "
            f"per million UL packets  [MEASURED]"
        )
    print(
        f"du tx_kpis late: dl_rgs={du_ofh['nof_late_dl_rgs']} ul_req={du_ofh['nof_late_ul_req']} "
        f"cp_dl={du_ofh['nof_late_cp_dl']} up_dl={du_ofh['nof_late_up_dl']} "
        f"cp_ul={du_ofh['nof_late_cp_ul']}  [MEASURED]"
    )

    print("=== Per-second late histogram @RU (rel_s: late_up/c/c_u/sum) ===")
    nonzero = [h for h in hist if h[4] > 0]
    if not nonzero:
        print("(no late seconds)")
    else:
        for rel, up, c, cu, sm in nonzero:
            marker = " <warm-up" if rel < warm else ""
            print(f"  t+{rel:4d}s: up={up} c={c} c_u={cu} sum={sm}{marker}")
        # Compact 0/nonzero map for first min
        first_n = min(int(args.secs) + 1, 120)
        bits = []
        late_map = {h[0]: h[4] for h in hist}
        for i in range(first_n):
            bits.append(str(late_map.get(i, 0)))
        print(f"first_{first_n}s_late_counts=[{','.join(bits)}]")

    ok_slots, slot_msg = slots_advance_without_gaps(du)
    mac_reports = parse_mac_slot_reports(du)
    print("=== DU slot indication ===")
    print(f"mac_reports={len(mac_reports)} detail={slot_msg}")
    if mac_reports:
        print(f"first={mac_reports[0]} last={mac_reports[-1]}")

    ofh_up = (
        "Open Fronthaul" in du
        or "Initializing the Open Fronthaul" in du
        or "Started the operation of the Open Fronthaul" in du
    )

    hard_fail = False

    if not rows:
        print("FAIL: no ProtO-RU KPI rows parsed")
        hard_fail = True
    if full["dl_rx_total"] == 0 and full["ul_tx_total"] == 0:
        print("FAIL: ProtO-RU saw no OFH traffic")
        hard_fail = True
    if not ok_slots:
        print(f"FAIL: slot indication not proven ({slot_msg})")
        hard_fail = True
    if not ofh_up:
        print("FAIL: DU OFH init string not found")
        hard_fail = True

    drop = gated["drop_at_ru"]
    late = gated["late_dl_sum_at_ru"]
    pkts = gated["all_pkts"]
    frac = gated["late_frac_all"]

    if drop > 0:
        print(f"FAIL: non-zero RX_ERR_DROP after warm-up: drop={drop}  [MEASURED]")
        hard_fail = True
    elif pkts > 0 and frac >= args.late_frac_limit:
        print(
            f"FAIL: late frac {frac:.3e} >= limit {args.late_frac_limit:.1e} "
            f"after warm-up={warm}s (late={late} all_pkts={pkts})  [MEASURED]"
        )
        hard_fail = True
    elif late > 0:
        print(
            f"PASS with provisional threshold: late={late} frac={frac:.3e} "
            f"< {args.late_frac_limit:.1e} after warm-up={warm}s "
            f"(all_pkts={pkts}); drop=0  [MEASURED]"
        )
    else:
        print(f"PASS: zero late/drop after warm-up={warm}s")

    payload = {
        "secs": args.secs,
        "warmup_s": warm,
        "warmup_note": warm_note,
        "late_frac_limit": args.late_frac_limit,
        "full": full,
        "gate": gated,
        "du_ofh": du_ofh,
        "hist_nonzero": [
            {"rel_s": h[0], "late_up": h[1], "late_c": h[2], "late_c_u": h[3], "late_sum": h[4]}
            for h in nonzero
        ],
        "slot_ok": ok_slots,
        "slot_msg": slot_msg,
    }
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n")
    if args.hist_out:
        lines = ["rel_s,late_up,late_c,late_c_u,late_sum,in_warmup"]
        for h in hist:
            lines.append(f"{h[0]},{h[1]},{h[2]},{h[3]},{h[4]},{1 if h[0] < warm else 0}")
        Path(args.hist_out).write_text("\n".join(lines) + "\n")

    if hard_fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
