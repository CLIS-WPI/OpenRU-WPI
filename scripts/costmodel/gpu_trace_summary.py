#!/usr/bin/env python3
"""Summarize an nvidia-smi --query-gpu CSV trace (clocks, power, pstate)."""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def numbers(rows, column):
    out = []
    for row in rows:
        value = row.get(column, "")
        for token in value.replace("MHz", "").replace("W", "").replace("%", "").split():
            try:
                out.append(float(token))
                break
            except ValueError:
                continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    lines = [line for line in args.trace.read_text(errors="replace").splitlines() if line.strip()]
    if not lines:
        args.out.write_text(json.dumps({"error": "empty trace"}, indent=2) + "\n")
        return 1
    header = [h.strip() for h in lines[0].split(",")]
    rows = []
    for line in lines[1:]:
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < len(header):
            continue
        rows.append(dict(zip(header, parts)))

    summary = {"samples": len(rows), "columns": header}
    for key in ("clocks.current.sm [MHz]", "clocks.current.memory [MHz]", "power.draw [W]", "power.limit [W]"):
        values = numbers(rows, key)
        if values:
            summary[key] = {
                "min": min(values),
                "median": statistics.median(values),
                "max": max(values),
            }
    for key in ("pstate", "clocks_event_reasons.active"):
        vals = sorted({row.get(key, "") for row in rows if row.get(key)})
        if vals:
            summary[key] = vals
    args.out.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
