#!/usr/bin/env python3
"""UHD gain-range checks from the in-container ``uhd_usrp_probe`` output.

The N310 probe reports per-frontend ``Gain range: <start> to <stop> dB`` lines
under a ``TX Frontend`` / ``RX Frontend`` section. This tool parses those ranges
and verifies every ``profiles/bench-*/protoru.yml`` ``sdr.tx_gain``/``sdr.rx_gain``
lies inside them (and on the 0.5 dB step). When the probe output carries no gain
ranges (older UHD or a device without RF frontends), the measured fallback
ranges from ``docker/bench.env`` are used and a note is printed.

Usage:
  probe_gains.py check --probe OUT.txt --profiles profiles \
      --fallback-tx 0 65 --fallback-rx 0 75 [--step 0.5]
Exit: 0 all values inside the ranges, 1 violation, 2 usage/parse problem.
"""
import argparse
import pathlib
import re
import sys

import yaml

_GAIN = re.compile(r"Gain range:\s*(-?[0-9]+(?:\.[0-9]+)?)\s*(?:dB\s*)?to\s*(-?[0-9]+(?:\.[0-9]+)?)\s*dB",
                   re.IGNORECASE)
_TX_HDR = re.compile(r"\bTX\s+Frontend\b", re.IGNORECASE)
_RX_HDR = re.compile(r"\bRX\s+Frontend\b", re.IGNORECASE)


def parse_ranges(text: str) -> dict:
    """Return {'tx': (min, max) | None, 'rx': (min, max) | None} (widest seen)."""
    kind = None
    out = {"tx": None, "rx": None}
    for line in text.splitlines():
        if _TX_HDR.search(line):
            kind = "tx"
            continue
        if _RX_HDR.search(line):
            kind = "rx"
            continue
        m = _GAIN.search(line)
        if m and kind:
            lo, hi = float(m.group(1)), float(m.group(2))
            cur = out[kind]
            out[kind] = (min(lo, cur[0]), max(hi, cur[1])) if cur else (lo, hi)
    return out


def profile_gains(profiles_dir: pathlib.Path) -> list:
    rows = []
    for path in sorted(profiles_dir.glob("bench-*/protoru.yml")):
        cfg = yaml.safe_load(path.read_text())
        sdr = cfg["ru_emu"]["cells"][0]["sdr"]
        rows.append((path.parent.name, float(sdr["tx_gain"]), float(sdr["rx_gain"])))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", help="captured uhd_usrp_probe output (default: none)")
    ap.add_argument("--profiles", default="profiles")
    ap.add_argument("--fallback-tx", nargs=2, type=float, metavar=("MIN", "MAX"))
    ap.add_argument("--fallback-rx", nargs=2, type=float, metavar=("MIN", "MAX"))
    ap.add_argument("--step", type=float, default=0.5)
    args = ap.parse_args()

    parsed = {"tx": None, "rx": None}
    if args.probe:
        try:
            parsed = parse_ranges(pathlib.Path(args.probe).read_text(errors="replace"))
        except OSError as exc:
            print(f"gain-check: cannot read probe output: {exc}", file=sys.stderr)
            return 2
    missing = []
    if parsed["tx"] is None and args.fallback_tx:
        parsed["tx"] = tuple(args.fallback_tx)
        missing.append("TX")
    if parsed["rx"] is None and args.fallback_rx:
        parsed["rx"] = tuple(args.fallback_rx)
        missing.append("RX")
    source = "in-container uhd_usrp_probe"
    if missing:
        source = "measured fallback" if not args.probe else \
            "measured fallback (probe reported no " + "/".join(missing) + " gain range)"
    if parsed["tx"] is None or parsed["rx"] is None:
        print("gain-check: FAIL: no gain ranges from the probe and no fallback configured", file=sys.stderr)
        return 2

    tx_lo, tx_hi = parsed["tx"]
    rx_lo, rx_hi = parsed["rx"]
    print(f"gain-check: ranges {source}: TX {tx_lo:g}-{tx_hi:g} dB, RX {rx_lo:g}-{rx_hi:g} dB, "
          f"step {args.step:g} dB")
    failed = 0
    for name, tx, rx in profile_gains(pathlib.Path(args.profiles)):
        for label, value, lo, hi in (("tx_gain", tx, tx_lo, tx_hi), ("rx_gain", rx, rx_lo, rx_hi)):
            if value < lo or value > hi:
                print(f"gain-check: FAIL {name}: {label}={value:g} outside [{lo:g}, {hi:g}]", file=sys.stderr)
                failed = 1
            elif abs(value / args.step - round(value / args.step)) > 1e-9:
                print(f"gain-check: FAIL {name}: {label}={value:g} is not on the {args.step:g} dB step",
                      file=sys.stderr)
                failed = 1
        if not failed:
            print(f"gain-check: OK {name}: tx_gain={tx:g} rx_gain={rx:g}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
