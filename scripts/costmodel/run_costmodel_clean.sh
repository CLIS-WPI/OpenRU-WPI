#!/usr/bin/env bash
# Clean cost-model run on reserved cores. Fully detached, no process pausing.
#
# The caller starts this with:
#   setsid nohup scripts/costmodel/run_costmodel_clean.sh > results/costmodel/clean_run.log 2>&1 &
#
# It selects idle cores on one NUMA node, runs each backend pinned there, checks
# per-core load before/during/after, records GPU clocks/power and GPU compute
# applications, retries if a foreign process used a reserved core or the GPU, and
# merges only a clean attempt. Progress is in results/costmodel/clean_status.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RAW="${ROOT}/results/costmodel/raw/${RUN_ID}"
STATUS="${ROOT}/results/costmodel/clean_status.json"
ITERS="${ITERS:-200}"
GPU_UUID="${GPU_UUID:-GPU-509d8ab3-0c8e-8b98-fbf8-0c55f6ba9058}"
LOCK="/tmp/openru-measure.lock"
THRESHOLD="${CORE_THRESHOLD:-5.0}"
COUNT_CORES="${COUNT_CORES:-3}"
ATTEMPTS="${ATTEMPTS:-5}"
RETRY_SLEEP="${RETRY_SLEEP:-60}"

mkdir -p "${RAW}" "${ROOT}/logs" "${ROOT}/results/costmodel"

exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "measurement lock is held (${LOCK}); refusing to run" >&2
  exit 1
fi
trap 'rm -f "${LOCK}"' EXIT

write_status() { # state message attempt dir
  python3 - "${STATUS}" "${RUN_ID}" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, datetime
path, run_id, state, message, attempt, raw = sys.argv[1:7]
data = {
    "run_id": run_id,
    "state": state,
    "message": message,
    "attempt": int(attempt),
    "raw": raw,
    "updated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
}
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
}

load_snapshot() {
  {
    echo "== $(date -u +%FT%TZ)"
    uptime
    cat /proc/loadavg
    echo "== top cpu (information only)"
    ps -eo pcpu,pid,comm --sort=-pcpu | head -12
    echo "== docker ps"
    docker ps --format '{{.Names}}' 2>/dev/null || true
  } > "$1"
}

gpu_snapshot() {
  {
    echo "== $(date -u +%FT%TZ)"
    nvidia-smi -i "${GPU_UUID}" \
      --query-gpu=timestamp,name,pstate,clocks.sm,clocks.mem,power.draw,power.limit,clocks_throttle_reasons.active \
      --format=csv
    echo "== detail"
    nvidia-smi -i "${GPU_UUID}" -q -d CLOCK,POWER,PERFORMANCE
  } > "$1" 2>&1
}

json_field() { # file key fallback (booleans printed lowercase)
  python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))[sys.argv[2]]).lower())' "$1" "$2" 2>/dev/null || echo "$3"
}

