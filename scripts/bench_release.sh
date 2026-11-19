#!/usr/bin/env bash
# Build, smoke-check and export a bench-image release.
#
#   make bench-release          (or: scripts/bench_release.sh)
#
# Refuses unless the working tree is clean, the submodule is at its recorded
# commit and HEAD is pushed to origin. Builds the bench image from that commit
# (UHD 4.11.0.0, x86-64-v3, FFTW + ESTIMATE, CUDA off), tags it
# openru/protoru:bench-<short-sha> + bench-latest, smoke-checks it (UHD version
# and a null-radio replay-golden baseline), then exports the images the bench
# needs into OPENRU_ARTIFACTS_DIR (outside the repo) with RELEASE.json +
# SHA256SUMS. Keeps the last BENCH_RELEASE_KEEP releases (default 5).
#
# Env: OPENRU_ARTIFACTS_DIR (docker/bench.local.env or $HOME/openru-artifacts)
#      BENCH_RELEASE_KEEP (default 5)
#      BENCH_RELEASE_SKIP_FETCH=1  verify against the cached origin refs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f "$ROOT/docker/bench.local.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$ROOT/docker/bench.local.env"
  set +a
fi

ART_ROOT="${OPENRU_ARTIFACTS_DIR:-$HOME/openru-artifacts}"
KEEP="${BENCH_RELEASE_KEEP:-5}"
LOCK=/tmp/openru-measure.lock
fail() { echo "[release] FAIL: $*" >&2; exit 1; }
step() { echo "[release] $*"; }

# ---------------------------------------------------------------- provenance --
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short >&2
  fail "working tree is dirty (a release must map to a public commit)"
fi
SUB_LINE="$(git submodule status --recursive | awk '/external\/proto-ru/ {print $1}')"
[[ -n "$SUB_LINE" ]] || fail "external/proto-ru submodule not initialised"
case "$SUB_LINE" in
  -*|+*) fail "submodule external/proto-ru is not at the recorded commit ($SUB_LINE) — run git submodule update --init" ;;
esac
SUBMODULE_COMMIT="$(git -C external/proto-ru rev-parse HEAD)"

if [[ "${BENCH_RELEASE_SKIP_FETCH:-0}" != "1" ]]; then
  step "fetching origin"
  timeout 300 git fetch --quiet origin || fail "git fetch failed (set BENCH_RELEASE_SKIP_FETCH=1 to use cached refs)"
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git rev-parse --verify -q "origin/$BRANCH" >/dev/null || fail "no origin/$BRANCH to compare against"
AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD")"
[[ "$AHEAD" -eq 0 ]] || fail "HEAD has $AHEAD commit(s) not pushed to origin/$BRANCH (push first)"

SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
TAG="bench-$SHORT"
IMG="openru/protoru:$TAG"
CORE_TAG="openru/core:$TAG"
DEST="$ART_ROOT/$TAG"

[[ -f docker/lab.env ]] || fail "docker/lab.env missing — the smoke replay needs this host's GPU/cpuset config"
if [[ -e "$LOCK" ]]; then
  fail "$LOCK exists (another measurement is running)"
fi
[[ -f testdata/golden/baseline/port0.cf32 ]] || fail "testdata/golden/baseline IQ missing — run make fetch-golden"

UHD_VERSION="$(sed -n 's/^UHD_VERSION=//p' docker/bench.env | head -1)"
MARCH="$(sed -n 's/^MARCH=//p' docker/bench.env | head -1)"
EXPECTED_MARCH="x86-64-v3"
[[ -n "$UHD_VERSION" && -n "$MARCH" ]] || fail "docker/bench.env must set UHD_VERSION and MARCH"
[[ "$MARCH" == "$EXPECTED_MARCH" ]] || fail "docker/bench.env MARCH=$MARCH != $EXPECTED_MARCH (the bench host has no AVX-512)"

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[release] commit  $SHA ($BRANCH, submodule $SUBMODULE_COMMIT)"
echo "[release] tag     $IMG (+ bench-latest), core $CORE_TAG"
echo "[release] config  UHD $UHD_VERSION, MARCH $MARCH, FFTW ESTIMATE, CUDA off"
echo "[release] dest    $DEST"

