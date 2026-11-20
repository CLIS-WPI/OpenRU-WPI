#!/usr/bin/env python3
"""Unit tests for tools/bench/pin_threads.py (plan parsing and pin decisions)."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from pin_threads import decide, missing_names, parse_plan  # noqa: E402

FULL = {2, 3, 4, 5, 6, 7, 12}


def t(comm, aff):
    return {"tid": 1, "ns_tid": 1, "comm": comm, "aff": set(aff), "cpu": min(aff), "policy": "FIFO/97"}


class PlanTest(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(parse_plan("ru_emu_#0=3 main_pool#0=11 *=12"), ({"ru_emu_#0": 3, "main_pool#0": 11}, 12))

    def test_parse_without_star(self):
        self.assertEqual(parse_plan("a=1"), ({"a": 1}, None))

    def test_parse_rejects_bad_entries(self):
        for bad in ("a", "a=", "=3", "a=x", "a=1 a=2"):
            with self.assertRaises(ValueError, msg=bad):
                parse_plan(bad)


class DecideTest(unittest.TestCase):
    def setUp(self):
        self.named, self.star = parse_plan("ru_emu_#0=3 ru_rx_#0=4 ru_timing=2 *=12")

    def state(self, threads):
        return {r["comm"]: (r["state"], r["want"]) for r in decide(threads, self.named, self.star, FULL)}

    def test_named_thread_on_shared_mask_is_moved(self):
        self.assertEqual(self.state([t("ru_emu_#0", {3, 4, 5})]), {"ru_emu_#0": ("move", 3)})

    def test_named_thread_already_pinned_is_ok(self):
        self.assertEqual(self.state([t("ru_timing", {2})]), {"ru_timing": ("ok", 2)})

    def test_unpinned_thread_goes_to_star(self):
        self.assertEqual(self.state([t("uhd_ctrl_ep0001", FULL)]), {"uhd_ctrl_ep0001": ("move", 12)})

    def test_unnamed_thread_already_on_star_is_ok(self):
        # re-reading the map after --apply: the '*' threads must show as on plan
        self.assertEqual(self.state([t("event_engine", {12})]), {"event_engine": ("ok", 12)})

    def test_app_pinned_unnamed_thread_is_left_alone(self):
        self.assertEqual(self.state([t("ru_phy_tx_#0", {6})]), {"ru_phy_tx_#0": ("app-pinned", None)})

    def test_named_thread_wrongly_pinned_by_app_is_moved(self):
        self.assertEqual(self.state([t("ru_rx_#0", {5})]), {"ru_rx_#0": ("move", 4)})

    def test_no_star_leaves_unpinned_threads(self):
        named, _ = parse_plan("ru_timing=2")
        rows = decide([t("gnb", FULL)], named, None, FULL)
        self.assertEqual((rows[0]["state"], rows[0]["want"]), ("app-pinned", None))

    def test_missing_names(self):
        self.assertEqual(missing_names([t("ru_timing", {2})], self.named), ["ru_emu_#0", "ru_rx_#0"])


if __name__ == "__main__":
    unittest.main()
