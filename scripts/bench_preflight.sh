#!/usr/bin/env bash
# Bench-bundle preflight for the bench host (docs/BENCH_BUNDLE.md).
#
# Fails closed on: P/E topology drift, kernel isolation of the DU/RU cores,
# X710 fronthaul port, MTU 9000, hwlatdetect >= 20 us, and a container UHD
# major that does not match the N310 MPM/filesystem generation.
#
# Usage: BENCH_ENV=docker/bench.env scripts/bench_preflight.sh
#   BENCH_HWLAT_SECS=60     hwlatdetect window (default 60)
#   BENCH_SKIP_HWLAT=1      skip hwlatdetect (warning; use before the cmdline reboot)
#   BENCH_USRP_REQUIRED=1   fail when the USRP is not found (after its address is known)
#
# The script never calls sudo interactively: hwlatdetect runs directly if the
# caller is root, else via `sudo -n` (passwordless) and fails with instructions.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ENV="${BENCH_ENV:-$ROOT/docker/bench.env}"
HWLAT_SECS="${BENCH_HWLAT_SECS:-60}"
HWLAT_LIMIT_US=20
IFACE="${BENCH_FH_IFACE:-}"
USRP_SERIAL="${BENCH_USRP_SERIAL:-}"

FAIL=0
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
ok()   { echo "ok    $*"; }
warn() { echo "WARN  $*"; }

[[ -f "$BENCH_ENV" ]] || { echo "FAIL: $BENCH_ENV missing (bench host env file)" >&2; exit 1; }
set -a; . "$BENCH_ENV"; set +a
IFACE="${IFACE:-${BENCH_FH_IFACE:-enp5s0f0np0}}"
USRP_SERIAL="${USRP_SERIAL:-${BENCH_USRP_SERIAL:-}}"
: "${PROTORU_CPUSET:?bench.env must set PROTORU_CPUSET}"
: "${DU_CPUSET:?bench.env must set DU_CPUSET}"
: "${OPENRU_TAG:?bench.env must set OPENRU_TAG}"

# cpuset_expand <list> → space-separated CPU numbers ("2-5,8" → "2 3 4 5 8").
cpuset_expand() {
  python3 - "$1" <<'PY'
import sys
out = []
for part in sys.argv[1].split(","):
    part = part.strip()
    if not part:
        continue
    if "-" in part:
        a, b = part.split("-", 1)
        out.extend(range(int(a), int(b) + 1))
    else:
        out.append(int(part))
print(" ".join(map(str, out)))
PY
}
in_set() { # in_set <cpu> <list>
  local c="$1"; shift
  [[ " $(cpuset_expand "$1") " == *" $c "* ]]
}
subset() { # subset <a-list> <b-list>
  local c
  for c in $(cpuset_expand "$1"); do in_set "$c" "$2" || return 1; done
  return 0
}

echo "== bench preflight ($BENCH_ENV) =="
echo "    protoru=${PROTORU_CPUSET} du=${DU_CPUSET} tag=${OPENRU_TAG} iface=${IFACE}"

# ---------------------------------------------------------------- topology --
P_LIST=""
E_LIST=""
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
  c="${cpu_dir##*/cpu}"
  f="$cpu_dir/cpufreq/cpuinfo_max_freq"
  [[ -r "$f" ]] || continue
  mhz=$(( $(cat "$f") / 1000 ))
  if [[ "$mhz" -ge 4000 ]]; then P_LIST="$P_LIST $c"; else E_LIST="$E_LIST $c"; fi
done
if [[ -z "$P_LIST" ]]; then
  # No cpufreq (e.g. intel_pstate off): fall back to lscpu.
  mapfile -t rows < <(lscpu -p=CPU,MAXMHZ 2>/dev/null | grep -v '^#')
  for r in "${rows[@]}"; do
    IFS=',' read -r c m <<<"$r"
    m="${m%%.*}"
    [[ -n "$m" ]] || continue
    if (( m >= 4000 )); then P_LIST="$P_LIST $c"; else E_LIST="$E_LIST $c"; fi
  done
fi
P_COUNT=$(echo $P_LIST | wc -w); E_COUNT=$(echo $E_LIST | wc -w)
if [[ "$P_COUNT" -eq 0 ]]; then
  fail "cannot classify P/E cores (no cpufreq/lscpu max frequency)"
