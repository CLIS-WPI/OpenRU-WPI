#!/usr/bin/env bash
# bench_rt.sh gate: settle, then 60 s windows until two in a row pass (rc 0 OK / 2 WARN),
# at most RT_CHECK_MAX_WINDOWS. A stub rt_watch.sh returns one scripted rc per window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/rt_watch.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = start ] && exit 0
rc="$(head -1 "$RCS")"; sed -i 1d "$RCS"; echo "window rc $rc"; exit "$rc"
STUB
chmod +x "$TMP/rt_watch.sh"
run() { # <expected exit> <expected word> <rc per window...>
  local want="$1" word="$2" got=0 out; shift 2
  printf '%s\n' "$@" > "$TMP/rcs"
  out="$(RT_WATCH="$TMP/rt_watch.sh" RCS="$TMP/rcs" RT_SETTLE_SECS=0 RT_CHECK_SECS=1 \
         "$ROOT/scripts/bench_rt.sh" check 2>&1)" || got=$?
  [[ "$got" == "$want" ]] && grep -q "$word" <<<"$out" || {
    echo "FAIL: windows [$*]: exit $got (want $want), no '$word':"; echo "$out"; exit 1; } >&2
  echo "$(wc -l < "$TMP/rcs")"  # windows left unused
}
[[ "$(run 0 'OK:' 0 0 1)" == 1 ]]          # two clean windows, stops early
run 1 'FAIL:' 1 1 1 1 1 >/dev/null          # never passes
run 0 'OK:' 1 1 1 0 0 >/dev/null            # start-up burst, then clean
run 1 'FAIL:' 0 1 0 1 0 >/dev/null          # no two in a row within 5
run 0 'WARN:' 1 2 0 >/dev/null              # passes with a WARN window
run 0 'OK:' 2 1 0 0 >/dev/null              # WARN before a FAIL does not count
grep -q 'skipped' <<<"$(RT_WATCH=/bin/false RT_CHECK_SECS=0 "$ROOT/scripts/bench_rt.sh" check)"
echo "bench-rt-gate: PASS"
