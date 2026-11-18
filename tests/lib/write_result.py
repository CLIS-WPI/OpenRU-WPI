#!/usr/bin/env python3
"""Write one test-framework result JSON (docs/reports/runs/<suite>/<date>-<profile>.json).

Common schema for every suite run:
  schema, suite, profile, status (PASS|FAIL|INVALID|SKIPPED), skip_reason,
  image {tag,digest,id}, submodule_commit, repo_commit, host {...},
  isolation {...}, start, end, rc, command, metrics {...}, evidence [...]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import re
import socket
import subprocess
import sys
from pathlib import Path

SCHEMA = "openru-test-result/1"


def sh(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    except Exception:
        return ""


def repo_commit(root: Path) -> str:
    return sh(["git", "-C", str(root), "rev-parse", "HEAD"])


def submodule_commit(root: Path) -> str:
    return sh(["git", "-C", str(root / "external" / "proto-ru"), "rev-parse", "HEAD"])


def kernel_isolation() -> dict:
    """isolcpus/nohz_full/rcu_nocbs coverage of the reserved cores (see BENCH_BUNDLE.md)."""

    def parse(spec: str) -> set[int]:
        cores: set[int] = set()
        for part in (spec or "").split(","):
            part = part.strip()
            if "-" in part:
                lo, hi = part.split("-", 1)
                cores.update(range(int(lo), int(hi) + 1))
            elif part:
                cores.add(int(part))
        return cores

    reserved = parse(f"{os_env('PROTORU_CPUSET')},{os_env('DU_CPUSET')}")
    cmdline = Path("/proc/cmdline").read_text() if Path("/proc/cmdline").exists() else ""

    def param(key: str) -> set[int]:
        for tok in cmdline.split():
            if tok.startswith(key + "="):
                val = tok.split("=", 1)[1]
                parts = [p for p in val.split(",") if re.fullmatch(r"\d+(-\d+)?", p)]
                return parse(",".join(parts))
        return set()

    iso, nohz, rcu = param("isolcpus"), param("nohz_full"), param("rcu_nocbs")
    covered = reserved & iso & nohz & rcu
    missing = sorted(reserved - covered)
    required = os_env("OPENRU_REQUIRE_ISOLATION") == "1"
    return {
        "isolated": bool(reserved) and not missing,
        "missing_cores": missing,
        "required": required,
        "kernel_params": {
            "isolcpus": sorted(iso),
            "nohz_full": sorted(nohz),
            "rcu_nocbs": sorted(rcu),
        },
    }


def os_env(key: str) -> str:
    import os

    return os.environ.get(key, "")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--suite", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--status", required=True, choices=["PASS", "FAIL", "INVALID", "SKIPPED"])
    ap.add_argument("--skip-reason", default="", help="host_limited | deferred")
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--rc", type=int, default=0)
    ap.add_argument("--image-tag", default="")
    ap.add_argument("--metrics-file", type=Path, default=None)
    ap.add_argument("evidence", nargs="*", help="evidence paths (relative to repo root when possible)")
    args = ap.parse_args()

    root = Path(sh(["git", "rev-parse", "--show-toplevel"]) or ".")
    image = {"tag": args.image_tag or os_env("OPENRU_TAG_USED") or os_env("OPENRU_TAG") or "", "digest": "", "id": ""}
    if image["tag"]:
        try:
            d = json.loads(sh(["docker", "image", "inspect", image["tag"]]).strip() or "[]")
            if d:
                image["id"] = d[0].get("Id", "").removeprefix("sha256:")[:12]
                digests = d[0].get("RepoDigests") or []
                image["digest"] = digests[0] if digests else ""
        except Exception:
            pass

    metrics: dict = {}
    if args.metrics_file and args.metrics_file.exists():
        try:
            metrics = json.loads(args.metrics_file.read_text())
        except Exception as exc:
            metrics = {"metrics_file_error": str(exc)}

    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    out_dir = root / "docs" / "reports" / "runs" / args.suite
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{stamp}-{args.profile}.json"

    evidence = []
    for p in args.evidence:
        if not p:
            continue
        path = Path(p)
        if not path.exists():
            continue  # evidence must exist; a vanished artifact is not evidence
        try:
            rp = path.resolve().relative_to(root.resolve())
            evidence.append(str(rp))
        except ValueError:
            evidence.append(str(p))

    result = {
        "schema": SCHEMA,
        "suite": args.suite,
        "profile": args.profile,
        "status": args.status,
        "skip_reason": args.skip_reason or None,
        "image": image,
        "repo_commit": repo_commit(root),
        "submodule_commit": submodule_commit(root),
        "host": {
            "hostname": socket.gethostname(),
            "kernel": platform.release(),
            "gpu_uuid": os_env("OPENRU_GPU_UUID"),
            "cpusets": {"protoru": os_env("PROTORU_CPUSET"), "du": os_env("DU_CPUSET")},
        },
        "isolation": kernel_isolation(),
        "start": args.start,
        "end": args.end,
        "rc": args.rc,
        "metrics": metrics,
        "evidence": evidence,
    }
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"{args.status} {out.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