run_backend() { # <dir> <isa> <bin> [extra args...]
  local dir="$1" isa="$2" bin="$3"
  shift 3
  local log="${dir}/${isa}.log" csv="${dir}/${isa}.csv" pid="${dir}/${isa}.pid"
  local trace_pid="" apps_pid=""

  load_snapshot "${dir}/${isa}.load.before.txt"
  if [[ "${isa}" == "gpu" ]]; then
    gpu_snapshot "${dir}/${isa}.nvidia-smi.before.txt"
  fi

  echo "== ${isa}: start $(date -u +%FT%TZ)"
  env CUDA_VISIBLE_DEVICES="${GPU_UUID}" \
    taskset -c "${BENCH_CORE}" "${bin}" \
    --iters "${ITERS}" --cpu-core "${BENCH_CORE}" --isa "${isa}" --csv "${csv}" "$@" \
    > "${log}" 2>&1 &
  local bpid=$!
  echo "${bpid}" > "${pid}"

  if [[ "${isa}" == "gpu" ]]; then
    (
      echo "timestamp,pstate,clocks.current.sm [MHz],clocks.current.memory [MHz],power.draw [W],power.limit [W],clocks_event_reasons.active"
      while [[ -d "/proc/${bpid}" ]]; do
        nvidia-smi -i "${GPU_UUID}" \
          --query-gpu=timestamp,pstate,clocks.sm,clocks.mem,power.draw,power.limit,clocks_throttle_reasons.active \
          --format=csv,noheader
        sleep 0.5
      done
    ) > "${dir}/${isa}.nvidia-smi.trace.csv" 2>&1 &
    trace_pid=$!
    python3 "${ROOT}/scripts/costmodel/gpu_apps_watch.py" \
      --uuid "${GPU_UUID}" --allow-pid-file "${pid}" --interval 1.0 \
      --out "${dir}/${isa}.gpu_apps.json" > "${dir}/${isa}.gpu_apps.stdout" 2>&1 &
    apps_pid=$!
  fi

  python3 "${ROOT}/scripts/costmodel/core_watch.py" \
    --cores "${RESERVED}" --bench-core "${BENCH_CORE}" --bench-pid-file "${pid}" \
    --interval 0.2 --threshold "${THRESHOLD}" --out "${dir}/${isa}.cores.json" \
    > "${dir}/${isa}.cores.stdout" 2>&1 &
  local watch_pid=$!

  local rc=0
  wait "${bpid}" || rc=$?
  wait "${watch_pid}" 2>/dev/null || true
  if [[ -n "${trace_pid}" ]]; then
    wait "${trace_pid}" 2>/dev/null || true
    gpu_snapshot "${dir}/${isa}.nvidia-smi.after.txt"
    python3 "${ROOT}/scripts/costmodel/gpu_trace_summary.py" \
      --trace "${dir}/${isa}.nvidia-smi.trace.csv" --out "${dir}/${isa}.gpu_clock.json" \
      > "${dir}/${isa}.gpu_clock.stdout" 2>&1 || true
  fi
  if [[ -n "${apps_pid}" ]]; then
    wait "${apps_pid}" 2>/dev/null || true
  fi
  load_snapshot "${dir}/${isa}.load.after.txt"

  local core_rej="true" gpu_rej="false"
  [[ -s "${dir}/${isa}.cores.json" ]] && core_rej=$(json_field "${dir}/${isa}.cores.json" rejected true)
  [[ -s "${dir}/${isa}.gpu_apps.json" ]] && gpu_rej=$(json_field "${dir}/${isa}.gpu_apps.json" rejected false)
  echo "== ${isa}: rc=${rc} core_rejected=${core_rej} gpu_rejected=${gpu_rej}"
  if [[ "${rc}" -ne 0 || "${core_rej}" == "true" || "${gpu_rej}" == "true" ]]; then
    return 1
  fi
  return 0
}

run_diag() { # <dir> <name> <bin> <precoder>
  local dir="$1" name="$2" bin="$3" prec="$4"
  local log="${dir}/${name}.log" csv="${dir}/${name}.csv" pid="${dir}/${name}.pid"
  env CUDA_VISIBLE_DEVICES="${GPU_UUID}" \
    taskset -c "${BENCH_CORE}" "${bin}" \
    --iters "${ITERS}" --cpu-core "${BENCH_CORE}" --isa "${name}" --skip-gpu \
    --bfp avx2 --precoder "${prec}" --csv "${csv}" > "${log}" 2>&1 &
  local bpid=$!
  echo "${bpid}" > "${pid}"
  python3 "${ROOT}/scripts/costmodel/core_watch.py" \
    --cores "${RESERVED}" --bench-core "${BENCH_CORE}" --bench-pid-file "${pid}" \
    --interval 0.2 --threshold "${THRESHOLD}" --out "${dir}/${name}.cores.json" \
    > "${dir}/${name}.cores.stdout" 2>&1 &
  local watch_pid=$!
  local rc=0
  wait "${bpid}" || rc=$?
  wait "${watch_pid}" 2>/dev/null || true
  echo "== diag ${name}: rc=${rc} core_rejected=$(json_field "${dir}/${name}.cores.json" rejected true)"
}

write_status running "starting" 0 "${RAW}"

