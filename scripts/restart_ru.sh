#!/usr/bin/env bash
# TX gain step-up: update a LOCAL copy of the profile and restart ProtO-RU only.
#
#   make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=5
#   make BENCH=1 restart-ru PROFILE=bench-20mhz TX_GAIN=10 RESTART_DU=1
#
# The committed profile is never modified: the copy lives in build/local-profiles/
# (gitignored) and is passed to compose as PROTORU_CONFIG_PATH. Only `protoru` is
# recreated (RESTART_DU=1 also recreates the DU).
#
# The DU tolerates an O-RU-only restart: the cell stays up and the OFH link
# recovers, but expect a short burst of late/missing U-plane packets while the RU
# is down (verified in the null-radio dry run). Restart both only if the DU logs
# OFH timing errors or drops the cell.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${PROFILE:?set PROFILE=<profiles/…>}"
TX_GAIN="${TX_GAIN:?set TX_GAIN=<value>}"
RADIO="${RADIO:-uhd}"
RESTART_DU="${RESTART_DU:-0}"

python3 - "$PROFILE" "$TX_GAIN" <<'PY'
import sys, yaml
profile, value = sys.argv[1], float(sys.argv[2])
if not (0.0 <= value <= 65.0) or abs(value * 2 - round(value * 2)) > 1e-9:
    sys.exit(f"restart-ru: TX_GAIN={value:g} outside 0..65 dB or off the 0.5 dB step")
PY

if [[ "$RADIO" == "null" ]]; then
  SRC="profiles/$PROFILE/protoru-null.yml"
else
  [[ "${BENCH:-0}" == "1" ]] || { echo "restart-ru: RADIO=uhd needs BENCH=1" >&2; exit 2; }
  SRC="profiles/$PROFILE/protoru.yml"
fi
OUT="build/local-profiles/$PROFILE/protoru.yml"
mkdir -p "build/local-profiles/$PROFILE"
cp "$SRC" "$OUT"
python3 - "$OUT" "$TX_GAIN" <<'PY'
import re, sys
path, value = sys.argv[1], float(sys.argv[2])
text = open(path).read()
new = re.sub(r"(?m)^(\s*)tx_gain:.*$", lambda m: f"{m.group(1)}tx_gain: {value:g}", text, count=1)
if new == text:
    sys.exit("restart-ru: no tx_gain line in the profile")
open(path, "w").write(new)
print(f"restart-ru: {path} tx_gain={value:g}")
PY

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

export PROTORU_CONFIG_PATH="$ROOT/$OUT"
"${COMPOSE[@]}" --profile fh --profile core up -d --no-deps --force-recreate protoru
if [[ "$RESTART_DU" == "1" ]]; then
  "${COMPOSE[@]}" --profile fh --profile core up -d --no-deps --force-recreate du
  echo "restart-ru: DU recreated too"
fi
echo "restart-ru: done. Watch: docker compose logs -f protoru du; then modem RSRP (target -80..-90 dBm)."
