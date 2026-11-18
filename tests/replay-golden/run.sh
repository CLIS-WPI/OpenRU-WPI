#!/usr/bin/env bash
# tests/replay-golden — wrap of the existing `make replay-golden` CPU-vs-golden
# replay, one golden per profile. The suite reads lead_mode/sender from the
# golden MANIFEST (via the make target) and applies the shared golden-energy
# check. Profiles: baseline (default), b40 (host_limited), b100 (deferred).
# See tests/replay-golden/README.md.
#
# Usage: PROFILE=baseline tests/replay-golden/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=replay-golden
. "$ROOT/tests/lib/common.sh"
. "$ROOT/tests/lib/golden_energy.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"
RAW="$ROOT/docs/reports/raw"
GOLDEN="testdata/golden/$PROFILE"
MANIFEST="$ROOT/$GOLDEN/MANIFEST.json"

manifest_field() { # <field> — read via tools/golden/manifest_mode.py when valid
  python3 "$ROOT/tools/golden/manifest_mode.py" --manifest "$MANIFEST" --field "$1" 2>/dev/null || echo ""
}

trap 'test_unlock_measure' EXIT

# 1. Preflight.
if ! make -C "$ROOT" preflight >>"$LOG" 2>&1; then
  echo "[replay-golden] preflight FAILED" | tee -a "$LOG"
  TEST_STATUS=FAIL; TEST_RC=1
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 2. SKIPPED before locking: deferred goldens and host-limited goldens.
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("status")=="deferred" else 1)' \
    "$MANIFEST" 2>/dev/null; then
  echo "[replay-golden] $PROFILE deferred — SKIPPED" | tee -a "$LOG"
  TEST_STATUS=SKIPPED; TEST_SKIP_REASON=deferred; TEST_RC=0
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("host_limited") else 1)' \
    "$MANIFEST" 2>/dev/null && [[ "${RUN_HOST_LIMITED:-0}" != "1" ]]; then
  reason="$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["host_limited"]; print("{} / {} runs passed: {}".format(h.get("passes"), h.get("runs"), h.get("reason")))' "$MANIFEST" 2>/dev/null || echo "see MANIFEST")"
  echo "[replay-golden] $PROFILE SKIPPED (host_limited: $reason)" | tee -a "$LOG"
  TEST_STATUS=SKIPPED; TEST_SKIP_REASON=host_limited; TEST_RC=0
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 3. Lock the measurement lanes (replay sends live fronthaul traffic).
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 4. The existing target restricted to this profile (same script, same results).
echo "[replay-golden] running make replay-golden REPLAY_PROFILES=$PROFILE (timeout ${TIMEOUT_SECS:-2400}s)" | tee -a "$LOG"
RC=0
# run.sh owns /tmp/openru-measure.lock; tell replay_iq_dump.sh (it would refuse
# to run otherwise).
OPENRU_MEASURE_LOCK_HELD=1 timeout "${TIMEOUT_SECS:-2400}" make -C "$ROOT" replay-golden REPLAY_PROFILES="$PROFILE" \
  RUN_HOST_LIMITED="${RUN_HOST_LIMITED:-0}" >>"$LOG" 2>&1 || RC=$?
cp -f "$LOG" "$EVDIR/" 2>/dev/null || true

DUMP="$RAW/replay-golden-$PROFILE"
CHECK_JSON="$DUMP-check.json"
IQ_LOG="$EVDIR/iq-compare.log"

if [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
  test_finish "-" "$DUMP" "$CHECK_JSON" "$LOG"
fi

# 5. Validate via the shared golden-energy check (window slot, per-port energy,
#    silent ports, UL leakage, non-empty count) — same check the target runs.
if ! golden_energy_check "$DUMP" "$ROOT/$GOLDEN/window.json" \
     "$ROOT/profiles/$PROFILE/du-fh.yml" "$CHECK_JSON" >>"$LOG" 2>&1; then
  echo "[replay-golden] FAIL: golden energy check failed" | tee -a "$LOG"
  TEST_STATUS=FAIL; TEST_RC=1
  test_finish "-" "$DUMP" "$CHECK_JSON" "$LOG"
fi

# 6. Bit-exact IQ compare (0 differing samples) and metrics.
python3 "$ROOT/tools/iq_compare/iq_compare.py" \
  --dut "$DUMP" --golden "$ROOT/$GOLDEN" --by-slot --threshold 0 >"$IQ_LOG" 2>&1 || RC=$?
tail -20 "$IQ_LOG" >>"$LOG" 2>/dev/null || true
if [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
  test_finish "-" "$DUMP" "$CHECK_JSON" "$IQ_LOG" "$LOG"
fi
differing="$(grep -c '^DIFF:' "$IQ_LOG" 2>/dev/null)"; differing="${differing:-0}"
slots_ok="$(grep -cE 'all [0-9]+ overlapping DU slots PASS' "$IQ_LOG" 2>/dev/null)"; slots_ok="${slots_ok:-0}"
TEST_STATUS=PASS; TEST_RC=0

python3 - "$CHECK_JSON" "$IQ_LOG" "$differing" "$EVDIR/metrics.json" "$PROFILE" "$slots_ok" <<'PY' || true
import json, sys
from pathlib import Path
check = json.loads(Path(sys.argv[1]).read_text()) if Path(sys.argv[1]).exists() else {}
out = {
    "golden_check_pass": check.get("pass"),
    "expected_slots": check.get("expected_slots"),
    "nonempty_slots": check.get("nonempty_slots"),
    "differing_slots": int(sys.argv[3]),
    "ports_all_slots_pass": int(sys.argv[6]),
    "profile": sys.argv[5],
}
Path(sys.argv[4]).write_text(json.dumps(out, indent=2) + "\n")
PY

test_finish "$EVDIR/metrics.json" "$DUMP" "$CHECK_JSON" "$IQ_LOG" "$LOG"
