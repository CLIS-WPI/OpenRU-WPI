#!/usr/bin/env python3
"""Real-time health of the bench stack from ProtO-RU and DU logs.

    rt_health.py --ru proto-ru.lines --du gnb.lines --since 2026-11-20T00:41:55 --until 2026-11-20T00:51:55
                 [--per10s] [--fail-ru-per-min 6] [--fail-du-per-min 30]

Clean fronthaul counters can hide a lower PHY that misses its deadlines (the
2026-11-19 outage: OFH late/drop 0 while "Downlink data late" ramped to ~240/s).
This counts, inside a UTC time window:

  RU (proto-ru.log): "Real-time failure in lower PHY: Downlink/Uplink data late",
                     "PUxCH request late", "Real-time failure in RF: underflow/overflow/late"
  DU (gnb.log, [OFH] warnings): missed incoming U-plane (uplink, PRACH), dropped late
                     DL grid / UL request, timing worker woke up late, potentially lost messages

Input lines may be the whole logs or pre-filtered (scripts/rt_watch.sh greps first).
Exit: 0 OK (nothing counted), 2 WARN (anything counted), 1 FAIL (a side reaches its
per-minute threshold over the window).
"""
import argparse
import re
import sys

RU_PATTERNS = {
    "dl_late": re.compile(r"Real-time failure in lower PHY: Downlink data late"),
    "ul_late": re.compile(r"Real-time failure in lower PHY: Uplink data late"),
    "puxch_late": re.compile(r"PUxCH request late"),
    "rf_underflow": re.compile(r"\[W\] Real-time failure in RF: underflow"),
    "rf_overflow": re.compile(r"\[W\] Real-time failure in RF: overflow"),
    "rf_late": re.compile(r"\[W\] Real-time failure in RF: late"),
}
DU_PATTERNS = {
    "missed_ul": re.compile(r"missed incoming User-Plane uplink messages"),
    "missed_prach": re.compile(r"missed incoming User-Plane PRACH messages"),
    "dropped_dl_grid": re.compile(r"dropped late downlink resource grid"),
    "dropped_ul_req": re.compile(r"dropped late uplink request"),
    "timing_late": re.compile(r"Real-time timing worker woke up late"),
    "lost_msgs": re.compile(r"potentially lost '\d+' messages"),
}
DU_WARN = re.compile(r"\[OFH\s*\] \[W\]")
TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)")


def count(lines, patterns, since, until, only=None):
    """Return ({category: n}, {10s-bucket: n}) for lines with since <= timestamp < until."""
    totals = {k: 0 for k in patterns}
    buckets: dict[str, int] = {}
    for line in lines:
        m = TS.match(line)
        if not m or not (since <= m.group(1) < until):
            continue
        if only is not None and not only.search(line):
            continue
        for k, pat in patterns.items():
            if pat.search(line):
                totals[k] += 1
                b = m.group(1)[:18] + "0"
                buckets[b] = buckets.get(b, 0) + 1
                break
    return totals, buckets


def minutes_between(since: str, until: str) -> float:
    def secs(ts):
        h, mi, s = (int(x) for x in ts[11:19].split(":"))
        return h * 3600 + mi * 60 + s
    d = secs(until) - secs(since)
    if d <= 0:
        d += 86400
    return d / 60.0


def verdict(ru_total, du_total, minutes, fail_ru, fail_du):
    if ru_total / minutes >= fail_ru or du_total / minutes >= fail_du:
        return "FAIL", 1
    if ru_total or du_total:
        return "WARN", 2
    return "OK", 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ru", help="ProtO-RU log (or its filtered lines)")
    ap.add_argument("--du", help="DU gnb.log (or its filtered lines)")
    ap.add_argument("--since", required=True, help="UTC, YYYY-MM-DDTHH:MM:SS (inclusive)")
    ap.add_argument("--until", required=True, help="UTC, YYYY-MM-DDTHH:MM:SS (exclusive)")
    ap.add_argument("--per10s", action="store_true", help="also print non-zero 10 s buckets")
    ap.add_argument("--fail-ru-per-min", type=float, default=6.0)
    ap.add_argument("--fail-du-per-min", type=float, default=30.0)
    a = ap.parse_args()

    minutes = minutes_between(a.since, a.until)
    ru, ru_b = ({}, {})
    du, du_b = ({}, {})
    if a.ru:
        with open(a.ru, errors="replace") as f:
            ru, ru_b = count(f, RU_PATTERNS, a.since, a.until)
    if a.du:
        with open(a.du, errors="replace") as f:
            du, du_b = count(f, DU_PATTERNS, a.since, a.until, only=DU_WARN)
    ru_total, du_total = sum(ru.values()), sum(du.values())
    status, rc = verdict(ru_total, du_total, minutes, a.fail_ru_per_min, a.fail_du_per_min)

    window = f"{a.since}..{a.until} UTC ({minutes:.1f} min)"
    if a.ru:
        print(f"rt: RU lower-PHY/RF real-time failures: {ru_total} ({ru_total / minutes:.1f}/min) "
              + " ".join(f"{k}={v}" for k, v in ru.items()))
    if a.du:
        print(f"rt: DU fronthaul real-time warnings:   {du_total} ({du_total / minutes:.1f}/min) "
              + " ".join(f"{k}={v}" for k, v in du.items()))
    if a.per10s:
        for name, b in (("RU", ru_b), ("DU", du_b)):
            if b:
                print(f"rt: {name} per 10 s: " + " ".join(f"{k[11:]}={v}" for k, v in sorted(b.items())))
    msg = {"OK": "no real-time failures", "WARN": "real-time failures present (below FAIL threshold)",
           "FAIL": f"real-time failures at or above threshold (RU >= {a.fail_ru_per_min:g}/min "
                   f"or DU >= {a.fail_du_per_min:g}/min)"}[status]
    banner = "!!!!!!!! " if status != "OK" else ""
    print(f"rt: {banner}{status}: {msg} in {window}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
