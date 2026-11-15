#!/usr/bin/env bash
# Fetch golden IQ blobs (not stored in plain git) and verify SHA256 against MANIFEST.json.
# Usage:
#   OPENRU_GOLDEN_URL=https://.../openru-goldens make fetch-golden
#   OPENRU_GOLDEN_URL=/mnt/share/openru-goldens make fetch-golden
# Layout at URL/path: <profile>/portN.cf32 (and optional iq_meta.json / tx_index.jsonl).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${OPENRU_GOLDEN_URL:?Set OPENRU_GOLDEN_URL to an https:// or local directory of goldens}"
PROFILES="${PROFILES:-baseline b40 b100}"

fetch_one() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ "$BASE" == http://* || "$BASE" == https://* ]]; then
    curl -fsSL "$src" -o "$dst"
  else
    cp -f "$src" "$dst"
  fi
}

python3 - <<'PY' "$ROOT" "$BASE" $PROFILES
import hashlib, json, sys, urllib.request, shutil
from pathlib import Path

root = Path(sys.argv[1])
base = sys.argv[2]
profiles = sys.argv[3:]

def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def fetch(src: str, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if base.startswith("http://") or base.startswith("https://"):
        urllib.request.urlretrieve(src, dst)
    else:
        shutil.copy2(src, dst)

ok = True
for prof in profiles:
    man_path = root / "testdata" / "golden" / prof / "MANIFEST.json"
    if not man_path.exists():
        print(f"FAIL: missing {man_path}")
        ok = False
        continue
    man = json.loads(man_path.read_text())
    files = man.get("files") or {k: {"sha256": v} for k, v in man.get("SHA256", {}).items()}
    for name, meta in files.items():
        if not name.startswith("port"):
            # Small sidecars may already be in git; still verify if present remotely.
            pass
        expect = meta["sha256"] if isinstance(meta, dict) else meta
        dst = root / "testdata" / "golden" / prof / name
        src = f"{base.rstrip('/')}/{prof}/{name}"
        if not base.startswith("http") and not Path(src).exists():
            # Allow local tree that only ships large blobs
            if dst.exists() and sha256(dst) == expect:
                print(f"OK cached {prof}/{name}")
                continue
            print(f"FAIL: missing source {src}")
            ok = False
            continue
        print(f"fetch {prof}/{name}")
        fetch(src, dst)
        got = sha256(dst)
        if got != expect:
            print(f"FAIL: {prof}/{name} sha256 {got} != {expect}")
            ok = False
        else:
            print(f"OK {prof}/{name}")
if not ok:
    sys.exit(1)
print("fetch-golden: all checksums OK")
PY
