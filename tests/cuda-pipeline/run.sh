#!/usr/bin/env bash
# tests/cuda-pipeline — wrap of src/cuda/standalone test_pipeline
# (device-resident DL/UL low-PHY chain vs standalone kernels: byte-identical;
# sustained throughput + latency on the pinned GPU). Compute-only [MEASURED].
# See tests/cuda-pipeline/README.md.
#
# Usage: PROFILE=default tests/cuda-pipeline/run.sh
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SUITE=cuda-pipeline
. "$ROOT/tests/lib/common.sh"
. "$ROOT/tests/lib/cuda.sh"

test_common_init "$SUITE" || exit 1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="$ROOT/docs/reports/runs/$SUITE/evidence/$STAMP-$PROFILE"
mkdir -p "$EVDIR"
LOG="$EVDIR/run.log"

trap 'test_unlock_measure' EXIT

echo "[cuda-pipeline] gpu=${OPENRU_GPU_UUID}" | tee -a "$LOG"

# 1. Host capability.
if ! cuda_require_gpu; then
  echo "[cuda-pipeline] SKIPPED (host_limited): no nvcc/GPU for ${OPENRU_GPU_UUID}" | tee -a "$LOG"
  TEST_STATUS=SKIPPED; TEST_SKIP_REASON=host_limited; TEST_RC=0
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi

# 2. Build trees + binaries.
RC=0
cuda_build_ocudu ocuudu-only >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-pipeline] FAIL: OCUDU build (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }
cuda_build_tests >>"$LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] || { TEST_STATUS=FAIL; TEST_RC="$RC"; echo "[cuda-pipeline] FAIL: test build (rc=$RC)" | tee -a "$LOG"; test_finish "-" "$LOG"; }

# 3. Measure (lock + pinned GPU; CPU pin core ${CPU_CORE} like RESULTS.md).
if ! test_lock_measure; then
  TEST_STATUS=INVALID; TEST_RC=3
  cp -f "$LOG" "$EVDIR/" 2>/dev/null || true
  test_finish "-" "$LOG"
fi
echo "[cuda-pipeline] running test_pipeline --sustained ${SUSTAINED:-4000} --latency-iters ${LATENCY_ITERS:-200} --cpu-core ${CPU_CORE:-8}" | tee -a "$LOG"
RC=0
timeout "${TIMEOUT_SECS:-1800}" env CUDA_VISIBLE_DEVICES="${OPENRU_GPU_UUID}" \
  "$ROOT/build/lowphy-cuda/test_pipeline" \
  --sustained "${SUSTAINED:-4000}" --latency-iters "${LATENCY_ITERS:-200}" \
  --cpu-core "${CPU_CORE:-8}" >"$EVDIR/test_pipeline.out" 2>&1 || RC=$?
test_unlock_measure

if [[ "$RC" -ne 0 ]]; then
  TEST_STATUS=FAIL; TEST_RC="$RC"
  test_finish "-" "$EVDIR/test_pipeline.out" "$LOG"
fi
TEST_STATUS=PASS; TEST_RC=0

# 4. Metrics: sustained + latency tables, device, mismatches.
python3 - "$EVDIR/test_pipeline.out" "$EVDIR/metrics.json" <<'PY' || true
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
out = {
    "harness": "test_pipeline",
    "device": (re.search(r"Device: (.*)", text) or [None, ""])[1].strip(),
    "sustained_slots": int((re.search(r"Sustained slots: (\d+)", text) or [0, 0])[1]),
    "latency_iters": int((re.search(r"latency iters: (\d+)", text) or [0, 0])[1]),
    "mismatch_lines": len(re.findall(r"MISMATCH", text)),
}
Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
PY

test_finish "$EVDIR/metrics.json" "$EVDIR/test_pipeline.out" "$LOG"
