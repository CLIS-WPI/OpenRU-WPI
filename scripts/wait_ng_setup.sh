#!/usr/bin/env bash
# Wait until the AMF accepts the DU's NG Setup.
#
#   SINCE=<RFC3339 timestamp> scripts/wait_ng_setup.sh
#
# The DU can take several minutes to create its O-DU before it starts CU-CP
# and sends NGSetupRequest. Do not judge OFH or call the stack "up" before this
# returns. Polling is on the Open5GS AMF log, every 30 s, timeout 6 min.
set -euo pipefail
TIMEOUT="${NG_SETUP_TIMEOUT:-360}"
INTERVAL="${NG_SETUP_INTERVAL:-30}"
SINCE="${SINCE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

start=$SECONDS
while :; do
  if [[ -n "${NG_LOG_FILE:-}" ]]; then
    logs="$(cat "$NG_LOG_FILE")"
  else
    core_cid="$(docker ps -q --filter label=com.docker.compose.project=openru \
      --filter label=com.docker.compose.service=core --filter status=running 2>/dev/null | head -1 || true)"
    if [[ -z "$core_cid" ]]; then
      echo "[ng] FAIL: no running core container (compose service 'core'); start core/up first" >&2
      exit 1
    fi
    logs="$(docker logs --since "$SINCE" "$core_cid" 2>&1 || true)"
  fi
  if grep -Eiq 'gNB-N2 accepted|NGSetupResponse|NG Setup (Procedure )?Response|Connected to AMF' <<<"$logs"; then
    echo "[ng] AMF accepted the DU NG Setup after $((SECONDS - start))s"
    exit 0
  fi
  if grep -Eiq 'NGSetupFailure|unknown-PLMN|CU-CP failed to connect to AMF' <<<"$logs"; then
    echo "[ng] FAIL: AMF rejected the DU NG Setup" >&2
    printf '%s\n' "$logs" | tail -20 | sed 's/^/      | /' >&2
    exit 1
  fi
  elapsed=$((SECONDS - start))
  if (( elapsed >= TIMEOUT )); then
    echo "[ng] FAIL: no AMF NG Setup for the DU after ${TIMEOUT}s" >&2
    printf '%s\n' "$logs" | tail -20 | sed 's/^/      | /' >&2
    exit 1
  fi
  echo "[ng] waiting for AMF NG Setup for the DU (${elapsed}s / ${TIMEOUT}s) ..."
  sleep "$INTERVAL"
done
