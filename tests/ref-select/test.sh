#!/usr/bin/env bash
# Test the REF/overlay path and the UHD-API ref_locked check without a radio.
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
assert s["sync_source"] == "internal", s["sync_source"]
assert "clock_source=external,time_source=internal" in s["device_args"], s["device_args"]
PY

# Real UHD sensor value strings: "locked"/"unlocked" (the boolean unit pair),
# not "true"/"false". The helper override exercises ref_check without a radio;
# the image self-test exercises the real UHD API.
cat > "$TMP/locked" <<'EOF'
#!/bin/sh
echo "ref_locked: locked"
exit 0
EOF
cat > "$TMP/unlocked" <<'EOF'
#!/bin/sh
echo "ref_locked: unlocked"
exit 1
EOF
chmod +x "$TMP/locked" "$TMP/unlocked"

UHD_REF_CHECK_HELPER="$TMP/locked" REF=external BENCH_USRP_ADDR=192.168.10.2 \
  "$ROOT/scripts/ref_check.sh" >/dev/null
if UHD_REF_CHECK_HELPER="$TMP/unlocked" REF=external BENCH_USRP_ADDR=192.168.10.2 \
     "$ROOT/scripts/ref_check.sh" >/dev/null 2>&1; then
  fail "ref_locked=unlocked was accepted"
fi
REF=internal "$ROOT/scripts/ref_check.sh" >/dev/null

IMG="${IMG:-openru/protoru:${OPENRU_TAG:-bench-latest}}"
if docker image inspect "$IMG" >/dev/null 2>&1; then
  if docker run --rm --entrypoint /bin/bash "$IMG" -lc \
       'command -v uhd_ref_check >/dev/null || test -x /opt/ocudu/bin/uhd_ref_check'; then
    docker run --rm --entrypoint /bin/bash "$IMG" -lc \
      'uhd_ref_check --self-test 2>/dev/null || /opt/ocudu/bin/uhd_ref_check --self-test'
  else
    echo "SKIP: ${IMG} predates uhd_ref_check; rebuild the bench image for the API self-test"
  fi
fi

echo "PASS: REF overlay is absolute and ref_locked is enforced for external"
