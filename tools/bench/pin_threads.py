#!/usr/bin/env python3
"""Pin a running container's threads to a CPU plan and check the result (bench host).

    pin_threads.py <container> "<plan>" [--apply]

Plan: space-separated ``name=cpu`` entries. ``name`` is the exact thread name
(/proc/<tid>/comm, max 15 chars); ``*=cpu`` covers every other thread that is
still allowed on the container's whole cpuset (threads the application did not
pin itself: UHD control, gRPC, loggers, the main thread). Threads the
application pinned and the plan does not name are left alone and only reported.

The thread map is read from the host's /proc (no root needed). With --apply,
threads that differ from the plan are moved with taskset in a throw-away
container that shares the target's PID namespace and has CAP_SYS_NICE: no
``docker exec`` into the real-time container and no sudo.

Prints the measured map and exits 1 if any thread the plan covers is not where
the plan says (after --apply), 0 otherwise. A planned name with no thread is a
warning, not a failure (the set of threads depends on the radio profile).
"""
import argparse
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from cpulist import parse as parse_cpus  # noqa: E402

POLICIES = {0: "OTHER", 1: "FIFO", 2: "RR", 3: "BATCH", 5: "IDLE"}


def parse_plan(text: str) -> tuple[dict[str, int], int | None]:
    """'a=3 b#0=4 *=12' -> ({'a': 3, 'b#0': 4}, 12)."""
    named: dict[str, int] = {}
    star = None
    for tok in text.split():
        name, sep, cpu = tok.rpartition("=")
        if not sep or not name or not cpu.isdigit():
            raise ValueError(f"bad plan entry {tok!r} (want name=cpu)")
        if name == "*":
            star = int(cpu)
        elif name in named:
            raise ValueError(f"thread {name!r} listed twice in the plan")
        else:
            named[name] = int(cpu)
    return named, star


def decide(threads: list[dict], named: dict[str, int], star: int | None, full: set[int]) -> list[dict]:
    """Annotate each thread with 'want' (target CPU or None) and 'state'.

    state: 'ok'        planned and already on its CPU (an unnamed thread already on the
                       '*' CPU counts as planned: that is where the step put it)
           'move'      planned, currently elsewhere
           'app-pinned' not in the plan, pinned by the application (left alone)
    """
    out = []
    for t in threads:
        want = named.get(t["comm"])
        if want is None and star is not None and (t["aff"] == full or t["aff"] == {star}):
            want = star
        if want is None:
            state = "app-pinned"
        else:
            state = "ok" if t["aff"] == {want} else "move"
        out.append({**t, "want": want, "state": state})
    return out


def missing_names(threads: list[dict], named: dict[str, int]) -> list[str]:
    present = {t["comm"] for t in threads}
    return sorted(n for n in named if n not in present)


def read_threads(pid: int) -> list[dict]:
    threads = []
    for task in sorted(pathlib.Path(f"/proc/{pid}/task").iterdir(), key=lambda p: int(p.name)):
        tid = int(task.name)
        try:
            comm = (task / "comm").read_text().strip()
            stat = (task / "stat").read_text()
            nspid = [ln for ln in (task / "status").read_text().splitlines() if ln.startswith("NSpid:")]
            aff = set(os.sched_getaffinity(tid))
            policy = POLICIES.get(os.sched_getscheduler(tid), "?")
            prio = os.sched_getparam(tid).sched_priority
        except (FileNotFoundError, ProcessLookupError):
            continue  # thread exited while we looked
        cpu = int(stat.rsplit(")", 1)[1].split()[36])
        ns_tid = int(nspid[0].split()[-1]) if nspid else tid
        threads.append({"tid": tid, "ns_tid": ns_tid, "comm": comm, "aff": aff, "cpu": cpu,
                        "policy": f"{policy}/{prio}"})
    return threads


def fmt_cpus(cpus: set[int]) -> str:
    return ",".join(str(c) for c in sorted(cpus))


def apply_moves(container: str, image: str, moves: list[dict]) -> None:
    cmd = " && ".join(f"taskset -cp {m['want']} {m['ns_tid']} >/dev/null" for m in moves)
    subprocess.run(["docker", "run", "--rm", "--network", "none", "--pid", f"container:{container}",
                    "--cap-add", "SYS_NICE", "--entrypoint", "/bin/sh", image, "-c", cmd],
                   check=True, capture_output=True, text=True, timeout=60)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("container")
    ap.add_argument("plan")
    ap.add_argument("--apply", action="store_true", help="move threads that differ from the plan")
    a = ap.parse_args()

    try:
        named, star = parse_plan(a.plan)
    except ValueError as e:
        print(f"pin: FAIL: {e}", file=sys.stderr)
        return 1
    insp = subprocess.run(["docker", "inspect", "-f", "{{.State.Pid}} {{.Config.Image}} {{.HostConfig.CpusetCpus}}",
                           a.container], check=True, capture_output=True, text=True).stdout.split()
    pid, image, cpuset = int(insp[0]), insp[1], insp[2] if len(insp) > 2 else ""
    full = set(parse_cpus(cpuset)) if cpuset else set(os.sched_getaffinity(pid))
    for cpu in list(named.values()) + ([star] if star is not None else []):
        if cpu not in full:
            print(f"pin: FAIL: plan CPU {cpu} is outside {a.container}'s cpuset {fmt_cpus(full)}", file=sys.stderr)
            return 1

    rows = decide(read_threads(pid), named, star, full)
    moves = [r for r in rows if r["state"] == "move"]
    if a.apply and moves:
        apply_moves(a.container, image, moves)
        rows = decide(read_threads(pid), named, star, full)

    print(f"pin: {a.container} (cpuset {fmt_cpus(full)}) plan: {a.plan}")
    print(f"  {'thread':<16} {'policy':<9} {'cpu':>3}  {'affinity':<10} {'plan':>4}  state")
    for r in sorted(rows, key=lambda r: (r["want"] is None, r["want"] or 0, r["comm"])):
        want = "-" if r["want"] is None else str(r["want"])
        print(f"  {r['comm']:<16} {r['policy']:<9} {r['cpu']:>3}  {fmt_cpus(r['aff']):<10} {want:>4}  {r['state']}")
    for name in missing_names(rows, named):
        print(f"pin: WARN: planned thread {name!r} not found in {a.container}")
    bad = [r for r in rows if r["state"] == "move"]
    if bad:
        print(f"pin: FAIL: {len(bad)} thread(s) not on their planned CPU: "
              + ", ".join(f"{r['comm']}({fmt_cpus(r['aff'])}->{r['want']})" for r in bad))
        return 1
    print(f"pin: OK: {sum(r['state'] == 'ok' for r in rows)} thread(s) on plan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
