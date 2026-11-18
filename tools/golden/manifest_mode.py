#!/usr/bin/env python3
"""Read and validate the replay settings recorded in a golden MANIFEST.json.

The replay mode is recorded per golden (`lead_mode`, one of `quantized-lead` or `exact-lead`, with `lead_us` and
`sender`). The replay harness must use exactly those values, so this module is the single reader for the Makefile and
the unit test: a MODE MISMATCH IS IMPOSSIBLE because the mode passed to the sender is the mode read here, and the test
asserts the reader returns the MANIFEST's own values.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LEAD_MODES = ("quantized-lead", "exact-lead")


class ManifestModeError(ValueError):
    """Raised when a golden MANIFEST lacks or has an invalid replay mode."""


def read_settings(path: str | Path) -> tuple[str, float, str]:
    """Return (lead_mode, lead_us, sender) from a golden MANIFEST, validating the mode."""
    p = Path(path)
    try:
        d = json.loads(p.read_text())
    except json.JSONDecodeError as exc:
        raise ManifestModeError(f"{p}: invalid JSON ({exc})") from exc
    mode = d.get("lead_mode")
    if not mode:
        raise ManifestModeError(
            f"{p}: MANIFEST has no lead_mode; the replay must use the golden's recorded mode "
            f"({', '.join(LEAD_MODES)})"
        )
    if mode not in LEAD_MODES:
        raise ManifestModeError(
            f"{p}: unknown lead_mode {mode!r}; expected one of {', '.join(LEAD_MODES)}"
        )
    lead = d.get("lead_us")
    if lead is None:
        raise ManifestModeError(f"{p}: MANIFEST has no lead_us")
    sender = d.get("sender")
    if not sender:
        raise ManifestModeError(f"{p}: MANIFEST has no sender")
    return str(mode), float(lead), str(sender)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--field", required=True, choices=("lead_mode", "lead_us", "sender"))
    args = ap.parse_args()
    try:
        mode, lead, sender = read_settings(args.manifest)
    except (ManifestModeError, OSError) as exc:
        print(f"manifest-mode: ERROR {exc}", file=sys.stderr)
        return 2
    value = {"lead_mode": mode, "lead_us": lead, "sender": sender}[args.field]
    if args.field == "lead_us":
        print(f"{value:g}")
    else:
        print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
