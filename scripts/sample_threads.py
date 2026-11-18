#!/usr/bin/env python3
"""Sample per-thread CPU of the OpenRU containers every N seconds.

Each sample reads /proc/<pid>/task/<tid>/stat inside the container and reports
the CPU used between two samples (instantaneous over the sample interval), not
the lifetime average that `ps -o pcpu` would give.

Writes one CSV row per thread per sample: ts,run,container,category,tid,psr,pcpu,comm.

OFH receive/decode workers are reported separately from the low-PHY workers
(ProtO-RU names from proto-ru/ARCHITECTURE.md section 4):
  ru_rx_#i   -> ofh_rx          (Ethernet receiver, frames in)
  ru_emu_#i  -> ofh_rx_decode   (OFH receive decode + mode handler)
  ru_ofh_tx  -> ofh_tx          (OFH transmit / drain)
  ru_phy*, ru_timing -> low_phy (lower-PHY baseband + GPS tick)
  ru_radio   -> radio
DU side: gnb -> du_main, ru_txrx/ru_timing -> du_ofh, main_pool -> du_worker_pool.
Unknown names go to `other` and are printed once to stderr.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import subprocess
import sys
import time

CLK_TCK = 100


def classify(container: str, comm: str) -> str:
    if container.endswith("protoru-1"):
        if comm == "ru_emulator":
            return "main"
        if comm.startswith("ru_rx_"):
            return "ofh_rx"
        if comm.startswith("ru_emu_"):
            return "ofh_rx_decode"
        if comm.startswith("ru_ofh_tx_"):
            return "ofh_tx"
        if comm.startswith("ru_phy") or comm == "ru_timing":
            return "low_phy"
        if comm.startswith("ru_radio_"):
            return "radio"
        return "other"
    if comm == "gnb":
        return "du_main"
    if comm == "ru_timing" or comm.startswith("ru_txrx"):
        return "du_ofh"
    if comm.startswith("main_pool"):
        return "du_worker_pool"
    return "other"


def container_id(name: str) -> str:
    try:
        out = subprocess.run(
            ["docker", "ps", "-q", "--filter", f"name=^{name}$"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def threads(cid: str) -> list[tuple[str, str, str, str]]:
    """Return (host_pid, host_tid, psr, comm) from the host, without entering
    the container. `docker exec` is unusable during a run: the RT threads
    occupy the container cpuset and starve a SCHED_OTHER shell."""
    try:
        out = subprocess.run(
            ["docker", "top", cid, "-eo", "pid,tid,psr,comm"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except Exception:
        return []
    rows = []
    for line in out.stdout.splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) != 4:
            continue
        pid, tid, psr, comm = parts
        if not (pid.isdigit() and tid.isdigit()):
            continue
        rows.append((pid, tid, psr, comm))
    return rows


def sample(pid: str, tid: str, psr: str) -> tuple[int, int] | None:
    """(utime, stime) ticks from the host /proc for one container thread."""
    try:
        with open(f"/proc/{pid}/task/{tid}/stat") as fh:
            s = fh.read()
    except OSError:
        return None
    end = s.rfind(")")
    if end < 0:
        return None
    post = s[end + 2:].split()
    try:
        return int(post[11]), int(post[12])
    except (ValueError, IndexError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=20.0)
    ap.add_argument("--run", default="")
    ap.add_argument("--containers", default="openru-protoru-1,openru-du-1")
    ap.add_argument("--stop-file", default="")
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    names = [n for n in args.containers.split(",") if n]
    seen_unknown: set[str] = set()
    prev: dict[tuple[str, str], tuple[int, float]] = {}
    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ts", "run", "container", "category", "tid", "psr", "pcpu", "comm"])
        fh.flush()
        while True:
            if args.stop_file:
                try:
                    if open(args.stop_file).read().strip() == "stop":
                        break
                except FileNotFoundError:
                    pass
            ts = dt.datetime.now().astimezone().isoformat(timespec="seconds")
            now = time.monotonic()
            for name in names:
                cid = container_id(name)
                if not cid:
                    continue
                for pid, tid, psr, comm in threads(cid):
                    ticks = sample(pid, tid, psr)
                    if ticks is None:
                        continue
                    cat = classify(name, comm)
                    if cat == "other" and comm not in seen_unknown:
                        seen_unknown.add(comm)
                        print(f"[sample_threads] unclassified {name} thread: {comm}", file=sys.stderr)
                    key = (name, tid)
                    pcpu = ""
                    if key in prev:
                        old_ticks, old_t = prev[key]
                        dt_s = now - old_t
                        if dt_s > 0:
                            pcpu = f"{100.0 * (sum(ticks) - old_ticks) / CLK_TCK / dt_s:.2f}"
                    prev[key] = (sum(ticks), now)
                    w.writerow([ts, args.run, name, cat, tid, psr, pcpu, comm])
            fh.flush()
            if args.once:
                break
            time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
