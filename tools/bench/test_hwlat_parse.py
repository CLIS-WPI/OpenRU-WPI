#!/usr/bin/env python3
"""Unit tests for tools/bench/hwlat_parse.py (captured hwlatdetect output)."""
import pathlib
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from hwlat_parse import parse_max_latency_us  # noqa: E402

PASS_OUTPUT = """\
hwlatdetect:  test duration 60 seconds
   detector: tracer
   parameters:
        Latency threshold: 20us
        Sample window:     1000000us
        Sample width:      500000us
     Non-sampling period:  500000us
        Output File:       None

Starting test
test finished
Max Latency: 12us
Samples recorded: 1
Samples exceeding threshold: 0
"""

FAIL_OUTPUT = PASS_OUTPUT.replace("Max Latency: 12us", "Max Latency: 21.50us")
VARIANT_OUTPUT = """\
parameters:
     Latency threshold: 20us
     Sample window:     1000000us
Maximum Latency: 19.75 \u00b5s
"""
NO_RESULT_OUTPUT = """\
hwlatdetect:  test duration 60 seconds
     Latency threshold: 20us
     Sample window:     1000000us
"""


class HwlatParseTest(unittest.TestCase):
    def test_pass_sample(self):
        self.assertEqual(parse_max_latency_us(PASS_OUTPUT), 12.0)

    def test_fail_sample(self):
        self.assertEqual(parse_max_latency_us(FAIL_OUTPUT), 21.5)

    def test_parameter_lines_are_not_the_result(self):
        # The sample window (1000000us) must not win over the result line.
        self.assertEqual(parse_max_latency_us(PASS_OUTPUT), 12.0)
        self.assertNotEqual(parse_max_latency_us(PASS_OUTPUT), 1000000.0)

    def test_variant_wording_and_micro_sign(self):
        self.assertEqual(parse_max_latency_us(VARIANT_OUTPUT), 19.75)

    def test_missing_result_is_none(self):
        self.assertIsNone(parse_max_latency_us(NO_RESULT_OUTPUT))

    def test_cli_exit_codes(self):
        script = str(pathlib.Path(__file__).resolve().parent / "hwlat_parse.py")
        ok = subprocess.run([sys.executable, script], input=PASS_OUTPUT,
                            text=True, capture_output=True)
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, "12"))
        bad = subprocess.run([sys.executable, script], input=NO_RESULT_OUTPUT,
                             text=True, capture_output=True)
        self.assertEqual(bad.returncode, 1)


if __name__ == "__main__":
    unittest.main()
