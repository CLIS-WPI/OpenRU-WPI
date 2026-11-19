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
printf '  Four 4-way dividers; each N310 port through 30 dB into its own divider.\n'
printf '  Out1 -> modem A +20 dB; Out2 -> modem B +20 dB; Out3/Out4 -> 50 ohm.\n'
printf '  RF0 TX/RX -> ANT0   (DL layer 0)\n'
printf '  RF1 TX/RX -> ANT1   (DL layer 1)\n'
printf '  RF0 RX2   <- ANT2   (modem main TX / UL)\n'
printf '  RF1 RX2   <- ANT3\n'
printf '  ~57 dB per path. UHD names: tx_antenna=TX/RX, rx_antenna=RX2.\n'
echo

case "$WHAT" in
  fh)   "${COMPOSE[@]}" --profile fh up -d du protoru ;;
  core) "${COMPOSE[@]}" -f "$ROOT/docker/compose.core.yml" --profile core up -d core ;;
  *) echo "usage: $0 [fh|core]" >&2; exit 2 ;;
esac
echo
"${COMPOSE[@]}" ps
