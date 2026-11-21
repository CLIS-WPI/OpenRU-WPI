#!/usr/bin/env bash
# UL/PRACH harness — Stage 2a gate test.
#
# Runs the null-radio RX start-gate unit test. The synthetic UL C-plane,
# feed/comparator e2e and corruption capture are the remaining Stage 2 work;
# they will call the same gate and comparator and run under this target.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/ul-harness/evidence/$STAMP"
mkdir -p "$EVDIR" "$ROOT/build/ul-harness"
LOG="$EVDIR/run.log"
RC=0

{
  echo "== ul-harness Stage 2a gate test $(date -u +%FT%TZ)"
  g++ -std=c++17 -O2 -Wall -Wextra \
    -o "$ROOT/build/ul-harness/test_null_rx_gate" \
    "$ROOT/tools/ul_harness/test_null_rx_gate.cpp" -I"$ROOT"
  "$ROOT/build/ul-harness/test_null_rx_gate"
} 2>&1 | tee "$LOG" || RC=$?

python3 - "$EVDIR/metrics.json" "$RC" <<'PY' || true
import json, sys
json.dump({"suite": "ul-harness", "stage": "2a-gate", "pass": int(sys.argv[2]) == 0,
           "full_e2e": False}, open(sys.argv[1], "w"), indent=2)
PY

if [[ "$RC" -eq 0 ]]; then
  echo "[ul-harness] PASS (Stage 2a gate; full e2e pending)"
else
  echo "[ul-harness] FAIL rc=$RC"
fi
exit "$RC"
