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
IFACE="${IFACE:-${BENCH_FH_IFACE:-enp5s0f1np1}}"
USRP_SERIAL="${USRP_SERIAL:-${BENCH_USRP_SERIAL:-}}"
: "${PROTORU_CPUSET:?bench.env must set PROTORU_CPUSET}"
: "${DU_CPUSET:?bench.env must set DU_CPUSET}"
: "${OPENRU_TAG:?bench.env must set OPENRU_TAG}"

# CPU lists are parsed by tools/bench/cpulist.py (ranges, commas, spaces, mixed;
# sysfs/lscpu output is space-separated, cmdline is comma-separated).
CPULIST="python3 $ROOT/tools/bench/cpulist.py"
cpuset_expand() { $CPULIST expand "$1"; }
in_set() { $CPULIST contains "$1" "$2"; }
subset() { $CPULIST check "$1" "$2" 2>/dev/null; }


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
  if [[ -n "${BENCH_USRP_HOST_IP:-}" ]]; then
    if ip -4 -o addr show "$IFACE" | grep -q " ${BENCH_USRP_HOST_IP} "; then
      ok "$IFACE has ${BENCH_USRP_HOST_IP} (N310 subnet)"
    else
      fail "$IFACE has no ${BENCH_USRP_HOST_IP} address (set: sudo ip addr add ${BENCH_USRP_HOST_IP} dev $IFACE)"
    fi
  fi
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

# ------------------------------------------------ radio profile (MCR / srate) --
# The N310 only supports master clock rates 122.88, 125.0 and 153.6 MHz, and the
# sample rate must be an integer divisor of the MCR (Ettus KB "N300/N310" and the
# N300/N310/N320/N321 Getting Started Guide; even decimation preferred).
PROFILE_DIR="${BENCH_PROFILE_DIR:-$ROOT/profiles}"
mapfile -t RADIO_PROFILES < <(ls -d "$PROFILE_DIR"/bench-*/protoru.yml 2>/dev/null)
if [[ ${#RADIO_PROFILES[@]} -eq 0 ]]; then
  fail "no bench radio profiles found under $PROFILE_DIR/bench-*/protoru.yml"
fi
for prof in "${RADIO_PROFILES[@]}"; do
  OUT="$(python3 - "$prof" <<'PY'
import sys
import yaml

SUPPORTED_MCR_HZ = {122.88e6: "122.88", 125.0e6: "125.0", 153.6e6: "153.6"}
path = sys.argv[1]
cell = yaml.safe_load(open(path))["ru_emu"]["cells"][0]
sdr = cell["sdr"]
args = dict(part.split("=", 1) for part in sdr["device_args"].split(",") if "=" in part)
mcr = float(args.get("master_clock_rate", "nan"))
srate = float(sdr["srate"]) * 1e6
scs = float(cell["common_scs"]) * 1e3
print(path.split("/")[-2])
if mcr not in SUPPORTED_MCR_HZ:
    print("FAIL mcr {} MHz is not an N310 rate (122.88 / 125.0 / 153.6)".format(mcr / 1e6))
    sys.exit(0)
ratio = mcr / srate
if abs(ratio - round(ratio)) > 1e-9 or round(ratio) < 1 or round(ratio) > 1024:
    print("FAIL srate {} Msps is not an integer divisor of MCR {} MHz".format(srate / 1e6, SUPPORTED_MCR_HZ[mcr]))
    sys.exit(0)
fft = srate / scs
kind = "even" if round(ratio) % 2 == 0 else "ODD (CIC roll-off)"
print("OK mcr={} MHz srate={} Msps decim={} ({}), fft={}".format(
    SUPPORTED_MCR_HZ[mcr], round(srate / 1e6, 3), round(ratio), kind,
    round(fft) if abs(fft - round(fft)) < 1e-9 else "non-integer"))
PY
)"
  name="$(printf '%s' "$OUT" | head -1)"
  detail="$(printf '%s' "$OUT" | tail -1)"
  case "$detail" in
    OK*)   ok "radio profile ${name}: ${detail#OK }" ;;
    FAIL*) fail "radio profile ${name}: ${detail#FAIL }" ;;
    *)     fail "radio profile ${prof##*/}: unreadable sdr block" ;;
  esac
done

