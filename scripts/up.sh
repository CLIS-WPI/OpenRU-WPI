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
echo "== antenna map (N310 RF -> RM520N) =="
printf '  RF0 -> ANT2  primary n78 TX\n'
printf '  RF1 -> ANT0  second TX\n'
printf '  RF2 -> ANT1  third TX\n'
printf '  RF3 -> ANT3  fourth TX\n'
printf '  2x2 profiles use RF0-RF1; 4x4 uses all four ports\n'
echo

case "$WHAT" in
  fh)   "${COMPOSE[@]}" --profile fh up -d du protoru ;;
  core) "${COMPOSE[@]}" -f "$ROOT/docker/compose.core.yml" --profile core up -d core ;;
  *) echo "usage: $0 [fh|core]" >&2; exit 2 ;;
esac
echo
"${COMPOSE[@]}" ps
