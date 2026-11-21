#!/usr/bin/env bash
# Split stack config without hardware: fh is a macvlan (never a bridge) on each role's NIC with MTU 9000,
# and the split DU profile's real-time CPUs are inside the core host's DU cpuset and isolated range.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
for r in core ran; do
  ( set -a; . docker/bench.env; . "docker/split-$r.env"; set +a
    export DU_CONFIG_PATH="$ROOT/profiles/bench-split-20mhz/du-core.yml" PROTORU_CONFIG_PATH="$ROOT/profiles/bench-split-20mhz/protoru-null.yml"
    f=(-f docker/compose.yml -f docker/compose.cpu.yml); [[ $r == core ]] && f+=(-f docker/compose.e2e.yml)
    docker compose --env-file docker/versions.env --env-file docker/bench.env --env-file "docker/split-$r.env" \
      "${f[@]}" -f docker/compose.split.yml --profile core --profile fh config ) > "/tmp/split-$r.$$.yml"
done
python3 - "/tmp/split-core.$$.yml" "/tmp/split-ran.$$.yml" "$ROOT/profiles/bench-split-20mhz/du-core.yml" <<'PY'
import re, sys, yaml
def cpus(s):
    out = set()
    for p in str(s).split(","):
        a, _, b = p.partition("-"); out |= set(range(int(a), int(b or a) + 1))
    return out
for path, parent in ((sys.argv[1], "ran_link"), (sys.argv[2], "enp5s0f0np0")):
    n = yaml.safe_load(open(path))["networks"]["fh"]
    assert n["driver"] == "macvlan", n
    assert n["driver_opts"]["parent"] == parent and n["driver_opts"]["com.docker.network.driver.mtu"] == "9000", n
core = yaml.safe_load(open(sys.argv[1]))
du_set = cpus(core["services"]["du"]["cpuset"])
aff = yaml.safe_load(open(sys.argv[3]))["expert_execution"]["affinities"]
rt = {aff["main_pool_cpus"], aff["ofh"]["timing_cpu"], *aff["ofh"]["txrx_cpus"]}
isolated = cpus("6-9,16-19")  # core host isolcpus (docker/split-core.env)
assert rt <= du_set and rt <= isolated and len(rt) == 3, (rt, du_set)
assert not (cpus(core["services"]["core"]["cpuset"]) & rt), "Open5GS overlaps DU real-time CPUs"
print("ok: fh macvlan on both roles; DU RT CPUs", sorted(rt), "in", sorted(du_set))
PY
rm -f /tmp/split-core.$$.yml /tmp/split-ran.$$.yml
echo "PASS: split stack config"

# --core-only: only on "core up"; refused for ran and for unknown flags before anything starts.
for args in "ran up --core-only" "core up --bogus" "core check --core-only"; do
  if out="$(scripts/split.sh $args 2>&1)"; then echo "FAIL: split.sh $args was accepted" >&2; exit 1; fi
  grep -qE "only 'split.sh core up --core-only' takes a flag|window length in seconds" <<<"$out" || { echo "FAIL: split.sh $args: $out" >&2; exit 1; }
done
echo "PASS: split.sh --core-only argument checks"

# TX gain guard on the split path (RADIO=uhd); the full matrix is in tests/tx-gain. Every case stops before any
# docker/network action: refused cases at the guard; the allowed case at the next check (unknown BENCH_RADIO).
gain() { env RF_SPLIT_OK=1 RADIO=uhd BENCH_RADIO=no-such-radio PROFILE=bench-split-20mhz-2t2r "$@" "$ROOT/scripts/split.sh" ran up 2>&1 || true; }
gain TX_GAIN=35 | grep -q "TX_GAIN 35 > limit 30" || { echo "FAIL: TX_GAIN=35 accepted without TX_GAIN_MAX" >&2; exit 1; }
gain TX_GAIN=35 TX_GAIN_MAX=41 | grep -q "TX_GAIN_MAX must be a plain integer <= 40" || { echo "FAIL: TX_GAIN_MAX=41 accepted" >&2; exit 1; }
gain TX_GAIN=41 TX_GAIN_MAX=40 | grep -q "TX_GAIN 41 > limit 40" || { echo "FAIL: TX_GAIN=41 accepted" >&2; exit 1; }
out=$(gain TX_GAIN=40 TX_GAIN_MAX=40); ! grep -q "TX_GAIN" <<< "$out" || { echo "FAIL: TX_GAIN=40 with TX_GAIN_MAX=40 refused: $out" >&2; exit 1; }
grep -q "no-such-radio" <<< "$out" || { echo "FAIL: allowed gain did not stop at BENCH_RADIO: $out" >&2; exit 1; }
echo "PASS: split.sh TX gain guard (30 default, TX_GAIN_MAX up to 40)"

# --core-only compose config: Open5GS files only — no fh network, no macvlan.
# Must match scripts/split.sh CORE_ONLY compose files (compose.yml + compose.cpu.yml).
( set -a; . docker/bench.env; . docker/split-core.env; set +a
  docker compose --env-file docker/versions.env --env-file docker/bench.env --env-file docker/split-core.env \
    -f docker/compose.yml -f docker/compose.cpu.yml --profile core config ) > "/tmp/split-core-only.$$.yml"
python3 - "/tmp/split-core-only.$$.yml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
nets = cfg.get("networks") or {}
assert "fh" not in nets, nets
for name, n in nets.items():
    assert (n or {}).get("driver") != "macvlan", (name, n)
svcs = cfg.get("services") or {}
assert "core" in svcs and "du" not in svcs and "protoru" not in svcs, list(svcs)
print("ok: core-only config services", sorted(svcs), "networks", sorted(nets))
PY
rm -f /tmp/split-core-only.$$.yml
echo "PASS: --core-only compose config has no fh/macvlan"

