#!/usr/bin/env bash
# Materialise a local copy of a bench profile and patch tx_gain in it.
#
#   scripts/local_profile.sh <profile> <tx_gain>   # prints the local protoru.yml path
#
# The committed profile is never modified: the copy lives in build/local-profiles/
# (gitignored). Used by `make up TX_GAIN=…` and `make restart-ru TX_GAIN=…`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${1:?usage: local_profile.sh <profile> <tx_gain>}"
TX_GAIN="${2:?usage: local_profile.sh <profile> <tx_gain>}"

SRC="profiles/$PROFILE/protoru.yml"
OUT="build/local-profiles/$PROFILE/protoru.yml"
[[ -f "$SRC" ]] || { echo "local_profile: missing $SRC" >&2; exit 1; }

python3 - "$SRC" "$OUT" "$TX_GAIN" <<'PY'
import pathlib, re, sys
src, out, value = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), float(sys.argv[3])
if not (0.0 <= value <= 65.0) or abs(value * 2 - round(value * 2)) > 1e-9:
    sys.exit(f"local_profile: TX_GAIN={value:g} outside 0..65 dB or off the 0.5 dB step")
text = src.read_text()
new, n = re.subn(r"(?m)^(\s*)tx_gain:.*$", lambda m: f"{m.group(1)}tx_gain: {value:g}", text, count=1)
if n != 1:
    sys.exit(f"local_profile: no tx_gain line in {src}")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(new)
print(f"local_profile: {out} tx_gain={value:g}")
PY
echo "$OUT"
