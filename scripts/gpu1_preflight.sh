#!/usr/bin/env bash
# Fail-closed lab + GPU lane check for OpenRU Phase 1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# GPU hosts use docker/lab.env; the GPU-less bench host passes its own env file
# (OPENRU_PREFLIGHT_ENV=docker/bench.env, or `make ... BENCH=1`).
LAB_ENV="${OPENRU_PREFLIGHT_ENV:-${ROOT}/docker/lab.env}"
if [[ ! -f "${LAB_ENV}" ]]; then
  echo "FAIL: ${LAB_ENV} is missing."
  echo "GPU host: copy docker/lab.env.example to docker/lab.env and set GPU UUID + cpusets."
  echo "  cp ${ROOT}/docker/lab.env.example ${ROOT}/docker/lab.env"
  echo "Bench host (no GPU): make ... BENCH=1 (uses docker/bench.env), see docs/BENCH_BUNDLE.md."
  exit 1
fi

# shellcheck disable=SC1091
source "${ROOT}/docker/versions.env"
# shellcheck disable=SC1091
source "${LAB_ENV}"

: "${PROTORU_CPUSET:?PROTORU_CPUSET must be set in ${LAB_ENV}}"
: "${DU_CPUSET:?DU_CPUSET must be set in ${LAB_ENV}}"

# CPU-only hosts (bench bundle) run the v1 CPU configuration: no GPU pin.
CPU_ONLY=0
if [[ "${OPENRU_GPU_UUID:-}" == "cpu-only" || "${OPENRU_GPU_UUID:-}" == "none" || -z "${OPENRU_GPU_UUID:-}" ]]; then
  CPU_ONLY=1
fi

if [[ "${CPU_ONLY}" == "0" ]]; then
  : "${OPENRU_FORBIDDEN_GPU_UUID:?OPENRU_FORBIDDEN_GPU_UUID must be set in ${LAB_ENV}}"
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
  echo "OK: ${LAB_ENV##*/} loaded; GPU ${OPENRU_GPU_UUID}; cpusets protoru=${PROTORU_CPUSET} du=${DU_CPUSET}"
  echo "NOTE: containers must use --gpus device=${OPENRU_GPU_UUID} (never --gpus all)."
  echo "Forbidden UUID: ${OPENRU_FORBIDDEN_GPU_UUID}"
else
  echo "OK: ${LAB_ENV##*/} loaded; CPU-only host (no GPU pin); cpusets protoru=${PROTORU_CPUSET} du=${DU_CPUSET}"
fi

# Real-time core isolation (bench requirement; DEV warns). The bench host must boot with isolcpus/nohz_full/rcu_nocbs
# covering the DU/RU cpusets. See docs/BENCH_BUNDLE.md and docs/OPEN_QUESTIONS.md.
python3 - "${PROTORU_CPUSET}" "${DU_CPUSET}" <<'PY'
import os, re, sys

def parse(spec):
    cores = set()
    for part in (spec or "").replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            cores.update(range(int(a), int(b) + 1))
        else:
            cores.add(int(part))
    return cores

def cmdline_list(key):
    for tok in open("/proc/cmdline").read().split():
        if tok.startswith(key + "="):
            val = tok.split("=", 1)[1]
            # isolcpus accepts flags (domain,managed_irq,...); keep only numeric ranges.
            parts = [p for p in val.split(",") if re.fullmatch(r"\d+(-\d+)?", p)]
            return parse(",".join(parts))
    return set()

required = parse(sys.argv[1]) | parse(sys.argv[2])
iso = cmdline_list("isolcpus")
nohz = cmdline_list("nohz_full")
rcu = cmdline_list("rcu_nocbs")
covered = required & iso & nohz & rcu
missing = sorted(required - covered)
if not required:
    print("WARNING: PROTORU_CPUSET/DU_CPUSET empty; cannot check isolation")
elif missing:
    msg = (f"WARNING: DU/RU cores not fully isolated: missing {missing}; "
           f"isolcpus={sorted(iso)} nohz_full={sorted(nohz)} rcu_nocbs={sorted(rcu)}. "
           "See docs/BENCH_BUNDLE.md.")
    if os.environ.get("OPENRU_REQUIRE_ISOLATION") == "1":
        print("FAIL: " + msg)
        sys.exit(1)
    print(msg)
else:
    print(f"OK: DU/RU cores isolated ({len(required)} cores) via isolcpus/nohz_full/rcu_nocbs")
PY

# Reference lock (bench UHD only). REF=external selects the OctoClock 10 MHz
# reference (time stays internal); the probe runs inside the bench image. Skip when the stack is
# already up (the device is claimed); restart-ru performs the same check after
# it stops the old RU.
if [[ "${RADIO:-}" == "uhd" && -n "${BENCH_USRP_ADDR:-}" ]]; then
  REF="${REF:-internal}"
  case "$REF" in
    external|internal) ;;
    *) echo "FAIL: REF must be external or internal (got $REF)" >&2; exit 1 ;;
  esac
  if [[ "$REF" == "internal" ]]; then
    echo "OK: REF=internal (N310 oscillator; ref_locked not required)"
  elif docker ps -q --filter label=com.docker.compose.service=protoru 2>/dev/null | grep -q .; then
    echo "WARN: ProtO-RU is already running; skipping REF=external ref_locked probe (restart-ru checks it)"
  else
    "$ROOT/scripts/ref_check.sh"
  fi
fi
