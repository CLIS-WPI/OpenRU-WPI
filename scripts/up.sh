#!/usr/bin/env bash
# Bring up the OpenRU stack and print the wiring the operator needs.
#
#   make up                                  # dev: fh stack, profile baseline
#   make up STACK=e2e PROFILE=bench-20mhz    # core + DU + RU (radio=uhd under BENCH=1)
#   make BENCH=1 up STACK=e2e PROFILE=bench-20mhz
#   make up STACK=e2e PROFILE=bench-20mhz RADIO=null   # dry run / null radio
#
# Env: STACK=fh|core|e2e, PROFILE=<profiles/…>, RADIO=uhd|null,
#      BENCH=1 (docker/bench.env + docker/compose.cpu.yml).
# Prints the core map, the antenna/divider map and the image tags on every
# bring-up, so a cabling mistake is visible before the first run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK="${STACK:-fh}"
PROFILE="${PROFILE:-baseline}"
RADIO="${RADIO:-${BENCH:+uhd}}"
RADIO="${RADIO:-null}"

if [[ "${BENCH:-0}" == "1" ]]; then
  ENV_FILE="$ROOT/docker/bench.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml" -f "$ROOT/docker/compose.cpu.yml")
else
  ENV_FILE="$ROOT/docker/lab.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml")
fi

PROFILE_DIR="$ROOT/profiles/$PROFILE"
[[ -d "$PROFILE_DIR" ]] || { echo "[up] FAIL: unknown PROFILE '$PROFILE' ($PROFILE_DIR)" >&2; exit 2; }

case "$RADIO" in
  uhd)  RU_YML="$PROFILE_DIR/protoru.yml"; [[ "${BENCH:-0}" == "1" ]] || {
          echo "[up] FAIL: RADIO=uhd is the bench path (BENCH=1); use RADIO=null here" >&2; exit 2; } ;;
  null) RU_YML="$PROFILE_DIR/protoru-null.yml" ;;
  *) echo "[up] FAIL: RADIO must be uhd or null" >&2; exit 2 ;;
esac
[[ -f "$RU_YML" ]] || { echo "[up] FAIL: missing $RU_YML" >&2; exit 2; }

DU_YML="$PROFILE_DIR/du-fh.yml"
case "$STACK" in
  fh)   ;;
  core) COMPOSE+=(-f "$ROOT/docker/compose.core.yml"); DU_YML="$PROFILE_DIR/du-core.yml" ;;
  e2e)  COMPOSE+=(-f "$ROOT/docker/compose.e2e.yml"); DU_YML="$PROFILE_DIR/du-core.yml"
        [[ "$RADIO" == "uhd" ]] && COMPOSE+=(-f "$ROOT/docker/compose.radio.yml") ;;
  *) echo "[up] FAIL: STACK must be fh, core or e2e" >&2; exit 2 ;;
esac
[[ -f "$DU_YML" ]] || { echo "[up] FAIL: missing $DU_YML" >&2; exit 2; }

export DU_CONFIG_PATH="$DU_YML"
export PROTORU_CONFIG_PATH="$RU_YML"

OPENRU_PREFLIGHT_ENV="$ENV_FILE" "$ROOT/scripts/gpu1_preflight.sh"

set -a; . "$ENV_FILE"; set +a
echo
echo "== stack: $STACK / profile: $PROFILE / radio: $RADIO =="
echo "  DU config      : ${DU_YML#$ROOT/}"
echo "  ProtO-RU config: ${RU_YML#$ROOT/}"
echo
echo "== core map (${ENV_FILE##*/}) =="
printf '  ProtO-RU real-time : %s\n' "${PROTORU_CPUSET:-?}"
printf '  DU real-time       : %s\n' "${DU_CPUSET:-?}"
printf '  housekeeping/IRQs  : 0-1,12-19 (bench); core containers: %s\n' "${CORE_CPUSET:-n/a}"
echo
echo "== networking =="
echo "  core bridge 10.53.1.0/24 : DU 10.53.1.6 <-> AMF/UPF 10.53.1.2"
echo "  fh bridge   10.54.1.0/24 (MTU 9000): DU 10.54.1.10 <-> ProtO-RU 10.54.1.20"
if [[ "$RADIO" == "uhd" ]]; then
  echo "  radio macvlan ${BENCH_RADIO_SUBNET:-192.168.10.0/24} via ${BENCH_FH_IFACE:-enp5s0f1np1}: ProtO-RU ${BENCH_RU_IP:-192.168.10.3} -> N310 ${BENCH_USRP_ADDR:-192.168.10.2}"
