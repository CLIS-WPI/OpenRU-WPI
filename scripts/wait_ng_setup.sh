#!/usr/bin/env bash
# Wait until the AMF accepts the DU's NG Setup.
#
#   SINCE=<RFC3339 timestamp> scripts/wait_ng_setup.sh
#
# The DU can take several minutes to create its O-DU before it starts CU-CP
# and sends NGSetupRequest. Do not judge OFH or call the stack "up" before this
# returns. Polling is on the Open5GS AMF log, every 30 s, timeout 6 min.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="${BENCH:-0}"
TIMEOUT="${NG_SETUP_TIMEOUT:-360}"
INTERVAL="${NG_SETUP_INTERVAL:-30}"
SINCE="${SINCE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [[ "$BENCH" == "1" ]]; then
  ENV_FILE="$ROOT/docker/bench.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml" -f "$ROOT/docker/compose.cpu.yml")
else
  ENV_FILE="$ROOT/docker/lab.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml")
fi
[[ -f "$ENV_FILE" ]] || { echo "[ng] FAIL: $ENV_FILE missing" >&2; exit 1; }

start=$SECONDS
while :; do
  logs="$("${COMPOSE[@]}" logs --no-color --since "$SINCE" core 2>/dev/null || true)"
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
