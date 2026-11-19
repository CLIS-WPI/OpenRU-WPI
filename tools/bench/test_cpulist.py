#!/usr/bin/env python3
"""Unit tests for tools/bench/cpulist.py (sysfs/lscpu/cmdline forms)."""
import pathlib
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from cpulist import parse  # noqa: E402


class CpuListTest(unittest.TestCase):
    def test_range_and_comma(self):
        self.assertEqual(parse("2-5,8"), [2, 3, 4, 5, 8])

    def test_spaces(self):
        self.assertEqual(parse("0 1 2"), [0, 1, 2])

    def test_mixed_spaces_commas_ranges(self):
        self.assertEqual(parse("0 1 10 11 2-3"), [0, 1, 2, 3, 10, 11])

    def test_newlines_and_dedup(self):
        self.assertEqual(parse("0-1\n1-2\n2\n"), [0, 1, 2])

    def test_empty(self):
        self.assertEqual(parse(""), [])
        self.assertEqual(parse("   \n "), [])

    def test_malformed(self):
        for bad in ("a", "1-", "1-2-3", "5-2"):
            with self.assertRaises(ValueError, msg=bad):
                parse(bad)

    def test_cli(self):
        here = pathlib.Path(__file__).resolve().parent
        script = str(here / "cpulist.py")
        run = lambda *a: subprocess.run([sys.executable, script, *a], capture_output=True, text=True)
        self.assertEqual(run("expand", "2-5,8").stdout.strip(), "2 3 4 5 8")
        self.assertEqual(run("normalize", "0 1 2 4,5").stdout.strip(), "0-2,4-5")
        self.assertEqual(run("check", "2-5", "0-7").returncode, 0)
        self.assertEqual(run("check", "2-9", "0-7").returncode, 1)
        self.assertEqual(run("contains", "5", "0-7").returncode, 0)
        self.assertEqual(run("contains", "9", "0-7").returncode, 1)
        self.assertEqual(run("expand", "0 1 x").returncode, 2)


if __name__ == "__main__":
    unittest.main()
