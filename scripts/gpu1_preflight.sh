#!/usr/bin/env bash
# Fail-closed GPU1 lane check for OpenRU Phase 1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/docker/versions.env"

AUTHORIZED="${OPENRU_GPU_UUID}"
FORBIDDEN="${OPENRU_FORBIDDEN_GPU_UUID}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "FAIL: nvidia-smi not found on host."
  exit 1
fi

LIST="$(nvidia-smi -L 2>/dev/null || true)"
if ! grep -q "${AUTHORIZED}" <<<"${LIST}"; then
  echo "FAIL: authorized GPU1 UUID ${AUTHORIZED} not visible on host."
  echo "${LIST}"
  exit 1
fi

echo "OK: host has GPU1 ${AUTHORIZED}"
echo "NOTE: containers must use --gpus device=${AUTHORIZED} (never --gpus all)."
echo "Forbidden UUID (GPU0): ${FORBIDDEN}"
