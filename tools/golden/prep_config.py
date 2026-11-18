#!/usr/bin/env python3
"""Write a replay-time ProtO-RU profile: dump window anchored to the pcap, gate marker and C-plane lead."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

DROP = {
    "max_dump_slots",
    "dump_start_stable_slots",
    "dump_start_du_slot",
    "dump_start_marker",
    "align_cplane_lead_us",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile-yaml", required=True, type=Path)
    ap.add_argument("--window-json", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--marker", required=True)
    ap.add_argument("--stable-slots", type=int, default=10)
    args = ap.parse_args()

    win = json.loads(args.window_json.read_text())
    text = args.profile_yaml.read_text()
    m = re.search(r'^(\s*device_args:\s*)"([^"]*)"', text, re.MULTILINE)
    if not m:
        raise SystemExit(f"prep-config: no quoted device_args in {args.profile_yaml}")

    kv = []
    for item in m.group(2).split(","):
        item = item.strip()
        if not item:
            continue
        key = item.split("=", 1)[0]
        if key in DROP:
            continue
        kv.append(item)
    kv += [
        f"max_dump_slots={win['window_slots']}",
        f"dump_start_stable_slots={args.stable_slots}",
        f"dump_start_du_slot={win['start_du']}",
        f"dump_start_marker={args.marker}",
        f"align_cplane_lead_us={int(round(float(win['lead_us'])))}",
    ]
    new_line = f'{m.group(1)}"{",".join(kv)}"'
    args.out.write_text(text[: m.start()] + new_line + text[m.end() :])
    print(f"prep-config: {args.out} window={win['window_slots']} start_du={win['start_du']} lead_us={win['lead_us']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
