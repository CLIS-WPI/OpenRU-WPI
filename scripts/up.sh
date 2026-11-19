#!/usr/bin/env bash
# Bring up the OpenRU stack and print the wiring the operator needs.
#
#   scripts/up.sh            # GPU host: docker/lab.env, profile fh (du + protoru)
#   BENCH=1 scripts/up.sh    # bench host: docker/bench.env + docker/compose.cpu.yml
#   scripts/up.sh core       # NG-Setup stack (core + du)
#
# Prints the core map (from the active env file) and the N310/RM520N antenna
# map on every bring-up, so a cabling mistake is visible before the first run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-fh}"

if [[ "${BENCH:-0}" == "1" ]]; then
  ENV_FILE="$ROOT/docker/bench.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml" -f "$ROOT/docker/compose.cpu.yml")
else
  ENV_FILE="$ROOT/docker/lab.env"
  COMPOSE=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ENV_FILE"
           -f "$ROOT/docker/compose.yml")
fi

OPENRU_PREFLIGHT_ENV="$ENV_FILE" "$ROOT/scripts/gpu1_preflight.sh"

set -a; . "$ENV_FILE"; set +a
echo
echo "== core map (${ENV_FILE##*/}) =="
printf '  ProtO-RU real-time : %s\n' "${PROTORU_CPUSET:-?}"
printf '  DU real-time       : %s\n' "${DU_CPUSET:-?}"
printf '  housekeeping/IRQs  : 0-1,12-19 (bench); core containers: %s\n' "${CORE_CPUSET:-n/a}"
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

case "$WHAT" in
  fh)   "${COMPOSE[@]}" --profile fh up -d du protoru ;;
  core) "${COMPOSE[@]}" -f "$ROOT/docker/compose.core.yml" --profile core up -d core ;;
  *) echo "usage: $0 [fh|core]" >&2; exit 2 ;;
esac
echo
"${COMPOSE[@]}" ps
