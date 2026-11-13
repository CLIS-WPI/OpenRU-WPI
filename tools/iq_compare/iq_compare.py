#!/usr/bin/env python3
"""Compare two .cf32 IQ dumps (per port).

Reports max abs error, RMS error in dB vs golden, and first differing sample index.
Exit non-zero if max abs error exceeds --threshold (default 0 for bit-exact).
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np


def load_cf32(path: Path) -> np.ndarray:
    raw = np.fromfile(path, dtype=np.float32)
    if raw.size % 2:
        raw = raw[:-1]
    return raw.reshape(-1, 2).view(np.complex64).ravel()


def compare(a: np.ndarray, b: np.ndarray, threshold: float) -> dict:
    n = min(a.size, b.size)
    if n == 0:
        return {"n": 0, "max_abs": float("nan"), "rms_db": float("nan"), "first_diff": -1, "pass": False}
    aa, bb = a[:n], b[:n]
    err = np.abs(aa - bb)
    max_abs = float(err.max())
    first = int(np.argmax(err > 0)) if max_abs > 0 else -1
    if first >= 0 and err[first] == 0:
        first = -1
    # EVM-style: 20*log10(rms(err)/rms(golden))
    rms_err = float(np.sqrt(np.mean(np.abs(aa - bb) ** 2)))
    rms_ref = float(np.sqrt(np.mean(np.abs(bb) ** 2)))
    if rms_ref > 0 and rms_err > 0:
        rms_db = 20.0 * math.log10(rms_err / rms_ref)
    elif rms_err == 0:
        rms_db = float("-inf")
    else:
        rms_db = float("inf")
    return {
        "n": n,
        "max_abs": max_abs,
        "rms_db": rms_db,
        "first_diff": first if max_abs > 0 else -1,
        "pass": max_abs <= threshold,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dut", required=True, help="DUT .cf32 (or directory of port*.cf32)")
    ap.add_argument("--golden", required=True, help="Golden .cf32 (or directory)")
    ap.add_argument("--threshold", type=float, default=0.0)
    args = ap.parse_args()

    dut_p, gold_p = Path(args.dut), Path(args.golden)
    pairs: list[tuple[Path, Path]] = []
    if dut_p.is_dir() and gold_p.is_dir():
        for g in sorted(gold_p.glob("port*.cf32")):
            d = dut_p / g.name
            if not d.exists():
                print(f"FAIL: missing DUT file {d}")
                return 1
            pairs.append((d, g))
    else:
        pairs.append((dut_p, gold_p))

    ok = True
    for d, g in pairs:
        r = compare(load_cf32(d), load_cf32(g), args.threshold)
        print(
            f"{d.name}: n={r['n']} max_abs={r['max_abs']:.6g} "
            f"rms_db={r['rms_db']:.3f} first_diff={r['first_diff']} "
            f"{'PASS' if r['pass'] else 'FAIL'}"
        )
        ok = ok and r["pass"]
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
