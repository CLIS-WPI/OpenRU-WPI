#!/usr/bin/env python3
"""Shared U-plane rate check for suites that measure fronthaul rates.

Compares the measured per-second frame rates (from a parse_smoke_fh.py KPI JSON)
against the expected rates for the profile, derived from the profile TDD /
eAxC configuration and the golden pcap (see docs/reports/V1_SMOKE.md and
docs/reports/raw/m1-quiet/). Rates:

  dl_u_plane: one section per DL symbol per port   ~6,785/s (baseline TDD, 2 ports)
  dl_c_plane: per-slot DL C-plane (2 ports)        ~513/s
  ul_c_plane: UL data C-plane 1,600/s + PRACH 200/s 1,800/s

Tolerance default +-2% (the KPI one-second buckets explain ~+1%; V1_SMOKE).

Usage:
  uplane_rate.py --kpi kpi.json --expected expected.json [--tolerance 0.02] [--out out.json]
Exit 0 pass, 1 fail, 2 usage error.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def check(kpi: dict, expected: dict, tolerance: float) -> tuple[bool, list[dict], dict]:
    full = kpi.get("full") or {}
    # The KPI window is 1 Hz rows; the nominal --secs can be shorter than the
    # parsed log window (settle + first-RX wait add rows), so the KPI row count
    # is the honest denominator for rates.
    secs = float(full.get("kpi_rows") or 0) or float(kpi.get("secs") or 0)
    measured = {
        "dl_u_plane_per_s": (full.get("dl_u_plane_pkts") or 0) / secs if secs else None,
        "dl_c_plane_per_s": (full.get("dl_c_plane_pkts") or 0) / secs if secs else None,
        "ul_c_plane_at_ru_per_s": (full.get("ul_c_plane_pkts_at_ru") or 0) / secs if secs else None,
    }
    results = []
    ok = True
    for key, m in measured.items():
        if key not in expected:
            results.append({"rate": key, "status": "NOT_CONFIGURED"})
            continue
        exp = float(expected[key])
        if m is None:
            results.append({"rate": key, "status": "MISSING_MEASUREMENT", "expected_per_s": exp})
            ok = False
            continue
        delta = (m - exp) / exp if exp else float("inf")
        passed = abs(delta) <= tolerance
        ok = ok and passed
        results.append(
            {
                "rate": key,
                "status": "PASS" if passed else "FAIL",
                "measured_per_s": round(m, 2),
                "expected_per_s": exp,
                "delta_frac": round(delta, 4),
                "tolerance": tolerance,
            }
        )
    return ok, results, measured


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kpi", required=True, help="parse_smoke_fh.py --json-out file")
    ap.add_argument("--expected", required=True, help="expected-rate JSON for the suite profile")
    ap.add_argument("--tolerance", type=float, default=0.02)
    ap.add_argument("--out", help="write the rate check result here")
    args = ap.parse_args()

    try:
        kpi = json.loads(Path(args.kpi).read_text())
        expected = json.loads(Path(args.expected).read_text())
    except Exception as exc:
        print(f"uplane-rate: ERROR {exc}", file=sys.stderr)
        return 2

    ok, results, measured = check(kpi, expected, args.tolerance)
    payload = {"pass": ok, "tolerance": args.tolerance, "rates": results}
    if args.out:
        Path(args.out).write_text(json.dumps(payload, indent=2) + "\n")
    for r in results:
        print(f"uplane-rate: {r['rate']}: {r['status']}"
              + (f" measured={r['measured_per_s']}/s expected={r['expected_per_s']}/s delta={r['delta_frac']:+.2%}"
                 if "measured_per_s" in r else ""))
    print(f"uplane-rate: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
