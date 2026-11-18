#!/usr/bin/env bash
# Capture OFH on the compose fh network for golden generation.
# Usage: make capture PROFILE=baseline CAPTURE_SECS=12
# The final guard computes the golden window from the pcap content (tools/golden/window.py) and fails unless the
# window fits, the capture has downlink User-Plane, and the fh network is MTU 9000.
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

MTU=$(docker network inspect openru_fh -f '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null || true)
if [[ "$MTU" != "9000" ]]; then
  echo "[capture] FAIL openru_fh MTU=${MTU:-unknown}, expected 9000 (pre-MTU captures lack DL User-Plane)" >&2
  ${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
  exit 1
fi

# Confirm mounted bandwidth from inside containers
cid=$(${COMPOSE} --profile fh ps -q protoru)
cid_du=$(${COMPOSE} --profile fh ps -q du)
docker exec "$cid" bash -lc 'grep -E "bandwidth:|srate:" /opt/protoru.yml | head -5' | tee "${ROOT}/docs/reports/raw/capture-${PROFILE}-cfg.txt"
docker exec "$cid_du" bash -lc 'grep -E "bandwidth_MHz|channel_bandwidth" /opt/du.yml | head -5' | tee -a "${ROOT}/docs/reports/raw/capture-${PROFILE}-cfg.txt"

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

${COMPOSE} --profile fh logs --no-color du 2>&1 | tee "${ROOT}/docs/reports/raw/capture-${PROFILE}-du.log" >/dev/null || true
${COMPOSE} --profile fh down --remove-orphans >/dev/null 2>&1 || true
test -s "$OUT"

# Window guard: anchor the window to the pcap's first DL C-plane and require the expected User-Plane content.
T2A_US=$(sed -n 's/^[[:space:]]*t2a_min_cp_dl:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROTORU_CONFIG_PATH" | head -1)
if [[ -z "${T2A_US}" ]]; then echo "ERROR: profile has no t2a_min_cp_dl; cannot derive the C-plane lead" >&2; exit 2; fi
WINDOW=$(sed -n 's/.*max_dump_slots=\([0-9][0-9]*\).*/\1/p' "$PROTORU_CONFIG_PATH" | head -1)
if [[ -z "${WINDOW}" ]]; then echo "ERROR: profile has no max_dump_slots; cannot derive the dump window" >&2; exit 2; fi
WIN_JSON="${OUT%.*}.window.json"
if ! python3 "${ROOT}/tools/golden/window.py" --pcap "$OUT" --window-slots "$WINDOW" --t2a-us "$T2A_US" \
  --du-config "$DU_CONFIG_PATH" --json "$WIN_JSON"; then
  echo "[capture] FAIL: pcap cannot provide a ${WINDOW}-slot window with DL User-Plane (see message above)." >&2
  echo "[capture] Increase CAPTURE_SECS or check MTU 9000 and the O-DU data path." >&2
  exit 1
fi
echo "[capture] window OK: $(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(f\"{d['expected_uplane_count']} DL U-plane slots from {d['start_du_sfn']}.{d['start_du_slot']}\")" "$WIN_JSON")"

ls -la "$OUT"
echo "[capture] done sha=$(sha256sum "$OUT" | awk '{print $1}')"
