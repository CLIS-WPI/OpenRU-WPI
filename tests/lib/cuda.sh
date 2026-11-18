#!/usr/bin/env bash
# Shared CUDA standalone low-PHY test helpers (tests/cuda-standalone,
# tests/cuda-pipeline, tests/cuda-scaling).
#
# The three suites link the production OCUDU static libraries from two host
# build trees of external/proto-ru:
#   build/ocudu       — Release, generic DFT (reference path)
#   build/ocudu-fair  — Release, FFTW + x86-64-v4 (fair CPU baseline)
# Binaries are built into build/lowphy-cuda (src/cuda/standalone).
#
# GPU: CUDA_VISIBLE_DEVICES is pinned to the lab.env OPENRU_GPU_UUID; the
# forbidden GPU is never used. Every timed run holds /tmp/openru-measure.lock
# (the caller does that via tests/lib/common.sh).

CU_BIN_DIR="build/lowphy-cuda"

# Build the OCUDU static libraries the tests link (no-op when present).
cuda_build_ocudu() { # <ocudu|fair|both>
  local variant="${1:-both}"
  local prefix="/home/tanglab/.local/mbedtls;/home/tanglab/miniconda3"
  # Target names extracted programmatically from the proto-ru CMake lists:
  local targets="ocuduvec ocudu_ran ocudu_support ocudu_support_math ocudulog"
  targets="$targets ocudu_instrumentation fmt ocudu_dft ocudu_phy_support"
  targets="$targets ocudu_ofh_compression ocudu_lower_phy_modulation ocudu_yaml_util"
  local fair_targets="$targets ocudu_channel_precoder"

  _cuda_cfg() { # dir extra-cmake-args...
    local dir="$1"; shift
    if [[ -f "$dir/Makefile" ]]; then return 0; fi
    echo "[cuda] configuring $dir"
    cmake -S external/proto-ru -B "$dir" -DCMAKE_BUILD_TYPE=Release -DOPENRU_CUDA=OFF \
      -DBUILD_TESTING=OFF -DDISABLE_SCTP=ON -DCMAKE_PREFIX_PATH="$prefix" \
      -DMBEDTLS_DIR=/home/tanglab/.local/mbedtls "$@"
  }
  _cuda_build() { # dir targets...
    local dir="$1"; shift
    echo "[cuda] building $dir (targets: $*)"
    timeout 5400 cmake --build "$dir" -j 32 --target "$@"
  }

  if [[ "$variant" != "fair-only" ]]; then
    _cuda_cfg build/ocudu -DENABLE_FFTW=OFF
    _cuda_build build/ocudu $targets
  fi
  if [[ "$variant" != "ocudu-only" ]]; then
    # FFTW3_DIR: FindFFTW3F.cmake honours it; the host-local FFTW (3.6.10)
    # provides the .so symlink the system package lacks.
    FFTW3_DIR="${OPENRU_FFTW3_DIR:-/home/tanglab/.local/fftw3}" \
      _cuda_cfg build/ocudu-fair -DENABLE_FFTW=ON -DMARCH=x86-64-v4
    _cuda_build build/ocudu-fair $fair_targets
  fi
}

# Build the test binaries (no GPU time, no lock needed). Always runs an
# incremental cmake --build so relinks pick up updated OCUDU static archives.
cuda_build_tests() {
  if [[ ! -f "$CU_BIN_DIR/Makefile" ]]; then
    echo "[cuda] configuring $CU_BIN_DIR"
    timeout 600 cmake -S src/cuda/standalone -B "$CU_BIN_DIR" -DCMAKE_BUILD_TYPE=Release
  fi
  timeout 5400 cmake --build "$CU_BIN_DIR" -j 16
  test -x "$CU_BIN_DIR/test_lowphy"
  test -x "$CU_BIN_DIR/test_pipeline"
  test -x "$CU_BIN_DIR/test_scaling"
}

# Fail closed unless this host can run the CUDA suites (nvcc + nvidia-smi + GPU).
cuda_require_gpu() {
  command -v nvcc >/dev/null 2>&1 || return 1
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi -L 2>/dev/null | grep -q "${OPENRU_GPU_UUID:?OPENRU_GPU_UUID missing}" || return 1
}