else
  ok "P cores (logical):$(echo $P_LIST | tr ' ' ',')  E cores (logical):$(echo $E_LIST | tr ' ' ',')"
  ok "counts: P=$P_COUNT (expect 12), E=$E_COUNT (expect 8)"
  [[ "$P_COUNT" -eq 12 ]] || fail "P-core count $P_COUNT != 12 (i5-13600KF: 6 P-cores with HT)"
  [[ "$E_COUNT" -eq 8 ]] || fail "E-core count $E_COUNT != 8"
  subset "$PROTORU_CPUSET" "$P_LIST" || fail "PROTORU_CPUSET=$PROTORU_CPUSET is not P-cores-only"
  subset "$DU_CPUSET" "$P_LIST" || fail "DU_CPUSET=$DU_CPUSET is not P-cores-only"
  [ "$(cpuset_expand "$PROTORU_CPUSET")" != "" ] && ok "RT lanes are P-core logical CPUs only"
fi

# ------------------------------------------------------------ kernel cmdline --
CMDLINE="$(cat /proc/cmdline 2>/dev/null)"
cmd_cpus() { # cmd_cpus <param> → CPU list on the cmdline (domain prefixes stripped)
  local tok
  for tok in $CMDLINE; do
    case "$tok" in
      "$1="*)
        echo "${tok#*=}" | tr ',' ' ' | tr ' ' '\n' | grep -E '^[0-9]+(-[0-9]+)?$' | paste -sd, -
        return 0 ;;
    esac
  done
  return 1
}
RT_LANES="$PROTORU_CPUSET,$DU_CPUSET"
HOUSE="0-1,${CORE_CPUSET:-12-19}"
for param in isolcpus nohz_full rcu_nocbs; do
  if v="$(cmd_cpus "$param")"; then
    if subset "$RT_LANES" "$v"; then ok "$param=$(echo $v | tr ' ' ',') covers $RT_LANES"; else
      fail "$param=$v does not cover DU+RU lanes $RT_LANES"; fi
  else
    fail "$param missing from kernel cmdline (required: $param=$RT_LANES)"
  fi
done
if v="$(cmd_cpus irqaffinity)"; then
  if subset "$HOUSE" "$v" && ! subset "$RT_LANES" "$v"; then
    ok "irqaffinity=$(echo $v | tr ' ' ',') keeps IRQs off $RT_LANES"
  else
    fail "irqaffinity=$v must include housekeeping $HOUSE and exclude $RT_LANES"
  fi
else
  fail "irqaffinity missing (required: irqaffinity=$HOUSE)"
fi

# ------------------------------------------------------------------- X710 ----
if ip link show "$IFACE" >/dev/null 2>&1; then
  drv=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/{print $2}')
  state=$(ip -o link show "$IFACE" | grep -o 'state [A-Z]*' | awk '{print $2}')
  mtu=$(ip -o link show "$IFACE" | sed -n 's/.* mtu \([0-9]*\).*/\1/p')
  speed=$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Speed:/{print $2}')
  ok "$IFACE driver=${drv:-?} state=${state:-?} mtu=${mtu:-?} speed=${speed:-?}"
  [[ "$drv" == "i40e" ]] || fail "$IFACE driver ${drv:-unknown} != i40e (X710 required)"
  [[ "$state" == "UP" ]] || fail "$IFACE is not link up"
  [[ "$speed" == "10000Mb/s" ]] || fail "$IFACE speed ${speed:-unknown} != 10000Mb/s (10 GbE required)"
  [[ "$mtu" == "9000" ]] || fail "$IFACE mtu ${mtu:-?} != 9000 (set: sudo ip link set $IFACE mtu 9000)"
else
  fail "interface $IFACE not found (X710 fronthaul port)"
fi

# -------------------------------------------------------------- hwlatdetect --
if [[ "${BENCH_SKIP_HWLAT:-0}" == "1" ]]; then
  warn "hwlatdetect skipped (BENCH_SKIP_HWLAT=1)"
