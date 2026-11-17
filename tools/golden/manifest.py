#!/usr/bin/env python3
"""Write a golden MANIFEST.json and SHA256SUMS from a replay dump."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_rev(cwd: Path) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(cwd), "rev-parse", "HEAD"], text=True).strip()
    except Exception:  # noqa: BLE001
        return ""


def git_branch(cwd: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"], text=True
        ).strip()
    except Exception:  # noqa: BLE001
        return ""


def profile_bw(profile_yaml: Path) -> int:
    m = re.search(r"^\s*bandwidth\s*:\s*(\d+)", profile_yaml.read_text(), re.MULTILINE)
    return int(m.group(1)) if m else 0


def load_tx_index(dump: Path) -> list[dict]:
    out = []
    p = dump / "tx_index.jsonl"
    if not p.exists():
        return out
    for line in p.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump", required=True, type=Path)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--profile-yaml", required=True, type=Path)
    ap.add_argument("--window-json", required=True, type=Path)
    ap.add_argument("--pcap", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--mtu", type=int, required=True)
    ap.add_argument("--check-json", default=None, type=Path)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--root", required=True, type=Path)
    args = ap.parse_args()

    meta = json.loads((args.dump / "iq_meta.json").read_text())
    win = json.loads(args.window_json.read_text())
    tx = load_tx_index(args.dump)
    slots = [(int(e["du_sfn"]), int(e["du_slot"])) for e in tx if "du_sfn" in e and "du_slot" in e]
    if not slots:
        raise SystemExit("manifest: no tx_index slots")
    first_key, last_key = min(slots), max(slots)

    ports = sorted(args.dump.glob("port*.cf32"))
    files: dict[str, dict] = {}
    sums: list[str] = []
    for p in ports + [args.dump / "iq_meta.json", args.dump / "tx_index.jsonl"]:
        if not p.exists():
            continue
        h = sha256(p)
        files[p.name] = {"sha256": h, "bytes": p.stat().st_size}
        sums.append(f"{h}  {p.name}")

    manifest = {
        "profile": args.profile,
        "bandwidth_MHz": profile_bw(args.profile_yaml),
        "nof_ports": len(ports),
        "ports": [p.name for p in ports],
        "scs_kHz": meta["slot_grid"]["scs_kHz"],
        "sample_rate_Hz": meta["sample_rate_Hz"],
        "samples_per_slot": meta["slot_grid"]["samples_per_slot"],
        "nof_slots": win["window_slots"],
        "max_dump_slots_cap": meta["dump"]["max_dump_slots"],
        "start_du": {
            "sfn": win["start_du_sfn"],
            "slot": win["start_du_slot"],
        },
        "start_du_slot": win["start_du"],
        "window_slots": win["window_slots"],
        "lead_us": win["lead_us"],
        "first_du": {"sfn": first_key[0], "slot": first_key[1]},
        "last_du": {"sfn": last_key[0], "slot": last_key[1]},
        "last_du_from_meta": {
            "sfn": meta["dump"]["last_du_sfn"],
            "slot": meta["dump"]["last_du_slot"],
        },
        "total_iq_bytes": sum(files[p.name]["bytes"] for p in ports),
        "tx_index_entries": len(tx),
        "files": files,
        "SHA256": {k: v["sha256"] for k, v in files.items()},
        "pcap": args.pcap,
        "json_window": win,
        "openru_sw_commit": git_rev(args.root),
        "proto_ru_commit": git_rev(args.root / "external" / "proto-ru"),
        "proto_ru_branch": git_branch(args.root / "external" / "proto-ru"),
        "image": args.tag,
        "network_mtu": args.mtu,
        "compare_gate": "0 differing samples (CPU vs CPU, two cold replays)",
        "golden_check": json.loads(args.check_json.read_text()) if args.check_json and args.check_json.exists() else {},
        "dump_gate": meta.get("dump", {}),
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.out_dir / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    print(f"manifest: wrote {args.out_dir/'MANIFEST.json'} ({args.profile}, {win['window_slots']} slots from "
          f"{win['start_du_sfn']}.{win['start_du_slot']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
