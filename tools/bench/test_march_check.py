#!/usr/bin/env python3
"""Unit tests for tools/bench/march_check.py (captured builder-log fixtures)."""
import pathlib
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from march_check import check  # noqa: E402

# Captured from logs/build-m2-fftw-estimate.log (a real x86-64-v4 build line).
V4_BUILDER_LINE = (
    '#14 [builder 2/3] RUN --mount=type=cache,id=openru-ccache,target=/src/ccache     '
    'ARCH_FLAG=$([ "amd64" = "arm64" ] && echo "-DMCPU=x86-64-v4" || echo "-DMARCH=x86-64-v4")     '
    '&& /src/docker/scripts/builder.sh -c gcc -x ccache -r False        '
    '-m "-j32 ocu odu ..."        -DBUILD_TESTING=False -DENABLE_UHD=On -DENABLE_DPDK=On '
    '${ARCH_FLAG} -DCMAKE_INSTALL_PREFIX=/opt/ocudu        -DENABLE_FFTW=ON -DOPENRU_CUDA=OFF\n'
)
V3_BUILDER_LOG = V4_BUILDER_LINE.replace("x86-64-v4", "x86-64-v3")
NO_ARCH_LOG = "#10 [builder-base 3/3] RUN apt-get install ...\n#11 built\n"


class MarchCheckTest(unittest.TestCase):
    def test_pass_v3_log_and_label(self):
        ok, builder, label, errors = check(V3_BUILDER_LOG, "x86-64-v3")
        self.assertTrue(ok, errors)
        self.assertEqual((builder, label), ("x86-64-v3", "x86-64-v3"))

    def test_fail_v4_builder_log(self):
        ok, builder, _, errors = check(V4_BUILDER_LINE, "x86-64-v3")
        self.assertFalse(ok)
        self.assertEqual(builder, "x86-64-v4")
        self.assertTrue(any("builder log -DMARCH=x86-64-v4" in e for e in errors))

    def test_fail_v4_image_label(self):
        ok, _, label, errors = check(V3_BUILDER_LOG, "x86-64-v4")
        self.assertFalse(ok)
        self.assertEqual(label, "x86-64-v4")
        self.assertTrue(any("org.openru.march=x86-64-v4" in e for e in errors))

    def test_fail_missing_builder_line(self):
        ok, builder, _, errors = check(NO_ARCH_LOG, "x86-64-v3")
        self.assertFalse(ok)
        self.assertIsNone(builder)
        self.assertTrue(any("no -DMARCH" in e for e in errors))

    def test_fail_missing_or_unknown_label(self):
        for label in ("", None, "unknown", "<no value>"):
            ok, _, _, errors = check(V3_BUILDER_LOG, label)
            self.assertFalse(ok, f"label {label!r} must fail")
            self.assertTrue(any("label org.openru.march missing" in e for e in errors))

    def test_last_builder_line_wins(self):
        # A retried build may print the arch twice; the final value is authoritative.
        log = V4_BUILDER_LINE + V3_BUILDER_LOG
        ok, builder, _, _ = check(log, "x86-64-v3")
        self.assertTrue(ok)
        self.assertEqual(builder, "x86-64-v3")

    def test_cli_exit_codes_and_json(self):
        here = pathlib.Path(__file__).resolve().parent
        script = str(here / "march_check.py")
        good = here / "_tmp_v3.log"
        bad = here / "_tmp_v4.log"
        out = here / "_tmp_march.json"
        try:
            good.write_text(V3_BUILDER_LOG)
            bad.write_text(V4_BUILDER_LINE)
            ok = subprocess.run([sys.executable, script, "--log", str(good),
                                 "--label", "x86-64-v3", "--json-out", str(out)],
                                capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertIn("PASS", ok.stdout)
            self.assertIn('"ok": true', out.read_text())

            bad_run = subprocess.run([sys.executable, script, "--log", str(bad),
                                      "--label", "x86-64-v3"],
                                     capture_output=True, text=True)
            self.assertEqual(bad_run.returncode, 1)
            self.assertIn("FAIL", bad_run.stderr)

            by_label = subprocess.run([sys.executable, script, "--log", str(good),
                                       "--label", "x86-64-v4"],
                                      capture_output=True, text=True)
            self.assertEqual(by_label.returncode, 1)
            self.assertIn("label", by_label.stderr)
        finally:
            for p in (good, bad, out):
                p.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
