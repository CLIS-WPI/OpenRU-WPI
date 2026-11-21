#!/usr/bin/env bash
# Session-scoped kernel.timer_migration=0 for bench runs, guarded by a D-state watchdog.
#
#   bench_tm.sh watch     # bring-up (up.sh BENCH=1, split.sh up): start the watchdog; idempotent
#   bench_tm.sh set0      # after the real-time gate passed (end of bench_rt.sh): record the value, set 0
#   bench_tm.sh restore   # before teardown: put the recorded value back
#   bench_tm.sh stop      # after teardown: restore if still recorded, stop the watchdog
#
# Why: with timer_migration=1 the kernel moves ru_timing's sleep timer off its nohz_full CPU to a busy housekeeping
# core, where it expires 10-90 us late (~5 RU stalls/min); with 0 the A/B on ran had none (2026-11-20, no ftrace,
# 3 x 10 min each). But 0 plus an ftrace buffer resize (kernel work queued on the isolated CPUs, where FIFO threads
# spin) hung the host for 2 h; setting 1 cleared it in 20 s. Hence: 0 only after the gate, and a watchdog throughout.
#
# watch/set0 act only with BENCH_TM0=1 (docker/bench.env; split-core.env keeps 0 until the core A/B); set0 refuses
# without a live watchdog. restore/stop act on the recorded state, so `make down` always cleans up.
# Watchdog (housekeeping CPUs BENCH_TM_CPUS, every BENCH_TM_INTERVAL s): a thread in D state for >= BENCH_TM_DMAX
# (30) s -> record the blocked tasks (sysrq w to dmesg, /proc stacks with CPUs, timer_list, sched debug) in
# $BENCH_TM_DIR/hang-<time>/, set timer_migration=1, stop the openru containers, exit.
set -uo pipefail
DIR="${BENCH_TM_DIR:-/var/tmp/openru-bench-tm}"
TM="${BENCH_TM_PROC:-/proc/sys/kernel/timer_migration}"
DMAX="${BENCH_TM_DMAX:-30}"; IV="${BENCH_TM_INTERVAL:-5}"
ORIG="$DIR/orig"; PID="$DIR/watchdog.pid"; LOG="$DIR/watchdog.log"
say() { echo "bench-tm: $*"; }
log() { echo "$(TZ=America/New_York date '+%F %T') $*" >> "$LOG"; }
alive() { [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; }
setv() { sudo -n sysctl -q -w kernel.timer_migration="$1"; }
enabled() { [[ "${BENCH_TM0:-0}" == 1 ]]; }

record() { # the blocked tasks, before anything is changed
  local d; d="$DIR/hang-$(TZ=America/New_York date +%Y%m%d-%H%M%S)"; mkdir -p "$d"
  ps -eLo tid,pid,stat,psr,cls,rtprio,pcpu,wchan:32,etime,comm > "$d/ps-all.txt"
  awk 'NR == 1 || $3 ~ /^D/' "$d/ps-all.txt" > "$d/d-tasks.txt"
  echo w | sudo -n tee /proc/sysrq-trigger >/dev/null; sleep 1
  sudo -n dmesg -T > "$d/dmesg.txt" 2>&1
  awk 'NR > 1 {print $1, $2, $4, $10}' "$d/d-tasks.txt" | while read -r tid pid cpu comm; do
    echo "== tid $tid pid $pid cpu $cpu $comm"; sudo -n timeout 5 cat "/proc/$pid/task/$tid/stack"
  done > "$d/stacks.txt" 2>&1
  sudo -n timeout 10 cat /proc/timer_list > "$d/timer_list.txt" 2>&1
  sudo -n timeout 10 cat /sys/kernel/debug/sched/debug > "$d/sched_debug.txt" 2>&1
  cat /proc/interrupts > "$d/interrupts.txt" 2>/dev/null
  echo "$d"
}

loop() {
  local -A seen=(); local now tid st d
  log "watchdog started (pid $$, D >= ${DMAX}s, every ${IV}s)"
  while :; do
    now=$(date +%s); local -A cur=()
    while read -r tid st; do [[ $st == D* ]] && cur[$tid]=1; done < <(ps -eLo tid=,stat=)
    for tid in "${!seen[@]}"; do [[ -n ${cur[$tid]-} ]] || unset "seen[$tid]"; done
    for tid in "${!cur[@]}"; do
      [[ -n ${seen[$tid]-} ]] || seen[$tid]=$now
      if (( now - seen[$tid] >= DMAX )); then
        d="$(record)"; setv 1; rm -f "$ORIG"
        log "HANG: tid $tid in D for $((now - seen[$tid]))s; recorded $d; timer_migration=$(cat "$TM"); stopping openru containers"
        docker ps -q --filter name=openru | xargs -r docker stop -t 10 >/dev/null 2>&1
        log "containers stopped; D threads now $(ps -eLo stat= | grep -c '^D'); run 'make down' / 'split.sh <role> down'"
        echo "bench-tm: HANG recorded in $d; timer_migration set to 1, openru containers stopped" >&2
        rm -f "$PID"; exit 3
      fi
    done
    unset cur; sleep "$IV"
  done
}

case "${1:-}" in
  watch)
    enabled || exit 0
    alive && { say "watchdog already running (pid $(cat "$PID"))"; exit 0; }
    sudo -n true 2>/dev/null || { say "WARN: no passwordless sudo: no watchdog, timer_migration stays as it is" >&2; exit 0; }
    mkdir -p "$DIR"
    setsid nohup taskset -c "${BENCH_TM_CPUS:-0-1}" "$0" _loop > /dev/null 2>> "$LOG" < /dev/null &
    echo $! > "$PID"; sleep 0.2
    alive && say "watchdog running (pid $(cat "$PID"), log $LOG)" || { say "WARN: watchdog did not start (see $LOG)" >&2; rm -f "$PID"; } ;;
  _loop) loop ;;
  set0)
    enabled || exit 0
    alive || { say "WARN: no watchdog running: timer_migration left at $(cat "$TM")" >&2; exit 0; }
    [[ -f "$ORIG" ]] || cat "$TM" > "$ORIG"
    setv 0 && say "timer_migration 0 for this session (was $(cat "$ORIG"); restored by down)" \
      || say "WARN: could not set timer_migration=0" >&2 ;;
  restore)
    [[ -f "$ORIG" ]] || exit 0
    if setv "$(cat "$ORIG")"; then say "timer_migration restored to $(cat "$TM")"; rm -f "$ORIG"
    else say "WARN: could not restore timer_migration (recorded $(cat "$ORIG"), now $(cat "$TM"))" >&2; exit 1; fi ;;
  stop)
    "$0" restore; rc=$?
    if alive; then kill "$(cat "$PID")" 2>/dev/null; log "watchdog stopped"; say "watchdog stopped"; fi
    rm -f "$PID"; exit "$rc" ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
