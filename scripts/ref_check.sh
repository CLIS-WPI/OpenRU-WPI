#!/usr/bin/env bash
# Fail unless the in-container N310 probe reports ref_locked=true.
#
#   REF=external BENCH_USRP_ADDR=192.168.10.2 scripts/ref_check.sh
#
# REF=external|internal (default external). For external the probe opens the
# N310 with clock_source=external,time_source=external and requires the
# OctoClock 10 MHz reference to be locked. REF=internal skips the check.
#
# The probe runs inside openru/protoru:${OPENRU_TAG:-bench-latest} on the host
# network (the bench host reaches the N310 at 192.168.10.2 from 192.168.10.1).
# Set RADIO_PROBE_FILE to reuse an existing uhd_usrp_probe output instead of
# opening the radio again.
set -euo pipefail

REF="${REF:-external}"
case "$REF" in
  external|internal) ;;
  *) echo "[ref] FAIL: REF must be external or internal (got $REF)" >&2; exit 2 ;;
esac

if [[ "$REF" == "internal" ]]; then
  echo "[ref] REF=internal: ref_locked not required"
  exit 0
fi

: "${BENCH_USRP_ADDR:?ref_check: BENCH_USRP_ADDR must be set for REF=external}"
IMG="openru/protoru:${OPENRU_TAG:-bench-latest}"
PROBE_ARGS="addr=${BENCH_USRP_ADDR}${BENCH_MGMT_ADDR:+,mgmt_addr=${BENCH_MGMT_ADDR}},clock_source=external,time_source=external"

if [[ -n "${RADIO_PROBE_FILE:-}" ]]; then
  [[ -s "$RADIO_PROBE_FILE" ]] || {
    echo "[ref] FAIL: RADIO_PROBE_FILE=$RADIO_PROBE_FILE is empty or missing" >&2
    exit 1
  }
  OUT="$(cat "$RADIO_PROBE_FILE")"
else
  command -v docker >/dev/null 2>&1 || { echo "[ref] FAIL: docker not found" >&2; exit 1; }
  docker image inspect "$IMG" >/dev/null 2>&1 || {
    echo "[ref] FAIL: image $IMG not found (build/load the bench release first)" >&2
    exit 1
  }
  OUT="$(timeout "${REF_PROBE_TIMEOUT:-180}" docker run --rm --network host \
    --entrypoint /bin/bash "$IMG" \
    -lc "uhd_usrp_probe --args '${PROBE_ARGS}'" 2>&1)" || true
fi

if grep -qiE 'ref_locked[[:space:]]*:[[:space:]]*true' <<<"$OUT"; then
  echo "[ref] N310 ${BENCH_USRP_ADDR} ref_locked=true (REF=external)"
  exit 0
fi

echo "[ref] FAIL: N310 ${BENCH_USRP_ADDR} ref_locked is not true (REF=external)" >&2
if grep -qiE 'ref_locked' <<<"$OUT"; then
  grep -iE 'ref_locked' <<<"$OUT" | tail -3 | sed 's/^/      | /' >&2
else
  echo "      ref_locked sensor not found in the UHD probe output" >&2
  grep -iE 'error|no devices|claimed|sensor|compatib' <<<"$OUT" | tail -5 | sed 's/^/      | /' >&2
fi
exit 1
