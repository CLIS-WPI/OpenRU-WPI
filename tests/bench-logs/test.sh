#!/usr/bin/env bash
# Bench log caps and disk guard (no hardware): bench DU profiles keep per-packet/per-allocation layers at warning,
# and scripts/bench_disk_check.sh passes or refuses on the free-space threshold.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1]); n = 0
for p in sorted(root.glob("profiles/bench-*/du-*.yml")):
    log = yaml.safe_load(p.read_text())["log"]
    for k in ("ofh_level", "phy_level", "rlc_level", "pdcp_level", "gtpu_level", "f1u_level"):
        assert log.get(k) == "warning", (str(p), k, log.get(k))
    assert log.get("all_level") == "info", (str(p), "METRICS/OFH lines the analysers read need info")
    n += 1
assert n >= 8, n
print(f"PASS: {n} bench DU profiles log per-packet layers at warning")
PY
BENCH_MIN_FREE_GB=0 "$ROOT/scripts/bench_disk_check.sh" >/dev/null && echo "PASS: disk check passes at 0 GB"
if BENCH_MIN_FREE_GB=1000000 "$ROOT/scripts/bench_disk_check.sh" 2>/dev/null; then
  echo "FAIL: disk check passed with a 1000000 GB threshold" >&2; exit 1
fi
echo "PASS: disk check refuses below the threshold"
