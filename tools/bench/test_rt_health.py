#!/usr/bin/env python3
"""Unit tests for tools/bench/rt_health.py (log line classification, window, verdict)."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from rt_health import DU_PATTERNS, DU_WARN, RU_PATTERNS, count, minutes_between, verdict  # noqa: E402

RU_LINES = [
    "2026-11-19T21:01:59.006974 [PHY     ] [W] [  872.18] Real-time failure in lower PHY: Downlink data late for sector 0 and slot 872.18.",
    "2026-11-19T21:02:09.317289 [RF      ] [W] Real-time failure in RF: underflow",
    "2026-11-19T21:02:09.317291 [RF      ] [D] Real-time failure in RF: Type=underflow Source=tx Timestamp=na",
    "2026-11-19T21:02:10.000001 [PHY     ] [W] [  873.4] Real-time failure in lower PHY: Uplink data late for sector 0 and slot 873.4.",
    "2026-11-19T21:03:00.000000 [PHY     ] [W] [  900.0] Real-time failure in lower PHY: Downlink data late for sector 0 and slot 900.0.",
]
DU_LINES = [
    "2026-11-20T00:41:56.1 [OFH     ] [W] Sector#0: missed incoming User-Plane uplink messages for slot '1.4', symbol '12'",
    "2026-11-20T00:41:57.1 [OFH     ] [W] Sector#0: missed incoming User-Plane PRACH messages for slot '1.19'",
    "2026-11-20T00:41:58.1 [OFH     ] [W] Real-time timing worker woke up late, skipped '3' symbols. Current symbol is '8'.",
    "2026-11-20T00:41:58.2 [OFH     ] [I] Real-time timing worker woke up late, skipped '2' symbols, current symbol is '10'",
    "2026-11-20T00:41:59.1 [OFH     ] [W] Sector#0: dropped late downlink resource grid in slot '2.3'. No OFH data will be transmitted",
    "2026-11-20T00:42:01.1 [OFH     ] [W] Sector#0: potentially lost '12' messages sent by the RU",
    "2026-11-20T00:41:59.5 [METRICS ] OFH sector#0 metrics: rx_late=0",
]


class CountTest(unittest.TestCase):
    def test_ru_window_and_categories(self):
        totals, buckets = count(RU_LINES, RU_PATTERNS, "2026-11-19T21:01:00", "2026-11-19T21:03:00")
        self.assertEqual(totals["dl_late"], 1)  # the 21:03:00 line is outside (until is exclusive)
        self.assertEqual(totals["ul_late"], 1)
        self.assertEqual(totals["rf_underflow"], 1)  # the [D] detail line is not counted twice
        self.assertEqual(sum(totals.values()), 3)
        self.assertEqual(buckets, {"2026-11-19T21:01:50": 1, "2026-11-19T21:02:00": 1, "2026-11-19T21:02:10": 1})

    def test_du_only_warnings(self):
        totals, _ = count(DU_LINES, DU_PATTERNS, "2026-11-20T00:41:00", "2026-11-20T00:43:00", only=DU_WARN)
        self.assertEqual(totals, {"missed_ul": 1, "missed_prach": 1, "dropped_dl_grid": 1, "dropped_ul_req": 0,
                                  "timing_late": 1, "lost_msgs": 1})  # the [I] wake-up line is not a warning


class VerdictTest(unittest.TestCase):
    def test_minutes(self):
        self.assertAlmostEqual(minutes_between("2026-11-20T00:41:55", "2026-11-20T00:51:55"), 10.0)
        self.assertAlmostEqual(minutes_between("2026-11-19T23:59:30", "2026-11-20T00:00:30"), 1.0)

    def test_verdicts(self):
        self.assertEqual(verdict(0, 0, 10, 6, 30), ("OK", 0))
        self.assertEqual(verdict(2, 55, 10, 6, 30), ("WARN", 2))      # the accepted cores-plan baseline
        self.assertEqual(verdict(2400, 0, 1, 6, 30), ("FAIL", 1))     # the outage ramp
        self.assertEqual(verdict(0, 300, 10, 6, 30), ("FAIL", 1))


if __name__ == "__main__":
    unittest.main()