# Bench-host RU plan (docker/split-ran.env + bench-split profiles' ru_cpus): every planned CPU inside the RU container
# cpuset, the FIFO workers on isolated CPUs, and ru_phy_ul (5th in round-robin order radio, hp, tx, rx, ul) not
# on ru_radio's physical core (bench host i5-13600KF: P-core HT pairs n/n+1 for 0-11, E-cores 12-19 single), and
# no other planned thread on ru_radio's physical core.
python3 - "$ROOT" <<'PY'
import re, sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
env = {}
for f in ("docker/bench.env", "docker/split-ran.env"):
    for l in (root / f).read_text().splitlines():
        m = re.match(r'^([A-Z_][A-Z0-9_]*)=(.*)$', l)
        if m: env[m.group(1)] = m.group(2).strip().strip('"')
def cpus(s):
    out = set()
    for p in s.split(","):
        a, _, b = p.partition("-"); out |= set(range(int(a), int(b or a) + 1))
    return out
cset, isolated = cpus(env["PROTORU_CONTAINER_CPUSET"]), set(range(2, 12))
core = lambda c: c // 2 if c < 12 else c  # physical core id on the bench host
plan = dict(e.split("=") for e in env["BENCH_RU_THREADS"].split())
assert all(int(c) in cset for c in plan.values()), (plan, cset)
for t in ("ru_timing", "ru_emu_#0", "ru_rx_#0", "ru_ofh_tx_#0", "ru_phy_hp_#0", "ru_phy_tx_#0", "ru_phy_rx_#0", "ru_phy_ul_#0"):
    assert int(plan[t]) in isolated, (t, plan[t])
for prof in ("bench-split-20mhz", "bench-split-20mhz-2t2r"):
    sdr = yaml.safe_load((root / "profiles" / prof / "protoru.yml").read_text())["ru_emu"]["cells"][0]["sdr"]
    rc = sdr["ru_cpus"]; order = ["radio", "hp", "tx", "rx", "ul"]
    got = {w: rc[i % len(rc)] for i, w in enumerate(order)}
    assert set(rc) <= cset, (prof, rc, cset)
    assert core(got["ul"]) != core(got["radio"]), (prof, "ru_phy_ul shares ru_radio's physical core", rc)
    assert got["radio"] == int(plan["ru_radio_#0"]) and got["ul"] == int(plan["ru_phy_ul_#0"]), (prof, got, plan)
radio = int(plan["ru_radio_#0"])
others = [t for t, c in plan.items() if t != "ru_radio_#0" and core(int(c)) == core(radio)]
assert not others, ("threads share ru_radio's physical core", others)
assert not any(core(c) == core(radio) for c in cset - {radio}), ("cpuset holds ru_radio's HT sibling", sorted(cset))
print("PASS: split RU plan inside cpuset", sorted(cset), "| FIFO workers isolated | ru_cpus radio/ul (own cores)",
      got["radio"], got["ul"])
PY

# Reference on the split path (RADIO=uhd): REF, else the RU profile's clock_source; external needs ref_locked before
# anything starts. Every case stops at or before the lock check (unlocked helper), and docker is a stub that fails, so
# no container can start even on the bench host.
T="$(mktemp -d)"; X="test-ref-ext-$$"
trap 'rm -rf "$T" "$ROOT/profiles/$X" "$ROOT/build/local-profiles/$X"' EXIT
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "docker stub called: $*" >&2; exit 99\n' > "$T/bin/docker"
printf '#!/bin/sh\necho "ref_locked: unlocked"; exit 1\n' > "$T/unlocked"; chmod +x "$T/bin/docker" "$T/unlocked"
cp -r "$ROOT/profiles/bench-split-20mhz-2t2r" "$ROOT/profiles/$X"
sed -i 's/clock_source=internal/clock_source=external/; s/^\([[:space:]]*clock_source:\).*/\1 external/' "$ROOT/profiles/$X/protoru.yml"
ref() { env PATH="$T/bin:$PATH" UHD_REF_CHECK_HELPER="$T/unlocked" RF_SPLIT_OK=1 RADIO=uhd BENCH_RADIO=n310-20 TX_GAIN=30 "$@" "$ROOT/scripts/split.sh" ran up 2>&1 || true; }
out=$(ref PROFILE=bench-split-20mhz-2t2r REF=bogus); grep -q "reference must be internal or external" <<< "$out" || { echo "FAIL: REF=bogus: $out" >&2; exit 1; }
out=$(ref PROFILE="$X"); grep -q "split: ran: reference external" <<< "$out" && grep -q "N310 not locked to the external reference" <<< "$out" \
  || { echo "FAIL: profile clock_source external not honoured or unlocked accepted: $out" >&2; exit 1; }
grep -q "clock_source=external,time_source=internal" "$ROOT/build/local-profiles/$X/protoru.yml" \
  || { echo "FAIL: local profile not external 10 MHz / time internal" >&2; exit 1; }
out=$(ref PROFILE=bench-split-20mhz-2t2r REF=external); grep -q "N310 not locked to the external reference" <<< "$out" \
  || { echo "FAIL: REF=external override not checked: $out" >&2; exit 1; }
! grep -q "docker stub called" <<< "$out" || { echo "FAIL: docker was called before the lock check: $out" >&2; exit 1; }
grep -q "^clock_source=internal\|clock_source: internal" "$ROOT/profiles/bench-split-20mhz-2t2r/protoru.yml" || { echo "FAIL: committed profile changed" >&2; exit 1; }
echo "PASS: split.sh reference (profile clock_source or REF; external refused unless ref_locked, before any container)"
