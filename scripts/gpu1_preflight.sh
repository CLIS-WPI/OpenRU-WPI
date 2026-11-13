#!/usr/bin/env bash
# Fail-closed lab + GPU lane check for OpenRU Phase 1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAB_ENV="${ROOT}/docker/lab.env"
if [[ ! -f "${LAB_ENV}" ]]; then
  echo "FAIL: docker/lab.env is missing."
  echo "Copy docker/lab.env.example to docker/lab.env and set GPU UUID + cpusets for this host."
  echo "  cp ${ROOT}/docker/lab.env.example ${ROOT}/docker/lab.env"
  exit 1
fi

# shellcheck disable=SC1091
source "${ROOT}/docker/versions.env"
# shellcheck disable=SC1091
source "${LAB_ENV}"

: "${OPENRU_GPU_UUID:?OPENRU_GPU_UUID must be set in docker/lab.env}"
: "${OPENRU_FORBIDDEN_GPU_UUID:?OPENRU_FORBIDDEN_GPU_UUID must be set in docker/lab.env}"
: "${PROTORU_CPUSET:?PROTORU_CPUSET must be set in docker/lab.env}"
: "${DU_CPUSET:?DU_CPUSET must be set in docker/lab.env}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "FAIL: nvidia-smi not found on host."
  exit 1
fi

LIST="$(nvidia-smi -L 2>/dev/null || true)"
if ! grep -q "${OPENRU_GPU_UUID}" <<<"${LIST}"; then
  echo "FAIL: authorized GPU UUID ${OPENRU_GPU_UUID} not visible on host."
  echo "${LIST}"
  exit 1
fi

echo "OK: lab.env loaded; GPU ${OPENRU_GPU_UUID}; cpusets protoru=${PROTORU_CPUSET} du=${DU_CPUSET}"
echo "NOTE: containers must use --gpus device=${OPENRU_GPU_UUID} (never --gpus all)."
echo "Forbidden UUID: ${OPENRU_FORBIDDEN_GPU_UUID}"
