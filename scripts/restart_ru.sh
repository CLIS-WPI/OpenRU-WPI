#!/usr/bin/env bash
# TX gain step-up / RU restart for the bench stack.
#
#   make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=5
#   make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=5 REF=external
#   make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=10 RESTART_DU=1
#
# REF=external|internal (default internal). external selects only the 10 MHz
# reference (clock_source=external, time_source=internal); internal uses the
# N310 onboard oscillator for both clock and time.
#
# The committed profile is never modified: the copy lives in build/local-profiles/
# (gitignored) and is passed to compose as PROTORU_CONFIG_PATH.
#
# Before recreating ProtO-RU the old container is fully stopped and the N310 must
# report claimed=False (UHD only) — otherwise the new container opens the device
# while the old one still holds it. Timeout: RU_RELEASE_TIMEOUT (default 60 s).
#
# The DU tolerates an O-RU-only restart (cell and NG stay up; OFH resumes), so
# only protoru is recreated unless RESTART_DU=1. With RESTART_DU=1, wait for
# the AMF NG Setup before reporting done; never judge OFH before that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${PROFILE:?set PROFILE=<profiles/…>}"
TX_GAIN="${TX_GAIN:?set TX_GAIN=<value>}"
REF="${REF:-internal}"
case "$REF" in
  external|internal) ;;
  *) echo "restart-ru: FAIL: REF must be external or internal (got $REF)" >&2; exit 1 ;;
esac
RADIO="${RADIO:-uhd}"
RESTART_DU="${RESTART_DU:-0}"
RELEASE_TIMEOUT="${RU_RELEASE_TIMEOUT:-60}"

OUT="$("$ROOT/scripts/local_profile.sh" "$PROFILE" "$TX_GAIN" "$REF" | tail -1)"
export PROTORU_CONFIG_PATH="$OUT"
export REF

if [[ "${BENCH:-0}" == "1" ]]; then
  ENV_FILE="docker/bench.env"
  COMPOSE=(docker compose --env-file docker/versions.env --env-file "$ENV_FILE"
           -f docker/compose.yml -f docker/compose.cpu.yml)
  [[ "$RADIO" == "uhd" ]] && COMPOSE+=(-f docker/compose.radio.yml)
else
  ENV_FILE="docker/lab.env"
  COMPOSE=(docker compose --env-file docker/versions.env --env-file "$ENV_FILE" -f docker/compose.yml)
fi
[[ -f "$ENV_FILE" ]] || { echo "restart-ru: FAIL: $ENV_FILE missing" >&2; exit 1; }
COMPOSE+=(-f docker/compose.e2e.yml)
set -a; . "$ENV_FILE"; set +a

# 1. Stop the old ProtO-RU and wait until it is really down.
OLD_CID="$("${COMPOSE[@]}" ps -q protoru 2>/dev/null | head -1 || true)"
RU_IMAGE="openru/protoru:${OPENRU_TAG:-bench-latest}"
if [[ -n "$OLD_CID" ]]; then
  RU_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$OLD_CID" 2>/dev/null || echo "$RU_IMAGE")"
  echo "restart-ru: stopping $OLD_CID"
  docker stop "$OLD_CID" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$OLD_CID" 2>/dev/null || echo false)" == "false" ]] && break
    sleep 1
  done
  if [[ "$(docker inspect -f '{{.State.Running}}' "$OLD_CID" 2>/dev/null || echo false)" != "false" ]]; then
    echo "restart-ru: FAIL: the old ProtO-RU container did not stop" >&2; exit 1
  fi
fi

# 2. Wait until the N310 is released (UHD only): uhd_find_devices must report
#    claimed=False. A throw-away container on the radio macvlan network probes it
#    from BENCH_PROBE_IP (default .4), so Docker never auto-assigns .2 (the N310).
if [[ "$RADIO" == "uhd" ]]; then
  [[ -n "${BENCH_USRP_ADDR:-}" ]] || { echo "restart-ru: FAIL: BENCH_USRP_ADDR missing" >&2; exit 1; }
  PROBE_IP="${BENCH_PROBE_IP:-192.168.10.4}"
  released=0
  for _ in $(seq 1 "$RELEASE_TIMEOUT"); do
    probe="$(timeout 15 docker run --rm --network openru_radio --ip "$PROBE_IP" \
               --entrypoint /bin/bash "$RU_IMAGE" \
               -lc "uhd_find_devices --args addr=${BENCH_USRP_ADDR} 2>&1" 2>&1 || true)"
    if printf '%s' "$probe" | grep -qiE 'claimed: *false'; then released=1; break; fi
    if printf '%s' "$probe" | grep -qiE 'claimed: *true'; then sleep 1; continue; fi
    sleep 1
  done
  if [[ "$released" != 1 ]]; then
    echo "restart-ru: FAIL: N310 ${BENCH_USRP_ADDR} not released (claimed=False) within ${RELEASE_TIMEOUT}s" >&2
    printf '%s\n' "$probe" | tail -5 | sed 's/^/      | /' >&2
    exit 1
  fi
  echo "restart-ru: N310 ${BENCH_USRP_ADDR} released (claimed=False; probe ${PROBE_IP})"
  if [[ "$REF" == "external" ]]; then
    echo "restart-ru: checking N310 ref_locked (REF=external)"
    "$ROOT/scripts/ref_check.sh"
  fi
fi

# 3. Start ProtO-RU (and optionally the DU) with the local profile.
"${COMPOSE[@]}" --profile fh --profile core up -d --no-deps --force-recreate protoru
if [[ "$RESTART_DU" == "1" ]]; then
  NG_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "${COMPOSE[@]}" --profile fh --profile core up -d --no-deps --force-recreate du
  echo "restart-ru: DU recreated too; waiting for AMF NG Setup"
  BENCH="${BENCH:-0}" SINCE="$NG_SINCE" "$ROOT/scripts/wait_ng_setup.sh"
fi
echo "restart-ru: done (tx_gain=${TX_GAIN}, ref=${REF}; external=10 MHz only); waiting for NG Setup before judging OFH; watch: docker compose logs -f protoru du; then modem RSRP (target -80..-90 dBm)."
