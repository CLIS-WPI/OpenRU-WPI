#!/usr/bin/env bash
# Start ProtO-RU alone, fh_replay a pcap onto the fh network, tar IQ dump out.
# Usage: replay_iq_dump.sh <profile> <pcap> <out_dir> [rate]
#
# The dump window is anchored to the pcap: tools/golden/window.py picks start_du (first frame boundary at least two
# frames after the first DL C-plane) and the replay writes a marker when it starts sending, so the null radio starts
# dumping exactly at that wire slot. The C-plane lead is derived from the profile's t2a_min_cp_dl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:?profile}"
PCAP="${2:?pcap}"
OUT="${3:?out_dir}"
RATE="${4:-1.0}"
TAG="${OPENRU_TAG:-m1}"
RU_MAC="02:00:00:00:00:20"
DU_MAC="02:00:00:00:00:10"
MARKER_HOST="${ROOT}/docs/reports/raw/replay-start.marker"
MARKER_RU="/reports/raw/replay-start.marker"
MARKER_REPLAY="/work/docs/reports/raw/replay-start.marker"

COMPOSE=(docker compose --env-file "${ROOT}/docker/versions.env" --env-file "${ROOT}/docker/lab.env"
         -f "${ROOT}/docker/compose.yml")

if [[ -f /tmp/openru-measure.lock ]]; then
  echo "[replay] ERROR /tmp/openru-measure.lock exists; no measurement while another run holds it" >&2
  exit 1
fi
echo "$$" > /tmp/openru-measure.lock
trap 'rm -f /tmp/openru-measure.lock' EXIT

export DU_CONFIG_PATH="${ROOT}/profiles/${PROFILE}/du-fh.yml"
BASE_RU_YML="${PROTORU_CONFIG_PATH:-${ROOT}/profiles/${PROFILE}/protoru-null.yml}"
export OPENRU_TAG="$TAG"

PCAP_ABS="$(cd "$(dirname "$PCAP")" && pwd)/$(basename "$PCAP")"
test -f "$PCAP_ABS"
PCAP_IN_CT="/work/${PCAP_ABS#${ROOT}/}"

# C-plane lead (t2a_min_cp_dl) and dump window (max_dump_slots) from the RU profile.
T2A_US=$(sed -n 's/^[[:space:]]*t2a_min_cp_dl:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$BASE_RU_YML" | head -1)
T2A_US="${T2A_US:-2235}"
WINDOW=$(sed -n 's/.*max_dump_slots=\([0-9][0-9]*\).*/\1/p' "$BASE_RU_YML" | head -1)
WINDOW="${WINDOW:-4000}"
WIN_JSON="${OPENRU_WINDOW_JSON:-${PCAP_ABS%.*}.window.json}"

if [[ -n "${OPENRU_WINDOW_JSON:-}" ]]; then
  # The golden's tracked window: never recompute or overwrite it, so a changed pcap fails the check instead.
  test -s "$WIN_JSON" || { echo "[replay] ERROR OPENRU_WINDOW_JSON=$WIN_JSON not found" >&2; exit 1; }
else
  reuse=0
  if [[ -f "$WIN_JSON" ]]; then
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("fits") and int(d.get("window_slots",-1))==int(sys.argv[2]) and float(d.get("lead_us",-1))==float(sys.argv[3]) else 1)' \
        "$WIN_JSON" "$WINDOW" "$T2A_US"; then
      reuse=1
    fi
  fi
  if [[ "$reuse" == 0 ]]; then
    python3 "${ROOT}/tools/golden/window.py" --pcap "$PCAP_ABS" --window-slots "$WINDOW" \
      --t2a-us "$T2A_US" --json "$WIN_JSON"
  fi
fi
read -r START_DU WINDOW LEAD_US < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["start_du"], d["window_slots"], d["lead_us"])' "$WIN_JSON")

TMP_YML="/tmp/protoru-replay-${PROFILE}-$$.yml"
python3 "${ROOT}/tools/golden/prep_config.py" --profile-yaml "$BASE_RU_YML" --window-json "$WIN_JSON" \
  --out "$TMP_YML" --marker "$MARKER_RU"
