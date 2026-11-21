#!/usr/bin/env bash
# Quiet the bench host for a session: hold snap auto-refreshes and stop fwupd-refresh.timer, then restore both.
#
#   scripts/bench_quiet.sh hold      # called by up.sh (BENCH=1) and split.sh up
#   scripts/bench_quiet.sh release   # called by make down and split.sh down
#
# Why: a snap refresh or firmware-metadata refresh during a run adds housekeeping load next to the real-time CPUs
# (snapd showed up in the ru_timing late-wake traces, 2026-11-20). Restores only what hold changed, as recorded in
# the state file: a hold the human set themselves stays, and a timer that was already stopped is not started.
# The snap hold is time-limited (BENCH_QUIET_HOLD, default 12h) so a missed release cannot block refreshes for good.
# Needs passwordless sudo; without it, or without snap/systemd, it warns and changes nothing (never blocks a run).
set -uo pipefail
STATE="${BENCH_QUIET_STATE:-/var/tmp/openru-bench-quiet.state}"
HOLD="${BENCH_QUIET_HOLD:-12h}"
TIMER=fwupd-refresh.timer
warn() { echo "bench-quiet: WARN: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  hold)
    # A second hold (e.g. split.sh up after up.sh) keeps the first record, which holds the pre-session state.
    [[ -f "$STATE" ]] && { echo "bench-quiet: already held ($STATE)"; exit 0; }
    sudo -n true 2>/dev/null || { warn "no passwordless sudo; snap refreshes and $TIMER left as they are"; exit 0; }
    snap=none; timer=none
    if have snap; then
      if sudo -n snap refresh --time 2>/dev/null | grep -q '^hold:'; then snap=preheld
      elif sudo -n snap refresh --hold="$HOLD" >/dev/null 2>&1; then snap=held
      else warn "snap refresh --hold failed"; fi
    fi
    if have systemctl && systemctl is-active --quiet "$TIMER"; then
      if sudo -n systemctl stop "$TIMER"; then timer=stopped; else warn "could not stop $TIMER"; fi
    fi
    printf 'snap=%s\ntimer=%s\n' "$snap" "$timer" > "$STATE" || { warn "cannot write $STATE"; exit 0; }
    echo "bench-quiet: snap refreshes $snap, $TIMER $timer (restore: scripts/bench_quiet.sh release)" ;;
  release)
    [[ -f "$STATE" ]] || exit 0
    snap="$(sed -n 's/^snap=//p' "$STATE")"; timer="$(sed -n 's/^timer=//p' "$STATE")"; rc=0
    if [[ "$snap" == held ]]; then sudo -n snap refresh --unhold >/dev/null 2>&1 || { warn "snap refresh --unhold failed"; rc=1; }; fi
    if [[ "$timer" == stopped ]]; then sudo -n systemctl start "$TIMER" || { warn "could not start $TIMER"; rc=1; }; fi
    if (( rc == 0 )); then rm -f "$STATE"; echo "bench-quiet: restored (snap $snap, $TIMER $timer)"
    else warn "restore incomplete; $STATE kept, re-run: scripts/bench_quiet.sh release"; fi
    exit "$rc" ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
