#!/usr/bin/env bash
# Real-time health watcher for the bench stack: ProtO-RU lower-PHY/RF real-time
# failures and DU fronthaul real-time warnings (tools/bench/rt_health.py).
#
#   scripts/rt_watch.sh start            # start the log follower (once, after the RU is up)
#   scripts/rt_watch.sh check <seconds>  # count over the next <seconds>: exit 0 OK, 2 WARN, 1 FAIL
#   scripts/rt_watch.sh watch [seconds]  # print every 10 s (Ctrl-C to stop); final verdict over the run
#   scripts/rt_watch.sh stop
#
# Clean OFH counters can hide a lower PHY that misses its deadlines; this is
# the check that does not. Thresholds: RT_FAIL_RU_PER_MIN (default 6),
# RT_FAIL_DU_PER_MIN (default 60).
#
# Why one long-lived follower with --network none: starting a container on a Docker
# bridge network while the stack runs disrupted the DU's uplink (2026-11-20, three
# `docker run alpine`: all PRACH missed for ~55 s, then every UL symbol for ~30 s;
# ProtO-RU itself saw nothing). --network none helpers (this follower, pin_threads.py)
# showed no effect. The follower is created once, on the housekeeping CPUs, and
# every check only reads its output through the Docker API. Never `docker exec`
# into the real-time containers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${RT_WATCH_NAME:-openru-rtwatch}"
HK_CPUS="${RT_WATCH_CPUS:-0-1}"
RU_LOG="${RT_RU_LOG:-/tmp/proto-ru.log}"
DU_LOG="${RT_DU_LOG:-/tmp/gnb.log}"
FAIL_RU="${RT_FAIL_RU_PER_MIN:-6}"
FAIL_DU="${RT_FAIL_DU_PER_MIN:-60}"
PATTERN='Real-time failure|request late|\[OFH +\] \[W\]'

cid_of() { docker ps -q --filter label=com.docker.compose.project=openru \
             --filter "label=com.docker.compose.service=$1" --filter status=running | head -1; }
utc() { date -u -d "${1:-now}" +%Y-%m-%dT%H:%M:%S; }

start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  local ru du img
  ru="$(cid_of protoru)"; du="$(cid_of du)"
  [[ -n "$ru" && -n "$du" ]] || { echo "rt-watch: FAIL: protoru and du must be running" >&2; return 1; }
  img="$(docker inspect -f '{{.Config.Image}}' "$ru")"
  # The project label makes `make down` (--remove-orphans) remove the follower too.
  docker run -d --name "$NAME" --label com.docker.compose.project=openru \
    --label com.docker.compose.service=rtwatch --network none --cpuset-cpus "$HK_CPUS" \
    --volumes-from "$ru:ro" --volumes-from "$du:ro" --entrypoint /bin/sh "$img" \
    -c "follow() { tail -n +1 -F \"\$1\" 2>/dev/null | grep --line-buffered -E '$PATTERN' | sed -u \"s/^/\$2|/\"; }
        follow '$RU_LOG' RU & follow '$DU_LOG' DU & wait" >/dev/null
  docker update --cpu-shares 2 "$NAME" >/dev/null 2>&1 || true
  echo "rt-watch: follower $NAME started (cpus $HK_CPUS) on $RU_LOG and $DU_LOG"
}

lines() { # split the follower's tagged lines into $1 (RU) and $2 (DU)
  docker inspect "$NAME" >/dev/null 2>&1 || { echo "rt-watch: FAIL: follower not running (scripts/rt_watch.sh start)" >&2; return 1; }
  docker logs "$NAME" 2>/dev/null | awk -v ru="$1" -v du="$2" \
    '/^RU\|/ {print substr($0, 4) > ru; next} /^DU\|/ {print substr($0, 4) > du}'
  touch "$1" "$2"
}

evaluate() { # <since> <until> [--per10s]
  local ru du rc=0
  ru="$(mktemp)"; du="$(mktemp)"; trap 'rm -f "$ru" "$du"' RETURN
  lines "$ru" "$du" || return 1
  python3 "$ROOT/tools/bench/rt_health.py" --ru "$ru" --du "$du" --since "$1" --until "$2" \
    --fail-ru-per-min "$FAIL_RU" --fail-du-per-min "$FAIL_DU" "${@:3}" || rc=$?
  return "$rc"
}

case "${1:-}" in
  start) start ;;
  stop)  docker rm -f "$NAME" >/dev/null 2>&1 && echo "rt-watch: follower stopped" || true ;;
  check)
    secs="${2:?usage: rt_watch.sh check <seconds>}"
    t0="$(utc)"; sleep "$secs"; t1="$(utc)"
    evaluate "$t0" "$t1" --per10s ;;
  watch)
    dur="${2:-0}"; t_start="$(utc)"; end=$((SECONDS + dur))
    while (( dur == 0 || SECONDS < end )); do
      t0="$(utc)"; sleep 10; t1="$(utc)"
      evaluate "$t0" "$t1" | grep -E "rt: (RU|DU)|OK|WARN|FAIL" | sed "s/^/[${t1:11}] /" || true
    done
    echo "rt-watch: verdict over the whole watch:"
    evaluate "$t_start" "$(utc)" --per10s ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
