#!/usr/bin/env bash
# Provision bench subscribers in the Open5GS core from a local, restricted file.
#
#   scripts/add_subscriber.sh [--dry-run] [FILE]
#
# FILE defaults to ${OPENRU_SUBSCRIBERS_FILE:-$HOME/Desktop/OpenRU/secrets/subscribers.env}.
# It contains SIM credentials (K/OPc): never commit it, and make it owner-only
# (chmod 600). The script refuses a group/world-readable file, never prints K or
# OPc, and passes the documents to the core container over stdin (never argv).
#
# File format — one block per subscriber, blank line between blocks (placeholders):
#
#   imsi=001010000000001
#   k=<32 hex digits>
#   opc=<32 hex digits>
#   amf=8000          # optional, 1-4 hex digits (default 8000)
#   sst=1             # optional, must be 1 (the core allows slice 1 only)
#   dnn=internet      # optional, default "internet" (matches the modems)
#   qci=9             # optional, default 9
#   sqn=000000000060  # optional, 12 hex digits; not needed with AUTS resync
#
# The core container must be running (make BENCH=1 up UP_PROFILE=core).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

dry=0
file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "add_subscriber: unknown option: $1" >&2; exit 2 ;;
    *) file="$1"; shift ;;
  esac
done
file="${file:-${OPENRU_SUBSCRIBERS_FILE:-$HOME/Desktop/OpenRU/secrets/subscribers.env}}"

fail() { echo "add_subscriber: FAIL: $*" >&2; exit 1; }
[[ -f "$file" ]] || fail "subscriber file not found: $file (see docs/BENCH_SUBSCRIBERS.md)"
[[ -r "$file" ]] || fail "subscriber file is not readable: $file"
mode="$(stat -Lc '%a' "$file")"
if (( (8#$mode & 8#077) != 0 )); then
  fail "subscriber file is group/world accessible (mode $mode): chmod 600 \"$file\""
fi

# Validate and build the Open5GS subscriber documents (JSON on stdout; the plan
# goes to stderr; secrets never leave memory/stdin).
docs="$(python3 - "$file" "$dry" <<'PY'
import json, re, sys

path, dry = sys.argv[1], sys.argv[2] == "1"
blocks, cur = [], {}
for raw in open(path):
    line = raw.strip()
    if not line or line.startswith("#"):
        if cur:
            blocks.append(cur); cur = {}
        continue
    key, _, value = line.partition("=")
    key = key.strip().lower()
    if key:
        cur[key] = value.strip().strip('"\'')
if cur:
    blocks.append(cur)
if not blocks:
    sys.exit("add_subscriber: no subscriber blocks in the file")

HEX32 = re.compile(r"^[0-9a-fA-F]{32}$")
errors, docs = [], []
for i, b in enumerate(blocks, 1):
    imsi = b.get("imsi", "")
    if not re.fullmatch(r"\d{15}", imsi):
        errors.append(f"block {i}: imsi must be 15 digits")
        continue
    for fld in ("k", "opc"):
        if not HEX32.fullmatch(b.get(fld, "")):
            errors.append(f"block {i} (IMSI {imsi}): {fld} must be 32 hex digits")
    amf = b.get("amf", "8000")
    if not re.fullmatch(r"[0-9a-fA-F]{1,4}", amf):
        errors.append(f"block {i} (IMSI {imsi}): amf must be 1-4 hex digits")
    try:
        sst = int(b.get("sst", "1"))
        qci = int(b.get("qci", "9"))
    except ValueError:
        errors.append(f"block {i} (IMSI {imsi}): sst/qci must be integers")
        continue
    if sst != 1:
        errors.append(f"block {i} (IMSI {imsi}): sst must be 1 (core plmn_support allows 1 only)")
    dnn = b.get("dnn", "internet")
    if not dnn:
        errors.append(f"block {i} (IMSI {imsi}): dnn must not be empty")
    sqn = b.get("sqn")
    if sqn is not None and not re.fullmatch(r"[0-9a-fA-F]{12}", sqn):
        errors.append(f"block {i} (IMSI {imsi}): sqn must be 12 hex digits")

    doc = {
        "imsi": imsi,
        "subscribed_rau_tau_timer": 12,
        "network_access_mode": 2,
        "subscriber_status": 0,
        "access_restriction_data": 32,
        "ambr": {"uplink": {"value": 1, "unit": 3}, "downlink": {"value": 1, "unit": 3}},
        "security": {"k": b.get("k", ""), "amf": amf, "opc": b.get("opc", "")},
        "slice": [{
            "sst": sst,
            "default_indicator": True,
            "session": [{
                "name": dnn, "type": 3, "pcc_rule": [],
                "ambr": {"uplink": {"value": 1, "unit": 3}, "downlink": {"value": 1, "unit": 3}},
                "qos": {"index": qci, "arp": {"priority_level": 8,
                                              "pre_emption_capability": 1,
                                              "pre_emption_vulnerability": 1}},
                # No "ue" key: the SMF pool assigns the address. An empty
                # "ue.ipv4" makes Open5GS reject the UE (cause 7, "Cannot find SUPI").
            }],
        }],
        "schema_version": 1,
        "__v": 0,
    }
    if sqn:
        doc["sqn"] = sqn
    docs.append(doc)
    print(f"add_subscriber:   {imsi}  sst={sst} dnn={dnn} qci={qci}"
          + ("  sqn=<set>" if sqn else ""), file=sys.stderr)

if errors:
    for e in errors:
        print(f"add_subscriber: {e}", file=sys.stderr)
    sys.exit(1)
if dry:
    print(f"add_subscriber: {len(docs)} subscriber(s) validated (dry run, nothing written)",
          file=sys.stderr)
    sys.exit(0)
print(json.dumps(docs))
PY
)"

if (( dry )); then exit 0; fi

# Push the documents into the running core over stdin (no argv, no temp file).
if [[ "${BENCH:-0}" == "1" ]]; then
  compose=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ROOT/docker/bench.env"
           -f "$ROOT/docker/compose.yml" -f "$ROOT/docker/compose.cpu.yml")
else
  compose=(docker compose --env-file "$ROOT/docker/versions.env" --env-file "$ROOT/docker/lab.env"
           -f "$ROOT/docker/compose.yml")
fi
"${compose[@]}" ps -q core 2>/dev/null | grep -q . || {
  echo "add_subscriber: FAIL: the core container is not running (make BENCH=1 up UP_PROFILE=core)" >&2
  exit 1
}
printf '%s' "$docs" | "${compose[@]}" exec -T core python3 -c '
import json, sys
from pymongo import MongoClient
docs = json.load(sys.stdin)
col = MongoClient("mongodb://127.0.0.1:27017/")["open5gs"]["subscribers"]
for d in docs:
    r = col.update_one({"imsi": d["imsi"]}, {"$set": d}, upsert=True)
    print("add_subscriber: %s IMSI %s" % ("updated" if r.matched_count else "added", d["imsi"]))
'
echo "add_subscriber: done ($(printf '%s' "$docs" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') subscriber(s))"