elif command -v hwlatdetect >/dev/null 2>&1 || command -v hwlatdetect.py >/dev/null 2>&1; then
  HWLAT_BIN="$(command -v hwlatdetect || command -v hwlatdetect.py)"
  RUN=("$HWLAT_BIN" --duration="$HWLAT_SECS" --threshold="$HWLAT_LIMIT_US" --report=/dev/stdout)
  if [[ "$(id -u)" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then RUN=(sudo -n "${RUN[@]}"); else
      fail "hwlatdetect needs root and passwordless sudo is not configured (or set BENCH_SKIP_HWLAT=1)"
      RUN=()
    fi
  fi
  if [[ ${#RUN[@]} -gt 0 ]]; then
    OUT="$("${RUN[@]}" 2>&1)"
    # Parse the result line only (parameters also end in "us"): tools/bench/hwlat_parse.py.
    if MAXV="$(printf '%s\n' "$OUT" | python3 "$ROOT/tools/bench/hwlat_parse.py")"; then
      if python3 -c "import sys; sys.exit(0 if float('$MAXV') < $HWLAT_LIMIT_US else 1)"; then
        ok "hwlatdetect max ${MAXV} us < ${HWLAT_LIMIT_US} us over ${HWLAT_SECS}s"
      else
        fail "hwlatdetect max ${MAXV} us >= ${HWLAT_LIMIT_US} us over ${HWLAT_SECS}s"
        printf '%s\n' "$OUT" | tail -5 | sed 's/^/      | /'
      fi
    else
      fail "hwlatdetect output not parseable (no 'Max Latency: <n>us' line)"
      printf '%s\n' "$OUT" | tail -8 | sed 's/^/      | /'
    fi
  fi
else
  fail "hwlatdetect not installed (apt-get install rt-tests)"
fi

# --------------------------------------------------------------- UHD / N310 --
# Container UHD major must match the device MPM/filesystem generation
# (N310 MPM 3.x ↔ UHD 3.x filesystem, MPM 4.x ↔ UHD 4.x filesystem).
CONT_UHD=""
if docker image inspect "openru/protoru:${OPENRU_TAG}" >/dev/null 2>&1; then
  CONT_UHD="$(docker run --rm --network none --entrypoint /bin/bash \
    "openru/protoru:${OPENRU_TAG}" -lc 'uhd_config_info --version 2>/dev/null' 2>/dev/null \
    | grep -Eo 'UHD [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
  [[ -n "$CONT_UHD" ]] && ok "container UHD ${CONT_UHD} (openru/protoru:${OPENRU_TAG})" || warn "could not read the container UHD version"
else
  fail "image openru/protoru:${OPENRU_TAG} not found (build/load the v3 image)"
fi
docker image inspect openru/core:m0 >/dev/null 2>&1 || warn "openru/core:m0 not found (needed for smoke-core)"

if command -v uhd_find_devices >/dev/null 2>&1; then
  DEVS="$(uhd_find_devices 2>&1)"
  if [[ -n "$USRP_SERIAL" ]] && ! printf '%s' "$DEVS" | grep -q "$USRP_SERIAL"; then
    if [[ "${BENCH_USRP_REQUIRED:-0}" == "1" ]]; then fail "USRP $USRP_SERIAL not found by host UHD"
    else warn "USRP $USRP_SERIAL not found yet (address open item; BENCH_USRP_REQUIRED=1 to enforce)"; fi
  else
    ok "host UHD sees USRP ${USRP_SERIAL:-unknown}"
    MPM_MAJOR="$(printf '%s' "$DEVS" | grep -Eo 'MPM[^0-9]*([0-9]+)\.[0-9]+' | grep -Eo '[0-9]+' | head -1)"
    if [[ -n "$MPM_MAJOR" && -n "$CONT_UHD" ]]; then
      if [[ "${CONT_UHD%%.*}" == "$MPM_MAJOR" ]]; then
        ok "UHD majors match: container $CONT_UHD, device MPM $MPM_MAJOR.x"
      else
        fail "container UHD $CONT_UHD vs device MPM ${MPM_MAJOR}.x: major mismatch — update one side (uhd_images_downloader + usrp_n3xx_fs_updater --type filesystem)"
      fi
    elif [[ -z "$MPM_MAJOR" ]]; then
      warn "device MPM version not exposed by uhd_find_devices; verify with uhd_usrp_probe once the address is known"
    fi
  fi
else
  wake_pkg=""
  command -v docker >/dev/null && wake_pkg="docker"
  fail "host uhd_find_devices not installed (UHD is required on the bench host: apt install libuhd-dev uhd-host, or uhd_find_devices via the ${wake_pkg:-container} image)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "bench-preflight: PASS"
  exit 0
fi
echo "bench-preflight: FAIL ($FAIL item(s))"
exit 1
