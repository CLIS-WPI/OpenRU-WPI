#!/usr/bin/env bash
# Verify OFH container capabilities: AF_PACKET on iface + chrt -f 50.
# Usage: verify_caps.sh <container_id_or_name> [iface]
set -euo pipefail
CID="${1:?container id/name required}"
IFACE="${2:-eth0}"
OUT="${3:-}"

run() {
  docker exec "$CID" bash -lc "$1"
}

echo "=== verify_caps in $CID (iface=$IFACE) ==="
CAPS="$(run 'grep -E "^Cap(Eff|Prm|Bnd):" /proc/self/status')"
echo "$CAPS"

CHRT_OUT="$(run 'chrt -f 50 true && echo OK_CHRT')"
echo "chrt -f 50 true: $CHRT_OUT"
test "$CHRT_OUT" = "OK_CHRT"

AFP="$(run "python3 - <<'PY'
import socket, os
iface = '${IFACE}'
assert iface in os.listdir('/sys/class/net'), iface
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind((iface, 0))
print(f'OK_AF_PACKET fd={s.fileno()} iface={iface}')
s.close()
PY")"
echo "$AFP"
echo "$AFP" | grep -q OK_AF_PACKET

if [[ -n "$OUT" ]]; then
  {
    echo "## Caps / AF_PACKET / chrt"
    echo
    echo '```'
    echo "$CAPS"
    echo "chrt -f 50 true: $CHRT_OUT"
    echo "$AFP"
    echo '```'
  } >>"$OUT"
fi

echo "verify_caps: PASS"
