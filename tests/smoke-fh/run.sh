#!/usr/bin/env bash
# tests/smoke-fh — wrap of the existing `make smoke-fh` M0/M1 fronthaul gate.
# Profiles: emulator (M0, PROTORU_PROFILE=emulator), null (M1, null radio).
# See tests/smoke-fh/README.md.
#
# Usage: PROFILE=emulator tests/smoke-fh/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=smoke-fh
. "$ROOT/tests/lib/common.sh"
. "$ROOT/tests/lib/quiet_host.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"
RAW="$ROOT/docs/reports/raw"
EV_FILES=(smoke-fh-kpi.json smoke-fh-late-hist.csv smoke-fh-hostcheck.json smoke-fh-hostcheck-pre.json smoke-fh-du.log smoke-fh-ru.log)
RATE_OUT="$EVDIR/uplane-rate.json"
METRICS="$EVDIR/metrics.json"

echo "[smoke-fh] tag=${OPENRU_TAG} protoru_profile=${PROTORU_PROFILE} secs=${SMOKE_SECS}" | tee -a "$LOG"

trap 'test_unlock_measure' EXIT

# 1. Preflight (fail closed on lab.env/GPU problems).
if ! make -C "$ROOT" preflight >>"$LOG" 2>&1; then
  echo "[smoke-fh] preflight FAILED" | tee -a "$LOG"
  TEST_STATUS=FAIL; TEST_RC=1
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "$METRICS" "${EV_FILES[@]/#/$RAW/}" "$LOG"
fi

# 2. Lock the measurement lanes.
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "${EV_FILES[@]/#/$RAW/}" "$LOG"
fi

# 3. Quiet-host pre-check (shared library; same rule as inside the make target).
HC_PRE="$RAW/smoke-fh-hostcheck-pre.json"
if ! quiet_host_precheck "$HC_PRE" >>"$LOG" 2>&1; then
  echo "[smoke-fh] INVALID: busy host before measurement ($HC_PRE)" | tee -a "$LOG"
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$HC_PRE" "$EVDIR/" 2>/dev/null || true
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "${EV_FILES[@]/#/$RAW/}" "$LOG"
fi

# 4. The existing target, unchanged: measure SMOKE_SECS with its own gates.
echo "[smoke-fh] running make smoke-fh (timeout ${TIMEOUT_SECS:-900}s)" | tee -a "$LOG"
RC=0
timeout "${TIMEOUT_SECS:-900}" make -C "$ROOT" smoke-fh \
  PROTORU_PROFILE="${PROTORU_PROFILE}" PROFILE="${DOCKER_PROFILE:-baseline}" \
  SMOKE_SECS="${SMOKE_SECS}" OPENRU_TAG="${OPENRU_TAG}" >>"$LOG" 2>&1 || RC=$?

cp -f "${EV_FILES[@]/#/$RAW/}" "$EVDIR/" 2>/dev/null || true

# 5. Map the outcome.
if [[ "$RC" -eq 3 ]]; then
  TEST_STATUS=INVALID; TEST_RC=3
elif [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
else
  # Gate the result on the shared quiet-host + U-plane rate libraries.
  if ! quiet_host_validate "$RAW/smoke-fh-hostcheck.json"; then
    echo "[smoke-fh] INVALID: host not quiet during measurement" | tee -a "$LOG"
    TEST_STATUS=INVALID; TEST_RC=3
  elif ! python3 "$ROOT/tests/lib/uplane_rate.py" \
      --kpi "$RAW/smoke-fh-kpi.json" \
      --expected "$ROOT/tests/$SUITE/profiles/$PROFILE/expected_rates.json" \
      --out "$RATE_OUT" >>"$LOG" 2>&1; then
    echo "[smoke-fh] FAIL: U-plane rate check failed ($RATE_OUT)" | tee -a "$LOG"
    TEST_STATUS=FAIL; TEST_RC=1
  else
    TEST_STATUS=PASS; TEST_RC=0
  fi
fi

# 6. Metrics = the suite KPI plus the shared rate check.
python3 - "$RAW/smoke-fh-kpi.json" "$RATE_OUT" "$METRICS" <<'PY' || true
import json, sys
kpi = json.load(open(sys.argv[1])) if len(sys.argv) > 1 and sys.argv[1] else {}
rates = json.load(open(sys.argv[2])) if len(sys.argv) > 2 and sys.argv[2] else {}
out = {"smoke_fh_kpi": kpi, "uplane_rate_check": rates}
open(sys.argv[3], "w").write(json.dumps(out, indent=2) + "\n")
PY

test_finish "$METRICS" "${EV_FILES[@]/#/$RAW/}" "$RATE_OUT" "$LOG"
