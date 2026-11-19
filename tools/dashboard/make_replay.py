#!/usr/bin/env python3
"""Build an offline replay snapshot from captured null-radio logs.

This does not touch Docker or the bench.  It exists so the UI can be reviewed
and screenshotted on a workstation while a measurement lock is held.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dashboard.parsers.core import CoreAccumulator  # noqa: E402
from dashboard.parsers.du import DuAccumulator, MAC_RE, OFH_RE  # noqa: E402
from dashboard.parsers.host import host_snapshot  # noqa: E402
from dashboard.parsers.protoru import parse_row  # noqa: E402
from dashboard.redact import redact_text  # noqa: E402

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)")


def timestamp(line: str) -> float | None:
    match = TS_RE.match(line)
    if not match:
        return None
    text = match.group(1).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(text).replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--du", required=True, type=Path)
    parser.add_argument("--ru", required=True, type=Path)
    parser.add_argument("--core", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--max-log-lines", type=int, default=180)
    args = parser.parse_args()

    du_lines = read_lines(args.du)
    ru_lines = read_lines(args.ru)
    core_lines = read_lines(args.core) if args.core else []

    stamps = [ts for line in (du_lines + ru_lines + core_lines) if (ts := timestamp(line))]
    if not stamps:
        first, span = time.time() - 120.0, 120.0
    else:
        first, span = min(stamps), max(stamps) - min(stamps)
    base = time.time() - span - 2.0

    def shifted(line: str, fallback: float) -> float:
        ts = timestamp(line)
        return base + (ts - first) if ts is not None else fallback

    du = DuAccumulator()
    du_history = []
    last_point_ts = None
    for index, line in enumerate(du_lines):
        ts = shifted(line, base + index / 10.0)
        du.process(line, ts=ts)
        if MAC_RE.search(line) or OFH_RE.search(line):
            point = du.point()
            if point["ts"] != last_point_ts:
                du_history.append(point)
                last_point_ts = point["ts"]
    du_now = base + span + 1.0
    du_snapshot = du.snapshot(now=du_now)

    ru_history = []
    for index, line in enumerate(ru_lines):
        sample = parse_row(line, shifted(line, base + index))
        if sample is not None:
            ru_history.append(sample.to_point())
    if ru_history:
        ru_shift = (time.time() - 1.0) - ru_history[-1]["ts"]
        for point in ru_history:
            point["ts"] = round(point["ts"] + ru_shift, 3)
    ru_latest = ru_history[-1] if ru_history else None

    core = CoreAccumulator()
    for index, line in enumerate(core_lines):
        core.process(line, ts=shifted(line, base + index / 10.0))
    core_snapshot = core.snapshot(now=du_now)

    logs = []
    seq = 0
    selected = []
    for source, lines in (("ru", ru_lines[-40:]), ("du", du_lines[-120:]), ("core", core_lines[-40:])):
        for line in lines:
            selected.append((source, line, shifted(line, base)))
    for source, line, ts in sorted(selected, key=lambda item: item[2]):
        text = redact_text(line, mask_imsis=True)
        if not text.strip():
            continue
        seq += 1
        logs.append(
            {
                "seq": seq,
                "ts": round(ts, 3),
                "source": source,
                "level": "info",
                "text": text[:2000],
            }
        )
    logs = logs[-args.max_log_lines :]

    now = time.time()
    payload = {
        "stack": {
            "services": {
                "core": {"name": "openru-core-1", "state": "running", "health": "healthy", "running": True},
                "du": {"name": "openru-du-1", "state": "running", "health": None, "running": True},
                "protoru": {"name": "openru-protoru-1", "state": "running", "health": None, "running": True},
            },
            "status": "up",
            "stack_up": True,
            "expected": ["du", "protoru"],
            "required": ["du", "protoru"],
            "running": ["du", "protoru", "core"],
            "required_running": ["du", "protoru"],
            "uptime_s": round(span, 1),
        },
        "host": host_snapshot(),
        "ru": {"latest": ru_latest, "history": ru_history[-240:]},
        "du": du_snapshot,
        "du_history": du_history[-240:],
        "core": core_snapshot,
        "modems": {
            label: {
                "port": None,
                "updated": now,
                "error": "no modem port configured",
                "registered": False,
            }
            for label in ("A", "B")
        },
        "modem_history": {"A": [], "B": []},
        "logs": logs,
        "collectors": {
            "replay": {"ok": True, "error": None, "since": now},
            "docker": {"ok": True, "error": None, "since": now},
            "host": {"ok": True, "error": None, "since": now},
        },
    }
    args.out.write_text(json.dumps(payload, indent=1), encoding="utf-8")
    print(
        f"wrote {args.out}: ru={len(ru_history)} du={len(du_history)} "
        f"errors={du_snapshot['errors']} ues={core_snapshot['ue_count']} logs={len(logs)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
