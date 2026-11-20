#!/usr/bin/env bash
# Bench profiles: DU and ProtO-RU agree on DL/UL/PRACH eAxC ports, and the DU antenna counts match them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT"/profiles/bench-* <<'PY'
import pathlib, sys, yaml
def ports(cell): return tuple(tuple(cell[k]) for k in ("dl_port_id", "ul_port_id", "prach_port_id"))
for d in map(pathlib.Path, sys.argv[1:]):
    ru = {f: yaml.safe_load((d / f).read_text())["ru_emu"]["cells"][0] for f in ("protoru.yml", "protoru-null.yml") if (d / f).exists()}
    for f in ("du-core.yml", "du-fh.yml"):
        if not (d / f).exists(): continue
        du = yaml.safe_load((d / f).read_text())
        c = du["ru_ofh"]["cells"][0]; cc = du["cell_cfg"]
        for rf, rc in ru.items():
            assert ports(c) == ports(rc), f"{d.name}: {f} ports {ports(c)} != {rf} {ports(rc)}"
        assert cc["nof_antennas_dl"] == len(c["dl_port_id"]), f"{d.name}/{f}: nof_antennas_dl vs dl_port_id"
        assert cc["nof_antennas_ul"] == len(c["ul_port_id"]), f"{d.name}/{f}: nof_antennas_ul vs ul_port_id"
        rank = cc.get("pdsch", {}).get("max_rank")
        assert rank is None or rank <= cc["nof_antennas_dl"], f"{d.name}/{f}: max_rank {rank} > nof_antennas_dl"
    print(f"ok {d.name}")
PY
echo "PASS: bench profile ports consistent"
