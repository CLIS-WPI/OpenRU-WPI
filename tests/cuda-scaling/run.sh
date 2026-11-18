#!/usr/bin/env bash
# tests/cuda-scaling — wrap of src/cuda/standalone test_scaling
# (GPU vs fair CPU FFTW+AVX-512 baseline across antenna-port counts; TDD/FDD
# core budgets). Compute-only [MEASURED]. See tests/cuda-scaling/README.md.
#
# Usage: PROFILE=default tests/cuda-scaling/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=cuda-scaling
. "$ROOT/tests/lib/common.sh"
. "$ROOT/tests/lib/cuda.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"

trap 'test_unlock_measure' EXIT

echo "[cuda-scaling] gpu=${OPENRU_GPU_UUID}" | tee -a "$LOG"

# 1. Host capability.
if ! cuda_require_gpu; then
  echo "[cuda-scaling] SKIPPED (host_limited): no nvcc/GPU for ${OPENRU_GPU_UUID}" | tee -a "$LOG"
  TEST_STATUS=SKIPPED; TEST_SKIP_REASON=host_limited; TEST_RC=0
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 2. Build trees + binaries (the fair CPU baseline needs build/ocudu-fair).
RC=0
cuda_build_ocudu both >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-scaling] FAIL: OCUDU builds (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }
cuda_build_tests >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-scaling] FAIL: test build (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }

# 3. Measure (lock + pinned GPU; CPU pin core ${CPU_CORE} like RESULTS_SCALING.md).
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi
echo "[cuda-scaling] running test_scaling --latency-iters ${LATENCY_ITERS:-80} --cpu-core ${CPU_CORE:-10}" | tee -a "$LOG"
RC=0
timeout "${TIMEOUT_SECS:-1800}" env CUDA_VISIBLE_DEVICES="${OPENRU_GPU_UUID}" \
  "$ROOT/build/lowphy-cuda/test_scaling" \
  --latency-iters "${LATENCY_ITERS:-80}" --cpu-core "${CPU_CORE:-10}" \
  --csv "$EVDIR/scaling_results.csv" >"$EVDIR/test_scaling.out" 2>&1 || RC=$?
test_unlock_measure

if [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
  test_finish "-" "$EVDIR/test_scaling.out" "$LOG"
fi
TEST_STATUS=PASS; TEST_RC=0

# 4. Metrics: per-port rows from the CSV.
python3 - "$EVDIR/scaling_results.csv" "$EVDIR/metrics.json" <<'PY' || true
import csv, json, sys
from pathlib import Path
rows = []
p = Path(sys.argv[1])
if p.exists():
    with p.open() as f:
        for r in csv.DictReader(f):
            rows.append({k: r.get(k) for k in list(r.keys())[:12]})
out = {"harness": "test_scaling", "rows": len(rows), "csv_head": rows[:4]}
Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
PY

test_finish "$EVDIR/metrics.json" "$EVDIR/test_scaling.out" "$EVDIR/scaling_results.csv" "$LOG"
