#!/usr/bin/env bash
# Load a bench release on the bench host.
#
#   scripts/bench_load.sh <release-dir>
#
# Verifies the tarball SHA-256 (integrity), docker-loads every tarball, then
# verifies the loaded images by content, not by image ID: the config digest read
# from the tarball plus the provenance labels recorded in RELEASE.json must
# match. Docker 29 with the containerd image store assigns different image IDs
# on load than the build host had; IDs are recorded in LOAD-REPORT.json but are
# not required to be equal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:?usage: scripts/bench_load.sh <release-dir>}"
[[ -f "$DIR/RELEASE.json" && -f "$DIR/SHA256SUMS" ]] || {
  echo "FAIL: $DIR is not a bench release (RELEASE.json/SHA256SUMS missing)" >&2; exit 1; }
cd "$DIR"

echo "[load] verifying SHA256SUMS (tarball integrity)"
sha256sum -c SHA256SUMS

echo "[load] docker load"
for f in *.tar.gz; do
  [[ -e "$f" ]] || { echo "FAIL: no tarballs in $DIR" >&2; exit 1; }
  echo "[load]   $f"
  gzip -dc "$f" | docker load
done

echo "[load] verifying images by content (config digest + labels)"
OBSERVED="$(mktemp)"
trap 'rm -f "$OBSERVED"' EXIT
python3 - "$DIR" "$OBSERVED" <<'PY'
import json, subprocess, sys

release = json.load(open(f"{sys.argv[1]}/RELEASE.json"))
observed = {}
for img in release["images"]:
    tag = img["repo_tag"]
    out = subprocess.run(["docker", "image", "inspect", tag, "--format",
                          "{{.Id}}\t{{json .Config.Labels}}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(f"FAIL {tag}: not loaded")
        continue
    image_id, labels = out.stdout.strip().split("\t", 1)
    observed[tag] = {"id": image_id, "labels": json.loads(labels) if labels else {}}
open(sys.argv[2], "w").write(json.dumps(observed, indent=2) + "\n")
PY
python3 "$ROOT/tools/bench/load_verify.py" check \
  --release "$DIR/RELEASE.json" --observed "$OBSERVED" \
  --release-dir "$DIR" --report "$DIR/LOAD-REPORT.json"

python3 - "$DIR" <<'PY'
import json, subprocess, sys

data = json.load(open(f"{sys.argv[1]}/RELEASE.json"))
for img in data["images"]:
    repo = img["repo_tag"].rsplit(":", 1)[0]
    subprocess.run(["docker", "tag", img["repo_tag"], f"{repo}:bench-latest"], check=False)
print(f"[load] release commit {data['git_commit']} ({data['git_branch']}), "
      f"submodule {data['submodule_commit']}")
print(f"[load] built {data['built_at']} on {data['built_on']}, UHD {data['build']['uhd_version']}, "
      f"MARCH {data['build']['march']}")
print(f"[load] use: export OPENRU_TAG={data['tag']}   (or OPENRU_TAG=bench-latest)")
PY

echo "[load] load report: $DIR/LOAD-REPORT.json"
echo "[load] done — next: OPENRU_TAG=bench-latest make BENCH=1 bench-preflight"
