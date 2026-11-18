#!/usr/bin/env bash
# v1 CPU-lock b100 batch: 3 x 600 s ESTIMATE + 1 x 600 s MEASURE, quiet-host retry.
#
# An INVALID attempt (quiet-host gate) is never counted: log the offenders, poll
# the quiet-host pre-check every 60 s (give up after 30 min), retry the same run.
# A valid FAIL is a result and is counted.
#
# Each run is gated by `make smoke-fh PROFILE=b100 PROTORU_PROFILE=null`, which
# also starts the quiet-host monitor. This wrapper starts the 20 s per-thread
# sampler for the duration of each attempt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/docs/reports/raw/m2-v1-b100"
RAW="${ROOT}/docs/reports/raw"
LOGS="${ROOT}/logs"
TAGS=(m2-fftw-estimate m2-fftw-estimate m2-fftw-estimate m2)
ROUNDS=(1 2 3 1)
QUIET_POLL_S=60
QUIET_GIVEUP_S=1800
MAX_ATTEMPTS=3
LOCK=/tmp/openru-measure.lock

mkdir -p "$OUT" "$LOGS"

if [ -e "$LOCK" ]; then
  echo "FAIL: $LOCK exists; another measurement is running"
  exit 1
fi
printf '%s %s\n' "$$" "$(date -Iseconds)" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

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
  cp "${RAW}/smoke-fh-hostcheck.json" \
     "${OUT}/${tag}-r${round}-a${attempt}-hostcheck.json" 2>/dev/null || true
  cp "${RAW}/smoke-fh-hostcheck-pre.json" \
     "${OUT}/${tag}-r${round}-a${attempt}-hostcheck-pre.json" 2>/dev/null || true
  cp "${RAW}/smoke-fh-du.log" \
     "${OUT}/${tag}-r${round}-a${attempt}-du.log" 2>/dev/null || true
  cp "${RAW}/smoke-fh-ru.log" \
     "${OUT}/${tag}-r${round}-a${attempt}-ru.log" 2>/dev/null || true
  cp "${RAW}/caps-protoru.md" \
     "${OUT}/${tag}-r${round}-a${attempt}-caps-protoru.md" 2>/dev/null || true
  cp "${RAW}/caps-du.md" \
     "${OUT}/${tag}-r${round}-a${attempt}-caps-du.md" 2>/dev/null || true
}

save_result() {
  local tag="$1" round="$2"
  cp "${RAW}/smoke-fh-kpi.json" "${OUT}/${tag}-r${round}-kpi.json"
  cp "${RAW}/smoke-fh-late-hist.csv" "${OUT}/${tag}-r${round}-late-hist.csv"
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
  local attempt rc log sampler pid threads stop
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    log="${LOGS}/m2-v1-b100-${tag}-r${round}-a${attempt}.log"
    threads="${OUT}/${tag}-r${round}-a${attempt}-threads.csv"
    stop="${LOGS}/m2-v1-b100-${tag}-r${round}-a${attempt}.sampler-stop"
    rm -f "$stop"
    echo "[v1-b100] ${tag} round ${round} attempt ${attempt}/${MAX_ATTEMPTS}"
    python3 "${ROOT}/scripts/sample_threads.py" \
      --out "$threads" --interval 20 --run "${tag}-r${round}-a${attempt}" \
      --stop-file "$stop" \
      > "${LOGS}/m2-v1-b100-${tag}-r${round}-a${attempt}-sampler.log" 2>&1 &
    pid=$!

    timeout 1500 make -C "$ROOT" smoke-fh PROFILE=b100 PROTORU_PROFILE=null \
      SMOKE_SECS=600 OPENRU_TAG="$tag" > "$log" 2>&1
    rc=$?

    echo stop > "$stop"
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill "$pid" 2>/dev/null || true
    rm -f "$stop"
    save_attempt "$tag" "$round" "$attempt" "$log"

    if [ $rc -eq 0 ]; then
      save_result "$tag" "$round"
      echo "[v1-b100] ${tag} round ${round}: PASS (attempt ${attempt})"
      return 0
    fi

    if grep -q 'INVALID' "$log"; then
      echo "[v1-b100] ${tag} round ${round}: INVALID (attempt ${attempt}); not counted"
      log_offenders "${tag}-r${round}-a${attempt}" "${RAW}/smoke-fh-hostcheck.json"
      log_offenders "${tag}-r${round}-a${attempt}-pre" "${RAW}/smoke-fh-hostcheck-pre.json"
      local waited=0
      while [ $waited -lt $QUIET_GIVEUP_S ]; do
        echo "[v1-b100] waiting for quiet host (${waited}s/${QUIET_GIVEUP_S}s)"
        if quiet_once "${OUT}/${tag}-r${round}-quiet-${waited}.json"; then
          echo "[v1-b100] host quiet again; retrying"
          break
        fi
        sleep $QUIET_POLL_S
        waited=$((waited + QUIET_POLL_S))
      done
      if [ $waited -ge $QUIET_GIVEUP_S ]; then
        echo "[v1-b100] ${tag} round ${round}: gave up after ${QUIET_GIVEUP_S}s of busy host"
        return 2
      fi
      continue
    fi

    save_result "$tag" "$round"
    echo "[v1-b100] ${tag} round ${round}: FAIL (attempt ${attempt}); counted"
    return 1
  done
  echo "[v1-b100] ${tag} round ${round}: exhausted ${MAX_ATTEMPTS} attempts without a valid run"
  return 2
}

for i in "${!TAGS[@]}"; do
  run_one "${TAGS[$i]}" "${ROUNDS[$i]}" || true
done
echo "[v1-b100] batch complete"
