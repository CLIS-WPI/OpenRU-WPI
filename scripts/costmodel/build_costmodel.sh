#!/usr/bin/env bash
# Build the OpenRU low-PHY cost-model harness against two OCUDU static builds:
#   build/ocudu-avx2   (x86-64-v3)
#   build/ocudu-avx512 (x86-64-v4)
# Usage: scripts/costmodel/build_costmodel.sh [ocudu-avx2-dir] [ocudu-avx512-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AVX2_BUILD="${1:-${ROOT}/build/ocudu-avx2}"
AVX512_BUILD="${2:-${ROOT}/build/ocudu-avx512}"
JOBS="${JOBS:-16}"
FFTW3F_ROOT="${FFTW3F_ROOT:-$HOME/.local/fftw3}"
YAML_CPP_LIBRARY="${YAML_CPP_LIBRARY:-$HOME/miniconda3/lib/libyaml-cpp.so}"

CMAKE_DEPS=()
[[ -d "${FFTW3F_ROOT}" ]] && CMAKE_DEPS+=(-DFFTW3F_ROOT="${FFTW3F_ROOT}")
[[ -f "${YAML_CPP_LIBRARY}" ]] && CMAKE_DEPS+=(-DYAML_CPP_LIBRARY="${YAML_CPP_LIBRARY}")

mkdir -p "${ROOT}/logs"

for pair in "avx2:${AVX2_BUILD}" "avx512:${AVX512_BUILD}"; do
  isa="${pair%%:*}"
  ocudu="${pair#*:}"
  echo "== configuring cost-model (${isa}) against ${ocudu}"
  cmake -S "${ROOT}/src/cuda/standalone" -B "${ROOT}/build/cm-${isa}" \
    -DOCUDU_BUILD="${ocudu}" \
    -DOCUDU_FAIR_BUILD="${ocudu}" \
    "${CMAKE_DEPS[@]}" \
    > "${ROOT}/logs/cmake_cm_${isa}.log" 2>&1
  echo "== building test_costmodel (${isa})"
  taskset -c 0-31 cmake --build "${ROOT}/build/cm-${isa}" -j"${JOBS}" \
    --target test_costmodel > "${ROOT}/logs/build_cm_${isa}.log" 2>&1
  echo "   ok: ${ROOT}/build/cm-${isa}/test_costmodel"
done
