"""Unit tests that the replay mode can never differ from the golden MANIFEST's recorded mode."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest_mode import LEAD_MODES, ManifestModeError, read_settings  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


class LeadModeTest(unittest.TestCase):
    def test_shipped_manifests_replay_mode_equals_manifest(self) -> None:
        """The single reader returns the MANIFEST's own mode/lead/sender for every non-deferred golden."""
        for prof in ("baseline", "b40"):
            p = ROOT / "testdata" / "golden" / prof / "MANIFEST.json"
            d = json.loads(p.read_text())
            self.assertNotEqual(d.get("status"), "deferred", prof)
            mode, lead, sender = read_settings(p)
            self.assertIn(mode, LEAD_MODES)
            # This equality is the no-mismatch invariant: the Makefile passes exactly this mode to the sender.
            self.assertEqual(mode, d["lead_mode"])
            self.assertAlmostEqual(lead, float(d["lead_us"]))
            self.assertEqual(sender, d["sender"])

    def test_missing_mode_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "MANIFEST.json"
            p.write_text(json.dumps({"lead_us": 2235.0, "sender": "python"}))
            with self.assertRaises(ManifestModeError):
                read_settings(p)

    def test_unknown_mode_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "MANIFEST.json"
            p.write_text(json.dumps({"lead_mode": "rounded-lead", "lead_us": 2235.0, "sender": "python"}))
            with self.assertRaises(ManifestModeError):
                read_settings(p)

    def test_deferred_golden_has_no_replay_mode(self) -> None:
        p = ROOT / "testdata" / "golden" / "b100" / "MANIFEST.json"
        d = json.loads(p.read_text())
        self.assertEqual(d.get("status"), "deferred")
        with self.assertRaises(ManifestModeError):
            read_settings(p)


if __name__ == "__main__":
    unittest.main()
