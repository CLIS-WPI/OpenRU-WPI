#!/usr/bin/env bash
# The AMF log sample is the real Open5GS line captured on the bench.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' \
  '11/19 17:51:30.715: [amf] INFO: gNB-N2 accepted[10.53.1.6]:54227 in ng-path module' > "$TMP/amf.log"
NG_LOG_FILE="$TMP/amf.log" NG_SETUP_TIMEOUT=2 NG_SETUP_INTERVAL=1 \
  "$ROOT/scripts/wait_ng_setup.sh" >/dev/null
printf '%s\n' 'no SCTP INIT here' > "$TMP/amf.log"
if NG_LOG_FILE="$TMP/amf.log" NG_SETUP_TIMEOUT=1 NG_SETUP_INTERVAL=1 \
   "$ROOT/scripts/wait_ng_setup.sh" >/dev/null 2>&1; then
  echo "FAIL: wait_ng_setup accepted a log with no NG Setup" >&2
  exit 1
fi
echo "PASS: AMF NG Setup gate"
