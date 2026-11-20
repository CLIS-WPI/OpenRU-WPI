#!/usr/bin/env bash
# Two-host split stack: DU + Open5GS on the "core" host, ProtO-RU on the bench host.
#
#   scripts/split.sh core up          # on the core host first: Open5GS + DU, NG Setup, DU thread plan
#   scripts/split.sh core up --core-only  # Open5GS only (e.g. provisioning): no DU, no fh macvlan, no PTP check
#   RADIO=null scripts/split.sh ran up # then on the bench host: ProtO-RU (null radio), RU thread plan
#   scripts/split.sh <role> check [s]  # on each host after both are up: rt follower + gate (settle 120 s, two passing windows of [s], default 60)
#   scripts/split.sh <role> down       # ran first, then core
#   Phase D (transmits; human go only):
#   RF_SPLIT_OK=1 RADIO=uhd BENCH_RADIO=n310-20 TX_GAIN=30 PROFILE=bench-split-20mhz-2t2r scripts/split.sh ran up
#
# Fronthaul: docker/compose.split.yml (macvlan on SPLIT_FH_IFACE, MTU 9000, never a bridge).
# Env: docker/bench.env, then docker/split-<role>.env. Profile: PROFILE (default bench-split-20mhz).
# Both hosts' slot timing follows their system clock: the core's is PTP-disciplined from the bench
# host (openru-ptp4l / openru-phc2sys); "up" refuses on core when phc2sys is not active.
# RADIO=uhd on ran is Phase D (transmits): RF_SPLIT_OK=1 and TX_GAIN <= 30 required; not the default.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLE="${1:?usage: split.sh <core|ran> <up|check|down>}"; ACT="${2:?usage: split.sh <core|ran> <up|check|down>}"
PROFILE="${PROFILE:-bench-split-20mhz}"; RADIO="${RADIO:-null}"
case "$ROLE" in core|ran) ;; *) echo "split: FAIL: role must be core or ran" >&2; exit 2 ;; esac
CORE_ONLY=0
if [[ "$ACT" == up && -n "${3:-}" ]]; then
  [[ "$3" == --core-only && "$ROLE" == core ]] || { echo "split: FAIL: only 'split.sh core up --core-only' takes a flag" >&2; exit 2; }
  CORE_ONLY=1
fi
set -a; . "$ROOT/docker/bench.env"; . "$ROOT/docker/split-$ROLE.env"; set +a
export RT_WATCH_SIDE=one
P="$ROOT/profiles/$PROFILE"
export DU_CONFIG_PATH="$P/du-core.yml"
case "$RADIO" in
  null) export PROTORU_CONFIG_PATH="$P/protoru-null.yml" ;;
  uhd)  [[ "$ROLE" == ran ]] || { echo "split: FAIL: RADIO applies to the ran role" >&2; exit 2; }
        [[ "${RF_SPLIT_OK:-0}" == 1 ]] || { echo "split: FAIL: RADIO=uhd transmits; set RF_SPLIT_OK=1 only with the human's go" >&2; exit 2; }
        # Phase D limits: explicit TX gain, never above 30 (cabled bench, p_max 10 in the DU profile).
        [[ "${TX_GAIN:-}" =~ ^[0-9]+(\.[05])?$ ]] && awk -v g="$TX_GAIN" 'BEGIN{exit !(g <= 30)}' \
          || { echo "split: FAIL: RADIO=uhd needs TX_GAIN <= 30 (got '${TX_GAIN:-}')" >&2; exit 2; }
        . "$ROOT/scripts/radio_env.sh"; radio_env_load "$ROOT" || exit 2   # BENCH_RADIO (default n310-10)
        export PROTORU_CONFIG_PATH="$("$ROOT/scripts/local_profile.sh" "$PROFILE" "$TX_GAIN" internal | tail -1)" ;;
  *) echo "split: FAIL: RADIO must be null or uhd" >&2; exit 2 ;;
esac
COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ROOT/docker/bench.env"
         --env-file "$ROOT/docker/split-$ROLE.env" -f "$ROOT/docker/compose.yml" -f "$ROOT/docker/compose.cpu.yml")
[[ "$ROLE" == core ]] && COMPOSE+=(-f "$ROOT/docker/compose.e2e.yml")
[[ "$ROLE" == ran && "$RADIO" == uhd ]] && COMPOSE+=(-f "$ROOT/docker/compose.radio.yml")
COMPOSE+=(-f "$ROOT/docker/compose.split.yml")

preflight() {
  local mtu; mtu="$(cat "/sys/class/net/$SPLIT_FH_IFACE/mtu" 2>/dev/null || echo 0)"
  [[ "$(cat "/sys/class/net/$SPLIT_FH_IFACE/operstate" 2>/dev/null)" == up ]] || { echo "split: FAIL: $SPLIT_FH_IFACE is not up" >&2; exit 1; }
  (( mtu >= 9000 )) || { echo "split: FAIL: $SPLIT_FH_IFACE MTU $mtu < 9000" >&2; exit 1; }
  if [[ "$ROLE" == core ]]; then
    systemctl is-active --quiet openru-phc2sys || { echo "split: FAIL: openru-phc2sys not active (PTP)" >&2; exit 1; }
  else
    systemctl is-active --quiet openru-ptp4l || { echo "split: FAIL: openru-ptp4l not active (PTP master)" >&2; exit 1; }
  fi
  echo "split: $ROLE: $SPLIT_FH_IFACE up, MTU $mtu; PTP service active; profile $PROFILE, radio $RADIO"
}

case "$ACT" in
  up)
    (( CORE_ONLY )) || preflight
    if [[ "$ROLE" == core ]]; then
      # Open5GS first: a DU started before the AMF listens exits on "Connection refused" (as in up.sh).
      # --core-only: profile core only, so neither the DU nor the fh macvlan is created.
      if (( CORE_ONLY )); then "${COMPOSE[@]}" --profile core up -d core
      else "${COMPOSE[@]}" --profile core --profile fh up -d core; fi
      for i in $(seq 1 120); do
        h="$(docker inspect -f '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q core | head -1)" 2>/dev/null || true)"
        [[ "$h" == healthy ]] && break
        [[ "$h" == unhealthy || "$i" == 120 ]] && { echo "split: FAIL: core not healthy ($h)" >&2; exit 1; }
        sleep 1
      done
      (( CORE_ONLY )) && { echo "split: core: Open5GS healthy (--core-only: no DU, no fh)"; exit 0; }
      since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      "${COMPOSE[@]}" --profile core --profile fh up -d du
      BENCH=1 SINCE="$since" "$ROOT/scripts/wait_ng_setup.sh"
      RT_CHECK_SECS=0 "$ROOT/scripts/bench_rt.sh" du
    else
      "${COMPOSE[@]}" --profile fh up -d --no-deps protoru
      RT_CHECK_SECS=0 "$ROOT/scripts/bench_rt.sh" ru
    fi ;;
  check)
    # The bench gate: settle 120 s, then 60 s windows until two in a row pass (scripts/bench_rt.sh).
    [[ "${3:-60}" =~ ^[0-9]+$ ]] || { echo "split: FAIL: check takes a window length in seconds (got $3)" >&2; exit 2; }
    RT_CHECK_SECS="${3:-60}" "$ROOT/scripts/bench_rt.sh" check ;;
  down)
    "$ROOT/scripts/rt_watch.sh" stop || true
    "${COMPOSE[@]}" --profile core --profile fh down --remove-orphans ;;
  *) echo "split: FAIL: action must be up, check or down" >&2; exit 2 ;;
esac
