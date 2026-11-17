#!/usr/bin/env bash
# Regenerate the CPU goldens from fresh MTU-9000 captures.
#
# For each profile: capture with the live O-DU (make capture, window + DL User-Plane guarded), replay twice cold,
# require 0 differing samples between the two dumps and pass the permanent golden checks, then install the IQ/window/
# tx index/MANIFEST. The pcap and .cf32 stay gitignored; MANIFEST.json, SHA256SUMS, iq_meta.json and window.json are
# tracked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${OPENRU_TAG:?set OPENRU_TAG to the candidate image tag}"
RAW="${ROOT}/docs/reports/raw/gen-golden"
mkdir -p "$RAW"

if [[ -f /tmp/openru-measure.lock ]]; then
  echo "[gen-golden] ERROR /tmp/openru-measure.lock exists" >&2
  exit 1
fi
echo "$$" > /tmp/openru-measure.lock
trap 'rm -f /tmp/openru-measure.lock' EXIT

for prof in baseline b40 b100; do
  secs=12
  [[ "$prof" != "baseline" ]] && secs=6
  echo "[gen-golden] capture $prof (${secs}s)"
  CAPTURE_SECS="$secs" PROFILE="$prof" make -C "$ROOT" OPENRU_TAG="$TAG" capture

  pcap="${ROOT}/testdata/pcap/${prof}.pcapng"
  test -s "$pcap"
  win="${ROOT}/testdata/pcap/${prof}.window.json"
  test -s "$win"

  for i in 1 2; do
    echo "[gen-golden] replay $prof run $i"
    OPENRU_WINDOW_JSON="$win" OPENRU_TAG="$TAG" \
      "${ROOT}/scripts/replay_iq_dump.sh" "$prof" "$pcap" "${RAW}/${prof}-${i}" 1.0
    python3 "${ROOT}/tools/golden/check.py" --dump "${RAW}/${prof}-${i}" --window-json "$win" \
      --du-config "${ROOT}/profiles/${prof}/du-fh.yml" --out "${RAW}/${prof}-${i}.check.json"
  done

  echo "[gen-golden] compare $prof two cold replays"
  python3 "${ROOT}/tools/iq_compare/iq_compare.py" --dut "${RAW}/${prof}-2" --golden "${RAW}/${prof}-1" \
    --by-slot --threshold 0

  dst="${ROOT}/testdata/golden/${prof}"
  mkdir -p "$dst"
  cp "${RAW}/${prof}-1/port"*.cf32 "$dst/"
  cp "${RAW}/${prof}-1/tx_index.jsonl" "$dst/"
  cp "${RAW}/${prof}-1/iq_meta.json" "$dst/"
  cp "$win" "$dst/window.json"
  python3 "${ROOT}/tools/golden/manifest.py" \
    --dump "$dst" --profile "$prof" --profile-yaml "${ROOT}/profiles/${prof}/protoru-null.yml" \
    --window-json "$dst/window.json" --pcap "testdata/pcap/${prof}.pcapng" \
    --tag "$TAG" --mtu 9000 --check-json "${RAW}/${prof}-1.check.json" \
    --out-dir "$dst" --root "$ROOT"
done
echo "[gen-golden] done: baseline b40 b100 regenerated with $TAG"