export PROTORU_CONFIG_PATH="$TMP_YML"

rm -rf "$OUT"
mkdir -p "$OUT"
rm -f "$MARKER_HOST"

"${COMPOSE[@]}" --profile fh --profile core --profile full down --remove-orphans >/dev/null 2>&1 || true
# RU only — no live DU; replay injects OFH.
OPENRU_TAG="$TAG" DU_CONFIG_PATH="$DU_CONFIG_PATH" PROTORU_CONFIG_PATH="$PROTORU_CONFIG_PATH" \
  "${COMPOSE[@]}" --profile fh up -d --no-deps protoru

# MTU must be 9000: the pre-MTU capture dropped the DL User-Plane (EMSGSIZE), which made every golden vacuous.
MTU=$(docker network inspect openru_fh -f '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null || true)
if [[ "$MTU" != "9000" ]]; then
  echo "[replay] FAIL openru_fh MTU=${MTU:-unknown}, expected 9000 (set docker/compose.yml networks.fh driver_opts)" >&2
  exit 1
fi

# Replay peer on openru_fh with DU MAC. Prepare it while the RU initialises so the replay can start as soon as the
# receiver is up.
docker rm -f openru-fh-replay >/dev/null 2>&1 || true
docker run -d --name openru-fh-replay \
  --network openru_fh --ip 10.54.1.10 --mac-address "$DU_MAC" \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  --cpuset-cpus "${OPENRU_REPLAY_CPUSET:-39}" \
  -v "${ROOT}:/work" \
  --entrypoint bash \
  "openru/protoru:${TAG}" \
  -lc 'sleep infinity' >/dev/null
docker exec openru-fh-replay bash -lc 'python3 -c "import dpkt" 2>/dev/null || pip3 install --break-system-packages -q dpkt'

# Wait for null radio ready
for i in $(seq 1 30); do
  if docker exec openru-protoru-1 bash -lc 'grep -q "null radio ready" /tmp/proto-ru.log 2>/dev/null'; then
    break
  fi
  sleep 1
done
# "null radio ready" precedes the OFH receiver socket bind; a short settle keeps the first pcap frames.
sleep "${OPENRU_REPLAY_READY_SLEEP:-2}"

# Resolve eth name; strip vlan/peer suffix (eth0@ifN → eth0)
IFACE=$(docker exec openru-fh-replay bash -lc "ip -o link | awk -F': ' '/^[0-9]+: eth/{print \$2; exit}' | cut -d@ -f1")
echo "[replay] iface=${IFACE} profile=${PROFILE} rate=${RATE} window=${WINDOW} start_du=${START_DU} lead_us=${LEAD_US}"

docker exec openru-fh-replay bash -lc \
  "python3 /work/tools/fh_replay/fh_replay.py \
    --pcap ${PCAP_IN_CT} \
    --iface ${IFACE} \
    --only-dst-mac ${RU_MAC} \
    --src-mac ${DU_MAC} \
    --dst-mac ${RU_MAC} \
    --rate ${RATE} \
    --lead-us ${OPENRU_REPLAY_LEAD_US:-0} \
    --uplane-delay-us ${OPENRU_REPLAY_UPLANE_DELAY_US:-0} \
    --align-cplane-lead-us ${OPENRU_REPLAY_ALIGN_LEAD_US:-${LEAD_US}} \
    --start-marker ${MARKER_REPLAY}"

# Wait for the dump cap
for i in $(seq 1 80); do
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

docker exec openru-protoru-1 cat /tmp/proto-ru.log > "${OUT}/ru.log" 2>&1 || \
  docker logs openru-protoru-1 > "${OUT}/ru.log" 2>&1 || true
docker rm -f openru-fh-replay >/dev/null 2>&1 || true
"${COMPOSE[@]}" --profile fh down --remove-orphans >/dev/null 2>&1 || true
rm -f "$TMP_YML"
echo "[replay] wrote ${OUT}"
