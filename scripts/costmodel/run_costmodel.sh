#!/usr/bin/env bash
# Run the OpenRU low-PHY cost model on the allowed GPU and a fixed CPU core.
# Produces raw CSVs under results/costmodel/raw/ and a merged table.
#
# Measurement hygiene: holds /tmp/openru-measure.lock for the whole run,
# records load, pins to core 0-15, and uses only GPU-509d8ab3 (index 1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ITERS="${ITERS:-200}"
CORE="${CORE:-8}"
ISA_TAG="${ISA_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
RAW="${ROOT}/results/costmodel/raw/${ISA_TAG}"
GPU_UUID="${GPU_UUID:-GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058}"
LOCK="/tmp/openru-measure.lock"

mkdir -p "${RAW}" "${ROOT}/logs"

exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "measurement lock is held (${LOCK}); refusing to run" >&2
  exit 1
fi
cleanup() {
  rm -f "${LOCK}"
}
trap cleanup EXIT

{
  echo "== started $(date -u +%FT%TZ)"
  uptime
  echo "== top cpu"
  ps -eo pcpu,comm --sort=-pcpu | head -6
  echo "== docker ps"
  docker ps --format '{{.Names}}' 2>/dev/null || true
} | tee "${RAW}/load.txt"

run() {
  local isa="$1" bin="$2"
  shift 2
  echo "== ${isa}: $*"
  taskset -c 0-15 "${bin}" --iters "${ITERS}" --cpu-core "${CORE}" --isa "${isa}" \
    --csv "${RAW}/${isa}.csv" "$@" 2>&1 | tee "${RAW}/${isa}.log"
}

run avx2   "${ROOT}/build/cm-avx2/test_costmodel" --bfp avx2 --precoder avx2
run avx512 "${ROOT}/build/cm-avx512/test_costmodel" --skip-gpu --bfp avx512 --precoder avx512
CUDA_VISIBLE_DEVICES="${GPU_UUID}" \
  run gpu "${ROOT}/build/cm-avx2/test_costmodel" --skip-cpu --bfp avx2 --precoder avx2

python3 "${ROOT}/scripts/costmodel/merge_costmodel.py" \
  --raw "${RAW}" --out "${ROOT}/results/costmodel"

echo "== raw: ${RAW}"
echo "== merged: ${ROOT}/results/costmodel/costmodel.csv"
