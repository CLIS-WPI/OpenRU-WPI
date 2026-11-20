#!/usr/bin/env bash
# BENCH_RADIO selection without a radio: env overlay values, profile address patch, unknown radio rejected.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

load() { # <radio> -> prints "addr iface subnet probe" after bench.env + radio overlay
  ( set -a; . "$ROOT/docker/bench.env"; set +a; . "$ROOT/scripts/radio_env.sh"
    BENCH_RADIO="$1" radio_env_load "$ROOT" >/dev/null || exit 2
    echo "$BENCH_USRP_ADDR $BENCH_FH_IFACE $BENCH_RADIO_SUBNET $BENCH_PROBE_IP" )
}
# Default unchanged: no BENCH_RADIO gives the stage-1 radio, same values as docker/bench.env.
def="$( set -a; . "$ROOT/docker/bench.env"; set +a; echo "$BENCH_USRP_ADDR $BENCH_FH_IFACE $BENCH_RADIO_SUBNET $BENCH_PROBE_IP")"
[[ "$(load "")" == "$def" ]] || fail "default radio differs from docker/bench.env: $(load "") vs $def"
[[ "$(load n310-10)" == "$def" ]] || fail "n310-10 differs from docker/bench.env"
[[ "$(load n310-20)" == "192.168.20.2 enp5s0f2np2 192.168.20.0/24 192.168.20.4" ]] || fail "n310-20: $(load n310-20)"
[[ "$(load n310-30)" == "192.168.30.2 enp5s0f3np3 192.168.30.0/24 192.168.30.4" ]] || fail "n310-30: $(load n310-30)"
if load n310-99 >/dev/null 2>&1; then fail "unknown BENCH_RADIO accepted"; fi

# Local profile gets the selected radio's device address; gain/reference handling is unchanged.
for r in n310-10 n310-20; do
  OUT="$( set -a; . "$ROOT/docker/bench.env"; set +a; . "$ROOT/scripts/radio_env.sh"
          BENCH_RADIO=$r radio_env_load "$ROOT"; "$ROOT/scripts/local_profile.sh" bench-20mhz - internal | tail -1 )"
  want="$(load $r | cut -d' ' -f1)"
  python3 - "$OUT" "$want" <<'PY'
import sys, yaml
s = yaml.safe_load(open(sys.argv[1]))["ru_emu"]["cells"][0]["sdr"]
a = sys.argv[2]
assert f"addr={a}," in s["device_args"] and f"mgmt_addr={a}," in s["device_args"], s["device_args"]
assert s["device_args"].count("addr=") == 2, s["device_args"]
assert "clock_source=internal,time_source=internal" in s["device_args"], s["device_args"]
PY
done
# bench_preflight must read the radio NIC/serial only after the overlay: `make BENCH=1` exports
# docker/bench.env (n310-10) into the environment, so an earlier capture overrode n310-20 (2026-11-20).
awk '/radio_env_load/ {loaded=1} /^(IFACE|USRP_SERIAL)=/ && !loaded {bad=1; print "  " NR ": " $0} END {exit bad}' \
  "$ROOT/scripts/bench_preflight.sh" || fail "bench_preflight.sh reads IFACE/USRP_SERIAL before radio_env_load"
echo "PASS: BENCH_RADIO selects n310-10 (default) / n310-20 / n310-30; unknown radio rejected"
