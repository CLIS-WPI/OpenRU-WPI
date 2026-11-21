#!/usr/bin/env bash
# scripts/bench_quiet.sh (no hardware, no root): hold/release against fake sudo, snap and systemctl that log calls.
# Covers: normal hold/release, a human's own snap hold kept, an already-stopped timer not started, a second hold
# keeping the first record, release without a record doing nothing, no sudo changing nothing, failed restore kept.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; Q="$ROOT/scripts/bench_quiet.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
cat > "$T/bin/sudo" <<'S'
#!/usr/bin/env bash
[[ "$1" == -n ]] && shift; [[ -f "$FAKE/nosudo" ]] && exit 1; [[ "$1" == true ]] && exit 0; exec "$@"
S
cat > "$T/bin/snap" <<'S'
#!/usr/bin/env bash
echo "snap $*" >> "$FAKE/calls"
if [[ "$*" == "refresh --time" ]]; then echo "timer: 00:00~24:00/4"; [[ -f "$FAKE/preheld" ]] && echo "hold: forever"; fi
[[ "$*" == "refresh --unhold" && -f "$FAKE/failunhold" ]] && exit 1; exit 0
S
cat > "$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
[[ "$1" == is-active ]] && { [[ -f "$FAKE/timer_on" ]]; exit; }
echo "systemctl $*" >> "$FAKE/calls"; exit 0
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" BENCH_QUIET_STATE="$T/state" FAKE="$T"
reset() { rm -f "$T"/{calls,state,preheld,timer_on,nosudo,failunhold}; touch "$T/calls"; }
calls() { grep -v -- '--time' "$T/calls" | paste -sd ';'; }
chk() { [[ "$2" == "$3" ]] && echo "PASS: $1" || { echo "FAIL: $1: got '$2' want '$3'"; exit 1; }; }

reset; touch "$T/timer_on"; "$Q" hold >/dev/null; "$Q" release >/dev/null
chk "hold + release" "$(calls)" "snap refresh --hold=12h;systemctl stop fwupd-refresh.timer;snap refresh --unhold;systemctl start fwupd-refresh.timer"
chk "state removed after release" "$([[ -f $T/state ]] && echo kept || echo gone)" gone

reset; touch "$T/timer_on" "$T/preheld"; "$Q" hold >/dev/null; "$Q" release >/dev/null
chk "human's own snap hold kept" "$(calls)" "systemctl stop fwupd-refresh.timer;systemctl start fwupd-refresh.timer"

reset; "$Q" hold >/dev/null; "$Q" release >/dev/null
chk "stopped timer not started" "$(calls)" "snap refresh --hold=12h;snap refresh --unhold"

reset; touch "$T/timer_on"; "$Q" hold >/dev/null; rm "$T/timer_on"; "$Q" hold >/dev/null; "$Q" release >/dev/null
chk "second hold keeps first record" "$(calls)" "snap refresh --hold=12h;systemctl stop fwupd-refresh.timer;snap refresh --unhold;systemctl start fwupd-refresh.timer"

reset; "$Q" release; chk "release without record" "$(calls)" ""

reset; touch "$T/nosudo" "$T/timer_on"; "$Q" hold 2>/dev/null
chk "no sudo: nothing changed, no record" "$(calls)$([[ -f $T/state ]] && echo +state)" ""

reset; touch "$T/timer_on" "$T/failunhold"; "$Q" hold >/dev/null; rc=0; "$Q" release >/dev/null 2>&1 || rc=$?
chk "failed restore: exit 1, record kept" "$rc$([[ -f $T/state ]] && echo +state)" "1+state"

BENCH_QUIET_HOLD=3h; reset; BENCH_QUIET_HOLD=3h "$Q" hold >/dev/null
chk "hold duration configurable" "$(calls)" "snap refresh --hold=3h"
