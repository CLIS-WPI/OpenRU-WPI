#!/usr/bin/env bash
# Test the REF/overlay path and the ref_locked parser without a radio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

OUT="$("$ROOT/scripts/local_profile.sh" bench-20mhz - internal | tail -1)"
[[ "$OUT" = /* ]] || fail "overlay path is not absolute: $OUT"
python3 - "$OUT" <<'PY'
import sys, yaml
s = yaml.safe_load(open(sys.argv[1]))["ru_emu"]["cells"][0]["sdr"]
assert s["clock_source"] == "internal", s["clock_source"]
assert s["sync_source"] == "internal", s["sync_source"]
assert "clock_source=internal,time_source=internal" in s["device_args"], s["device_args"]
PY

OUT="$("$ROOT/scripts/local_profile.sh" bench-20mhz 12.5 external | tail -1)"
[[ "$OUT" = /* ]] || fail "overlay path is not absolute: $OUT"
python3 - "$OUT" <<'PY'
import sys, yaml
s = yaml.safe_load(open(sys.argv[1]))["ru_emu"]["cells"][0]["sdr"]
assert s["tx_gain"] == 12.5, s["tx_gain"]
assert s["clock_source"] == "external", s["clock_source"]
assert s["sync_source"] == "external", s["sync_source"]
assert "clock_source=external,time_source=external" in s["device_args"], s["device_args"]
PY

printf '%s\n' "ref_locked: true" > "$TMP/true.txt"
printf '%s\n' "ref_locked: false" > "$TMP/false.txt"

REF=external BENCH_USRP_ADDR=192.168.10.2 RADIO_PROBE_FILE="$TMP/true.txt" \
  "$ROOT/scripts/ref_check.sh" >/dev/null
if REF=external BENCH_USRP_ADDR=192.168.10.2 RADIO_PROBE_FILE="$TMP/false.txt" \
     "$ROOT/scripts/ref_check.sh" >/dev/null 2>&1; then
  fail "ref_locked=false was accepted"
fi
REF=internal "$ROOT/scripts/ref_check.sh" >/dev/null

echo "PASS: REF overlay is absolute and ref_locked is enforced for external"
