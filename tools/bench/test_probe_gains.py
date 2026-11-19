#!/usr/bin/env python3
"""Unit tests for tools/bench/probe_gains.py (captured probe output shape)."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from probe_gains import parse_ranges  # noqa: E402

PROBE = """\
|   |   |   |       TX Frontend
|   |   |   |           Name: Magnesium TX
|   |   |   |           Antennas: TX/RX, RX2
|   |   |   |           Gain range: 0.000 to 65.000 dB
|   |   |   |           Gain step: 0.500 dB
|   |   |   |       RX Frontend
|   |   |   |           Name: Magnesium RX
|   |   |   |           Antennas: RX2, TX/RX
|   |   |   |           Gain range: 0.000 to 75.000 dB
"""

PROBE_TWO_CHANNELS = PROBE.replace(
    "Gain range: 0.000 to 65.000 dB",
    "Gain range: -5.000 to 65.000 dB\n|   |   |   |           Gain range: 0.000 to 65.000 dB")

PROBE_NO_RANGES = "|   |   |   |       TX Frontend\n|   |   |   |           Name: none\n"


class ProbeGainsTest(unittest.TestCase):
    def test_tx_rx_ranges(self):
        self.assertEqual(parse_ranges(PROBE), {"tx": (0.0, 65.0), "rx": (0.0, 75.0)})

    def test_widest_range_wins(self):
        self.assertEqual(parse_ranges(PROBE_TWO_CHANNELS)["tx"], (-5.0, 65.0))

    def test_no_ranges(self):
        self.assertEqual(parse_ranges(PROBE_NO_RANGES), {"tx": None, "rx": None})

    def test_rx_does_not_leak_into_tx(self):
        parsed = parse_ranges(PROBE)
        self.assertEqual(parsed["tx"], (0.0, 65.0))
        self.assertEqual(parsed["rx"], (0.0, 75.0))


if __name__ == "__main__":
    unittest.main()
