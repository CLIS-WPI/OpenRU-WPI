#!/usr/bin/env python3
"""Unit tests for iq_compare DU-slot alignment.

Run with:
    python3 -m unittest discover -s tools/iq_compare -p 'test_*.py' -v
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

TOOL = Path(__file__).with_name("iq_compare.py")
SPS = 4
SPF = 20
SFN_MOD = 256


def write_dump(root: Path, first: tuple[int, int], n_slots: int, values: dict[int, complex],
               ports: int = 1) -> Path:
    """Write a synthetic dump. Slot i uses file range [i*SPS, (i+1)*SPS)."""
    root.mkdir(parents=True, exist_ok=True)
    arr = np.empty(n_slots * SPS, dtype=np.complex64)
    for i in range(n_slots):
        arr[i * SPS:(i + 1) * SPS] = values[i]
    for p in range(ports):
        arr.astype(np.complex64).view(np.float32).tofile(root / f"port{p}.cf32")
    last_abs = (first[0] * SPF + first[1]) + n_slots - 1
    meta = {
        "sample_rate_Hz": SPS * 1000.0,
        "slot_grid": {"scs_kHz": 30, "samples_per_slot": SPS, "slots_per_frame": SPF,
                      "ofh_sfn_mod": SFN_MOD},
        "dump": {
            "slots_written": n_slots,
            "first_du_sfn": first[0],
            "first_du_slot": first[1],
            "last_du_sfn": (last_abs // SPF) % SFN_MOD,
            "last_du_slot": last_abs % SPF,
            "first_dump_sample_offset": 0,
        },
    }
    (root / "iq_meta.json").write_text(json.dumps(meta))
    return root


def run(dut: Path, golden: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(TOOL), "--dut", str(dut), "--golden", str(golden), *extra],
        capture_output=True, text=True,
    )


class DuAlignmentTests(unittest.TestCase):
    def test_one_slot_shift_pass(self) -> None:
        # Golden slots 10..13; DUT starts one slot earlier (9) with two extra slots.
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            gold = write_dump(base / "gold", (0, 10), 4, {i: complex(10 + i, 0) for i in range(4)})
            dut = write_dump(base / "dut", (0, 9), 6, {i: complex(9 + i, 0) for i in range(6)})
            r = run(dut, gold, "--by-slot", "--threshold", "0")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("offset=-1", r.stdout)
            self.assertIn("PASS", r.stdout)

    def test_one_slot_shift_too_short_fails(self) -> None:
        # DUT starts one slot later (11); overlap 11..13 is 3 slots < full golden 4.
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            gold = write_dump(base / "gold", (0, 10), 4, {i: complex(10 + i, 0) for i in range(4)})
            dut = write_dump(base / "dut", (0, 11), 5, {i: complex(11 + i, 0) for i in range(5)})
            r = run(dut, gold, "--by-slot", "--threshold", "0")
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("FAIL: DU slot overlap 3 < required 4", r.stdout)

    def test_short_overlap_allowed_by_min_override(self) -> None:
        # Same shifted DUT as above; lowering the required overlap makes it comparable.
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            gold = write_dump(base / "gold", (0, 10), 4, {i: complex(10 + i, 0) for i in range(4)})
            dut = write_dump(base / "dut", (0, 11), 5, {i: complex(11 + i, 0) for i in range(5)})
            r = run(dut, gold, "--by-slot", "--threshold", "0", "--min-overlap-slots", "3")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("offset=1", r.stdout)

    def test_mismatched_samples_fail_after_alignment(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            gold = write_dump(base / "gold", (0, 10), 4, {i: complex(10 + i, 0) for i in range(4)})
            vals = {i: complex(9 + i, 0) for i in range(6)}
            vals[2] = complex(999, 0)  # absolute DU slot 11 differs
            dut = write_dump(base / "dut", (0, 9), 6, vals)
            r = run(dut, gold, "--by-slot", "--threshold", "0")
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("DIFF", r.stdout)
            self.assertIn("DU slot 0.11", r.stdout)


if __name__ == "__main__":
    unittest.main()