# --------------------------------------------------------------------- build --
mkdir -p "$DEST"
BUILD_LOG="$DEST/build.log"
step "building $IMG from $SHA (BENCH=1, log: $BUILD_LOG)"
# Make command-line assignments, not env: the Makefile includes lab.env /
# versions.env, and makefile assignments override the environment (lab.env has
# MARCH=x86-64-v4, versions.env has OPENRU_TAG=m2).
BENCH=1 OPENRU_GIT_COMMIT="$SHA" OPENRU_GIT_SUBMODULE="$SUBMODULE_COMMIT" OPENRU_BUILD_DATE="$BUILT_AT" \
  timeout 7200 make build-protoru OPENRU_TAG="$TAG" UHD_VERSION="$UHD_VERSION" MARCH="$MARCH" \
    EXTRA_CMAKE_ARGS="-DENABLE_FFTW=ON -DOPENRU_CUDA=OFF -DOPENRU_FFTW_ESTIMATE=ON" 2>&1 \
  | tee "$BUILD_LOG" || fail "image build failed"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "build finished but $IMG is missing"

step "building $CORE_TAG (Open5GS + provenance labels)"
BENCH=1 OPENRU_GIT_COMMIT="$SHA" OPENRU_GIT_SUBMODULE="$SUBMODULE_COMMIT" OPENRU_BUILD_DATE="$BUILT_AT" \
  timeout 1800 make build-core OPENRU_TAG="$TAG" 2>&1 | tee -a "$BUILD_LOG" || fail "core image build failed"
docker image inspect "$CORE_TAG" >/dev/null 2>&1 || fail "build finished but $CORE_TAG is missing"
docker tag "$IMG" openru/protoru:bench-latest
docker tag "$CORE_TAG" openru/core:bench-latest

# Provenance labels must name this commit (catches a stale tag).
LABEL_COMMIT="$(docker image inspect "$IMG" --format '{{index .Config.Labels "org.openru.git.commit"}}')"
[[ "$LABEL_COMMIT" == "$SHA" ]] || fail "image label org.openru.git.commit=$LABEL_COMMIT != $SHA"
CORE_LABEL_COMMIT="$(docker image inspect "$CORE_TAG" --format '{{index .Config.Labels "org.openru.git.commit"}}')"
[[ "$CORE_LABEL_COMMIT" == "$SHA" ]] || fail "core label org.openru.git.commit=$CORE_LABEL_COMMIT != $SHA"

# Hard architecture check: the builder log AND the image label must both say
# x86-64-v3 (the bench host has no AVX-512). On mismatch the freshly made bench
# tags are removed and the release stops before smoke/export.
step "check: architecture (builder log -DMARCH and image label org.openru.march)"
LABEL_MARCH="$(docker image inspect "$IMG" --format '{{index .Config.Labels "org.openru.march"}}')"
if ! python3 tools/bench/march_check.py --log "$BUILD_LOG" --label "$LABEL_MARCH" \
     --expect "$EXPECTED_MARCH" --json-out "$DEST/.march.json"; then
  echo "[release] FAIL: architecture check failed — removing the bench tags" >&2
  for t in "$IMG" openru/protoru:bench-latest "$CORE_TAG" openru/core:bench-latest; do
    docker rmi "$t" >/dev/null 2>&1 || true
  done
  rm -f "$DEST/.march.json"
  fail "built image is not $EXPECTED_MARCH (builder log / label mismatch)"
fi

# -------------------------------------------------------------- smoke checks --
step "smoke: uhd_config_info in $IMG"
CONT_UHD="$(docker run --rm --network none --entrypoint /bin/bash "$IMG" -lc \
  'uhd_config_info --version' 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ "$CONT_UHD" == "$UHD_VERSION" ]] || fail "container UHD '${CONT_UHD:-none}' != $UHD_VERSION"
echo "[release] smoke: UHD $CONT_UHD ok"

step "smoke: replay-golden baseline with the null radio (measurement lock held)"
echo "$$" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
# OPENRU_TAG on the command line: versions.env sets it (m2) otherwise.
OPENRU_MEASURE_LOCK_HELD=1 OPENRU_REPLAY_TAG="$TAG" \
  timeout 2400 make replay-golden OPENRU_TAG="$TAG" || fail "replay-golden smoke failed for $TAG"
rm -f "$LOCK"
trap - EXIT
echo "[release] smoke: replay-golden baseline PASS"

# -------------------------------------------------------------------- export --
mkdir -p "$DEST"
step "exporting images to $DEST"
: > "$DEST/.files.tmp"
for img_tag in "$IMG" "$CORE_TAG"; do
  name="$(printf '%s' "$img_tag" | tr '/:' '__').tar.gz"
  echo "[release] save $img_tag -> $name"
  docker save "$img_tag" | gzip -6 > "$DEST/$name.part" || fail "docker save $img_tag failed"
  mv "$DEST/$name.part" "$DEST/$name"
  printf '%s\n' "$name" >> "$DEST/.files.tmp"
done