for attempt in $(seq 1 "${ATTEMPTS}"); do
  DIR="${RAW}/attempt-${attempt}"
  mkdir -p "${DIR}/diagnostics"
  write_status running "selecting cores" "${attempt}" "${DIR}"

  # Let the selector see the whole machine, then choose the least busy cores on
  # the GPU's NUMA node (falls back to the other node if needed).
  taskset -pc 0-63 $$ >/dev/null
  if ! python3 "${ROOT}/scripts/costmodel/pick_cores.py" \
      --uuid "${GPU_UUID}" --count "${COUNT_CORES}" --sample-seconds 20 --max-busy 100 \
      --out "${DIR}/cores.json" > "${DIR}/cores.stdout" 2>&1; then
    write_status retry "core selection failed" "${attempt}" "${DIR}"
    sleep "${RETRY_SLEEP}"
    continue
  fi

  RESERVED=$(python3 -c 'import json,sys;print(",".join(str(x) for x in json.load(open(sys.argv[1]))["cores"]))' "${DIR}/cores.json")
  BENCH_CORE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bench_core"])' "${DIR}/cores.json")
  NUMA_NODE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["numa_node"])' "${DIR}/cores.json")
  GPU_NUMA=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["gpu_numa_node"])' "${DIR}/cores.json")
  FALLBACK=$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))["fallback_node"]).lower())' "${DIR}/cores.json")
  SMT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["threads_per_core"])' "${DIR}/cores.json")
  echo "== attempt ${attempt}: cores=${RESERVED} bench=${BENCH_CORE} numa=${NUMA_NODE} gpu_numa=${GPU_NUMA} smt=${SMT}"

  ALLOWED=$(python3 - "${RESERVED}" <<'PY'
import sys
reserved = {int(x) for x in sys.argv[1].split(",")}
print(",".join(str(c) for c in range(64) if c not in reserved))
PY
)
  taskset -pc "${ALLOWED}" $$ >/dev/null

  write_status running "checking reserved cores" "${attempt}" "${DIR}"
  if ! python3 "${ROOT}/scripts/costmodel/core_watch.py" \
      --cores "${RESERVED}" --bench-core "${BENCH_CORE}" --duration 10 \
      --threshold "${THRESHOLD}" --out "${DIR}/cores.before.json" > "${DIR}/cores.before.stdout" 2>&1; then
    write_status retry "reserved cores busy before run" "${attempt}" "${DIR}"
    sleep "${RETRY_SLEEP}"
    continue
  fi

  OK=1
  write_status running "running avx2" "${attempt}" "${DIR}"
  run_backend "${DIR}" avx2 "${ROOT}/build/cm-avx2/test_costmodel" --skip-gpu --bfp avx2 --precoder avx2 || OK=0
  if [[ "${OK}" -eq 1 ]]; then
    write_status running "running avx512" "${attempt}" "${DIR}"
    run_backend "${DIR}" avx512 "${ROOT}/build/cm-avx512/test_costmodel" --skip-gpu --bfp avx512 --precoder avx512 || OK=0
  fi
  if [[ "${OK}" -eq 1 ]]; then
    write_status running "running gpu" "${attempt}" "${DIR}"
    run_backend "${DIR}" gpu "${ROOT}/build/cm-avx2/test_costmodel" --skip-cpu --bfp avx2 --precoder avx2 || OK=0
  fi
  if [[ "${OK}" -eq 0 ]]; then
    write_status retry "a run used a reserved core or the GPU, or failed" "${attempt}" "${DIR}"
    sleep "${RETRY_SLEEP}"
    continue
  fi

  write_status running "idle check after run" "${attempt}" "${DIR}"
  python3 "${ROOT}/scripts/costmodel/core_watch.py" \
    --cores "${RESERVED}" --bench-core "${BENCH_CORE}" --duration 10 \
    --threshold "${THRESHOLD}" --out "${DIR}/cores.after.json" > "${DIR}/cores.after.stdout" 2>&1 || true

  write_status running "Cat-B diagnostic" "${attempt}" "${DIR}"
  run_diag "${DIR}/diagnostics" avx2_prec_avx2     "${ROOT}/build/cm-avx2/test_costmodel"   avx2
  run_diag "${DIR}/diagnostics" avx2_prec_avx512   "${ROOT}/build/cm-avx2/test_costmodel"   avx512
  run_diag "${DIR}/diagnostics" avx512_prec_avx2   "${ROOT}/build/cm-avx512/test_costmodel" avx2
  run_diag "${DIR}/diagnostics" avx512_prec_avx512 "${ROOT}/build/cm-avx512/test_costmodel" avx512

  # Conditions + diagnostic summary.
  python3 - "${DIR}" "${RUN_ID}" "${RESERVED}" "${BENCH_CORE}" "${NUMA_NODE}" "${GPU_NUMA}" "${FALLBACK}" "${SMT}" "${THRESHOLD}" "${ITERS}" "${GPU_UUID}" <<'PY'