else
  echo "  radio: null (no radio NIC; dry run)"
fi
echo
echo "== antenna map (divider cabling; docs/BENCH_BUNDLE.md) =="
printf '  30 dB into each divider; Out1/Out2 through 20 dB; Out3/Out4 = 50 ohm.\n'
printf '  Div1 RF0 TX/RX : Out1 modem A ANT0, Out2 modem B ANT0\n'
printf '  Div2 RF1 TX/RX : Out1 modem A ANT1, Out2 modem B ANT1\n'
printf '  Div3 RF0 RX2   : Out1 modem A ANT2, Out2 modem B ANT2  (UL)\n'
printf '  Div4 RF1 RX2   : Out1 modem A ANT3, Out2 modem B ANT3  (UL)\n'
printf '  First test: modem A; modem B airplane (AT+CFUN=4).\n'
printf '  ~57 dB/path. UHD: tx_antenna=TX/RX, rx_antenna=RX2.\n'
echo

# Check a pinned interface name inside a container: it must exist and carry an
# address of the expected subnet. Docker used to hand out eth0/eth1 by
# attachment order; the compose files now pin ofh0/n2/radio0 and this fails
# loudly (before the radio is used) if a container came up differently.
check_iface() { # <container> <iface> <subnet-prefix> <what>
  local cid="$1" iface="$2" prefix="$3" what="$4" out
  out="$(docker exec "$cid" sh -c "ip -4 -o addr show dev '$iface' 2>/dev/null" || true)"
  if [[ -z "$out" ]]; then
    echo "[up] FAIL: $what: interface '$iface' missing in $cid" >&2
    echo "      interfaces: $(docker exec "$cid" ip -4 -o addr 2>/dev/null | awk '{print $2}' | paste -sd' ' -)" >&2
    return 1
  fi
  if ! grep -q "inet ${prefix}" <<<"$out"; then
    echo "[up] FAIL: $what: interface '$iface' has $(awk '{print $4}' <<<"$out"), expected ${prefix}/…" >&2
    return 1
  fi
  echo "[up] ok: $what $iface $(awk '{print $4}' <<<"$out")"
}

wait_healthy() { # <service> <seconds>
  local svc="$1" secs="${2:-120}" cid status i
  for i in $(seq 1 "$secs"); do
    cid="$("${COMPOSE[@]}" ps -q "$svc" 2>/dev/null | head -1)"
    [[ -n "$cid" ]] || { sleep 1; continue; }
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)"
    case "$status" in
      healthy|none) return 0 ;;
      unhealthy) echo "[up] FAIL: $svc is unhealthy" >&2; return 1 ;;
    esac
    sleep 1
  done
  echo "[up] FAIL: $svc did not become healthy within ${secs}s" >&2
  return 1
}

case "$STACK" in
  fh)   "${COMPOSE[@]}" --profile fh up -d du protoru ;;
  core) "${COMPOSE[@]}" --profile core up -d core; wait_healthy core || exit 1
        "${COMPOSE[@]}" --profile core up -d du ;;
  e2e)  "${COMPOSE[@]}" --profile core --profile fh up -d core; wait_healthy core || exit 1
        "${COMPOSE[@]}" --profile core --profile fh up -d du; sleep 2
        du_cid="$("${COMPOSE[@]}" ps -q du | head -1)"
        check_iface "$du_cid" ofh0 10.54.1. "DU" || { "${COMPOSE[@]}" --profile core --profile fh down --remove-orphans >/dev/null 2>&1; exit 1; }
        check_iface "$du_cid" n2 10.53.1. "DU" || { "${COMPOSE[@]}" --profile core --profile fh down --remove-orphans >/dev/null 2>&1; exit 1; }
        "${COMPOSE[@]}" --profile core --profile fh up -d protoru; sleep 2
        ru_cid="$("${COMPOSE[@]}" ps -q protoru | head -1)"
        check_iface "$ru_cid" ofh0 10.54.1. "ProtO-RU" || { "${COMPOSE[@]}" --profile core --profile fh down --remove-orphans >/dev/null 2>&1; exit 1; }
        if [[ "$RADIO" == "uhd" ]]; then
          check_iface "$ru_cid" radio0 192.168.10. "ProtO-RU radio" || { "${COMPOSE[@]}" --profile core --profile fh down --remove-orphans >/dev/null 2>&1; exit 1; }
        fi ;;
esac
echo
"${COMPOSE[@]}" ps
