#!/usr/bin/env bash
# Side-by-side DU vs Open5GS AMF PLMN/TAC/slice compare.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DU_YML="${1:-$ROOT/profiles/baseline/du-core.yml}"
AMF_YML="${2:-$ROOT/external/proto-ru/docker/open5gs/open5gs-5gc.yml}"
OUT="${3:-}"

REPORT="$(python3 - "$DU_YML" "$AMF_YML" <<'PY'
import sys, re
from pathlib import Path

du_txt = Path(sys.argv[1]).read_text()
amf_txt = Path(sys.argv[2]).read_text()

def first(rx, txt, flags=re.M):
    m = re.search(rx, txt, flags)
    return m.group(1).strip() if m else "?"

du_plmn = first(r'cell_cfg:.*?^\s*plmn:\s*"?(\d+)"?', du_txt, re.M | re.S)
du_tac = first(r'cell_cfg:.*?^\s*tac:\s*(\d+)', du_txt, re.M | re.S)
# slice under supported_tracking_areas
sst_m = re.search(r'tai_slice_support_list:\s*\n\s*-\s*sst:\s*(\d+)(.*?)(?=\n\s{0,8}-|\n\s{0,4}\w|\Z)', du_txt, re.S)
du_sst = sst_m.group(1) if sst_m else first(r'sst:\s*(\d+)', du_txt)
du_sd = "(none)"
if sst_m and re.search(r'^\s*sd:\s*(\d+)', sst_m.group(2), re.M):
    du_sd = re.search(r'^\s*sd:\s*(\d+)', sst_m.group(2), re.M).group(1)

amf_mcc = first(r'^amf:.*?guami:.*?mcc:\s*(\d+)', amf_txt, re.M | re.S)
amf_mnc = first(r'^amf:.*?guami:.*?mnc:\s*(\d+)', amf_txt, re.M | re.S)
amf_tac = first(r'^amf:.*?tai:.*?tac:\s*(\d+)', amf_txt, re.M | re.S)
amf_sst = first(r'^amf:.*?plmn_support:.*?sst:\s*(\d+)', amf_txt, re.M | re.S)
amf_sd = "(none)"
if re.search(r'^amf:.*?plmn_support:.*?s_nssai:.*?^\s*sd:\s*(\d+)', amf_txt, re.M | re.S):
    amf_sd = first(r'^amf:.*?plmn_support:.*?sd:\s*(\d+)', amf_txt, re.M | re.S)
amf_plmn = f"{amf_mcc}{amf_mnc}"

lines = []
lines.append("=== PLMN / TAC / slice side-by-side ===")
lines.append(f"{'field':<12} {'DU':<16} {'Open5GS AMF':<16}")
lines.append(f"{'-'*12} {'-'*16} {'-'*16}")
lines.append(f"{'plmn':<12} {du_plmn:<16} {amf_plmn:<16}")
lines.append(f"{'tac':<12} {du_tac:<16} {amf_tac:<16}")
lines.append(f"{'sst':<12} {du_sst:<16} {amf_sst:<16}")
lines.append(f"{'sd':<12} {du_sd:<16} {amf_sd:<16}")
lines.append("")
lines.append(f"AMF guami: MCC={amf_mcc} MNC={amf_mnc}; tai.tac={amf_tac}; plmn_support S-NSSAI sst={amf_sst} sd={amf_sd}")
lines.append(f"DU cell_cfg plmn={du_plmn} tac={du_tac}; supported_tracking_areas SST={du_sst} SD={du_sd}")
ok = (
    du_plmn == amf_plmn == "00101"
    and du_tac == amf_tac
    and du_sst == amf_sst == "1"
    and du_sd == amf_sd == "(none)"
)
lines.append("ALIGN: " + ("OK" if ok else "MISMATCH"))
print("\n".join(lines))
sys.exit(0 if ok else 1)
PY
)"
status=$?
printf '%s\n' "$REPORT"
if [[ -n "$OUT" ]]; then
  {
    echo "## PLMN / TAC / slice compare"
    echo
    echo '```'
    printf '%s\n' "$REPORT"
    echo '```'
  } >>"$OUT"
fi
exit $status
