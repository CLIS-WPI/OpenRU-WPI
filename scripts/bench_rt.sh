#!/usr/bin/env bash
# Bench post-start step: apply/check the thread plan, then a real-time health check.
#
#   scripts/bench_rt.sh [both|ru|du]     (called by scripts/up.sh and scripts/restart_ru.sh)
#
# Needs BENCH_RU_THREADS / BENCH_DU_THREADS from docker/bench.env in the environment.
#   1. wait until ProtO-RU prints "Running." (UHD threads exist only after radio init)
#   2. tools/bench/pin_threads.py --apply for DU and/or RU; FAIL if a planned thread is off-plan
#   3. scripts/rt_watch.sh start, settle RT_SETTLE_SECS (30), check RT_CHECK_SECS (60; 0 skips)
# Exit: 0 OK or WARN (loud banner), 1 FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHICH="${1:-both}"
SETTLE="${RT_SETTLE_SECS:-30}"
CHECK="${RT_CHECK_SECS:-60}"
READY_TIMEOUT="${RT_RU_READY_TIMEOUT:-120}"

cid_of() { docker ps -q --filter label=com.docker.compose.project=openru \
             --filter "label=com.docker.compose.service=$1" --filter status=running | head -1; }
pin() { # <service> <plan>
  local cid; cid="$(cid_of "$1")"
  [[ -n "$cid" ]] || { echo "[rt] FAIL: $1 is not running" >&2; return 1; }
  [[ -n "$2" ]] || { echo "[rt] WARN: no thread plan for $1 (docker/bench.env)"; return 0; }
  python3 "$ROOT/tools/bench/pin_threads.py" "$cid" "$2" --apply | sed 's/^/[rt] /'
  return "${PIPESTATUS[0]}"
}

if [[ "$WHICH" == both || "$WHICH" == ru ]]; then
  ru="$(cid_of protoru)"
  [[ -n "$ru" ]] || { echo "[rt] FAIL: protoru is not running" >&2; exit 1; }
  echo "[rt] waiting for ProtO-RU radio init (\"Running.\", up to ${READY_TIMEOUT}s) ..."
  ready=0
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    docker logs "$ru" 2>&1 | grep -q '^Running\.' && { ready=1; break; }
    sleep 1
  done
  (( ready )) || echo "[rt] WARN: ProtO-RU did not print \"Running.\" in ${READY_TIMEOUT}s; pinning anyway"
fi
if [[ "$WHICH" == both || "$WHICH" == du ]]; then pin du "${BENCH_DU_THREADS:-}" || exit 1; fi
if [[ "$WHICH" == both || "$WHICH" == ru ]]; then pin protoru "${BENCH_RU_THREADS:-}" || exit 1; fi

(( CHECK > 0 )) || { echo "[rt] real-time health check skipped (RT_CHECK_SECS=0)"; exit 0; }
"$ROOT/scripts/rt_watch.sh" start | sed 's/^/[rt] /'
echo "[rt] settling ${SETTLE}s, then counting real-time failures for ${CHECK}s ..."
sleep "$SETTLE"
rc=0
"$ROOT/scripts/rt_watch.sh" check "$CHECK" | sed 's/^/[rt] /' || true
rc="${PIPESTATUS[0]}"
case "$rc" in
  0) echo "[rt] OK: no lower-PHY / RF / DU fronthaul real-time failures" ;;
  2) echo "[rt] !!!!!!!! WARN: real-time failures after startup (see counts above); keep watching: make rt-watch" ;;
  *) echo "[rt] !!!!!!!! FAIL: real-time failures at or above threshold after startup: do not measure on this stack" >&2
     exit 1 ;;
esac
