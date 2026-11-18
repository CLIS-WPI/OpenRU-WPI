#!/usr/bin/env bash
# Shared library for every tests/<suite>/run.sh.
#
# Provides: environment loading (versions.env + lab.env, fail-closed), the
# /tmp/openru-measure.lock protocol, image tag/digest lookup, result-JSON
# writing (tests/lib/write_result.py) and the uniform PASS/FAIL/INVALID/
# SKIPPED exit codes.
#
# Exit codes (the contract for every run.sh):
#   0 PASS or SKIPPED   1 FAIL   3 INVALID (busy host / lock conflict)
#
# A run.sh must source this after computing SUITE_DIR/ROOT, then call
# test_common_init <suite> and finish with test_finish. NOTE: this file
# deliberately does not touch the shell options — the caller controls them.

TEST_STATUS=""        # PASS | FAIL | INVALID | SKIPPED
TEST_SKIP_REASON=""   # "" | host_limited | deferred
TEST_START_ISO=""
TEST_END_ISO=""
TEST_RC=0
TEST_LOCK_HELD=0

test_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Source docker/versions.env and docker/lab.env (fail closed like preflight).
test_load_env() {
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/docker/versions.env"
  if [[ -f "$ROOT/docker/lab.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/docker/lab.env"
  else
    echo "FAIL: docker/lab.env missing — copy docker/lab.env.example and set GPU UUID/cpusets" >&2
    return 1
  fi
  set +a
}

# Take /tmp/openru-measure.lock for the duration of a measurement (trap-removed).
test_lock_measure() {
  if [[ -f /tmp/openru-measure.lock ]]; then
    echo "INVALID: /tmp/openru-measure.lock exists ($(cat /tmp/openru-measure.lock)); no measurement while another run holds it" >&2
    return 3
  fi
  echo "$$" > /tmp/openru-measure.lock
  TEST_LOCK_HELD=1
}

test_unlock_measure() {
  rm -f /tmp/openru-measure.lock 2>/dev/null || true
  TEST_LOCK_HELD=0
}

# Image tag actually used and its digest/id, as JSON fragment strings.
test_image_info() { # <tag>
  local tag="$1"
  python3 - "$tag" <<'PY'
import json, subprocess, sys
tag = sys.argv[1]
info = {"tag": tag, "digest": "", "id": ""}
try:
    d = json.loads(subprocess.check_output(["docker", "image", "inspect", tag], text=True))[0]
    info["id"] = d.get("Id", "").removeprefix("sha256:")[:12]
    digests = d.get("RepoDigests") or []
    if digests:
        info["digest"] = digests[0]
except Exception:
    pass
print(json.dumps(info))
PY
}

# Validate a quiet-host JSON (scripts/quiet_host.py output).
test_quiet_host_validate() { # <path-to-hostcheck.json>
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.loads(open(sys.argv[1]).read())
except Exception as exc:
    print(f"INVALID: unreadable quiet-host JSON {sys.argv[1]}: {exc}", file=sys.stderr)
    sys.exit(3)
sys.exit(0 if d.get("valid") else 3)
PY
}

# Write the result JSON for this run; prints "<status> <path>" on stdout.
# Env: SUITE PROFILE TEST_STATUS TEST_SKIP_REASON TEST_START_ISO TEST_END_ISO TEST_RC
# Args: <metrics-json-path-or-empty> <evidence-path> [<evidence-path>...]
test_write_result() {
  local metrics_file="${1:-}" && shift || true
  [[ -n "${TEST_START_ISO}" ]] || TEST_START_ISO="$(test_now_iso)"
  [[ -n "${TEST_END_ISO}" ]] || TEST_END_ISO="$(test_now_iso)"
  python3 "$ROOT/tests/lib/write_result.py" \
    --suite "$SUITE" --profile "$PROFILE" \
    --status "${TEST_STATUS:-FAIL}" --skip-reason "$TEST_SKIP_REASON" \
    --start "$TEST_START_ISO" --end "$TEST_END_ISO" --rc "$TEST_RC" \
    ${metrics_file:+--metrics-file "$metrics_file"} \
    -- "$@"
}

# Common init: parse $PROFILE, apply tests/<suite>/profiles/<profile>/env
# defaults (caller environment wins), load docker env, stamp start time.
# Usage: test_common_init <suite>
test_common_init() {
  SUITE="${1:?suite name required}"
  PROFILE="${PROFILE:-}"
  [[ -n "$PROFILE" ]] || { echo "FAIL: PROFILE not set (make test SUITE=$SUITE PROFILE=<profile>)" >&2; return 1; }
  [[ -d "$ROOT/tests/$SUITE/profiles/$PROFILE" ]] || {
    echo "FAIL: unknown profile '$PROFILE' for suite $SUITE (see tests/$SUITE/profiles/)" >&2; return 1; }
  # Caller-set variables (direct run.sh invocation) win over profile values.
  local prof_env="$ROOT/tests/$SUITE/profiles/$PROFILE/env" locked=()
  if [[ -f "$prof_env" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "$k" || "$k" == \#* ]] && continue
      [[ -n "${!k:-}" ]] && locked+=("$k")
    done < "$prof_env"
  fi
  # Docker env (versions.env + lab.env) first: suite-profile env (e.g.
  # OPENRU_TAG=v1-candidate, image tags per milestone) then overrides the
  # versions.env defaults, but never a caller-set variable.
  test_load_env
  if [[ -f "$prof_env" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "$k" || "$k" == \#* ]] && continue
      local skip=""
      local l
      for l in ${locked[@]+"${locked[@]}"}; do
        [[ "$l" == "$k" ]] && skip=1
      done
      [[ -n "$skip" ]] && continue
      export "$k=$v"
    done < "$prof_env"
  fi
  TEST_START_ISO="$(test_now_iso)"
  TEST_RC=0
  echo "[test:$SUITE/$PROFILE] started $(test_now_iso) host=$(hostname -s)"
}

# Finish the run: write the result JSON and exit with the contract code.
# Env: TEST_STATUS, TEST_SKIP_REASON, TEST_RC. Args: <metrics.json|-> <evidence...>
test_finish() {
  local metrics="$1" && shift || true
  TEST_END_ISO="$(test_now_iso)"
  [[ "$metrics" == "-" ]] && metrics=""
  local code
  case "${TEST_STATUS:-FAIL}" in
    PASS|SKIPPED) code=0 ;;
    INVALID) code=3 ;;
    *) code=1 ;;
  esac
  test_write_result "$metrics" "$@" || true
  echo "[test:$SUITE/$PROFILE] ${TEST_STATUS:-FAIL} (rc=$TEST_RC) $(test_now_iso)"
  test_unlock_measure
  exit "$code"
}
