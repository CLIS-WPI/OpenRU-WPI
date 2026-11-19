#!/usr/bin/env python3
"""Verify a bench release on the load host.

Docker 29 with the containerd image store assigns different image IDs on
``docker load`` than the build host had. Image identity is therefore checked by
*content*:

  1. tarball SHA-256 (``sha256sum -c SHA256SUMS`` — done by the caller),
  2. the image config digest read from the tarball (classic ``manifest.json`` or
     OCI ``index.json`` layout),
  3. the provenance labels recorded in RELEASE.json (git commit, MARCH, UHD),
  4. loaded image IDs are recorded in the load report but are **not** required
     to equal the build host's IDs.

Usage:
  load_verify.py config-digest TAR [TAR ...]        # JSON {repo_tag: "sha256:..."}
  load_verify.py observe --release RELEASE.json --out OBSERVED.json
                                                    # docker inspect -> observed set
  load_verify.py check --release RELEASE.json --observed OBSERVED.json
                       [--release-dir DIR] [--report LOAD-REPORT.json]
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tarfile
from datetime import datetime, timezone


def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def config_digest_from_tar(tar_path: str) -> dict:
    """Map repo tag -> config digest, for docker-engine and OCI save layouts."""
    with tarfile.open(tar_path, "r:*") as tar:
        names = set(tar.getnames())

        def read(name: str) -> bytes:
            fh = tar.extractfile(name)
            if fh is None:
                raise ValueError(f"{tar_path}: {name} is not a regular file")
            return fh.read()

        if "manifest.json" in names:  # docker-engine archive (classic and containerd store)
            out = {}
            for entry in json.loads(read("manifest.json")):
                digest = _sha256(read(entry["Config"]))
                for tag in entry.get("RepoTags") or [None]:
                    out[tag] = digest
            return out

        if "index.json" in names:  # pure OCI layout
            out = {}
            index = json.loads(read("index.json"))
            for desc in index.get("manifests", []):
                manifest = json.loads(read("blobs/sha256/" + desc["digest"].split(":")[1]))
                tag = (desc.get("annotations") or {}).get("org.opencontainers.image.ref.name")
                out[tag] = _sha256(read("blobs/sha256/" + manifest["config"]["digest"].split(":")[1]))
            return out

        raise ValueError(f"{tar_path}: neither manifest.json nor index.json present")


def _tar_digests(release_dir: pathlib.Path, release: dict) -> dict:
    """config digests of the release tarballs (per repo tag)."""
    digests = {}
    for img in release.get("images", []):
        name = img.get("file")
        candidates = [release_dir / name] if name else []
        if not name:
            candidates = sorted(release_dir.glob("*.tar.gz"))
        for tar_path in candidates:
            if not tar_path.is_file():
                continue
            for tag, digest in config_digest_from_tar(str(tar_path)).items():
                if tag is None:
                    digests.setdefault(img["repo_tag"], digest)
                else:
                    digests[tag] = digest
    return digests


def observe(release: dict, out_path: str) -> int:
    """Write the loaded image set (id + labels) for the release images.

    The file is written with an explicit flush + fsync: the caller reads it back
    immediately (a plain ``open(...).write(...)`` without close/flush left an
    empty file on the bench host).
    """
    observed = {}
    for img in release.get("images", []):
        tag = img["repo_tag"]
        res = subprocess.run(["docker", "image", "inspect", tag, "--format",
                              "{{.Id}}\t{{json .Config.Labels}}"],
                             capture_output=True, text=True)
        if res.returncode != 0:
            print(f"FAIL {tag}: not loaded")
            continue
        image_id, labels = res.stdout.strip().split("\t", 1)
        observed[tag] = {"id": image_id, "labels": json.loads(labels) if labels else {}}
    with open(out_path, "w") as fh:
        json.dump(observed, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    if not observed:
        print("FAIL: no release image is loaded (empty observed set)", file=sys.stderr)
        return 1
    return 0


def check(release: dict, observed: dict, tar_digests: dict):
    errors: list[str] = []
    notes: list[str] = []
    rows = []
    for img in release.get("images", []):
        tag = img["repo_tag"]
        obs = observed.get(tag)
        row = {"repo_tag": tag, "build_id": img.get("id"), "loaded_id": None,
               "config_digest_release": img.get("config_digest"),
               "config_digest_tar": tar_digests.get(tag), "labels_ok": None}
        if obs is None:
            errors.append(f"{tag}: image not loaded")
            rows.append(row)
            continue
        row["loaded_id"] = obs.get("id")

        want_labels = img.get("labels") or {}
        if want_labels:
            bad = {k: (v, (obs.get("labels") or {}).get(k)) for k, v in want_labels.items()
                   if (obs.get("labels") or {}).get(k) != v}
            row["labels_ok"] = not bad
            for k, (want, got) in bad.items():
                errors.append(f"{tag}: label {k}={got!r} != release {want!r}")
        else:
            row["labels_ok"] = None
            notes.append(f"{tag}: no labels recorded in the release (label check skipped)")

        want_cfg = img.get("config_digest")
        got_cfg = tar_digests.get(tag)
        if want_cfg is None:
            notes.append(f"{tag}: release has no config_digest (older release) — label check only")
        elif got_cfg is None:
            errors.append(f"{tag}: could not read the config digest from the release tarball")
        elif got_cfg != want_cfg:
            errors.append(f"{tag}: tarball config digest {got_cfg} != release {want_cfg}")

        if obs.get("id") != img.get("id"):
            notes.append(f"{tag}: loaded ID {obs.get('id')} != build ID {img.get('id')} "
                         f"(containerd image store — identity verified by config digest)")
        rows.append(row)
    return errors, notes, rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_cfg = sub.add_parser("config-digest")
    p_cfg.add_argument("tars", nargs="+")
    p_obs = sub.add_parser("observe")
    p_obs.add_argument("--release", required=True)
    p_obs.add_argument("--out", required=True)
    p_chk = sub.add_parser("check")
    p_chk.add_argument("--release", required=True)
    p_chk.add_argument("--observed", required=True)
    p_chk.add_argument("--release-dir")
    p_chk.add_argument("--report")
    args = ap.parse_args()

    try:
        if args.cmd == "config-digest":
            out = {}
            for tar_path in args.tars:
                out.update(config_digest_from_tar(tar_path))
            print(json.dumps(out, indent=2))
            return 0

        if args.cmd == "observe":
            return observe(json.loads(pathlib.Path(args.release).read_text()), args.out)

        release = json.loads(pathlib.Path(args.release).read_text())
        observed_path = pathlib.Path(args.observed)
        if not observed_path.is_file() or observed_path.stat().st_size == 0:
            print(f"load_verify: observed set is missing or empty: {observed_path}", file=sys.stderr)
            return 2
        observed = json.loads(observed_path.read_text())
        if not observed:
            print(f"load_verify: observed set contains no images: {observed_path}", file=sys.stderr)
            return 2
        release_dir = pathlib.Path(args.release_dir or pathlib.Path(args.release).parent)
        tar_digests = _tar_digests(release_dir, release)
        errors, notes, rows = check(release, observed, tar_digests)

        for note in notes:
            print(f"[load] note: {note}")
        for err in errors:
            print(f"FAIL {err}", file=sys.stderr)
        if args.report:
            report = {
                "schema": "openru-bench-load-report/1",
                "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "release_tag": release.get("tag"),
                "git_commit": release.get("git_commit"),
                "submodule_commit": release.get("submodule_commit"),
                "host": "load-host",
                "images": rows,
                "ok": not errors,
                "notes": notes,
            }
            pathlib.Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
        if errors:
            return 1
        print(f"[load] release {release.get('tag')} verified: {len(rows)} image(s), "
              f"config digests and labels match")
        return 0
    except (ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"load_verify: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
