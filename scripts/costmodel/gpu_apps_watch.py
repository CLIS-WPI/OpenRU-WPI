#!/usr/bin/env python3
"""Watch compute applications on the allowed GPU during a run.

Rejects if any PID other than the benchmark (and its threads) appears on the
GPU. The caller pins this watcher away from the reserved cores.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

RUNNING = True


def _stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def read_pid(path: Path | None) -> int:
    if path is None:
        return 0
    try:
        return int(path.read_text().strip())
    except Exception:
        return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--uuid", required=True)
    ap.add_argument("--allow-pid-file", type=Path, default=None)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=0.0)
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    samples = []
    seen: set[int] = set()
    foreign: set[int] = set()
    seen_pid = False
    start = time.monotonic()
    while RUNNING:
        allow = read_pid(args.allow_pid_file)
        alive = bool(allow) and Path(f"/proc/{allow}").exists()
        if alive:
            seen_pid = True
        elif allow:
            break
        try:
            text = subprocess.check_output(
                [
                    "nvidia-smi",
                    "--query-compute-apps=gpu_uuid,pid,process_name,used_memory",
                    "--format=csv,noheader",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        except Exception:
            text = ""
        apps = []
        for line in text.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 4 or args.uuid not in parts[0]:
                continue
            try:
                pid = int(parts[1])
            except ValueError:
                continue
            apps.append({"pid": pid, "name": parts[2], "used_memory": parts[3]})
            seen.add(pid)
            if allow and pid != allow:
                foreign.add(pid)
        samples.append({"t": round(time.monotonic() - start, 2), "allow_pid": allow, "apps": apps})
        time.sleep(args.interval)
        if args.duration and (time.monotonic() - start) >= args.duration:
            break

    result = {
        "uuid": args.uuid,
        "samples": len(samples),
        "seen_pids": sorted(seen),
        "foreign_pids": sorted(foreign),
        "rejected": bool(foreign),
        "trace": samples[-60:],
    }
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("uuid", "seen_pids", "foreign_pids", "rejected")}))
    return 1 if foreign else 0


if __name__ == "__main__":
    sys.exit(main())
