#!/usr/bin/env bash
# Read-only probe of ProtO-RU's threads during a short UHD (RF) run on the bench host: which threads exist, their
# roles, policy and CPUs, their load, and which threads make the IQ socket calls (perf syscall tracepoints).
# Background and expected answers: docs/reports/UHD_THREADS.md. Changes nothing: /proc reads, perf stat/record.
#
#   scripts/uhd_threads_probe.sh [OUT_DIR] [LOAD_SECS=60] [PERF_SECS=10]
#
# Run only while the RU container (openru-protoru-1) is up on the UHD radio, with the human at the bench.
# perf needs sudo -n. Output: threads.txt, load.txt, syscalls-per-thread.txt, iq-calls.txt, interrupts-*.txt.
set -euo pipefail
OUT=${1:-"$HOME/Desktop/OpenRU/bench-notes/$(date +%F)-uhd-threads"}; LOAD_SECS=${2:-60}; PERF_SECS=${3:-10}
C=${PROTORU_CONTAINER:-openru-protoru-1}
mkdir -p "$OUT"
pid=$(docker inspect -f '{{.State.Pid}}' "$C")
[ "$pid" -gt 0 ] || { echo "container $C not running" >&2; exit 1; }
cat /proc/interrupts > "$OUT/interrupts-before.txt"

# 1. Threads, roles, policy, CPU, affinity; then per-thread load over LOAD_SECS.
python3 -I - "$pid" "$OUT" "$LOAD_SECS" <<'PY'
import os, sys, time
pid, out, secs = sys.argv[1], sys.argv[2], int(sys.argv[3]); hz = os.sysconf("SC_CLK_TCK")
POL = {0: "OTHER", 1: "FIFO", 2: "RR"}
ROLE = {  # docs/reports/UHD_THREADS.md
    "ru_phy_tx_#0": "TX samples: UHD send() + TX flow control", "ru_phy_rx_#0": "RX samples: UHD recv() + FC replies",
    "ru_phy_ul_#0": "UL processing of RX buffers", "ru_phy_hp_#0": "DL modulation / PRACH",
    "ru_radio_#0": "UHD async-message loop (recv_async_msg)", "uhd_ctrl_ep0001": "UHD control endpoint (busy-polls)",
    "action_handler": "UHD graph actions", "uhd_log": "UHD log consumer", "ru_timing": "OFH timing",
    "ru_emu_#0": "OFH emulator (busy-polls)", "ru_rx_#0": "OFH receive", "ru_ofh_tx_#0": "OFH transmit"}
def snap():
    t = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            s = open(f"/proc/{pid}/task/{tid}/stat").read(); f = s[s.rindex(")") + 2:].split()
            st = dict(l.split(":\t", 1) for l in open(f"/proc/{pid}/task/{tid}/status").read().splitlines() if ":\t" in l)
            t[tid] = dict(comm=s[s.index("(") + 1:s.rindex(")")], jif=int(f[11]) + int(f[12]), cpu=int(f[36]),
                          pol=POL.get(int(f[38]), f[38]), prio=int(f[37]), aff=st["Cpus_allowed_list"].strip())
        except (OSError, ValueError, KeyError): pass
    return t
a, t0 = snap(), time.time()
with open(f"{out}/threads.txt", "w") as fo:
    fo.write("tid comm policy/prio cpu allowed role\n")
    for tid, v in sorted(a.items(), key=lambda x: (x[1]["cpu"], x[1]["comm"])):
        role = ROLE.get(v["comm"], "gRPC (UHD MPM client)" if v["comm"].startswith(("event_engine", "grpc", "default-exec",
               "resolver", "timer_manager")) else "?")
        fo.write(f"{tid} {v['comm']} {v['pol']}/{v['prio']} {v['cpu']} {v['aff']} {role}\n")
with open(f"{out}/load.txt", "w") as fo:
    for _ in range(max(1, secs // 10)):
        time.sleep(10); b, t1 = snap(), time.time()
        fo.write(time.strftime("%H:%M:%S ") + " ".join(f"{v['comm']}[{tid}]@{v['cpu']}:{100*(v['jif']-a[tid]['jif'])/hz/(t1-t0):.0f}"
                 for tid, v in sorted(b.items(), key=lambda x: x[1]["cpu"]) if tid in a) + "\n"); fo.flush()
        a, t0 = b, t1
PY

# 2. Syscall counts per thread (all threads; counting only, cheap): who makes the socket calls and how often.
EV=syscalls:sys_enter_sendto,syscalls:sys_enter_recvfrom,syscalls:sys_exit_recvfrom,syscalls:sys_enter_poll,syscalls:sys_enter_ppoll,syscalls:sys_enter_clock_nanosleep,syscalls:sys_enter_sendmsg,syscalls:sys_enter_recvmsg,syscalls:sys_enter_recvmmsg
sudo -n perf stat --per-thread -e "$EV" -p "$pid" -o "$OUT/syscalls-per-thread.txt" -- sleep "$PERF_SECS"

# 3. Bytes per IQ call, only on the two sample threads (uhd_ctrl_ep0001 spins at ~100k+ calls/s, so it is excluded).
tids=$(for t in /proc/"$pid"/task/*; do case "$(cat "$t/comm")" in ru_phy_tx_#0|ru_phy_rx_#0) echo -n "${t##*/},";; esac; done)
if [ -n "$tids" ]; then
  sudo -n perf record -q -o "$OUT/iq.perf.data" -t "${tids%,}" \
    -e syscalls:sys_enter_sendto,syscalls:sys_exit_recvfrom,syscalls:sys_enter_poll,syscalls:sys_enter_ppoll -- sleep 2
  sudo -n perf script -i "$OUT/iq.perf.data" -F comm,tid,event,trace 2>/dev/null | python3 -I -c '
import re, sys, collections
n = collections.Counter(); by = collections.Counter()
for l in sys.stdin:
    m = re.match(r"\s*(\S+)\s+(\d+)\s+(\S+):\s*(.*)", l)
    if not m: continue
    comm, tid, ev, rest = m.groups(); k = (comm, ev.split(":")[-1]); n[k] += 1
    v = re.search(r"len: (0x[0-9a-f]+)", rest) or re.search(r"0x([0-9a-f]+)$", rest)
    if ev.endswith("sys_enter_sendto") and v: by[k] += int(v.group(1), 16)
    if ev.endswith("sys_exit_recvfrom"): by[k] += max(0, int(rest.strip().split()[-1], 0))
for k in sorted(n): print(f"{k[0]:16s} {k[1]:24s} calls/s {n[k]/2:9.0f}  bytes/call {by[k]/n[k] if by[k] else 0:7.0f}")
' > "$OUT/iq-calls.txt"
  sudo -n rm -f "$OUT/iq.perf.data"
fi
cat /proc/interrupts > "$OUT/interrupts-after.txt"
echo "uhd_threads_probe: wrote $OUT"; cat "$OUT/iq-calls.txt" 2>/dev/null || true
