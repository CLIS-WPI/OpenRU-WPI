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
