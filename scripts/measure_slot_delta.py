#!/usr/bin/env python3
"""Measure DU↔RU OFH slot residual Δ from smoke-fh logs.

Δ sources (file:line):
  DU: apps/units/.../mac_metrics_consumers.cpp:37
      \"MAC cell pci={} metrics: slots=[{start}, {end})\" — use window END.
  RU: apps/examples/ofh/ru_emulator_tti_orchestrator.cpp:161
      \"(slot={} ofh={})\" — use ofh (GPS/OFH wire slot after aligner).

Method: pair by wall-clock; advance RU ofh by round(dt*2000) to the DU log
timestamp; compare abs_slot(DU_end.sfn%256, DU_end.slot) vs RU ofh mod 5120
(OFH period = 256 frames × 20 slots @ 30 kHz). Report median Δ.
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

PERIOD = 5120  # 256 * 20 @ 30 kHz


def parse_ts(line: str):
    m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)", line)
    return datetime.fromisoformat(m.group(1)) if m else None


def abs_slot(sfn: int, slot: int) -> int:
    return sfn * 20 + slot


def wrap(x: int) -> int:
    return ((x + PERIOD // 2) % PERIOD) - PERIOD // 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--du-log", required=True)
    ap.add_argument("--ru-log", required=True)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    du_re = re.compile(r"MAC cell.*slots=\[(\d+)\.(\d+), (\d+)\.(\d+)")
    ru_re = re.compile(
        r"TTI orchestrator alive:.*\(slot=(\d+)\.(\d+) ofh=(\d+)\.(\d+)\)"
    )

    du_pts = []
    for line in Path(args.du_log).read_text(errors="replace").splitlines():
        ts, m = parse_ts(line), du_re.search(line)
        if ts and m:
            # END of half-open window [start, end)
            du_pts.append((ts, int(m.group(3)), int(m.group(4))))

    ru_pts = []
    align_ts = None
    gps_offset = None
    for line in Path(args.ru_log).read_text(errors="replace").splitlines():
        ts = parse_ts(line)
        if ts and "Aligned the radio slot numbering" in line:
            align_ts = ts
            om = re.search(r"offset '(\d+)'", line)
            gps_offset = int(om.group(1)) if om else None
        m = ru_re.search(line)
        if ts and m:
            ru_pts.append((ts, int(m.group(3)), int(m.group(4))))  # ofh

    diffs = []
    for ts, ds, dsl in du_pts:
        if align_ts and ts < align_ts:
            continue
        if not ru_pts:
            continue
        best = min(ru_pts, key=lambda r: abs((r[0] - ts).total_seconds()))
        dt = (ts - best[0]).total_seconds()
        ru_abs = (abs_slot(best[1], best[2]) + int(round(dt * 2000))) % PERIOD
        du_abs = abs_slot(ds % 256, dsl) % PERIOD
        diffs.append(wrap(du_abs - ru_abs))

    if not diffs:
        print(f"FAIL {args.label}: no paired samples")
        return 1
    sd = sorted(diffs)
    med = sd[len(sd) // 2]
    not_m8 = [d for d in diffs if d != -8]
    print(
        f"DELTA {args.label}: n={len(diffs)} min={min(diffs)} median={med} max={max(diffs)} "
        f"set={sorted(set(diffs))} gps_offset={gps_offset}  [MEASURED]"
    )
    if not_m8:
        print(f"  not_-8: {len(not_m8)}/{len(diffs)} (settle/wrap outliers; median is the applied mapping)")
    print(f"  DU line: mac_metrics_consumers.cpp:37  slots=[start, END)")
    print(f"  RU line: ru_emulator_tti_orchestrator.cpp:161  ofh=SFN.slot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
