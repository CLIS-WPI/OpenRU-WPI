#!/usr/bin/env bash
# Exercise wait_ng_setup against a fake running core container. The accepted
# line is the real Open5GS AMF format captured on the bench.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/bin/sh
if [ "$1" = "ps" ]; then
  [ "${FAKE_CORE:-1}" = "1" ] && echo fake-core-cid
  exit 0
fi
if [ "$1" = "logs" ]; then
  cat "$FAKE_LOG"
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/docker"

printf '%s\n' \
  '11/19 17:51:30.715: [amf] INFO: gNB-N2 accepted[10.53.1.6]:54227 in ng-path module' > "$TMP/amf.log"
PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/amf.log" NG_SETUP_TIMEOUT=2 NG_SETUP_INTERVAL=1 \
  "$ROOT/scripts/wait_ng_setup.sh" >/dev/null

printf '%s\n' 'no SCTP INIT here' > "$TMP/amf.log"
if PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/amf.log" NG_SETUP_TIMEOUT=1 NG_SETUP_INTERVAL=1 \
   "$ROOT/scripts/wait_ng_setup.sh" >/dev/null 2>&1; then
  echo "FAIL: wait_ng_setup accepted a log with no NG Setup" >&2
  exit 1
fi

if out="$(PATH="$TMP/bin:$PATH" FAKE_CORE=0 NG_SETUP_TIMEOUT=2 NG_SETUP_INTERVAL=1 \
          "$ROOT/scripts/wait_ng_setup.sh" 2>&1)"; then
  echo "FAIL: wait_ng_setup accepted a missing core container" >&2
  exit 1
fi
grep -q 'no running core container' <<<"$out" || { echo "FAIL: missing core message: $out" >&2; exit 1; }
echo "PASS: AMF NG Setup gate"
