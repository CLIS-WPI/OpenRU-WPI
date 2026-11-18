#!/usr/bin/env python3
"""Extract the maximum latency (us) from hwlatdetect output.

hwlatdetect prints parameter lines that also end in "us" (the latency
threshold, the sample window, ...) before the result block:

    hwlatdetect:  test duration 60 seconds
       parameters:
            Latency threshold: 20us
            Sample window:     1000000us
    ...
    Max Latency: 12us
    Samples recorded: 1

Only the result line counts: matching a bare "<n>us" would report the sample
window (1 s) as the maximum latency.
"""
import re
import sys

_RESULT = re.compile(
    r"max(?:imum)?(?:\s+latency)?\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*(?:us|\u00b5s)\b",
    re.IGNORECASE,
)


def parse_max_latency_us(text: str):
    """Return the largest 'Max [Latency]: <n>us' value, or None."""
    values = [float(m) for m in _RESULT.findall(text)]
    return max(values) if values else None


def main() -> int:
    value = parse_max_latency_us(sys.stdin.read())
    if value is None:
        print("hwlat_parse: no 'Max Latency: <n>us' line in input", file=sys.stderr)
        return 1
    print(f"{value:g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
