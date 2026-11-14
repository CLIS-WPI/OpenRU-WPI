#!/usr/bin/env bash
# Start ProtO-RU alone, fh_replay a pcap onto the fh network, tar IQ dump out.
# Usage: replay_iq_dump.sh <profile> <pcap> <out_dir> [rate]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:?profile}"
PCAP="${2:?pcap}"
OUT="${3:?out_dir}"
RATE="${4:-1.0}"
TAG="${OPENRU_TAG:-m1}"
RU_MAC="02:00:00:00:00:20"
DU_MAC="02:00:00:00:00:10"

COMPOSE=(docker compose --env-file "${ROOT}/docker/versions.env" --env-file "${ROOT}/docker/lab.env"
         -f "${ROOT}/docker/compose.yml")

export DU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/du-fh.yml"
export PROTORU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/protoru-null.yml"
export OPENRU_TAG="$TAG"

rm -rf "$OUT"
mkdir -p "$OUT"

"${COMPOSE[@]}" --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
# RU only — no live DU; replay injects OFH.
OPENRU_TAG="$TAG" DU_CONFIG_PATH="$DU_CONFIG_PATH" PROTORU_CONFIG_PATH="$PROTORU_CONFIG_PATH" \
  "${COMPOSE[@]}" --profile fh up -d --no-deps protoru
sleep 4

# Wait for null radio ready
for i in $(seq 1 30); do
  if docker exec openru-protoru-1 bash -lc 'grep -q "null radio ready" /tmp/proto-ru.log 2>/dev/null'; then
    break
  fi
  sleep 1
done

# Replay peer on openru_fh with DU MAC. Install scapy inside the image Python.
docker rm -f openru-fh-replay >/dev/null 2>&1 || true
docker run -d --name openru-fh-replay \
  --network openru_fh --ip 10.54.1.10 --mac-address "$DU_MAC" \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  -v "${ROOT}:/work" \
  --entrypoint bash \
  "openru/protoru:${TAG}" \
  -lc 'sleep infinity'

docker exec openru-fh-replay bash -lc 'python3 -c "import scapy" 2>/dev/null || pip3 install --break-system-packages -q scapy'

# Resolve eth name; strip vlan/peer suffix (eth0@ifN → eth0)
IFACE=$(docker exec openru-fh-replay bash -lc "ip -o link | awk -F': ' '/^[0-9]+: eth/{print \$2; exit}' | cut -d@ -f1")
echo "[replay] iface=${IFACE} profile=${PROFILE} rate=${RATE}"

PCAP_ABS="$(cd "$(dirname "$PCAP")" && pwd)/$(basename "$PCAP")"
PCAP_IN_CT="/work/${PCAP_ABS#${ROOT}/}"
test -f "$PCAP_ABS"
docker exec openru-fh-replay bash -lc \
  "python3 /work/tools/fh_replay/fh_replay.py \
    --pcap ${PCAP_IN_CT} \
    --iface ${IFACE} \
    --only-dst-mac ${RU_MAC} \
    --src-mac ${DU_MAC} \
    --dst-mac ${RU_MAC} \
    --rate ${RATE}"

# Wait for dump cap or a few seconds after replay
for i in $(seq 1 60); do
  if docker exec openru-protoru-1 bash -lc 'grep -q "max_dump_slots reached\|dump stop" /tmp/proto-ru.log 2>/dev/null'; then
    echo "[replay] dump stopped"
    break
  fi
  sleep 1
done
sleep 1

docker exec openru-protoru-1 tar -C /dev/shm/openru_iq -cf - . | tar -C "$OUT" -xf -
test -s "$OUT/port0.cf32" && test -s "$OUT/iq_meta.json"
ls -lah "$OUT"

docker rm -f openru-fh-replay >/dev/null 2>&1 || true
"${COMPOSE[@]}" --profile fh down --remove-orphans >/dev/null 2>&1 || true
echo "[replay] wrote ${OUT}"
