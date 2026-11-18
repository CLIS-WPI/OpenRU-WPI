#!/usr/bin/env python3
"""Hard architecture check for a bench image build.

The bench image must be built for x86-64-v3 (no AVX-512 on the bench host).
Two independent sources are checked and must agree:

  * the builder log line (``-DMARCH=<arch>`` passed to the OCUDU CMake build);
  * the image provenance label ``org.openru.march``.

Exit 0 only when both equal the expected architecture.
"""
import argparse
import json
import re
import sys

_BUILDER_MARCH = re.compile(r"-DMARCH=([A-Za-z0-9_.-]+)")
_LABEL_MARCH = re.compile(r"^[A-Za-z0-9_.-]+$")


def check(log_text: str, label: str, expect: str = "x86-64-v3"):
    """Return (ok, builder_log_march_or_None, label, list_of_errors)."""
    matches = _BUILDER_MARCH.findall(log_text)
    builder = matches[-1] if matches else None
    errors = []
    if builder is None:
        errors.append(f"no -DMARCH=<arch> line in the builder log (expected {expect})")
    elif builder != expect:
        errors.append(f"builder log -DMARCH={builder} != {expect}")
    if label is None or label == "" or label == "unknown" or label == "<no value>":
        errors.append(f"image label org.openru.march missing (expected {expect})")
    elif not _LABEL_MARCH.match(label):
        errors.append(f"image label org.openru.march={label!r} is malformed")
    elif label != expect:
        errors.append(f"image label org.openru.march={label} != {expect}")
    return (not errors), builder, label, errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="captured builder log")
    ap.add_argument("--label", required=True, help="value of org.openru.march")
    ap.add_argument("--expect", default="x86-64-v3")
    ap.add_argument("--json-out", help="write the verified values as JSON")
    args = ap.parse_args()

    with open(args.log, errors="replace") as fh:
        text = fh.read()
    ok, builder, label, errors = check(text, args.label, args.expect)

    if args.json_out:
        with open(args.json_out, "w") as fh:
            fh.write(json.dumps({"expect": args.expect, "builder_log": builder,
                                 "label": label, "ok": ok}, indent=2) + "\n")
    if ok:
        print(f"march-check: PASS builder log -DMARCH={builder}, image label={label}")
        return 0
    for e in errors:
        print(f"march-check: FAIL {e}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
