#!/usr/bin/env bash
# TX gain guard (scripts/tx_gain_guard.sh) and its use in split.sh, up.sh and restart_ru.sh. No hardware: every
# refused case exits at the guard before any docker/network action.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
expect() { # <pass|refuse> <label> [VAR=value ...]   (an unset variable is passed as -u NAME)
  local want="$1" label="$2"; shift 2
  if env -u TX_GAIN -u TX_GAIN_MAX "$@" bash -c '. "$0/scripts/tx_gain_guard.sh"; tx_gain_check t' "$ROOT" >/dev/null 2>&1
  then got=pass; else got=refuse; fi
  [[ "$got" == "$want" ]] && echo "ok   $want: $label" || { echo "FAIL $label: wanted $want, got $got" >&2; fails=1; }
}
expect pass   "30 (default limit)"                TX_GAIN=30
expect pass   "0"                                 TX_GAIN=0
expect refuse "31 without TX_GAIN_MAX"            TX_GAIN=31
expect pass   "40 with TX_GAIN_MAX=40"            TX_GAIN=40 TX_GAIN_MAX=40
expect refuse "41 with TX_GAIN_MAX=40"            TX_GAIN=41 TX_GAIN_MAX=40
expect refuse "TX_GAIN_MAX=41"                    TX_GAIN=30 TX_GAIN_MAX=41
for bad in 041 040 40.0 -1 "" " 40" "40 " "4 0" +40 0x28 30.5; do
  expect refuse "TX_GAIN='$bad' (max 40)"         "TX_GAIN=$bad" TX_GAIN_MAX=40
  expect refuse "TX_GAIN_MAX='$bad'"              TX_GAIN=30 "TX_GAIN_MAX=$bad"
done
expect refuse "TX_GAIN unset"                     TX_GAIN_MAX=40
# 08/09: invalid octal if anything used plain arithmetic; the regex refuses them first
expect refuse "TX_GAIN=08"                        TX_GAIN=08 TX_GAIN_MAX=40
# Callers refuse a malformed gain at the guard (and start nothing).
out=$(env RF_SPLIT_OK=1 RADIO=uhd BENCH_RADIO=n310-20 PROFILE=bench-split-20mhz-2t2r TX_GAIN=041 TX_GAIN_MAX=40 \
      "$ROOT/scripts/split.sh" ran up 2>&1); grep -q "split: FAIL: TX_GAIN must be a plain integer" <<< "$out" \
  && echo "ok   split.sh refuses 041" || { echo "FAIL split.sh: $out" >&2; fails=1; }
out=$(env BENCH=1 RADIO=uhd STACK=e2e PROFILE=bench-20mhz TX_GAIN=40.0 TX_GAIN_MAX=40 "$ROOT/scripts/up.sh" 2>&1)
grep -q "up: FAIL: TX_GAIN must be a plain integer" <<< "$out" && echo "ok   up.sh refuses 40.0" || { echo "FAIL up.sh: $out" >&2; fails=1; }
out=$(env BENCH=1 PROFILE=bench-20mhz TX_GAIN=35 "$ROOT/scripts/restart_ru.sh" 2>&1)
grep -q "restart-ru: FAIL: TX_GAIN 35 > limit 30" <<< "$out" && echo "ok   restart_ru.sh refuses 35 by default" || { echo "FAIL restart_ru.sh: $out" >&2; fails=1; }
(( fails == 0 )) && echo "PASS: TX gain guard" || { echo "FAIL: TX gain guard" >&2; exit 1; }
