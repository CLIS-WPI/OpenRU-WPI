#!/usr/bin/env bash
# Capture OFH on the compose fh network for M1 golden generation.
# Usage: make capture PROFILE=baseline CAPTURE_SECS=10
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${PROFILE:-baseline}"
SECS="${CAPTURE_SECS:-10}"
OUT="${ROOT}/testdata/pcap/${PROFILE}.pcapng"
mkdir -p "$(dirname "$OUT")"

COMPOSE="docker compose --env-file ${ROOT}/docker/versions.env --env-file ${ROOT}/docker/lab.env -f ${ROOT}/docker/compose.yml"
export DU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/du-fh.yml"
export PROTORU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/protoru-null.yml"
test -f "$DU_CONFIG_PATH"
test -f "$PROTORU_CONFIG_PATH"

echo "[capture] profile=${PROFILE} secs=${SECS} -> ${OUT}"
echo "[capture] DU_CONFIG_PATH=${DU_CONFIG_PATH}"
echo "[capture] PROTORU_CONFIG_PATH=${PROTORU_CONFIG_PATH}"
rm -f "$OUT"
${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
# Force config recreate so profile switches are not sticky.
${COMPOSE} --profile fh up -d --force-recreate du protoru
sleep 4

# Confirm mounted bandwidth from inside containers
cid=$(${COMPOSE} --profile fh ps -q protoru)
cid_du=$(${COMPOSE} --profile fh ps -q du)
docker exec "$cid" bash -lc 'grep -E "bandwidth:|srate:" /opt/protoru.yml | head -5' | tee "${ROOT}/docs/reports/capture-${PROFILE}-cfg.txt"
docker exec "$cid_du" bash -lc 'grep -E "bandwidth_MHz|channel_bandwidth" /opt/du.yml | head -5' | tee -a "${ROOT}/docs/reports/capture-${PROFILE}-cfg.txt"

# tcpdump on the docker bridge attached to protoru eth0
BR=$(docker network inspect openru_fh -f '{{(index .Options "com.docker.network.bridge.name")}}' 2>/dev/null || true)
if [[ -z "${BR}" || "${BR}" == "<no value>" ]]; then
  echo "[capture] using in-container tcpdump on protoru eth0"
  docker exec "$cid" bash -lc 'rm -f /tmp/capture.pcapng /tmp/tcpdump.log; tcpdump -i eth0 -w /tmp/capture.pcapng -U >/tmp/tcpdump.log 2>&1 & echo $! > /tmp/tcpdump.pid'
  sleep "$SECS"
  docker exec "$cid" bash -lc 'kill $(cat /tmp/tcpdump.pid) 2>/dev/null; sleep 1; ls -la /tmp/capture.pcapng; tail -5 /tmp/tcpdump.log'
  docker cp "$cid:/tmp/capture.pcapng" "$OUT"
else
  echo "[capture] host bridge=${BR}"
  sudo timeout "$SECS" tcpdump -i "$BR" -w "$OUT" || true
fi

${COMPOSE} --profile fh logs --no-color du 2>&1 | tee "${ROOT}/docs/reports/capture-${PROFILE}-du.log" >/dev/null || true
${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
test -s "$OUT"
ls -la "$OUT"
echo "[capture] done sha=$(sha256sum "$OUT" | awk '{print $1}')"
