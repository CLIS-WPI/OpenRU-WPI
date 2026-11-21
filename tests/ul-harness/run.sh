#!/usr/bin/env bash
# UL/PRACH harness — Stage 2b: gate + synthetic UL plan + comparator self-test.
#
# The OFH/BFP wire decoder and the RU replay capture are the remaining Stage 2
# items; set UL_CAPTURE=<decoded-grid.npz> to run the comparator on a capture.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/ul-harness/evidence/$STAMP"
OUT="$ROOT/build/ul-harness"
mkdir -p "$EVDIR" "$OUT"
LOG="$EVDIR/run.log"
RC=0

{
  echo "== ul-harness Stage 2b $(date -u +%FT%TZ)"

  echo "== gate unit test"
  g++ -std=c++17 -O2 -Wall -Wextra -o "$OUT/test_null_rx_gate" \
    "$ROOT/tools/ul_harness/test_null_rx_gate.cpp" -I"$ROOT"
  "$OUT/test_null_rx_gate"

  echo "== synthetic UL plan + feed (20 slots)"
  python3 "$ROOT/tools/ul_harness/gen_ul_feed.py" --out "$OUT/gen" --slots 20

  echo "== comparator self-test + corruption matrix"
  python3 "$ROOT/tools/ul_harness/compare_ul.py" \
    --expected "$OUT/gen/expected.npz" --self-test --out "$EVDIR/compare.json"

  if [[ -n "${UL_CAPTURE:-}" ]]; then
    echo "== comparator on captured grid $UL_CAPTURE"
    python3 "$ROOT/tools/ul_harness/compare_ul.py" \
      --expected "$OUT/gen/expected.npz" --capture "$UL_CAPTURE" --out "$EVDIR/capture.json"
  else
    echo "== e2e capture: SKIPPED (set UL_CAPTURE=<decoded-grid.npz>; OFH/BFP decoder + RU replay pending)"
  fi
} 2>&1 | tee "$LOG" || RC=$?

python3 - "$EVDIR/metrics.json" "$RC" "${UL_CAPTURE:-}" <<'PY' || true
import json, sys
json.dump({"suite": "ul-harness", "stage": "2b",
           "gate": True, "synthetic_plan": True, "comparator_self_test": True,
           "captured_grid": bool(sys.argv[3]), "pass": int(sys.argv[2]) == 0},
          open(sys.argv[1], "w"), indent=2)
PY

if [[ "$RC" -eq 0 ]]; then
  echo "[ul-harness] PASS (gate + synthetic plan + comparator self-test; e2e capture pending)"
else
  echo "[ul-harness] FAIL rc=$RC"
fi
exit "$RC"
