#!/usr/bin/env python3
"""Unit tests for tools/bench/load_verify.py.

Two synthetic save archives cover the identity behaviour of the two Docker
stores: classic (image ID == config digest, config file "<hex>.json") and
containerd (OCI-style blobs; the engine-generated image ID differs on load).
"""
import io
import json
import pathlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from load_verify import check, config_digest_from_tar  # noqa: E402

CONFIG = json.dumps({"architecture": "amd64",
                     "config": {"Labels": {"org.openru.git.commit": "c843ff77",
                                           "org.openru.march": "x86-64-v3",
                                           "org.openru.uhd": "4.11.0.0"}}}).encode()
CONFIG_HEX = __import__("hashlib").sha256(CONFIG).hexdigest()


def _tar(path, members):
    with tarfile.open(path, "w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return path


def classic_archive(path, tag="openru/protoru:bench-c843ff77"):
    """docker-engine archive: manifest.json + <config-sha>.json (image ID == config digest)."""
    return _tar(path, {
        f"{CONFIG_HEX}.json": CONFIG,
        "manifest.json": json.dumps([{
            "Config": f"{CONFIG_HEX}.json", "RepoTags": [tag], "Layers": []}]).encode(),
    })


def containerd_archive(path, tag="openru/protoru:bench-c843ff77"):
    """OCI-style archive: index.json + manifest/config blobs (ID != config digest)."""
    manifest = json.dumps({"schemaVersion": 2,
                           "config": {"digest": f"sha256:{CONFIG_HEX}"},
                           "layers": []}).encode()
    man_hex = __import__("hashlib").sha256(manifest).hexdigest()
    index = json.dumps({"schemaVersion": 2, "manifests": [{
        "digest": f"sha256:{man_hex}", "size": len(manifest),
        "annotations": {"org.opencontainers.image.ref.name": tag}}]}).encode()
    return _tar(path, {
        "index.json": index,
        f"blobs/sha256/{man_hex}": manifest,
        f"blobs/sha256/{CONFIG_HEX}": CONFIG,
    })


LABELS = {"org.openru.git.commit": "c843ff77", "org.openru.march": "x86-64-v3",
          "org.openru.uhd": "4.11.0.0"}


def release(tag="openru/protoru:bench-c843ff77", config_digest=f"sha256:{CONFIG_HEX}"):
    return {"tag": "bench-c843ff77", "git_commit": "c843ff77", "images": [{
        "repo_tag": tag, "id": f"sha256:{CONFIG_HEX}", "labels": LABELS,
        "config_digest": config_digest, "file": "img.tar.gz"}]}


class LoadVerifyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_classic_and_containerd_archives_yield_the_same_config_digest(self):
        a = config_digest_from_tar(classic_archive(self.dir / "classic.tar.gz"))
        b = config_digest_from_tar(containerd_archive(self.dir / "containerd.tar.gz"))
        self.assertEqual(a["openru/protoru:bench-c843ff77"], f"sha256:{CONFIG_HEX}")
        self.assertEqual(b["openru/protoru:bench-c843ff77"], f"sha256:{CONFIG_HEX}")

    def test_classic_store_load_matches(self):
        rel = release()
        observed = {"openru/protoru:bench-c843ff77": {"id": f"sha256:{CONFIG_HEX}", "labels": LABELS}}
        errors, notes, rows = check(rel, observed, config_digest_from_tar(
            classic_archive(self.dir / "classic.tar.gz")))
        self.assertEqual(errors, [])
        self.assertEqual(notes, [])  # IDs equal: no containerd note
        self.assertEqual(rows[0]["loaded_id"], f"sha256:{CONFIG_HEX}")

    def test_containerd_store_load_matches_content_not_id(self):
        rel = release()
        other_id = "sha256:" + "ab" * 32  # what docker 29 + containerd reports on load
        observed = {"openru/protoru:bench-c843ff77": {"id": other_id, "labels": LABELS}}
        errors, notes, rows = check(rel, observed, config_digest_from_tar(
            containerd_archive(self.dir / "containerd.tar.gz")))
        self.assertEqual(errors, [])
        self.assertTrue(any("containerd image store" in n for n in notes))
        self.assertEqual(rows[0]["loaded_id"], other_id)

    def test_label_mismatch_fails(self):
        rel = release()
        bad = dict(LABELS, **{"org.openru.march": "x86-64-v4"})
        observed = {"openru/protoru:bench-c843ff77": {"id": f"sha256:{CONFIG_HEX}", "labels": bad}}
        errors, _, _ = check(rel, observed, {})
        self.assertTrue(any("org.openru.march" in e for e in errors))

    def test_config_digest_mismatch_fails(self):
        rel = release(config_digest="sha256:" + "cd" * 32)
        observed = {"openru/protoru:bench-c843ff77": {"id": f"sha256:{CONFIG_HEX}", "labels": LABELS}}
        errors, _, _ = check(rel, observed, config_digest_from_tar(
            classic_archive(self.dir / "classic.tar.gz")))
        self.assertTrue(any("config digest" in e for e in errors))

    def test_old_release_without_config_digest_only_checks_labels(self):
        rel = release()
        rel["images"][0].pop("config_digest")
        observed = {"openru/protoru:bench-c843ff77": {"id": "sha256:" + "ee" * 32, "labels": LABELS}}
        errors, notes, _ = check(rel, observed, {})
        self.assertEqual(errors, [])
        self.assertTrue(any("no config_digest" in n for n in notes))

    def test_not_loaded_fails(self):
        errors, _, _ = check(release(), {}, {})
        self.assertTrue(any("not loaded" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
