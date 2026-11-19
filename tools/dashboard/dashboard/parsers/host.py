"""Host, kernel-isolation, NIC and hwlat state for the bench dashboard."""

from __future__ import annotations

import os
import platform
import re
import shutil
import socket
import time
from pathlib import Path
from typing import Iterable, List, Optional

from .common import parse_number

_CPU_ENTRY_RE = re.compile(r"^\s*(\d+)(?:-(\d+))?(?::\d+)?\s*$")


def parse_cpu_list(text: str) -> List[int]:
    cpus: List[int] = []
    for entry in (text or "").replace("\n", ",").split(","):
        entry = entry.strip()
        if not entry:
            continue
        for part in entry.split(","):
            match = _CPU_ENTRY_RE.match(part)
            if not match:
                continue
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else start
            step = 1
            if ":" in part:
                try:
                    step = int(part.rsplit(":", 1)[1])
                except ValueError:
                    step = 1
            cpus.extend(range(start, end + 1, max(1, step)))
    return sorted(set(cpus))


def parse_isolated(text: str) -> List[int]:
    return parse_cpu_list(text)


def parse_hwlat(text: str) -> dict:
    max_us: List[int] = []
    below = 0
    for line in (text or "").splitlines():
        match = re.search(r"Max Latency:\s*(\d+)\s*us", line, re.IGNORECASE)
        if match:
            max_us.append(int(match.group(1)))
        if "Below threshold" in line:
            below += 1
    return {
        "samples": len(max_us),
        "max_us": max(max_us) if max_us else None,
        "last_us": max_us[-1] if max_us else None,
        "below_threshold": below,
        "available": bool(max_us or below),
    }


def _meminfo() -> dict:
    data = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            data[key] = int(value.strip().split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    total = data.get("MemTotal")
    available = data.get("MemAvailable")
    return {
        "total_bytes": total,
        "available_bytes": available,
        "used_pct": round(100 * (1 - available / total), 1) if total and available else None,
    }


def _nic_names(fh_iface: Optional[str] = None) -> List[str]:
    base = Path("/sys/class/net")
    if not base.exists():
        return []
    names = []
    for entry in sorted(base.iterdir()):
        name = entry.name
        if name == "lo" or name.startswith(("veth", "docker", "br-", "virbr")):
            continue
        if fh_iface:
            if name == fh_iface:
                names.append(name)
            continue
        try:
            state = (entry / "operstate").read_text().strip()
        except OSError:
            continue
        if state in {"up", "unknown"}:
            names.append(name)
    return names


def _read_int(path: Path) -> Optional[int]:
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text().strip()
    except OSError:
        return None


def nic_snapshot(fh_iface: Optional[str] = None) -> List[dict]:
    out = []
    base = Path("/sys/class/net")
    for name in _nic_names(fh_iface):
        path = base / name
        out.append(
            {
                "name": name,
                "state": _read_text(path / "operstate"),
                "mtu": _read_int(path / "mtu"),
                "speed_mbps": _read_int(path / "speed"),
                "rx_errors": _read_int(path / "statistics" / "rx_errors"),
                "rx_dropped": _read_int(path / "statistics" / "rx_dropped"),
                "tx_errors": _read_int(path / "statistics" / "tx_errors"),
                "tx_dropped": _read_int(path / "statistics" / "tx_dropped"),
            }
        )
    return out


def _cmdline() -> str:
    return _read_text(Path("/proc/cmdline")) or ""


def _cmdline_value(name: str) -> Optional[str]:
    for token in _cmdline().split():
        if token == name:  # no-secrets-ok
            return "1"
        if token.startswith(name + "="):
            return token.split("=", 1)[1]
    return None


def _trace_text() -> Optional[str]:
    for path in (
        Path("/sys/kernel/debug/tracing/trace"),
        Path("/sys/kernel/tracing/trace"),
        Path("/sys/kernel/debug/tracing/trace_pipe"),
    ):
        try:
            return path.read_text(errors="replace")[-20000:]
        except OSError:
            continue
    return None


def _disk() -> dict:
    try:
        usage = shutil.disk_usage("/")
    except OSError:
        return {"total_bytes": None, "free_bytes": None, "used_pct": None}
    return {
        "total_bytes": usage.total,
        "free_bytes": usage.free,
        "used_pct": round(100 * usage.used / usage.total, 1) if usage.total else None,
    }


def host_snapshot(bench_env: Optional[dict] = None, now: Optional[float] = None) -> dict:
    now = time.time() if now is None else now
    bench_env = bench_env or {}
    isolated = parse_isolated(_read_text(Path("/sys/devices/system/cpu/isolated")) or "")
    nohz_full = parse_cpu_list(
        _read_text(Path("/sys/devices/system/cpu/nohz_full")) or ""
    )
    if not nohz_full:
        nohz_full = parse_cpu_list(_cmdline_value("nohz_full") or "")
    rcu_nocbs = parse_cpu_list(_cmdline_value("rcu_nocbs") or "")
    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = None
    trace = _trace_text()
    hwlat = parse_hwlat(trace) if trace is not None else {
        "samples": 0,
        "max_us": None,
        "last_us": None,
        "below_threshold": 0,
        "available": False,
    }
    if trace is None:
        hwlat["reason"] = "tracing trace not readable"
    try:
        uptime_s = float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        uptime_s = None
    return {
        "ts": now,
        "hostname": socket.gethostname(),
        "kernel": platform.release(),
        "cpu_count": os.cpu_count(),
        "load": {"1m": load1, "5m": load5, "15m": load15},
        "memory": _meminfo(),
        "disk_root": _disk(),
        "uptime_s": uptime_s,
        "isolation": {
            "isolcpus": parse_isolated(_cmdline_value("isolcpus") or ""),
            "isolated_sysfs": isolated,
            "nohz_full": nohz_full,
            "rcu_nocbs": rcu_nocbs,
            "irqaffinity": _cmdline_value("irqaffinity"),
            "cstate_limit": {
                "intel_idle.max_cstate": _cmdline_value("intel_idle.max_cstate"),
                "processor.max_cstate": _cmdline_value("processor.max_cstate"),
            },
        },
        "cpusets": {
            "protoru": bench_env.get("PROTORU_CPUSET"),
            "du": bench_env.get("DU_CPUSET"),
            "core": bench_env.get("CORE_CPUSET"),
        },
        "nic": nic_snapshot(bench_env.get("BENCH_FH_IFACE")),
        "fh_iface": bench_env.get("BENCH_FH_IFACE"),
        "hwlat": hwlat,
    }
