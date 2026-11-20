#!/usr/bin/env python3
"""Pick idle physical cores on one NUMA node for the clean cost-model run.

Samples /proc/stat for a few seconds, then selects the least busy cores on the
GPU's NUMA node (falling back to the other node only if needed). SMT is reported
explicitly; this host currently has one thread per core.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import time
import sys
from pathlib import Path

FIELDS = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")


def cpu_times() -> dict[int, tuple[int, int]]:
    out = {}
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("cpu") and line[3:4].isdigit():
            parts = line.split()
            cpu = int(parts[0][3:])
            values = [int(v) for v in parts[1:9]]
            total = sum(values)
            idle = values[3] + values[4]
            out[cpu] = (total, idle)
    return out


def topology() -> tuple[dict[int, int], dict[int, int], int]:
    cpu_node: dict[int, int] = {}
    cpu_core: dict[int, int] = {}
    threads_per_core = 1
    for line in subprocess.check_output(["lscpu", "-p=CPU,CORE,SOCKET,NODE"], text=True).splitlines():
        if line.startswith("#") or not line.strip():
            continue
        fields = line.split(",")
        cpu, core, _socket, node = (int(x) for x in fields[:4])
        cpu_node[cpu] = node
        cpu_core[cpu] = core
    counts: dict[int, int] = {}
    for core in cpu_core.values():
        counts[core] = counts.get(core, 0) + 1
    if counts:
        threads_per_core = max(counts.values())
    return cpu_node, cpu_core, threads_per_core


def gpu_numa_node(uuid: str) -> int:
    bus = subprocess.check_output(
        ["nvidia-smi", "-i", uuid, "--query-gpu=pci.bus_id", "--format=csv,noheader"], text=True
    ).strip()
    # 00000000:44:00.0 -> 0000:44:00.0
    domain, rest = bus.split(":", 1)
    short = f"{domain[-4:]}:{rest}"
    path = Path(f"/sys/bus/pci/devices/{short}/numa_node")
    return int(path.read_text().strip()) if path.exists() else -1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--uuid", default="GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058")
    ap.add_argument("--count", type=int, default=3)
    ap.add_argument("--sample-seconds", type=float, default=5.0)
    ap.add_argument("--max-busy", type=float, default=1.0)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    gpu_node = gpu_numa_node(args.uuid)
    cpu_node, cpu_core, threads_per_core = topology()
    nodes = sorted(set(cpu_node.values()))

    prev = cpu_times()
    last = time.monotonic()
    start = last
    stats: dict[int, list[float]] = {cpu: [] for cpu in cpu_node}
    while time.monotonic() - start < args.sample_seconds:
        time.sleep(0.5)
        cur = cpu_times()
        now = time.monotonic()
        dt = now - last
        if dt <= 0:
            continue
        for cpu, (total, idle) in cur.items():
            if cpu not in prev:
                continue
            dtot = total - prev[cpu][0]
            didle = idle - prev[cpu][1]
            if dtot > 0:
                stats.setdefault(cpu, []).append(100.0 * (1.0 - didle / dtot))
        prev = cur
        last = now

    node_rows = {}
    for node in nodes:
        rows = []
        for cpu, samples in stats.items():
            if cpu_node.get(cpu) != node or not samples:
                continue
            rows.append({
                "cpu": cpu,
                "core": cpu_core.get(cpu, cpu),
                "mean_pct": round(sum(samples) / len(samples), 3),
                "max_pct": round(max(samples), 3),
            })
        rows.sort(key=lambda r: (r["max_pct"], r["mean_pct"], r["cpu"]))
        node_rows[node] = rows

    # Prefer the GPU's NUMA node unless the other node is clearly quieter.
    best_node = gpu_node if gpu_node in node_rows else nodes[0]
    best_score = max(r["max_pct"] for r in node_rows[best_node][: args.count])
    for node, rows in node_rows.items():
        if node == best_node or len(rows) < args.count:
            continue
        score = max(r["max_pct"] for r in rows[: args.count])
        if score + 0.5 < best_score:
            best_node, best_score = node, score

    rows = node_rows[best_node]
    if len(rows) < args.count:
        args.out.write_text(json.dumps({"error": "not enough cores on a node", "gpu_numa_node": gpu_node}, indent=2) + "\n")
        print("not enough cores on a single NUMA node", file=sys.stderr)
        return 1
    chosen = rows[: args.count]
    result = {
        "numa_node": best_node,
        "gpu_numa_node": gpu_node,
        "fallback_node": best_node != gpu_node,
        "threads_per_core": threads_per_core,
        "sample_seconds": args.sample_seconds,
        "cores": [r["cpu"] for r in sorted(chosen, key=lambda r: r["cpu"])],
        "bench_core": chosen[0]["cpu"],
        "mean_busy_pct": {str(r["cpu"]): r["mean_pct"] for r in chosen},
        "max_busy_pct": {str(r["cpu"]): r["max_pct"] for r in chosen},
        "topology": rows,
    }
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("numa_node", "gpu_numa_node", "fallback_node", "cores", "bench_core", "threads_per_core", "mean_busy_pct", "max_busy_pct")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
