#!/usr/bin/env bash
# Shared quiet-host check (wraps scripts/quiet_host.py) for every suite that
# measures latency or late/drop ratios.
#
# A run is INVALID (exit 3) if any process outside our containers holds CPU
# affinity on the reserved cores (PROTORU_CPUSET ∪ DU_CPUSET) and uses >5% CPU.
# Functions:
#   quiet_host_precheck <out.json> [containers]   -> rc 3 when busy
#   quiet_host_monitor_start <out.json> <interval> [containers]  -> echoes pid
#   quiet_host_monitor_stop <pid>
#   quiet_host_validate <out.json>                -> rc 3 when busy

ROOT_QUIET_HOST="${ROOT:?ROOT required}"

quiet_host_precheck() {
  local out="$1"; local containers="${2:-openru-protoru-1,openru-du-1}"
  python3 "$ROOT_QUIET_HOST/scripts/quiet_host.py" --once \
    --reserved "${PROTORU_CPUSET:?},${DU_CPUSET:?}" \
    --containers "$containers" --out "$out"
}

quiet_host_monitor_start() {
  local out="$1"; local interval="${2:-30}"; local containers="${3:-openru-protoru-1,openru-du-1}"
  nohup python3 "$ROOT_QUIET_HOST/scripts/quiet_host.py" --monitor --interval "$interval" \
    --reserved "${PROTORU_CPUSET:?},${DU_CPUSET:?}" \
    --containers "$containers" --out "$out" >/dev/null 2>&1 &
  echo $!
}

quiet_host_monitor_stop() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  sleep 1
  rm -f /tmp/openru-hostcheck.pid 2>/dev/null || true
}

quiet_host_validate() {
  test_quiet_host_validate "$1"
}
