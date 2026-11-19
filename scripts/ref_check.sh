#!/usr/bin/env bash
# Fail unless the N310 reference-lock sensor reads "locked" through the UHD API.
#
#   REF=external BENCH_USRP_ADDR=192.168.10.2 scripts/ref_check.sh
#
# REF=external|internal (default internal). External selects only the OctoClock
# 10 MHz frequency reference (clock_source=external, time_source=internal);
# PPS time is not used because set_time_unknown_pps() would reset radio time and
# break ProtO-RU's wall-clock slot alignment. REF=internal skips the check.
#
# The sensor is read by uhd_ref_check inside the bench image:
#   get_mboard_sensor("ref_locked").to_bool()
# The real sensor value is "locked"/"unlocked", not "true"/"false", and
# uhd_usrp_probe can print sensor names without values.
#
# UHD_REF_CHECK_HELPER overrides the container probe with a local executable
# (used by tests). It receives the device args and must exit 0 when locked.
set -euo pipefail

REF="${REF:-internal}"
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
PROBE_ARGS="addr=${BENCH_USRP_ADDR}${BENCH_MGMT_ADDR:+,mgmt_addr=${BENCH_MGMT_ADDR}},clock_source=external,time_source=internal"

rc=0
if [[ -n "${UHD_REF_CHECK_HELPER:-}" ]]; then
  OUT="$("$UHD_REF_CHECK_HELPER" "$PROBE_ARGS" 2>&1)" || rc=$?
else
  command -v docker >/dev/null 2>&1 || { echo "[ref] FAIL: docker not found" >&2; exit 1; }
  docker image inspect "$IMG" >/dev/null 2>&1 || {
    echo "[ref] FAIL: image $IMG not found (build/load the bench release first)" >&2
    exit 1
  }
  OUT="$(timeout "${REF_PROBE_TIMEOUT:-180}" docker run --rm --network host \
    --entrypoint /bin/bash "$IMG" \
    -lc "uhd_ref_check '${PROBE_ARGS}'" 2>&1)" || rc=$?
fi

if [[ "$rc" -eq 0 ]]; then
  echo "[ref] N310 ${BENCH_USRP_ADDR} ref_locked=locked (REF=external, 10 MHz only)"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
  exit 0
fi

echo "[ref] FAIL: N310 ${BENCH_USRP_ADDR} ref_locked is not locked (REF=external; rc=$rc)" >&2
printf '%s\n' "$OUT" | tail -8 | sed 's/^/      | /' >&2
exit 1
