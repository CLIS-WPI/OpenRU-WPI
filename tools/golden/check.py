#!/usr/bin/env python3
"""Permanent golden validity checks.

The expected content is the downlink User-Plane the live O-DU actually sent in the window (recorded by
tools/golden/window.py as expected_uplane_slots). A golden or fresh replay dump is valid only if:
  1. the dump starts at the window's wire DU slot (start_du),
  2. every expected slot has non-zero energy on every TX port,
  3. no energy leaks into uplink-only slots of the profile's TDD pattern,
  4. the non-empty set matches the expected set within the stated tolerance.

Exit status: 0 pass, 1 fail, 2 usage/parse error.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

import numpy as np

from ofh_scan import OFH_PERIOD, SLOTS_PER_FRAME


def load_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path and path.exists() else {}


def load_tx_index(dump: Path) -> dict[tuple[int, int], dict]:
    out: dict[tuple[int, int], dict] = {}
    p = dump / "tx_index.jsonl"
    if not p.exists():
        return out
    for line in p.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "du_sfn" in d and "du_slot" in d:
            out[(int(d["du_sfn"]), int(d["du_slot"]))] = d
    return out


def parse_tdd(du_config: Path) -> dict:
    text = du_config.read_text()

    def get(key: str, default: int) -> int:
        m = re.search(rf"^\s*{key}\s*:\s*(\d+)", text, re.MULTILINE)
        return int(m.group(1)) if m else default

    period = get("dl_ul_tx_period", 0)
    dl_slots = get("nof_dl_slots", 0)
    dl_symbols = get("nof_dl_symbols", 0)
    special = 1 if (period > 0 and dl_symbols > 0 and dl_symbols < 14) else 0
    ul_only = list(range(dl_slots + special, period)) if period > 0 else []
    return {
        "dl_ul_tx_period": period,
        "nof_dl_slots": dl_slots,
        "nof_dl_symbols": dl_symbols,
        "special_slot": dl_slots if special else -1,
        "ul_only_slot_indices": ul_only,
    }


def slot_energy(memmaps: dict[int, np.ndarray], entry: dict, ports: list[int]) -> dict[int, float]:
    off = int(entry.get("symbol0_sample_offset", 0))
    n = int(entry.get("nof_samples", 0))
    out = {}
    for p in ports:
        chunk = memmaps[p][off * 2 : (off + n) * 2] if n > 0 and p in memmaps else np.empty(0)
        out[p] = float(np.max(np.abs(chunk))) if chunk.size else 0.0
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump", required=True, type=Path)
    ap.add_argument("--window-json", required=True, type=Path)
    ap.add_argument("--du-config", required=True, type=Path)
    ap.add_argument("--tolerance-frac", type=float, default=0.02)
    ap.add_argument("--tolerance-slots", type=int, default=2)
    ap.add_argument("--min-abs", type=float, default=1e-9)
    ap.add_argument("--out", default=None, type=Path)
    args = ap.parse_args()

    win = load_json(args.window_json)
    start_du = int(win.get("start_du", -1))
    window_slots = int(win.get("window_slots", -1))
    expected = sorted(int(v) for v in win.get("expected_uplane_slots", []))
    if start_du < 0 or window_slots <= 0:
        print("golden-check: ERROR window json missing start_du/window_slots", file=sys.stderr)
        return 2
    if window_slots > OFH_PERIOD:
        print(f"golden-check: ERROR window {window_slots} > {OFH_PERIOD} slots makes wire slots ambiguous", file=sys.stderr)
        return 2
    if not expected:
        print("golden-check: ERROR window json has no expected_uplane_slots (recapture with dl u-plane)", file=sys.stderr)
        return 2

    meta = load_json(args.dump / "iq_meta.json")
    tx = load_tx_index(args.dump)
    if not tx:
        print(f"golden-check: FAIL no tx_index.jsonl in {args.dump}", file=sys.stderr)
        return 1

    first_key = min(tx)
    dump_first_slot = first_key[0] * SLOTS_PER_FRAME + first_key[1]

    port_files = sorted(args.dump.glob("port*.cf32"))
    if not port_files:
        print(f"golden-check: FAIL no port*.cf32 in {args.dump}", file=sys.stderr)
        return 1
    memmaps = {i: np.memmap(p, dtype=np.float32, mode="r") for i, p in enumerate(port_files)}
    expected_ports = [int(p) for p in win.get("expected_ports", [])] or sorted(memmaps)
    bad_ports = [p for p in expected_ports if p not in memmaps]
    if bad_ports:
        print(f"golden-check: FAIL expected ports {bad_ports} but only {sorted(memmaps)} dumped", file=sys.stderr)
        return 1

    tdd = parse_tdd(args.du_config)
    period = tdd["dl_ul_tx_period"]

    def offset_of(key: tuple[int, int]) -> int:
        return ((key[0] * SLOTS_PER_FRAME + key[1]) - start_du) % OFH_PERIOD

    tx = {k: v for k, v in tx.items() if offset_of(k) < window_slots}
    observed = sorted({offset_of(k) for k, v in tx.items() if not v.get("is_empty", True)})

    zero_energy = []
    ul_leaks = []
    for off in expected:
        sfx, sl = divmod((start_du + off) % OFH_PERIOD, SLOTS_PER_FRAME)
        entry = tx.get((sfx, sl))
        if not entry or entry.get("is_empty", True):
            continue
        energies = slot_energy(memmaps, entry, expected_ports)
        if any(e <= args.min_abs for e in energies.values()):
            zero_energy.append({"slot": [sfx, sl], "port_max_abs": energies})
    for off in observed:
        sfx, sl = divmod((start_du + off) % OFH_PERIOD, SLOTS_PER_FRAME)
        if period > 0 and (sl % period) in tdd["ul_only_slot_indices"]:
            ul_leaks.append([sfx, sl])

    exp_set, obs_set = set(expected), set(observed)
    missing = sorted(exp_set - obs_set)
    extra = sorted(obs_set - exp_set)
    tol = max(args.tolerance_slots, math.ceil(args.tolerance_frac * len(expected)))

    problems = []
    if dump_first_slot % OFH_PERIOD != start_du % OFH_PERIOD:
        problems.append(f"dump starts at DU slot {dump_first_slot % OFH_PERIOD}, window starts at {start_du % OFH_PERIOD}")
    if missing:
        problems.append(f"{len(missing)} expected slots have no User-Plane (e.g. offsets {missing[:5]})")
    if zero_energy:
        problems.append(f"{len(zero_energy)} expected slots have a zero-energy port (e.g. {zero_energy[:3]})")
    if ul_leaks:
        problems.append(f"{len(ul_leaks)} non-empty slots fall in uplink-only positions (e.g. {ul_leaks[:5]})")
    if len(missing) + len(extra) > tol:
        problems.append(
            f"non-empty slots {len(observed)} vs expected {len(expected)} "
            f"(missing {len(missing)}, extra {len(extra)}, tolerance +/-{tol})"
        )

    summary = {
        "dump": str(args.dump),
        "pcap": win.get("pcap", ""),
        "start_du": start_du,
        "window_slots": window_slots,
        "expected_slots": len(expected),
        "nonempty_slots": len(observed),
        "missing": missing[:200],
        "extra": extra[:200],
        "tolerance_slots": tol,
        "tolerance_frac": args.tolerance_frac,
        "ports": [str(p) for p in port_files],
        "expected_ports": expected_ports,
        "tdd": tdd,
        "zero_energy": zero_energy[:50],
        "ul_leaks": ul_leaks[:50],
        "pass": not problems,
    }
    if args.out:
        args.out.write_text(json.dumps(summary, indent=2) + "\n")

    if problems:
        for p in problems:
            print(f"golden-check: FAIL {p}", file=sys.stderr)
        return 1
    print(
        f"golden-check: PASS {args.dump.name}: {len(observed)}/{len(expected)} expected DL slots non-empty "
        f"(+/-{tol}), all ports non-zero, no UL leakage"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
