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

When every sample is below the run's threshold, rt-tests prints
"Max Latency: Below threshold" and "Samples recorded: 0". That is a
PASS for the 20 us gate: report 0 us (strictly below the threshold).
"""
import re
import sys

_RESULT = re.compile(
    r"max(?:imum)?(?:\s+latency)?\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*(?:us|\u00b5s)\b",
    re.IGNORECASE,
)
_BELOW = re.compile(
    r"max(?:imum)?(?:\s+latency)?\s*:\s*below\s+threshold\b",
    re.IGNORECASE,
)
_SAMPLES = re.compile(r"samples\s+recorded\s*:\s*([0-9]+)", re.IGNORECASE)


def parse_max_latency_us(text: str):
    """Return the largest 'Max [Latency]: <n>us' value, 0 for below-threshold, or None."""
    values = [float(m) for m in _RESULT.findall(text)]
    if values:
        return max(values)
    if not _BELOW.search(text):
        return None
    recorded = [int(m) for m in _SAMPLES.findall(text)]
    if recorded and recorded[-1] != 0:
        return None
    return 0.0


def main() -> int:
    value = parse_max_latency_us(sys.stdin.read())
    if value is None:
        print("hwlat_parse: no 'Max Latency: <n>us' or below-threshold result in input",
              file=sys.stderr)
        return 1
    print(f"{value:g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
