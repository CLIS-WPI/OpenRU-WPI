#!/usr/bin/env bash
# Capture OFH on the compose fh network for M1 golden generation.
# Usage: make capture PROFILE=baseline CAPTURE_SECS=10
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${PROFILE:-baseline}"
SECS="${CAPTURE_SECS:-10}"
OUT="${ROOT}/testdata/pcap/${PROFILE}.pcapng"
mkdir -p "$(dirname "$OUT")"

COMPOSE="docker compose --env-file ${ROOT}/docker/versions.env -f ${ROOT}/docker/compose.yml"
export DU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/du-fh.yml"
export PROTORU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/protoru-null.yml"

echo "[capture] profile=${PROFILE} secs=${SECS} -> ${OUT}"
${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
${COMPOSE} --profile fh up -d du protoru
sleep 3

# tcpdump on the docker bridge attached to protoru eth0
BR=$(docker network inspect openru_fh -f '{{(index .Options "com.docker.network.bridge.name")}}' 2>/dev/null || true)
if [[ -z "${BR}" || "${BR}" == "<no value>" ]]; then
  BR=$(docker network inspect openru_fh -f '{{.Name}}' | head -1)
  # Fallback: capture inside protoru on eth0
  echo "[capture] using in-container tcpdump on protoru eth0"
  cid=$(${COMPOSE} --profile fh ps -q protoru)
  docker exec -d "$cid" bash -lc "tcpdump -i eth0 -w /tmp/capture.pcapng -U >/tmp/tcpdump.log 2>&1"
  sleep "$SECS"
  docker exec "$cid" bash -lc "pkill tcpdump || true"
  docker cp "$cid:/tmp/capture.pcapng" "$OUT"
else
  echo "[capture] host bridge=${BR}"
  sudo timeout "$SECS" tcpdump -i "$BR" -w "$OUT" || true
fi

${COMPOSE} --profile fh logs --no-color du 2>&1 | tee "${ROOT}/docs/reports/capture-${PROFILE}-du.log" >/dev/null || true
${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
ls -la "$OUT"
echo "[capture] done"