# --------------------------------------------------------------- UHD / N310 --
# The bench container must not depend on host UHD: the image ships UHD matching
# the N310 MPM, and the probe runs INSIDE the container against the radio.
IMG="openru/protoru:${OPENRU_TAG}"
CONT_UHD=""
if docker image inspect "$IMG" >/dev/null 2>&1; then
  CONT_UHD="$(docker run --rm --network none --entrypoint /bin/bash "$IMG" -lc \
    'uhd_config_info --version 2>/dev/null' 2>/dev/null \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$CONT_UHD" ]]; then
    fail "cannot read the container UHD version from $IMG"
  elif [[ -n "${BENCH_UHD_VERSION:-}" && "$CONT_UHD" != "$BENCH_UHD_VERSION" ]]; then
    fail "container UHD ${CONT_UHD} != required ${BENCH_UHD_VERSION} (must match the N310 MPM)"
  else
    ok "container UHD ${CONT_UHD} ($IMG)"
  fi

  if [[ -z "${BENCH_USRP_ADDR:-}" ]]; then
    fail "BENCH_USRP_ADDR missing (N310 IQ address)"
  elif [[ "${BENCH_SKIP_USRP:-0}" == "1" ]]; then
    warn "in-container USRP probe skipped (BENCH_SKIP_USRP=1)"
  else
    PROBE_ARGS="addr=${BENCH_USRP_ADDR}${BENCH_MGMT_ADDR:+,mgmt_addr=${BENCH_MGMT_ADDR}}"
    PROBE_RC=0
    OUT="$(timeout 180 docker run --rm --network host --entrypoint /bin/bash "$IMG" -lc \
      "uhd_usrp_probe --args '${PROBE_ARGS}'" 2>&1)" || PROBE_RC=$?
    if printf '%s' "$OUT" | grep -qiE "compatib|MPM.*(expected|requires)|update.*(filesystem|FPGA|image)"; then
      fail "N310 MPM/filesystem incompatible with container UHD ${CONT_UHD:-?}: $(printf '%s' "$OUT" | grep -iE 'compatib|MPM|filesystem|FPGA' | head -3 | tr '\n' ' ')"
    elif [[ "$PROBE_RC" -ne 0 ]]; then
      DETAIL="$(printf '%s' "$OUT" | grep -iE "error|no devices|not found" | head -2 | tr '\n' ' ')"
      [[ -n "$DETAIL" ]] || DETAIL="$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
      fail "uhd_usrp_probe failed (rc=$PROBE_RC) for ${PROBE_ARGS}: ${DETAIL}"
    elif [[ -n "${BENCH_USRP_SERIAL:-}" ]] && ! printf '%s' "$OUT" | grep -q "${BENCH_USRP_SERIAL}"; then
      fail "probe returned no USRP with serial ${BENCH_USRP_SERIAL} (${PROBE_ARGS})"
    else
      ok "in-container uhd_usrp_probe OK: ${PROBE_ARGS}, serial ${BENCH_USRP_SERIAL:-?}"
      printf '%s\n' "$OUT" | grep -iE "MPM|FPGA|filesystem" | head -2 | sed 's/^/      /'
    fi
  fi
else
  fail "image ${IMG} not found (build with UHD ${BENCH_UHD_VERSION:-4.11.0.0}: make BENCH=1 build-protoru)"
fi
# Release provenance: is the running image built from the checked-out commit?
IMG_COMMIT="$(docker image inspect "$IMG" --format '{{index .Config.Labels "org.openru.git.commit"}}' 2>/dev/null || true)"
REPO_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$IMG_COMMIT" || "$IMG_COMMIT" == "unknown" || "$IMG_COMMIT" == "<no value>" ]]; then
  warn "image ${IMG} carries no org.openru.git.commit label (pre-release build)"
elif [[ -n "$REPO_COMMIT" && "$IMG_COMMIT" != "$REPO_COMMIT" ]]; then
  warn "image commit ${IMG_COMMIT:0:12} != repo HEAD ${REPO_COMMIT:0:12} (expected when the checkout moved past the release)"
else
  ok "image commit matches repo HEAD (${REPO_COMMIT:0:12})"
fi
docker image inspect openru/core:${OPENRU_TAG} >/dev/null 2>&1 || warn "openru/core:${OPENRU_TAG} not found (load the release: scripts/bench_load.sh <dir>)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "bench-preflight: PASS"
  exit 0
fi
echo "bench-preflight: FAIL ($FAIL item(s))"
exit 1
