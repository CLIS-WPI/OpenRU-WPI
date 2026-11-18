#!/usr/bin/env bash
# tests/smoke-core — wrap of the existing `make smoke-core` (NG Setup against Open5GS).
# Profiles: default. See tests/smoke-core/README.md.
#
# Usage: PROFILE=default tests/smoke-core/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=smoke-core
. "$ROOT/tests/lib/common.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"
RAW="$ROOT/docs/reports/raw"
EV_FILES=(plmn-compare.md smoke-core-du.log)

echo "[smoke-core] tag=${OPENRU_TAG}" | tee -a "$LOG"

trap 'test_unlock_measure' EXIT

# 1. Preflight.
if ! make -C "$ROOT" preflight >>"$LOG" 2>&1; then
  echo "[smoke-core] preflight FAILED" | tee -a "$LOG"
  TEST_STATUS=FAIL; TEST_RC=1
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "${EV_FILES[@]/#/$RAW/}" "$LOG"
fi

# 2. Lock (compose up/down while a measurement runs would break it).
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "${EV_FILES[@]/#/$RAW/}" "$LOG"
fi

# 3. The existing target, unchanged.
echo "[smoke-core] running make smoke-core (timeout ${TIMEOUT_SECS:-900}s)" | tee -a "$LOG"
RC=0
timeout "${TIMEOUT_SECS:-900}" make -C "$ROOT" smoke-core OPENRU_TAG="${OPENRU_TAG}" >>"$LOG" 2>&1 || RC=$?
cp -f "${EV_FILES[@]/#/$RAW/}" "$EVDIR/" 2>/dev/null || true

if [[ "$RC" -eq 0 ]]; then
  TEST_STATUS=PASS; TEST_RC=0
else
  TEST_STATUS=FAIL; TEST_RC="$RC"
fi

# 4. Metrics: NG Setup observed + PLMN comparison status.
METRICS_OUT="$EVDIR/metrics.json"
python3 - "$EVDIR" "$METRICS_OUT" <<'PY' || METRICS_OUT="-"
import json, re, sys
from pathlib import Path
ev = Path(sys.argv[1])
du = ""
for f in [ev / "smoke-core-du.log", ev / "run.log"]:
    if f.exists():
        du += f.read_text(errors="replace")
ng_setup = bool(re.search(r"NGSetupResponse|NG Setup (Procedure )?Response|Connected to AMF|NG Setup successful", du))
plmn_ok = "ALIGN: OK" in (ev / "plmn-compare.md").read_text(errors="replace") if (ev / "plmn-compare.md").exists() else None
out = {"ng_setup_response_seen": ng_setup, "plmn_compare_ok": plmn_ok}
Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
PY

test_finish "$METRICS_OUT" "${EV_FILES[@]/#/$RAW/}" "$LOG"
