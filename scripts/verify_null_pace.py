#!/usr/bin/env python3
"""Verify null-radio read_current_time()/srate tracks wall clock within one slot over ~60s.

Expects a log line series or a CSV of (wall_s, radio_ts). For container runs, parse
ru_emulator / RADIO logs if instrumented; otherwise accept --samples file:
  wall_unix_s,radio_ts
"""
from __future__ import annotations

import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True, help="CSV wall_unix_s,radio_ts")
    ap.add_argument("--srate", type=float, default=23.04e6)
    ap.add_argument("--slot-samples", type=int, default=11520)  # 23.04e6/2000
    args = ap.parse_args()

    rows = []
    with open(args.samples) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            w, t = line.split(",")[:2]
            rows.append((float(w), int(float(t))))
    if len(rows) < 2:
        print("FAIL: need >=2 samples")
        return 1

    w0, t0 = rows[0]
    drifts = []
    for w, t in rows[1:]:
        wall_dt = w - w0
        radio_dt = (t - t0) / args.srate
        drifts.append(radio_dt - wall_dt)
    max_abs = max(abs(d) for d in drifts)
    slot_s = args.slot_samples / args.srate
    print(f"samples={len(rows)} max_|drift|={max_abs:.6f}s slot={slot_s:.6f}s  [MEASURED]")
    if max_abs <= slot_s:
        print("PASS: drift within one slot")
        return 0
    print("FAIL: drift exceeds one slot")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
