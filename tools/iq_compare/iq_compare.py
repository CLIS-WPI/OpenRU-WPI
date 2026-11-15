#!/usr/bin/env python3
"""Compare two .cf32 IQ dumps, aligning by DU slot via iq_meta.json.

The DUT and golden dumps may start at different DU slots (cold-start GPS/OFH offset).
This tool reads the first/last DU SFN/slot of each dump, compares only the
overlapping DU slot range, reports the slot offset, and fails if the overlap is
smaller than --min-overlap-slots (default: the full golden slot range).

Exit non-zero if the overlap is too short or if max abs error exceeds --threshold
(default 0 for bit-exact).
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Optional

import numpy as np

PERIOD_FRAMES = 256


def load_cf32(path: Path) -> np.ndarray:
    raw = np.fromfile(path, dtype=np.float32)
    if raw.size % 2:
        raw = raw[:-1]
    return raw.reshape(-1, 2).view(np.complex64).ravel()


def load_meta(dir_or_file: Path) -> dict:
    p = dir_or_file / "iq_meta.json" if dir_or_file.is_dir() else dir_or_file
    if p.exists():
        return json.loads(p.read_text())
    return {}


def load_tx_index(dir_path: Path) -> dict[tuple[int, int], tuple[int, int]]:
    """Map (du_sfn, du_slot) -> (file_sample_offset, nof_samples).

    The last line of a capped dump can be truncated; skip lines that do not parse.
    """
    p = dir_path / "tx_index.jsonl"
    out: dict[tuple[int, int], tuple[int, int]] = {}
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
            out[(int(d["du_sfn"]), int(d["du_slot"]))] = (
                int(d.get("symbol0_sample_offset", 0)),
                int(d.get("nof_samples", 0)),
            )
    return out


def shortest_offset(delta: int, period: int) -> int:
    """Wrap a slot difference to [-period/2, period/2)."""
    return ((delta + period // 2) % period) - period // 2


def slot_key(abs_slot: int, spf: int, sfn_mod: int) -> tuple[int, int]:
    return ((abs_slot // spf) % sfn_mod, abs_slot % spf)


def advance_key(key: tuple[int, int], n: int, spf: int, sfn_mod: int) -> tuple[int, int]:
    return slot_key(key[0] * spf + key[1] + n, spf, sfn_mod)


class DuRange:
    def __init__(self, meta: dict, manifest: dict, first: tuple[int, int], last: tuple[int, int],
                 n_slots: int, sps: int, spf: int, sfn_mod: int, first_sample_offset: int):
        self.meta = meta
        self.manifest = manifest
        self.first = first
        self.last = last
        self.n_slots = n_slots
        self.sps = sps
        self.spf = spf
        self.sfn_mod = sfn_mod
        self.first_sample_offset = first_sample_offset

    @property
    def first_abs(self) -> int:
        return self.first[0] * self.spf + self.first[1]

    @property
    def last_abs(self) -> int:
        last = self.last[0] * self.spf + self.last[1]
        while last < self.first_abs:
            last += self.sfn_mod * self.spf
        return last

    @property
    def n_range(self) -> int:
        return self.last_abs - self.first_abs + 1


def du_range(dir_path: Path, meta: dict) -> Optional[DuRange]:
    """Read the DU slot range. Prefer iq_meta.json; fall back to MANIFEST.json/tx_index.jsonl."""
    dump = meta.get("dump") or {}
    sg = meta.get("slot_grid") or {}
    sps = int(sg.get("samples_per_slot") or 0)
    spf = int(sg.get("slots_per_frame") or 20)
    sfn_mod = int(sg.get("ofh_sfn_mod") or PERIOD_FRAMES)
    n_slots = int(dump.get("slots_written") or 0)
    if sps <= 0 or n_slots <= 0:
        return None

    manifest: dict = {}
    mp = dir_path / "MANIFEST.json"
    if mp.exists():
        manifest = json.loads(mp.read_text())

    def first_last_from(src: dict) -> tuple[Optional[tuple[int, int]], Optional[tuple[int, int]]]:
        first = last = None
        if "first_du_sfn" in src and "first_du_slot" in src:
            first = (int(src["first_du_sfn"]), int(src["first_du_slot"]))
        if "last_du_sfn" in src and "last_du_slot" in src:
            last = (int(src["last_du_sfn"]), int(src["last_du_slot"]))
        return first, last

    first, last = first_last_from(dump)
    if first is None or last is None:
        mfirst, mlast = first_last_from(manifest)
        if first is None and mfirst is not None:
            first = mfirst
        if last is None and mlast is not None:
            last = mlast
    if last is None:
        return None
    if first is None:
        # No explicit first: derive it from the last slot and the written count.
        last_abs = last[0] * spf + last[1]
        first_abs = last_abs - (n_slots - 1)
        first = slot_key(first_abs, spf, sfn_mod)

    tx = load_tx_index(dir_path)
    first_sample_offset = int(dump.get("first_dump_sample_offset", -1))
    if first_sample_offset < 0:
        if first in tx:
            first_sample_offset = tx[first][0]
        else:
            first_sample_offset = 0

    return DuRange(meta, manifest, first, last, n_slots, sps, spf, sfn_mod, first_sample_offset)


def compare(a: np.ndarray, b: np.ndarray, threshold: float) -> dict:
    n = min(a.size, b.size)
    if n == 0:
        return {"n": 0, "max_abs": float("nan"), "rms_db": float("nan"), "first_diff": -1, "pass": False}
    aa, bb = a[:n], b[:n]
    err = np.abs(aa - bb)
    max_abs = float(err.max())
    first = int(np.argmax(err > threshold)) if max_abs > threshold else -1
    rms_err = float(np.sqrt(np.mean(np.abs(aa - bb) ** 2)))
    rms_ref = float(np.sqrt(np.mean(np.abs(bb) ** 2)))
    if rms_ref > 0 and rms_err > 0:
        rms_db = 20.0 * math.log10(rms_err / rms_ref)
    elif rms_err == 0:
        rms_db = float("-inf")
    else:
        rms_db = float("inf")
    return {"n": n, "max_abs": max_abs, "rms_db": rms_db, "first_diff": first, "pass": max_abs <= threshold}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dut", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--threshold", type=float, default=0.0)
    ap.add_argument("--by-slot", action="store_true", help="Report per DU slot using iq_meta.json")
    ap.add_argument("--min-overlap-slots", type=int, default=-1,
                    help="Minimum overlapping DU slots required; -1 (default) = full golden range")
    args = ap.parse_args()

    dut_p, gold_p = Path(args.dut), Path(args.golden)
    pairs: list[tuple[Path, Path]] = []
    meta_dut: dict = {}
    meta_gold: dict = {}
    if dut_p.is_dir() and gold_p.is_dir():
        for g in sorted(gold_p.glob("port*.cf32")):
            d = dut_p / g.name
            if not d.exists():
                print(f"FAIL: missing DUT {d}")
                return 1
            pairs.append((d, g))
        meta_gold = load_meta(gold_p)
        meta_dut = load_meta(dut_p)
        if not pairs:
            print(f"FAIL: no port*.cf32 under golden dir {gold_p}")
            return 1
    else:
        pairs.append((dut_p, gold_p))

    if not (meta_dut and meta_gold):
        # Raw file compare: no DU alignment possible.
        ok = True
        for d, g in pairs:
            da, ga = load_cf32(d), load_cf32(g)
            r = compare(da, ga, args.threshold)
            print(
                f"{d.name}: n={r['n']} max_abs={r['max_abs']:.6g} "
                f"rms_db={r['rms_db']:.3f} first_diff={r['first_diff']} "
                f"{'PASS' if r['pass'] else 'FAIL'} (no iq_meta.json: raw compare)"
            )
            ok = ok and r["pass"]
        return 0 if ok else 1

    rg = du_range(gold_p, meta_gold)
    rd = du_range(dut_p, meta_dut)
    if rg is None or rd is None:
        print(
            "FAIL: iq_meta.json lacks a usable DU slot range "
            "(need slot_grid.samples_per_slot and dump.last_du_sfn/slot); "
            "refusing an unaligned compare"
        )
        return 1
    if rg.sps != rd.sps:
        print(f"FAIL: samples_per_slot differs golden={rg.sps} dut={rd.sps}")
        return 1

    period = rg.sfn_mod * rg.spf
    offset = shortest_offset(rd.first_abs - rg.first_abs, period)
    dut_first_adj = rg.first_abs + offset
    dut_last_adj = dut_first_adj + (rd.last_abs - rd.first_abs)
    lo = max(rg.first_abs, dut_first_adj)
    hi = min(rg.last_abs, dut_last_adj)
    overlap = max(0, hi - lo + 1)

    min_overlap = args.min_overlap_slots
    if min_overlap < 0:
        min_overlap = rg.n_range

    print(
        f"du_align: offset={offset} slots ({offset * rg.sps} samples) "
        f"golden=[{rg.first[0]}.{rg.first[1]}..{rg.last[0]}.{rg.last[1]}] "
        f"({rg.n_range} slots) dut=[{rd.first[0]}.{rd.first[1]}..{rd.last[0]}.{rd.last[1]}] "
        f"({rd.n_range} slots)"
    )
    print(f"du_overlap: {overlap} slots (min required {min_overlap}) lo={slot_key(lo, rg.spf, rg.sfn_mod)}")
    if overlap < min_overlap:
        print(
            f"FAIL: DU slot overlap {overlap} < required {min_overlap} — "
            f"dump shorter than the golden range; refusing to pass on a partial compare"
        )
        return 1
    if overlap <= 0:
        print("FAIL: no overlapping DU slots")
        return 1

    gold_tx = load_tx_index(gold_p)
    dut_tx = load_tx_index(dut_p)

    def sample_range(tx: dict, key: tuple[int, int], idx: int, first_off: int, sps: int,
                     size: int) -> tuple[int, int]:
        off, n = tx.get(key, (first_off + idx * sps, sps))
        if n <= 0:
            n = sps
        off = max(0, off)
        n = min(n, max(0, size - off))
        return off, n

    ok = True
    for d, g in pairs:
        da, ga = load_cf32(d), load_cf32(g)
        differing_slots: list[str] = []
        total_n = 0
        max_abs = 0.0
        sum_err2 = 0.0
        sum_ref2 = 0.0
        first_diff = -1
        checked = 0
        for s in range(lo, hi + 1):
            key = slot_key(s, rg.spf, rg.sfn_mod)
            g_idx = s - rg.first_abs
            d_idx = s - dut_first_adj
            g_off, g_n = sample_range(gold_tx, key, g_idx, rg.first_sample_offset, rg.sps, ga.size)
            d_off, d_n = sample_range(dut_tx, key, d_idx, rd.first_sample_offset, rd.sps, da.size)
            n = min(g_n, d_n)
            if n <= 0:
                print(f"FAIL: {d.name} DU slot {key[0]}.{key[1]} has no comparable samples "
                      f"(golden off={g_off} n={g_n}, dut off={d_off} n={d_n})")
                ok = False
                continue
            r = compare(da[d_off:d_off + n], ga[g_off:g_off + n], args.threshold)
            checked += 1
            total_n += n
            if not r["pass"]:
                ok = False
                msg = (f"{d.name} DU slot {key[0]}.{key[1]} max_abs={r['max_abs']:.6g} "
                       f"first={r['first_diff']}")
                differing_slots.append(msg)
                print(f"DIFF: {msg}")
            if r["n"]:
                max_abs = max(max_abs, r["max_abs"])
                err = np.abs(da[d_off:d_off + n] - ga[g_off:g_off + n])
                sum_err2 += float(np.sum(err ** 2))
                sum_ref2 += float(np.sum(np.abs(ga[g_off:g_off + n]) ** 2))
                if first_diff < 0 and r["first_diff"] >= 0:
                    first_diff = total_n - n + r["first_diff"]

        if differing_slots:
            print(f"FAIL: {len(differing_slots)} differing DU slots — do not generate golden until resolved")
        elif args.by_slot:
            print(f"{d.name}: all {checked} overlapping DU slots PASS (n={total_n})")
        else:
            if total_n and sum_ref2 > 0 and sum_err2 > 0:
                rms_db = 10.0 * math.log10(sum_err2 / sum_ref2)
            elif sum_err2 == 0:
                rms_db = float("-inf")
            else:
                rms_db = float("inf")
            passed = max_abs <= args.threshold
            ok = ok and passed
            print(
                f"{d.name}: n={total_n} max_abs={max_abs:.6g} rms_db={rms_db:.3f} "
                f"first_diff={first_diff} {'PASS' if passed else 'FAIL'}"
            )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
