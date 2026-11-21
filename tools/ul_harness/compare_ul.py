#!/usr/bin/env python3
"""Compare decoded UL RE grids with the injected known answer."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np


def load(path: Path):
    d = np.load(path)
    return {k: d[k] for k in d.files}


def compare(exp, cap, max_rel_threshold=1e-3, evm_db_threshold=-35.0):
    if not np.array_equal(exp["sfn"], cap.get("sfn", exp["sfn"])) or \
       not np.array_equal(exp["slot"], cap.get("slot", exp["slot"])):
        return False, "slot mismatch", {}
    e = exp["grid"].astype(np.complex128)
    c = cap["grid"].astype(np.complex128)
    if e.shape != c.shape:
        return False, f"shape {c.shape} != {e.shape}", {}
    alpha = np.vdot(e, c) / np.vdot(e, e)
    residual = c - alpha * e
    denom = float(np.sum(np.abs(c) ** 2))
    num = float(np.sum(np.abs(residual) ** 2))
    evm_db = 10 * np.log10(num / denom) if num > 0 and denom > 0 else -300.0
    max_rel = float(np.max(np.abs(residual)) / (np.max(np.abs(e)) or 1.0))
    ok = bool(evm_db <= evm_db_threshold and max_rel <= max_rel_threshold)
    return ok, "ok" if ok else "IQ tolerance exceeded", {
        "evm_db": float(evm_db), "max_rel": max_rel, "alpha": [float(alpha.real), float(alpha.imag)],
        "max_rel_threshold": max_rel_threshold, "evm_db_threshold": evm_db_threshold,
    }


def corrupt(base, mode):
    cap = {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in base.items()}
    g = cap["grid"]
    if mode == "identity":
        pass
    elif mode == "re_bump":
        g[0, 0, 0, 0] += 0.05
    elif mode in ("slot_shift", "rx_skew"):
        cap["grid"] = np.roll(g, 1, axis=0)
        cap["sfn"] = np.roll(cap["sfn"], 1)
        cap["slot"] = np.roll(cap["slot"], 1)
    elif mode == "port_swap":
        g[..., [0, 1], :] = g[..., [1, 0], :]
    elif mode == "drop_symbol":
        g[0, 3, :, :] = 0
    elif mode == "drop_message":
        g[0, ...] = 0
    else:
        raise SystemExit(f"unknown corruption {mode}")
    return cap


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--expected", type=Path)
    ap.add_argument("--capture", type=Path)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--max-rel", type=float, default=1e-3)
    ap.add_argument("--evm-db", type=float, default=-35.0)
    args = ap.parse_args()

    if args.self_test:
        exp = load(args.expected)
        results = {}
        ok, why, stats = compare(exp, corrupt(exp, "identity"), args.max_rel, args.evm_db)
        results["identity"] = {"pass": ok, "why": why, **stats}
        failed_clean = not ok
        for mode in ("re_bump", "slot_shift", "port_swap", "drop_symbol", "drop_message", "rx_skew"):
            ok, why, stats = compare(exp, corrupt(exp, mode), args.max_rel, args.evm_db)
            results[mode] = {"pass": ok, "why": why, **stats}
            if ok:
                failed_clean = True
        out = {"self_test": True, "clean_pass": bool(results["identity"]["pass"]),
               "corruptions_failed": bool(all(not v["pass"] for k, v in results.items() if k != "identity")),
               "results": results}
        if args.out:
            args.out.write_text(json.dumps(out, indent=2) + "\n")
        print(json.dumps({k: {"pass": v["pass"], "why": v["why"]} for k, v in results.items()}, indent=2))
        return 0 if (results["identity"]["pass"] and out["corruptions_failed"]) else 1

    if not args.capture:
        raise SystemExit("--capture is required (decoded UL grid .npz)")
    exp, cap = load(args.expected), load(args.capture)
    ok, why, stats = compare(exp, cap, args.max_rel, args.evm_db)
    out = {"self_test": False, "pass": ok, "why": why, **stats}
    if args.out:
        args.out.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
