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
