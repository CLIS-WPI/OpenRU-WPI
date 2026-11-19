from __future__ import annotations

import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from dashboard.parsers.core import CoreAccumulator  # noqa: E402
from dashboard.parsers.du import DuAccumulator  # noqa: E402
from dashboard.parsers.host import parse_cpu_list, parse_hwlat  # noqa: E402
from dashboard.parsers.modem import parse_response  # noqa: E402
from dashboard.parsers.protoru import parse_row  # noqa: E402
from dashboard.parsers.stack import container_from_api, parse_rfc3339, stack_snapshot  # noqa: E402
from dashboard.redact import mask_imsi, redact_text  # noqa: E402
from dashboard.state import DashboardState  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def fixture(name: str) -> list[str]:
    return (FIXTURES / name).read_text(encoding="utf-8").splitlines()


class ProtoruParserTests(unittest.TestCase):
    def test_real_row(self):
        line = fixture("protoru.log")[0]
        sample = parse_row(line, 1000.0)
        self.assertIsNotNone(sample)
        assert sample is not None
        self.assertEqual(sample.time, "04:18:01")
        self.assertEqual(sample.rx_total, 9080)
        self.assertEqual(sample.rx_on_time, 6759)
        self.assertEqual(sample.rx_early, 9)
        self.assertEqual(sample.rx_late, 0)
        self.assertEqual(sample.rx_seq_err, 0.0)
        self.assertEqual(sample.rx_seq_err_prach, 0.0)
        self.assertEqual(sample.tx_total, 15232)
        self.assertEqual(sample.id, 0)

    def test_header_and_garbage_are_ignored(self):
        self.assertIsNone(parse_row("| TIME | ID | RX_TOTAL |", 1.0))
        self.assertIsNone(parse_row("no table here", 1.0))


class DuParserTests(unittest.TestCase):
    def test_real_lines_and_error_counters(self):
        acc = DuAccumulator()
        lines = fixture("du.log")
        for index, line in enumerate(lines):
            acc.process(line, ts=1000.0 + index)
        snapshot = acc.snapshot(now=1006.0)
        self.assertEqual(snapshot["cell"]["pci"], 1)
        self.assertEqual(snapshot["cell"]["band"], 78)
        self.assertEqual(snapshot["cell"]["dl_arfcn"], 628032)
        self.assertEqual(snapshot["cell"]["channel_bandwidth_MHz"], 20.0)
        self.assertTrue(snapshot["cell_up"])
        self.assertEqual(snapshot["mac"]["wall_avg_us"], 10.0)
        self.assertEqual(snapshot["mac"]["wall_max_us"], 76.0)
        self.assertEqual(snapshot["mac"]["nof_slots"], 2000)
        self.assertEqual(snapshot["ofh"]["rx_total"], 14354)
        self.assertEqual(snapshot["ofh"]["rx_late"], 26)
        self.assertEqual(snapshot["sched"]["nof_ues"], 0)
        self.assertEqual(snapshot["errors"]["seq_past"]["per_min"], 2)
        self.assertEqual(snapshot["errors"]["missed_prach"]["per_min"], 1)
        self.assertEqual(snapshot["errors"]["late_prach"]["per_min"], 0)
        self.assertEqual(len(snapshot["error_series"]), 60)

    def test_late_prach_uses_metric_delta(self):
        acc = DuAccumulator()
        line = next(line for line in fixture("du.log") if "nof_late_ul_req=1" in line)
        acc.process(line, ts=2000.0)
        acc.process(line.replace("nof_late_ul_req=1", "nof_late_ul_req=3"), ts=2001.0)
        snapshot = acc.snapshot(now=2002.0)
        self.assertEqual(snapshot["errors"]["late_prach"]["per_min"], 2)
        self.assertEqual(snapshot["errors"]["late_prach"]["total"], 2)


class CoreParserTests(unittest.TestCase):
    def test_ng_setup_registration_auth_and_pdu(self):
        acc = CoreAccumulator()
        for index, line in enumerate(fixture("core.log")):
            acc.process(line, ts=3000.0 + index)
        snapshot = acc.snapshot(now=3100.0)
        self.assertEqual(snapshot["gnb_count"], 1)
        self.assertTrue(snapshot["gnb_up"])
        accepted = next(g for g in snapshot["gnbs"] if g["addr"] == "10.53.1.6")
        self.assertTrue(accepted["accepted"])
        self.assertEqual(accepted["streams"], 30)
        refused = next(g for g in snapshot["gnbs"] if g["addr"] == "10.53.1.99")
        self.assertFalse(refused["accepted"])
        counts = snapshot["counts"]
        self.assertEqual(counts["reg_requested"], 1)
        self.assertEqual(counts["reg_accepted"], 1)
        self.assertEqual(counts["reg_rejected"], 1)
        self.assertEqual(counts["auth_requested"], 1)
        self.assertEqual(counts["auth_success"], 1)
        self.assertEqual(counts["auth_failure"], 1)
        self.assertEqual(counts["pdu_established"], 1)
        ue = next(item for item in snapshot["ues"] if item["supi"] == "imsi-001010000000001")
        self.assertEqual(ue["dnn"], "internet")
        self.assertEqual(ue["ipv4"], "10.45.0.2")
        self.assertEqual(ue["state"], "pdu")
        self.assertEqual(snapshot["rejects"][0]["cause"], 7)
        self.assertEqual(snapshot["rejects"][0]["cause_name"], "5GS services not allowed")
        self.assertEqual(snapshot["auth"]["last_cause"], "MAC failure")


