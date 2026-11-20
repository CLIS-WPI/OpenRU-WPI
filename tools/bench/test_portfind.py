import os
import tempfile
import unittest

import numpy as np

import portfind


def cs8(x):
    iq = np.empty(2 * len(x), np.int8)
    iq[0::2], iq[1::2] = np.clip(np.round(x.real), -127, 127), np.clip(np.round(x.imag), -127, 127)
    return iq


class PortFind(unittest.TestCase):
    def test_tone_is_found_and_baseline_is_flat(self):
        rng = np.random.default_rng(1)
        n = portfind.N * 8
        noise = lambda: (rng.normal(0, 2, n) + 1j * rng.normal(0, 2, n))
        t = np.arange(n) / portfind.FS
        tone = noise() + 40 * np.exp(2j * np.pi * 1.0e6 * t)
        b, s = cs8(noise()).view(np.int8), cs8(tone)
        over, dbfs = portfind.tone_over_baseline(b.astype(np.float32).view(np.complex64), s.astype(np.float32).view(np.complex64))
        self.assertGreater(over, 30)
        self.assertLess(dbfs, 0)
        flat, _ = portfind.tone_over_baseline(b.astype(np.float32).view(np.complex64), b.astype(np.float32).view(np.complex64))
        self.assertLess(flat, 15)  # max of a noise spectrum over its median, no tone

    def test_cli_marks_missing_captures(self):
        with tempfile.TemporaryDirectory() as d:
            n = portfind.N * 2
            cs8(np.ones(n, complex)).tofile(os.path.join(d, "pf_base_c0_abcd.cs8"))
            cs8(np.ones(n, complex)).tofile(os.path.join(d, "pf_tone_c0_abcd.cs8"))
            import io, contextlib
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                portfind.main(["portfind.py", d, "abcd"])
            self.assertIn("no capture", out.getvalue())   # channels 1..3
            self.assertIn("ch 0", out.getvalue())


if __name__ == "__main__":
    unittest.main()
