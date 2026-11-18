#!/usr/bin/env bash
# b100 (100 MHz) CPU-config batch with quiet-host retry.
#
# Each run is attempted at most 3 times (initial + 2 retries). An INVALID
# attempt is never counted: log the offender, poll the quiet-host pre-check
# every 60 s (give up after 30 min), then retry the same run. A valid FAIL is
# a result and is counted; a valid PASS is a result.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/docs/reports/m2-b100"
LOGS="${ROOT}/logs"
TAGS=("m2-gen-v4" "m2")
ROUNDS=(1 2)
QUIET_POLL_S=60
QUIET_GIVEUP_S=1800
MAX_ATTEMPTS=3

mkdir -p "$OUT" "$LOGS"

reserved="$(grep -E '^PROTORU_CPUSET=' "${ROOT}/docker/lab.env" | cut -d= -f2-),$(grep -E '^DU_CPUSET=' "${ROOT}/docker/lab.env" | cut -d= -f2-)"

quiet_once() {
  local out="$1"
  python3 "${ROOT}/scripts/quiet_host.py" --once \
    --reserved "$reserved" \
    --containers openru-protoru-1,openru-du-1 \
    --out "$out"
}

save_attempt() {
  local tag="$1" round="$2" attempt="$3" log="$4"
  cp "$log" "${OUT}/${tag}-r${round}-a${attempt}.log" 2>/dev/null || true
  cp "${ROOT}/docs/reports/smoke-fh-hostcheck.json" \
     "${OUT}/${tag}-r${round}-a${attempt}-hostcheck.json" 2>/dev/null || true
  cp "${ROOT}/docs/reports/smoke-fh-hostcheck-pre.json" \
     "${OUT}/${tag}-r${round}-a${attempt}-hostcheck-pre.json" 2>/dev/null || true
}

log_offenders() {
  local label="$1" hostcheck="$2"
  python3 - "$label" "$hostcheck" <<'PY'
import json, sys
label, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print(f"{label}: no hostcheck JSON")
    raise SystemExit
print(f"{label}: valid={d.get('valid')} loadavg={d.get('loadavg')} offenders={len(d.get('offenders', []))}")
for o in d.get("offenders", []):
    print(f"  {o['pid']} {o['comm']} {o['pcpu']}% reserved={o['reserved_affinity']} args={o['args'][:140]}")
PY
}

run_one() {
  local tag="$1" round="$2"
  local attempt rc log
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    log="${LOGS}/m2-b100-${tag}-r${round}-a${attempt}.log"
    echo "[b100] ${tag} round ${round} attempt ${attempt}/${MAX_ATTEMPTS}"
    make -C "$ROOT" smoke-fh PROFILE=b100 PROTORU_PROFILE=null \
      SMOKE_SECS=600 OPENRU_TAG="$tag" > "$log" 2>&1
    rc=$?
    save_attempt "$tag" "$round" "$attempt" "$log"

    if [ $rc -eq 0 ]; then
      cp "${ROOT}/docs/reports/smoke-fh-kpi.json" "${OUT}/${tag}-r${round}-kpi.json"
      cp "${ROOT}/docs/reports/smoke-fh-late-hist.csv" "${OUT}/${tag}-r${round}-late-hist.csv"
      git -C "$ROOT" checkout -- docs/reports/smoke-fh-kpi.json docs/reports/smoke-fh-late-hist.csv
      echo "[b100] ${tag} round ${round}: PASS (attempt ${attempt})"
      return 0
    fi

    if grep -q 'INVALID' "$log"; then
      echo "[b100] ${tag} round ${round}: INVALID (attempt ${attempt}); not counted"
      log_offenders "${tag}-r${round}-a${attempt}" "${ROOT}/docs/reports/smoke-fh-hostcheck.json"
      log_offenders "${tag}-r${round}-a${attempt}-pre" "${ROOT}/docs/reports/smoke-fh-hostcheck-pre.json"
      local waited=0
      while [ $waited -lt $QUIET_GIVEUP_S ]; do
        echo "[b100] waiting for quiet host (${waited}s/${QUIET_GIVEUP_S}s)"
        if quiet_once "${OUT}/${tag}-r${round}-quiet-${waited}.json"; then
          echo "[b100] host quiet again; retrying"
          break
        fi
        sleep $QUIET_POLL_S
        waited=$((waited + QUIET_POLL_S))
      done
      if [ $waited -ge $QUIET_GIVEUP_S ]; then
        echo "[b100] ${tag} round ${round}: gave up after ${QUIET_GIVEUP_S}s of busy host"
        return 2
      fi
      continue
    fi

    cp "${ROOT}/docs/reports/smoke-fh-kpi.json" "${OUT}/${tag}-r${round}-kpi.json"
    cp "${ROOT}/docs/reports/smoke-fh-late-hist.csv" "${OUT}/${tag}-r${round}-late-hist.csv"
    git -C "$ROOT" checkout -- docs/reports/smoke-fh-kpi.json docs/reports/smoke-fh-late-hist.csv
    echo "[b100] ${tag} round ${round}: FAIL (attempt ${attempt}); counted"
    return 1
  done
  echo "[b100] ${tag} round ${round}: exhausted ${MAX_ATTEMPTS} attempts without a valid run"
  return 2
}

touch /tmp/openru-measure.lock
trap 'rm -f /tmp/openru-measure.lock' EXIT

# Preserve the earlier invalid attempt (fwupd) as attempt 0.
if [ -f "${ROOT}/docs/reports/smoke-fh-hostcheck.json" ]; then
  cp "${ROOT}/docs/reports/smoke-fh-hostcheck.json" "${OUT}/m2-gen-v4-r1-a0-hostcheck.json" 2>/dev/null || true
fi
if [ -f "${LOGS}/m2-b100-m2-gen-v4-r1.log" ]; then
  cp "${LOGS}/m2-b100-m2-gen-v4-r1.log" "${OUT}/m2-gen-v4-r1-a0.log" 2>/dev/null || true
fi

for round in "${ROUNDS[@]}"; do
  for tag in "${TAGS[@]}"; do
    run_one "$tag" "$round" || true
  done
done
echo "[b100] batch complete"
