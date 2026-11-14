#!/usr/bin/env python3
"""Explain warm-up late packets: direction, plane, and which KPI seconds."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parse_smoke_fh import late_per_second, parse_du_ofh, parse_kpi  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ru-log", required=True)
    ap.add_argument("--du-log", default="")
    ap.add_argument("--warmup", type=int, default=57)
    args = ap.parse_args()

    rows = parse_kpi(Path(args.ru_log).read_text(errors="replace"))
    hist = late_per_second(rows)
    warm = [h for h in hist if h[0] < args.warmup and h[4] > 0]
    rest = [h for h in hist if h[0] >= args.warmup and h[4] > 0]

    print(f"=== Warm-up window [0, {args.warmup})s @RU (DL from DU) ===")
    print("Direction: DL at RU (RX_*). Planes: U=RX_LATE, C=RX_LATE_C, C_UL=RX_LATE_C_U")
    wu = wc = wcu = 0
    for rel, up, c, cu, sm in warm:
        print(f"  t+{rel:4d}s  U={up} C={c} C_UL={cu} sum={sm}  [MEASURED]")
        wu += up
        wc += c
        wcu += cu
    print(f"warm-up totals: U={wu} C={wc} C_UL={wcu} sum={wu+wc+wcu}  [MEASURED]")
    print("Note: ProtO-RU KPI rows are 1s aggregates — per-slot SFN is not in the KPI table.")
    if args.du_log:
        du = parse_du_ofh(Path(args.du_log).read_text(errors="replace"))
        print(
            f"DU UL (full log): ul_rx_late={du['ul_rx_late']} "
            f"past_seq_drops={du['ul_past_seq_drops']}  [MEASURED]"
        )
    print(f"=== Post warm-up late seconds: {len(rest)} ===")
    for rel, up, c, cu, sm in rest[:20]:
        print(f"  t+{rel:4d}s  U={up} C={c} C_UL={cu} sum={sm}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
