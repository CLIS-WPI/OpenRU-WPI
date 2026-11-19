from __future__ import annotations

import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from dashboard.state import DashboardState  # noqa: E402


def make_state() -> DashboardState:
    settings = types.SimpleNamespace(
        max_log_lines=50,
        release={"tag": "bench-latest"},
        hostname="test-host",
    )
    return DashboardState(settings)


class ReplayStateTests(unittest.TestCase):
    def test_loads_captured_snapshot_without_collectors(self):
        state = make_state()
        state.load_replay(
            {
                "ru": {
                    "latest": {"ts": 100.0, "rx_total": 10, "tx_total": 20},
                    "history": [{"ts": 100.0, "rx_total": 10, "tx_total": 20}],
                },
                "du": {"cell": {"pci": 1}, "cell_up": True, "errors": {}},
                "du_history": [{"ts": 100.0, "wall_avg_us": 10}],
                "core": {"gnb_count": 1, "gnbs": []},
                "host": {"hostname": "test-host"},
                "modems": {"A": {"error": "no modem port configured"}},
                "logs": [{"seq": 7, "ts": 100.0, "source": "du", "level": "info", "text": "x"}],
                "collectors": {"replay": {"ok": True}},
            }
        )
        snapshot = state.snapshot()
        self.assertTrue(snapshot["replay"])
        self.assertEqual(snapshot["du"]["cell"]["pci"], 1)
        self.assertEqual(snapshot["ru"]["latest"]["rx_total"], 10)
        self.assertEqual(snapshot["logs"][-1]["seq"], 7)
        self.assertEqual(snapshot["collectors"]["replay"]["ok"], True)


if __name__ == "__main__":
    unittest.main()