HOSTNAME_FQ="$(hostname -f 2>/dev/null || hostname)"
python3 - "$DEST" "$SHA" "$SHORT" "$BRANCH" "$SUBMODULE_COMMIT" "$TAG" \
  "$UHD_VERSION" "$MARCH" "$BUILT_AT" "$HOSTNAME_FQ" "$CONT_UHD" "$ROOT" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys

dest = pathlib.Path(sys.argv[1])
sha, short, branch, submodule, tag, uhd, march, built_at, host, cont_uhd, root = sys.argv[2:13]
sys.path.insert(0, str(pathlib.Path(root) / "tools" / "bench"))
from load_verify import config_digest_from_tar

def image_info(repo_tag):
    out = subprocess.run(["docker", "image", "inspect", repo_tag, "--format",
                          '{{.Id}}\t{{json .RepoDigests}}\t{{.Size}}\t{{json .Config.Labels}}'],
                         capture_output=True, text=True, check=True).stdout.strip()
    image_id, digests, size, labels = out.split("\t")
    tarball = pathlib.Path(repo_tag.replace("/", "_").replace(":", "_") + ".tar.gz")
    cfg = config_digest_from_tar(str(dest / tarball)).get(repo_tag)
    labels = json.loads(labels) if labels else {}
    return {"repo_tag": repo_tag, "id": image_id,
            "repo_digests": json.loads(digests), "size_bytes": int(size),
            "file": tarball.name,
            "config_digest": cfg,
            "labels": {k: v for k, v in labels.items() if k.startswith("org.openru.")}}

files = []
for name in (dest / ".files.tmp").read_text().split():
    p = dest / name
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    files.append({"name": name, "size_bytes": p.stat().st_size, "sha256": h.hexdigest()})

release = {
    "schema": "openru-bench-release/1",
    "tag": tag,
    "git_commit": sha,
    "git_short": short,
    "git_branch": branch,
    "submodule_commit": submodule,
    "built_at": built_at,
    "built_on": host,
    "build": {
        "image": "docker/bench.env + docker/compose.cpu.yml",
        "uhd_version": uhd,
        "march": march,
        "fftw": "ESTIMATE",
        "cuda": "OFF",
    },
    "march_check": json.loads((dest / ".march.json").read_text()),
    "smoke": {
        "uhd_config_info": cont_uhd,
        "replay_golden_baseline": "PASS (null radio, 4000 slots, 0 differing)",
    },
    "images": [image_info(f"openru/protoru:{tag}"), image_info(f"openru/core:{tag}")],
    "core_image_source": "openru/core:m0 retagged for this release (built from the recorded submodule)",
    "files": files,
}
(dest / "RELEASE.json").write_text(json.dumps(release, indent=2) + "\n")
(dest / ".march.json").unlink()
(dest / "SHA256SUMS").write_text("".join(f"{f['sha256']}  {f['name']}\n" for f in files))
(dest / ".files.tmp").unlink()
print(f"[release] wrote RELEASE.json ({len(files)} tarballs) and SHA256SUMS")
PY

# ----------------------------------------------------------------- retention --
IN_USE_TAG="$(sed -n 's/^OPENRU_TAG=//p' docker/bench.env | head -1)"
step "retention: keep $KEEP releases (in-use tag: ${IN_USE_TAG:-none})"
python3 - "$ART_ROOT" "$KEEP" "$TAG" "${IN_USE_TAG:-}" <<'PY'
import json, pathlib, shutil, sys

root = pathlib.Path(sys.argv[1]); keep = int(sys.argv[2]); current = sys.argv[3]; in_use = sys.argv[4]
releases = []
for d in sorted(root.glob("bench-*")):
    manifest = d / "RELEASE.json"
    if not manifest.exists():
        continue
    try:
        data = json.loads(manifest.read_text())
    except json.JSONDecodeError:
        continue
    releases.append((data.get("built_at", ""), d, data.get("tag", d.name)))
releases.sort(reverse=True)
protected = {current}
if in_use.startswith("bench-"):
    protected.add(in_use)
removed = 0
for built_at, d, tag in releases[keep:]:
    if tag in protected:
        print(f"[release] keep {d.name} (in use)")
        continue
    shutil.rmtree(d)
    print(f"[release] removed {d.name} ({built_at})")
    removed += 1
print(f"[release] retention: {len(releases)} releases, {removed} removed, kept "
      f"{[d.name for _, d, _ in releases[:keep]]}")
PY

echo
echo "[release] DONE: $TAG"
echo "  artifacts: $DEST"
echo "  next:      make bench-ship HOST=<bench-host>   (or copy $DEST to the bench host)"
echo "             on the bench: scripts/bench_load.sh $(basename "$DEST")"
echo "             then: OPENRU_TAG=$TAG make BENCH=1 bench-preflight"
