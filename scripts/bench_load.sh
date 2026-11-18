#!/usr/bin/env bash
# Load a bench release on the bench host.
#
#   scripts/bench_load.sh <release-dir>
#
# Verifies SHA256SUMS, docker-loads every tarball, checks the loaded image IDs
# against RELEASE.json, tags bench-latest and prints the release commit plus the
# OPENRU_TAG to use.
set -euo pipefail
DIR="${1:?usage: scripts/bench_load.sh <release-dir>}"
[[ -f "$DIR/RELEASE.json" && -f "$DIR/SHA256SUMS" ]] || {
  echo "FAIL: $DIR is not a bench release (RELEASE.json/SHA256SUMS missing)" >&2; exit 1; }
cd "$DIR"

echo "[load] verifying SHA256SUMS"
sha256sum -c SHA256SUMS

echo "[load] docker load"
for f in *.tar.gz; do
  [[ -e "$f" ]] || { echo "FAIL: no tarballs in $DIR" >&2; exit 1; }
  echo "[load]   $f"
  gzip -dc "$f" | docker load
done

python3 - "$DIR" <<'PY'
import json, subprocess, sys

data = json.load(open(f"{sys.argv[1]}/RELEASE.json"))
failed = 0
for img in data["images"]:
    out = subprocess.run(["docker", "image", "inspect", img["repo_tag"], "--format", "{{.Id}}"],
                         capture_output=True, text=True)
    got = out.stdout.strip()
    if out.returncode != 0 or got != img["id"]:
        print(f"FAIL {img['repo_tag']}: loaded {got or 'missing'}, release {img['id']}")
        failed = 1
    else:
        print(f"ok   {img['repo_tag']} {got[7:19]}")
        repo = img["repo_tag"].rsplit(":", 1)[0]
        subprocess.run(["docker", "tag", img["repo_tag"], f"{repo}:bench-latest"], check=True)

print(f"[load] release commit {data['git_commit']} ({data['git_branch']}), "
      f"submodule {data['submodule_commit']}")
print(f"[load] built {data['built_at']} on {data['built_on']}, UHD {data['build']['uhd_version']}, "
      f"MARCH {data['build']['march']}")
print(f"[load] use: export OPENRU_TAG={data['tag']}   (or OPENRU_TAG=bench-latest)")
sys.exit(failed)
PY

echo "[load] done — next: OPENRU_TAG=bench-latest make BENCH=1 bench-preflight"
