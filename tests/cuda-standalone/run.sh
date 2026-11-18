#!/usr/bin/env bash
# tests/cuda-standalone — wrap of src/cuda/standalone test_lowphy
# (BFP + OFDM CUDA kernels vs the OCUDU CPU reference; all profiles 20/40/100
# MHz, 2 and 4 ports). Pass: BFP byte-identical; OFDM mod/demod <= 1 LSB and
# <= -60 dB error power. See tests/cuda-standalone/README.md.
#
# Usage: PROFILE=default tests/cuda-standalone/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=cuda-standalone
. "$ROOT/tests/lib/common.sh"
. "$ROOT/tests/lib/cuda.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"

trap 'test_unlock_measure' EXIT

echo "[cuda-standalone] gpu=${OPENRU_GPU_UUID}" | tee -a "$LOG"

# 1. Host capability (fail closed; SKIPPED when this host cannot run CUDA).
if ! cuda_require_gpu; then
  echo "[cuda-standalone] SKIPPED (host_limited): no nvcc/GPU for ${OPENRU_GPU_UUID}" | tee -a "$LOG"
  TEST_STATUS=SKIPPED; TEST_SKIP_REASON=host_limited; TEST_RC=0
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 2. Build trees + binaries (no measurement; no lock held).
RC=0
cuda_build_ocudu ocuudu-only >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-standalone] FAIL: OCUDU build (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }
cuda_build_tests >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-standalone] FAIL: test build (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }

# 3. Measure (lock + pinned GPU).
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi
echo "[cuda-standalone] running test_lowphy --iters ${ITERS:-30}" | tee -a "$LOG"
RC=0
timeout "${TIMEOUT_SECS:-1800}" env CUDA_VISIBLE_DEVICES="${OPENRU_GPU_UUID}" \
  "$ROOT/build/lowphy-cuda/test_lowphy" --iters "${ITERS:-30}" >"$EVDIR/test_lowphy.out" 2>&1 || RC=$?
test_unlock_measure

if [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
  test_finish "-" "$EVDIR/test_lowphy.out" "$LOG"
fi
TEST_STATUS=PASS; TEST_RC=0

# 4. Metrics from the harness output.
python3 - "$EVDIR/test_lowphy.out" "$EVDIR/metrics.json" <<'PY' || true
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
m = re.search(r"iters[=: ]+(\d+)", text)
out = {"harness": "test_lowphy", "iters": int(m.group(1)) if m else None}
Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
PY

test_finish "$EVDIR/metrics.json" "$EVDIR/test_lowphy.out" "$LOG"
