#!/usr/bin/env bash
# Bench log caps and disk guard (no hardware): bench DU profiles keep per-packet/per-allocation layers at warning
# but OFH at info, ul_past_seq_drops is counted from forced drops in the DU's own message format, and
# scripts/bench_disk_check.sh passes or refuses on the free-space threshold.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1]); n = 0
for p in sorted(root.glob("profiles/bench-*/du-*.yml")):
    log = yaml.safe_load(p.read_text())["log"]
    for k in ("phy_level", "rlc_level", "pdcp_level", "gtpu_level", "f1u_level"):
        assert log.get(k) == "warning", (str(p), k, log.get(k))
    # ul_past_seq_drops is an OFH info line: OFH must not be capped.
    assert log.get("ofh_level", log.get("all_level")) in ("info", "debug"), (str(p), "ofh_level", log.get("ofh_level"))
    assert log.get("all_level") == "info", (str(p), "METRICS/OFH lines the analysers read need info")
    n += 1
assert n >= 8, n
print(f"PASS: {n} bench DU profiles log per-packet layers at warning, OFH at info")
PY

# Forced drops: three DU log lines built from the DU's own format string (lib/ofh/receiver) must count as three
# ul_past_seq_drops; the same log without them counts zero.
python3 - "$ROOT" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
src = (root / "external/proto-ru/lib/ofh/receiver/ofh_message_receiver_impl.cpp").read_text()
m = re.search(r'logger\.info\("(Sector#\{\}: dropped received Open Fronthaul User-Plane packet[^)]*?from the past)"', re.sub(r'"\s*\n\s*"', "", src))
assert m, "drop message not found in the DU source"
fmt = m.group(1)
sys.path.insert(0, str(root / "scripts"))
import parse_smoke_fh as p
drops = [f"2026-11-20T21:00:0{i}.000000 [OFH     ] [I] " + fmt.replace("{}", "0", 1).replace("{}", str(i), 1) for i in range(3)]
base = ["2026-11-20T21:00:00.500000 [METRICS ] OFH sector#0 metrics: rx_total=10 rx_early=0 rx_on_time=10 rx_late=0"]
got, none = p.parse_du_ofh("\n".join(base + drops))["ul_past_seq_drops"], p.parse_du_ofh("\n".join(base))["ul_past_seq_drops"]
assert (got, none) == (3, 0), (got, none)
print(f"PASS: forced drops counted: ul_past_seq_drops={got} (0 without drops)")
PY
BENCH_MIN_FREE_GB=0 "$ROOT/scripts/bench_disk_check.sh" >/dev/null && echo "PASS: disk check passes at 0 GB"
if BENCH_MIN_FREE_GB=1000000 "$ROOT/scripts/bench_disk_check.sh" 2>/dev/null; then
  echo "FAIL: disk check passed with a 1000000 GB threshold" >&2; exit 1
fi
echo "PASS: disk check refuses below the threshold"