class ModemParserTests(unittest.TestCase):
    def test_read_only_response(self):
        snapshot = parse_response((FIXTURES / "modem.txt").read_text(encoding="utf-8"))
        self.assertEqual(snapshot["cfun"], 1)
        self.assertEqual(snapshot["cfun_name"], "full")
        self.assertEqual(snapshot["sim"]["imsi"], "001010000000001")
        self.assertTrue(snapshot["registered"])
        self.assertEqual(snapshot["serving"]["rat"], "NR5G-SA")
        self.assertEqual(snapshot["serving"]["pci"], 123)
        self.assertEqual(snapshot["serving"]["band"], "78")
        self.assertEqual(snapshot["serving"]["rsrp_dbm"], -82.5)
        self.assertEqual(snapshot["registration"]["fivegs"]["stat"], 1)
        self.assertEqual(snapshot["pdn"]["address"], "10.45.0.2")
        self.assertEqual(snapshot["operator"]["mcc"], "001")
        self.assertEqual(snapshot["operator"]["mnc"], "01")
        self.assertEqual(snapshot["signal"]["dbm"], -73)
        self.assertEqual(snapshot["errors"], 0)


class HostParserTests(unittest.TestCase):
    def test_cpu_list(self):
        self.assertEqual(parse_cpu_list("0-1,12-19"), [0, 1, 12, 13, 14, 15, 16, 17, 18, 19])
        self.assertEqual(parse_cpu_list("2-5:2"), [2, 4])
        self.assertEqual(parse_cpu_list(""), [])

    def test_hwlat(self):
        result = parse_hwlat((FIXTURES / "hwlat.txt").read_text(encoding="utf-8"))
        self.assertEqual(result["samples"], 2)
        self.assertEqual(result["max_us"], 41)
        self.assertEqual(result["last_us"], 41)
        self.assertEqual(result["below_threshold"], 2)
        self.assertTrue(result["available"])


class StackParserTests(unittest.TestCase):
    def test_stack_snapshot(self):
        now = 2000.0
        items = []
        for service, running, health in (("du", True, None), ("protoru", True, None), ("core", True, "healthy")):
            items.append(
                {
                    "Id": service * 4,
                    "Names": [f"/openru-{service}-1"],
                    "Image": f"openru/{service}:bench-latest",
                    "State": "running" if running else "exited",
                    "Status": "Up 10 seconds" if running else "Exited (0)",
                    "Created": "2026-11-19T04:16:40.000000000Z",
                    "Labels": {"com.docker.compose.service": service},
                }
            )
            items[-1]["_health"] = health
        containers = []
        for item in items:
            inspect = {
                "State": {
                    "Running": item["State"] == "running",
                    "StartedAt": "2026-11-19T04:16:40.000000000Z",
                    "Health": {"Status": item["_health"]} if item["_health"] else {},
                    "RestartCount": 0,
                },
                "Config": {"Image": item["Image"]},
            }
            containers.append(container_from_api(item, inspect))
        snapshot = stack_snapshot(containers, now=parse_rfc3339("2026-11-19T04:16:50Z"))
        self.assertEqual(snapshot["status"], "up")
        self.assertTrue(snapshot["stack_up"])
        self.assertEqual(snapshot["healthy"], ["core"])
        self.assertIsNotNone(snapshot["uptime_s"])

    def test_rfc3339_nanoseconds(self):
        value = parse_rfc3339("2026-11-19T04:16:40.367639342Z")
        self.assertIsNotNone(value)
        assert value is not None
        self.assertGreater(value, 1_700_000_000)


class RedactionTests(unittest.TestCase):
    def test_secret_patterns(self):
        text = (
            "reach 100.101.102.103 via host.tailnet.ts.net token=supersecret "  # no-secrets-ok
            "K=00112233445566778899aabbccddeeff ssh root@example.invalid"  # no-secrets-ok
        )
        clean = redact_text(text, mask_imsis=False)
        self.assertNotIn("100.101.102.103", clean)  # no-secrets-ok
        self.assertNotIn("supersecret", clean)
        self.assertNotIn("00112233445566778899aabbccddeeff", clean)  # no-secrets-ok
        self.assertNotIn("root@example.invalid", clean)
        self.assertIn("[redacted]", clean)

    def test_imsi_masking(self):
        self.assertEqual(mask_imsi("imsi-001010000000001"), "imsi-***********0001")
        self.assertEqual(mask_imsi("001010000000001"), "***********0001")

    def test_state_redacts_logs_and_snapshots(self):
        settings = types.SimpleNamespace(
            max_log_lines=10,
            release={"tag": "bench-latest", "commit": "b685cd5"},
            hostname="bench",
        )
        state = DashboardState(settings)
        state.add_log("core", "UE SUPI[imsi-001010000000001] token=supersecret")  # no-secrets-ok
        state.set_core(
            {
                "ues": [{"supi": "imsi-001010000000001", "ipv4": "10.45.0.2"}],
                "counts": {},
                "gnbs": [],
            }
        )
        snapshot = state.snapshot()
        self.assertNotIn("001010000000001", str(snapshot))
        self.assertNotIn("supersecret", str(snapshot))


if __name__ == "__main__":
    unittest.main()
