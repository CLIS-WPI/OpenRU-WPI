#!/usr/bin/env bash
# scripts/bench_tm.sh (no hardware, no root) against fake sudo/ps/docker: opt-in per host, set0 refuses without a
# watchdog, set0/restore/stop round trip, a hang (thread in D >= DMAX) is recorded then timer_migration=1 and the
# containers stopped, a short D episode does not trigger. Plus: core health check every >= 30 s, CORE_CPUSET off the
# isolated CPUs in each bench host env, BENCH_TM0 on for ran and the split core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; S="$ROOT/scripts/bench_tm.sh"
T="$(mktemp -d)"; mkdir "$T/bin"
cleanup() { [[ -f "$T/state/watchdog.pid" ]] && kill "$(cat "$T/state/watchdog.pid")" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
cat > "$T/bin/sudo" <<'X'
#!/usr/bin/env bash
[[ "$1" == -n ]] && shift; echo "sudo $*" >> "$FAKE/calls"
case "$1" in
  true) exit 0 ;;
  sysctl) v="${*: -1}"; echo "${v#*=}" > "$BENCH_TM_PROC" ;;
  tee) cat > /dev/null ;;
  *) : ;;
esac
X
cat > "$T/bin/ps" <<'X'
#!/usr/bin/env bash
case "$*" in *tid=,stat=*) cat "$FAKE/ps" ;; *stat=*) awk '{print $2}' "$FAKE/ps" ;;
  *) echo "TID PID STAT PSR CLS RTPRIO %CPU WCHAN ELAPSED COMMAND"; awk '{print $1, $1, $2, 3, "TS", "-", 0, "-", "1:00", "kworker"}' "$FAKE/ps" ;; esac
X
cat > "$T/bin/docker" <<'X'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE/calls"; [[ "$1" == ps ]] && echo abc123; exit 0
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE="$T" BENCH_TM_DIR="$T/state" BENCH_TM_PROC="$T/tm" BENCH_TM_CPUS=0 BENCH_TM_INTERVAL=0.2
reset() { "$S" stop >/dev/null 2>&1 || true; rm -rf "$T/state" "$T/calls"; echo 1 > "$T/tm"; echo "100 S" > "$T/ps"; touch "$T/calls"; }
chk() { [[ "$2" == "$3" ]] && echo "PASS: $1" || { echo "FAIL: $1: got '$2' want '$3'"; exit 1; }; }
tm() { cat "$T/tm"; }
wd() { [[ -f "$T/state/watchdog.pid" ]] && kill -0 "$(cat "$T/state/watchdog.pid")" 2>/dev/null && echo up || echo down; }

reset; "$S" watch; "$S" set0; chk "BENCH_TM0 unset: nothing happens" "$(tm) $(wd)" "1 down"
export BENCH_TM0=1
reset; "$S" set0 2>/dev/null; chk "set0 refuses without watchdog" "$(tm)" "1"
reset; "$S" watch >/dev/null; "$S" set0 >/dev/null; chk "watch + set0" "$(tm) $(wd) $(cat "$T/state/orig")" "0 up 1"
p1="$(cat "$T/state/watchdog.pid")"; "$S" watch >/dev/null; chk "second watch keeps the same watchdog" "$(cat "$T/state/watchdog.pid") $(wd)" "$p1 up"
"$S" restore >/dev/null; chk "restore" "$(tm) $(wd) $([[ -f $T/state/orig ]] && echo rec || echo norec)" "1 up norec"
"$S" set0 >/dev/null; "$S" stop >/dev/null; chk "stop restores and ends watchdog" "$(tm) $(wd)" "1 down"
# DMAX=2: the watchdog counts whole seconds, so a 0.5 s episode can span one second boundary but never two
reset; BENCH_TM_DMAX=2 "$S" watch >/dev/null; "$S" set0 >/dev/null; echo "100 S
777 D" > "$T/ps"; sleep 0.5; echo "100 S" > "$T/ps"; sleep 2.5
chk "short D episode: no trigger" "$(tm) $(wd)" "0 up"
"$S" stop >/dev/null
reset; BENCH_TM_DMAX=1 "$S" watch >/dev/null; "$S" set0 >/dev/null; echo "100 S
777 D" > "$T/ps"
for _ in $(seq 1 30); do [[ "$(wd)" == down ]] && break; sleep 0.2; done
h="$(ls -d "$T"/state/hang-* 2>/dev/null | head -1)"
chk "hang: timer_migration=1, watchdog exited" "$(tm) $(wd)" "1 down"
chk "hang: blocked task recorded" "$(awk 'NR>1 {print $1, $3}' "$h/d-tasks.txt")" "777 D"
chk "hang: sysrq w, stack read, then sysctl 1, then containers stopped" \
  "$(grep -oE 'sudo tee /proc/sysrq-trigger|sudo timeout 5 cat /proc/777/task/777/stack|sudo sysctl -q -w kernel.timer_migration=1|docker stop -t 10 abc123' "$T/calls" | paste -sd ';')" \
  "sudo tee /proc/sysrq-trigger;sudo timeout 5 cat /proc/777/task/777/stack;sudo sysctl -q -w kernel.timer_migration=1;docker stop -t 10 abc123"
chk "hang: record cleared, restore is a no-op" "$("$S" restore; echo rc$?) $([[ -f $T/state/orig ]] && echo rec || echo norec)" "rc0 norec"

python3 - "$ROOT" <<'PY'
import re, sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
hc = yaml.safe_load((root / "docker/compose.yml").read_text())["services"]["core"]["healthcheck"]
assert int(hc["interval"].rstrip("s")) >= 30, hc
print(f"PASS: core health check every {hc['interval']} (start_interval {hc.get('start_interval')})")
def cpus(s):
    out = set()
    for p in s.split(","):
        a, _, b = p.partition("-"); out |= set(range(int(a), int(b or a) + 1))
    return out
env = lambda f: dict(re.findall(r"^([A-Z0-9_]+)=(\S+)", (root / "docker" / f).read_text(), re.M))
for f in ("bench.env", "split-core.env"):
    iso = cpus(re.search(r"isolcpus=([0-9,-]+)", (root / "docker" / f).read_text()).group(1).rstrip(","))
    core = cpus(env(f)["CORE_CPUSET"]); assert not core & iso, (f, core & iso)
    print(f"PASS: {f}: CORE_CPUSET {env(f)['CORE_CPUSET']} (health checks) off isolated {sorted(iso)}")
b, c = env("bench.env"), {**env("bench.env"), **env("split-core.env")}
assert b["BENCH_TM0"] == "1" and c["BENCH_TM0"] == "1", (b.get("BENCH_TM0"), c.get("BENCH_TM0"))
print("PASS: BENCH_TM0 on for ran (bench.env, split-ran inherits), and for the split core (split-core.env)")
PY
