#!/usr/bin/env python3
"""Watch only the reserved cores during a cost-model run.

Reports per-core busy, the benchmark's own CPU share, the foreign remainder, and
the benchmark core's frequency. Rejects when the foreign remainder on any
reserved core exceeds --threshold. Run before/after with no --bench-pid-file to
record idle load.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import sys
import time
from pathlib import Path

HZ = os.sysconf("SC_CLK_TCK")
RUNNING = True


def _stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def cpu_stats() -> dict[int, tuple[int, int]]:
    out = {}
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("cpu") and line[3:4].isdigit():
            parts = line.split()
            values = [int(v) for v in parts[1:9]]
            out[int(parts[0][3:])] = (sum(values), values[3] + values[4])
    return out


def proc_ticks(pid: int) -> int:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(errors="replace")
        rest = raw.rsplit(")", 1)[1].split()
        return int(rest[11]) + int(rest[12])
    except Exception:
        return 0


def read_pid(path: Path) -> int:
    try:
        return int(path.read_text().strip())
    except Exception:
        return 0


def cpu_mhz(cpu: int) -> float | None:
    try:
        text = Path("/proc/cpuinfo").read_text(errors="replace")
    except Exception:
        return None
    current = None
    for line in text.splitlines():
        if line.startswith("processor"):
            current = int(line.split(":")[1])
        elif current == cpu and line.startswith("cpu MHz"):
            try:
                return float(line.split(":")[1])
            except ValueError:
                return None
    return None


def freq_khz(cpu: int) -> int | None:
    base = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq")
    for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
        try:
            return int((base / name).read_text().strip())
        except Exception:
            continue
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cores", required=True)
    ap.add_argument("--bench-core", type=int, required=True)
    ap.add_argument("--bench-pid-file", type=Path, default=None)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--interval", type=float, default=0.2)
    ap.add_argument("--threshold", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=0.0)
    args = ap.parse_args()

    cores = [int(x) for x in args.cores.split(",") if x.strip()]
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    max_busy = {c: 0.0 for c in cores}
    max_foreign = {c: 0.0 for c in cores}
    foreign_series = []
    freq_sysfs = []
    freq_cpuinfo = []
    bench_series = []
    samples = 0

    prev = cpu_stats()
    prev_t = time.monotonic()
    prev_pid = 0
    prev_ticks = 0
    seen_pid = False
    while RUNNING:
        time.sleep(args.interval)
        now_t = time.monotonic()
        dt = now_t - prev_t
        if dt <= 0:
            continue
        cur = cpu_stats()
        pid = read_pid(args.bench_pid_file) if args.bench_pid_file else 0
        alive = bool(pid) and Path(f"/proc/{pid}").exists()
        if alive:
            seen_pid = True
        elif pid:
            break  # pid file exists and the benchmark is gone; exit on our own
        ticks = proc_ticks(pid) if alive else 0
        if pid != prev_pid:
            prev_pid, prev_ticks = pid, ticks
            prev = cur
            prev_t = now_t
            continue
        bench_pct = 100.0 * (ticks - prev_ticks) / (HZ * dt) if pid else 0.0
        bench_pct = max(0.0, bench_pct)
        for cpu in cores:
            if cpu not in cur or cpu not in prev:
                continue
            dtot = cur[cpu][0] - prev[cpu][0]
            didle = cur[cpu][1] - prev[cpu][1]
            busy = 100.0 * (1.0 - didle / dtot) if dtot > 0 else 0.0
            foreign = max(0.0, busy - (bench_pct if cpu == args.bench_core else 0.0))
            max_busy[cpu] = max(max_busy[cpu], busy)
            max_foreign[cpu] = max(max_foreign[cpu], foreign)
            if foreign > 0.25:
                foreign_series.append({"t": round(now_t, 2), "cpu": cpu, "busy_pct": round(busy, 2), "foreign_pct": round(foreign, 2)})
        bench_series.append(round(bench_pct, 2))
        f1 = freq_khz(args.bench_core)
        f2 = cpu_mhz(args.bench_core)
        if f1:
            freq_sysfs.append(f1)
        if f2:
            freq_cpuinfo.append(f2 * 1000.0)
        prev = cur
        prev_t = now_t
        prev_ticks = ticks
        samples += 1
        if args.duration and samples * args.interval >= args.duration:
            break

    rejected = any(v > args.threshold for v in max_foreign.values())
    result = {
        "cores": cores,
        "bench_core": args.bench_core,
        "threshold_pct": args.threshold,
        "samples": samples,
        "max_busy_pct": {str(c): round(v, 2) for c, v in max_busy.items()},
        "max_foreign_pct": {str(c): round(v, 2) for c, v in max_foreign.items()},
        "rejected": rejected,
        "bench_cpu_pct": {
            "max": max(bench_series) if bench_series else 0.0,
            "median": statistics.median(bench_series) if bench_series else 0.0,
        },
        "freq_khz_sysfs": {
            "min": min(freq_sysfs) if freq_sysfs else None,
            "median": statistics.median(freq_sysfs) if freq_sysfs else None,
            "max": max(freq_sysfs) if freq_sysfs else None,
        },
        "freq_khz_cpuinfo": {
            "min": min(freq_cpuinfo) if freq_cpuinfo else None,
            "median": statistics.median(freq_cpuinfo) if freq_cpuinfo else None,
            "max": max(freq_cpuinfo) if freq_cpuinfo else None,
        },
        "foreign_series": foreign_series[-400:],
    }
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("cores", "bench_core", "max_foreign_pct", "rejected", "freq_khz_sysfs", "freq_khz_cpuinfo")}))
    return 1 if rejected else 0


if __name__ == "__main__":
    sys.exit(main())
