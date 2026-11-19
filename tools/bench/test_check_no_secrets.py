#!/usr/bin/env python3
"""Unit tests for scripts/check_no_secrets.sh (fixture files, no network)."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_no_secrets.sh"

CLEAN = """\
make bench-ship                      # HOST from docker/bench.local.env
HOST=<bench-host>
LAB_IP=192.168.10.2
passwordless sudo is fine
GITHUB_TOKEN is read-only
k=<32 hex digits>
opc=<32 hex digits>
"""

CASES = {
    "tailscale_ip": "BENCH_HINT=100.101.102.103\n",
    "tailnet_name": "remote is on the tailnet now\n",
    "tailnet_id": "host ece107\n",
    "ssh_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n",
    "ssh_key_type": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI\n",
    "host_alias": "make bench-ship HOST=benchbox\n",
    "ssh_userhost": "ssh deploy@benchbox true\n",
    "credential": "DB_PASSWORD=hunter2hunter2\n",
    "sim_key_assign_k": "k=00112233445566778899aabbccddeeff\n",
    "sim_key_assign_opc": "OPc: 63bfa50ee6523365ff14c1f45f88737d\n",
    "sim_key_assign_adm": "ADM = 00112233445566778899aabbccddeeff\n",
    "sim_key_bare_hex32": "the value 00112233445566778899aabbccddeeff is a key\n",
}


def run(paths):
    return subprocess.run([str(SCRIPT), "--paths", *map(str, paths)],
                          capture_output=True, text=True)


class NoSecretsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_clean_fixture_passes(self):
        f = self.dir / "clean.txt"
        f.write_text(CLEAN)
        out = run([f])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("PASS", out.stdout)

    def test_each_pattern_fails(self):
        for name, content in CASES.items():
            f = self.dir / f"{name}.txt"
            f.write_text(content)
            out = run([f])
            self.assertEqual(out.returncode, 1, f"{name} should fail: {out.stderr}")
            self.assertIn("FAIL", out.stderr, name)

    def test_reviewed_false_positive_marker(self):
        f = self.dir / "ok.txt"
        f.write_text("remote is on the tailnet now  # no-secrets-ok\n")
        self.assertEqual(run([f]).returncode, 0)

    def test_staged_mode_scans_the_index(self):
        # --staged runs against a git repo; this test only checks the CLI contract.
        out = subprocess.run([str(SCRIPT), "--staged"], cwd=ROOT, capture_output=True, text=True)
        self.assertIn(out.returncode, (0, 1), out.stderr)
        self.assertTrue(("PASS" in out.stdout) or ("FAIL" in out.stderr))


if __name__ == "__main__":
    unittest.main()
