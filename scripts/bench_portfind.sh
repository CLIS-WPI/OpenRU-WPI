#!/usr/bin/env bash
# Bench port finder: which N310 TX/RX port reaches which HackRF. TRANSMITS (cabled, bounded).
#
#   RF_TONE_OK=1 HACKRF_SERIALS="<serial> <serial>" BENCH_RADIO=n310-20 scripts/bench_portfind.sh [channels]
#
# Per UHD channel (default "0 1 2 3"): a baseline capture on every HackRF, then a CW tone from
# uhd_one_tone (3421.48 MHz, TX/RX port, gain 30, 5 s; the tool itself refuses channel >3,
# gain >30 dB or >10 s), captured on every HackRF while the tone is on. HackRFs only receive:
# hackrf_transfer -r with the RF amp off (-a 0), LNA 32 / VGA 30. Analysis: tools/bench/portfind.py;
# captures are deleted only after the analysis succeeded.
# Refuses unless RF_TONE_OK=1 (a human go for this transmission), no openru container exists and
# nothing else uses the radio. Cabled only, no antennas.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANNELS="${1:-0 1 2 3}"
GAIN=30 SECS=5 LO=3420480000
fail() { echo "portfind: FAIL: $*" >&2; exit 1; }

[[ "${RF_TONE_OK:-0}" == "1" ]] || fail "this transmits; set RF_TONE_OK=1 only with the human's go (cabled, no antennas)"
[[ -n "${HACKRF_SERIALS:-}" ]] || fail "set HACKRF_SERIALS (hackrf_info lists them)"
for c in $CHANNELS; do [[ "$c" =~ ^[0-3]$ ]] || fail "channel $c not in 0..3"; done
command -v hackrf_transfer >/dev/null || fail "hackrf_transfer not installed"
[[ -z "$(docker ps -aq --filter name=openru)" ]] || fail "openru containers exist: make down first"
pgrep -x ru_emulator >/dev/null && fail "ru_emulator running"
pgrep -f "uhd_one_tone|tx_waveforms" >/dev/null && fail "another tone tool is running"

set -a; . "$ROOT/docker/bench.env"; set +a
. "$ROOT/scripts/radio_env.sh"; radio_env_load "$ROOT" || exit 1
IMG="openru/protoru:${OPENRU_TAG:-bench-latest}"
docker run --rm --network none --entrypoint /bin/sh "$IMG" -c 'command -v uhd_one_tone' >/dev/null \
  || fail "$IMG has no uhd_one_tone; rebuild the bench image"
OUT="${OUT:-$ROOT/build/portfind/$(date +%Y%m%d-%H%M%S)-$BENCH_RADIO}"; mkdir -p "$OUT"
ARGS="type=n3xx,addr=$BENCH_USRP_ADDR,mgmt_addr=$BENCH_MGMT_ADDR"
cap() { hackrf_transfer -d "$1" -r "$2" -f $LO -s 20000000 -b 20000000 -n 20000000 -a 0 -l 32 -g 30 >/dev/null 2>&1; }

echo "portfind: $BENCH_RADIO ($BENCH_USRP_ADDR), channels $CHANNELS, gain $GAIN, ${SECS}s, out $OUT"
for ch in $CHANNELS; do
  for s in $HACKRF_SERIALS; do cap "$s" "$OUT/pf_base_c${ch}_${s: -4}.cs8" || fail "baseline c$ch ${s: -4}"; done
  # --network host: UHD needs the radio NIC; the stack is down (checked above).
  timeout $((SECS + 30)) docker run --rm --network host --entrypoint /usr/local/bin/uhd_one_tone "$IMG" \
    "$ARGS" "$ch" "$GAIN" "$SECS" > "$OUT/tone-c$ch.log" 2>&1 & tp=$!
  for _ in $(seq 1 400); do grep -q "tone: streaming" "$OUT/tone-c$ch.log" && break; kill -0 $tp 2>/dev/null || break; sleep 0.05; done
  if grep -q "tone: streaming" "$OUT/tone-c$ch.log"; then
    for s in $HACKRF_SERIALS; do cap "$s" "$OUT/pf_tone_c${ch}_${s: -4}.cs8" || echo "portfind: capture c$ch ${s: -4} failed"; done
  else echo "portfind: channel $ch did not start streaming (see tone-c$ch.log)"; fi
  rc=0; wait $tp || rc=$?
  echo "portfind: ch$ch tone rc=$rc $(grep -m1 '^tone: ch=' "$OUT/tone-c$ch.log" || true)"
  sleep 3
done
sfx=(); for s in $HACKRF_SERIALS; do sfx+=("${s: -4}"); done
if python3 -I "$ROOT/tools/bench/portfind.py" "$OUT" "${sfx[@]}" | tee "$OUT/analysis.txt"; then
  rm -f "$OUT"/pf_*.cs8; echo "portfind: analysis ok; captures removed; evidence in $OUT"
else echo "portfind: analysis failed; captures kept in $OUT"; exit 1; fi
