"""Unit tests for the golden MANIFEST helpers."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest import first_last_slots  # noqa: E402


class FirstLastSlotsTest(unittest.TestCase):
    def test_time_order_across_sfn_wrap_1024(self) -> None:
        tx = [
            {"du_sfn": 1020, "du_slot": 0},
            {"du_sfn": 1022, "du_slot": 7},
            {"du_sfn": 1023, "du_slot": 19},
            {"du_sfn": 0, "du_slot": 0},
            {"du_sfn": 3, "du_slot": 5},
            {"du_sfn": 10, "du_slot": 19},
        ]
        first, last = first_last_slots(tx)
        self.assertEqual(first, (1020, 0))
        self.assertEqual(last, (10, 19))
        # The lexicographic min/max the manifest used before this fix would report (0,0) .. (1023,19).
        slots = [(e["du_sfn"], e["du_slot"]) for e in tx]
        self.assertNotEqual(first, min(slots))
        self.assertNotEqual(last, max(slots))

    def test_time_order_across_ofh_wrap_256(self) -> None:
        tx = [{"du_sfn": 124, "du_slot": 0}, {"du_sfn": 255, "du_slot": 19}, {"du_sfn": 0, "du_slot": 0},
              {"du_sfn": 67, "du_slot": 19}]
        self.assertEqual(first_last_slots(tx), ((124, 0), (67, 19)))


if __name__ == "__main__":
    unittest.main()
