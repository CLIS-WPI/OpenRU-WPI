#!/usr/bin/env bash
# Shared golden-energy check (wraps tools/golden/check.py) for every suite that
# replays or reads IQ dumps.
#   golden_energy_check <dump-dir> <window.json> <du-config.yml> [out.json]
# Exit 0 pass, 1 fail, 2 usage/parse error (check.py contract).

ROOT_ENERGY="${ROOT:?ROOT required}"

golden_energy_check() {
  local dump="$1" window="$2" du_config="$3" out="${4:-${dump}-check.json}"
  python3 "$ROOT_ENERGY/tools/golden/check.py" \
    --dump "$dump" --window-json "$window" --du-config "$du_config" --out "$out"
}