import json, sys
from pathlib import Path
d = Path(sys.argv[1]); run_id = sys.argv[2]
cores, bench, node, gpu_node, fallback, smt, threshold, iters, uuid = sys.argv[3:12]
def read(name):
    p = d / name
    return json.loads(p.read_text()) if p.exists() else None
conds = {
    "run_id": run_id, "raw": str(d), "method": "detached clean run on reserved cores",
    "cores": [int(x) for x in cores.split(",")], "bench_core": int(bench),
    "numa_node": int(node), "gpu_numa_node": int(gpu_node),
    "fallback_node": fallback == "true", "threads_per_core": int(smt),
    "core_threshold_pct": float(threshold), "iters": int(iters), "gpu_uuid": uuid,
    "core_before": read("cores.before.json"), "core_after": read("cores.after.json"),
    "gpu_clock": read("gpu.gpu_clock.json"), "gpu_apps": read("gpu.gpu_apps.json"),
    "gpu_before_text": (d / "gpu.nvidia-smi.before.txt").read_text(errors="replace") if (d / "gpu.nvidia-smi.before.txt").exists() else "",
    "gpu_after_text": (d / "gpu.nvidia-smi.after.txt").read_text(errors="replace") if (d / "gpu.nvidia-smi.after.txt").exists() else "",
}
(d / "conditions.json").write_text(json.dumps(conds, indent=2) + "\n")
PY

  python3 - "${DIR}/diagnostics" <<'PY'
import csv, json, sys
from pathlib import Path
d = Path(sys.argv[1]); names = ["avx2_prec_avx2", "avx2_prec_avx512", "avx512_prec_avx2", "avx512_prec_avx512"]
out = {"kernels": {}, "core": {}, "freq_khz_sysfs": {}}
for name in names:
    path = d / f"{name}.csv"
    rows = list(csv.DictReader(path.open())) if path.exists() else []
    for r in rows:
        if r["profile"] == "100 MHz" and r["kernel"] == "precoding" and r["ports"] in ("4", "8"):
            out["kernels"].setdefault(f"{r['ports']}p", {})[name] = float(r["compute_p50_ms"])
    cj = d / f"{name}.cores.json"
    if cj.exists():
        cd = json.loads(cj.read_text())
        out["core"][name] = cd.get("max_foreign_pct")
        out["freq_khz_sysfs"][name] = cd.get("freq_khz_sysfs")
(d / "summary.json").write_text(json.dumps(out, indent=2) + "\n")
PY

  python3 "${ROOT}/scripts/costmodel/merge_costmodel.py" \
    --raw "${DIR}" --out "${ROOT}/results/costmodel" --run-id "${RUN_ID}" \
    --conditions "${DIR}/conditions.json"
  cp "${DIR}/conditions.json" "${ROOT}/results/costmodel/run_conditions.json"
  write_status success "clean run merged" "${attempt}" "${DIR}"
  echo "== clean run PASS ${RUN_ID} (attempt ${attempt})"
  echo "== raw: ${DIR}"
  exit 0
done

write_status failed "no clean attempt after ${ATTEMPTS} tries" "${ATTEMPTS}" "${RAW}"
echo "== clean run FAILED after ${ATTEMPTS} attempts; raw under ${RAW}"
exit 3
