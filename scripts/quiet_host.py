#!/usr/bin/env python3
"""Fail-closed quiet-host check for smoke-fh measurements.

A host is quiet when no process outside our du/protoru containers has CPU
affinity on the reserved cores (PROTORU_CPUSET union DU_CPUSET) and uses more
than --threshold percent CPU. The check also records load average, per-core
usage on the reserved cores, and the top foreign processes.

Usage:
  quiet_host.py --once --out hostcheck.json
  quiet_host.py --monitor --interval 30 --out hostcheck.json
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
from typing import Optional


def parse_cpu_list(text: str) -> set[int]:
    cores: set[int] = set()
    for part in (text or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            cores.update(range(int(lo), int(hi) + 1))
        else:
            cores.add(int(part))
    return cores


def lab_env_reserved() -> set[int]:
    root = Path(__file__).resolve().parent.parent
    env = root / "docker" / "lab.env"
    values: dict[str, str] = {}
    if env.exists():
        for line in env.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    spec = ",".join(v for v in (values.get("PROTORU_CPUSET", ""), values.get("DU_CPUSET", "")) if v)
    return parse_cpu_list(spec)


def container_ids(names: list[str]) -> set[str]:
    ids: set[str] = set()
    for name in names:
        try:
            out = subprocess.check_output(
                ["docker", "inspect", "-f", "{{.Id}}", name],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=5,
            ).strip()
            if out:
                ids.add(out)
        except Exception:
            pass
    return ids


def in_our_container(pid: int, ids: set[str]) -> bool:
    if not ids:
        return False
    try:
        cgroup = Path(f"/proc/{pid}/cgroup").read_text(errors="replace")
    except Exception:
        return False
    return any(cid in cgroup for cid in ids)


def process_cpu() -> dict[int, tuple[float, str]]:
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid=,pcpu=,comm="], text=True, stderr=subprocess.DEVNULL, timeout=5
        )
    except Exception:
        return {}
    result: dict[int, tuple[float, str]] = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            pcpu = float(parts[1])
        except ValueError:
            continue
        result[pid] = (pcpu, parts[2] if len(parts) > 2 else "")
    return result


def process_cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except Exception:
        return ""
    return raw.replace(b"\x00", b" ").decode(errors="replace").strip()[:300]


def cpu_times() -> dict[int, tuple[int, int]]:
    times: dict[int, tuple[int, int]] = {}
    try:
        lines = Path("/proc/stat").read_text().splitlines()
    except Exception:
        return times
    for line in lines:
        if not line.startswith("cpu") or line.startswith("cpu "):
            continue
        parts = line.split()
        try:
            cpu = int(parts[0][3:])
            values = [int(v) for v in parts[1:]]
        except (IndexError, ValueError):
            continue
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        times[cpu] = (sum(values), idle)
    return times


def per_core_usage(start: dict[int, tuple[int, int]], end: dict[int, tuple[int, int]],
                   cores: set[int]) -> dict[str, Optional[float]]:
    usage: dict[str, Optional[float]] = {}
    for core in sorted(cores):
        if core not in start or core not in end:
            continue
        total = end[core][0] - start[core][0]
        idle = end[core][1] - start[core][1]
        usage[str(core)] = round(100.0 * (total - idle) / total, 1) if total > 0 else None
    return usage


def sample(reserved: set[int], ids: set[str], containers: list[str], threshold: float) -> dict:
    start = cpu_times()
    proc = process_cpu()
    time.sleep(1.0)
    end = cpu_times()

    offenders: list[dict] = []
    foreign: list[dict] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == os.getpid():
            continue
        if in_our_container(pid, ids):
            continue
        try:
            affinity = os.sched_getaffinity(pid)
        except Exception:
            continue
        reserved_affinity = affinity & reserved
        if not reserved_affinity:
            continue
        pcpu, comm = proc.get(pid, (None, ""))
        if pcpu is None:
            continue
        record = {
            "pid": pid,
            "comm": comm,
            "args": process_cmdline(pid),
            "pcpu": pcpu,
            "affinity": sorted(affinity),
            "reserved_affinity": sorted(reserved_affinity),
        }
        foreign.append(record)
        if pcpu > threshold:
            offenders.append(record)

    foreign.sort(key=lambda r: r["pcpu"], reverse=True)
    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "reserved_cores": sorted(reserved),
        "containers": containers,
        "threshold_percent": threshold,
        "loadavg": list(os.getloadavg()),
        "cpu_usage_percent": per_core_usage(start, end, reserved),
        "foreign_top": foreign[:10],
        "offenders": offenders,
        "valid": not offenders,
    }


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reserved", default="", help="CPU list, e.g. 32-47,48-55")
    parser.add_argument("--containers", default="openru-protoru-1,openru-du-1")
    parser.add_argument("--threshold", type=float, default=5.0)
    parser.add_argument("--interval", type=float, default=30.0)
    parser.add_argument("--out", required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--monitor", action="store_true")
    args = parser.parse_args()
    if not (args.once or args.monitor):
        parser.error("choose --once or --monitor")

    reserved = parse_cpu_list(args.reserved)
    if not reserved:
        reserved = parse_cpu_list(
            ",".join(
                v for v in (os.environ.get("PROTORU_CPUSET", ""), os.environ.get("DU_CPUSET", "")) if v
            )
        )
    if not reserved:
        reserved = lab_env_reserved()
    if not reserved:
        parser.error("reserved cores are empty; set PROTORU_CPUSET/DU_CPUSET or --reserved")

    containers = [c.strip() for c in args.containers.split(",") if c.strip()]
    ids = container_ids(containers)
    out = Path(args.out)

    if args.once:
        data = sample(reserved, ids, containers, args.threshold)
        write_json(out, data)
        print(
            f"quiet_host: {'QUIET' if data['valid'] else 'BUSY'} "
            f"loadavg={data['loadavg']} offenders={len(data['offenders'])} out={out}",
            file=sys.stderr,
        )
        return 0 if data["valid"] else 2

    stop = False

    def handler(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)

    valid_all = True
    offenders_all: list[dict] = []
    samples = 0
    while not stop:
        data = sample(reserved, ids, containers, args.threshold)
        samples += 1
        valid_all = valid_all and data["valid"]
        offenders_all.extend(data["offenders"])
        data["valid"] = valid_all
        data["samples"] = samples
        data["offenders"] = offenders_all
        write_json(out, data)
        for _ in range(max(1, int(args.interval) - 1)):
            if stop:
                break
            time.sleep(1.0)
    return 0 if valid_all else 2


if __name__ == "__main__":
    sys.exit(main())
