# Bench host: move Docker/containerd storage to /home, prune UHD SD images (prepared, not run)

Status: **prepared 2026-11-20, not run.** For the human to schedule; bench down for ~20 minutes, no RF.

## Why

The bench host's `/` is 92 GB and was at 5.1 GB free on 2026-11-20 (one `docker load` filled it to 220 MB).
`/home` is a separate partition with ~620 GB free. Bench runs now refuse to start below 10 GB free
(`scripts/bench_disk_check.sh`).

What sits on `/` (measured 2026-11-20):

| Path | Size | What |
|---|---|---|
| `/var/lib/containerd` | ~27 GB | **all images** (Docker 29 uses the containerd image store: content 11 GB + overlayfs snapshots 16 GB) |
| `/var/lib/docker` | ~0.4 GB real | volumes (DU/RU logs, Open5GS DB), containers, buildkit, network. `rootfs/` shows 17 GB in `du` but that is only the running containers' mounted root filesystems |
| `/usr/share/uhd/4.10.0/images` | 15.9 GB | N3xx SD-card filesystem image **v4.10** (`usrp_n3xx_fs.sdimg`); not owned by a package |
| `/usr/local/share/uhd/images` | 15.9 GB | N3xx SD-card filesystem image **v4.11** (the host UHD 4.11's images dir) |

Moving only Docker's `data-root` (the earlier proposal in `docs/BENCH_BUNDLE.md`) would leave the images on `/`:
with the containerd image store, **containerd's `root` has to move too**.

## UHD images the bench needs

- At run time: **none** on the host. The N310 loads its FPGA image from its own SD card; ProtO-RU runs UHD 4.11
  inside the container.
- For maintenance only: the **v4.11 N3xx SD image** (`/usr/local/share/uhd/images`), to reflash the N310's SD card
  if `bench-preflight` reports an MPM/filesystem mismatch with UHD 4.11. No other device family (X3xx/X4xx/B2xx/E3xx)
  is present in either directory.
- The **v4.10** SD image (`/usr/share/uhd/4.10.0/images`, inventory `meta-ettus-v4.10.0.0`) matches the packaged
  uhd-host 4.10, which the bench does not use. Deleting it frees **15.9 GB**.
  Optional: move the v4.11 image to `/home/uhd-images/` and symlink it back (frees another 15.9 GB on `/`).

Expected free space on `/` afterwards: ~5 GB now + ~27 GB (containerd and Docker) + 15.9 GB (v4.10 SD image)
= **~48 GB**, or **~64 GB** with the v4.11 image moved too.

## Changes

`/etc/docker/daemon.json` (the file does not exist today):

```json
{
  "data-root": "/home/docker-data/docker"
}
```

`/etc/containerd/config.toml`: the only change is the `root` line, which is commented out today (default
`/var/lib/containerd`):

```toml
root = "/home/docker-data/containerd"
```

systemd drop-ins, so neither daemon starts before `/home` is mounted:

```ini
# /etc/systemd/system/containerd.service.d/home-storage.conf and /etc/systemd/system/docker.service.d/home-storage.conf
[Unit]
RequiresMountsFor=/home/docker-data
```

## Procedure (root on the bench host; times in America/New_York)

```bash
set -euo pipefail
B=<bench-notes dir>/$(date +%F)-disk-move; mkdir -p "$B"      # any directory on /home

# 0. Bench down, nothing running
test "$(docker ps -q | wc -l)" = 0 && test "$(docker network ls --filter name=openru -q | wc -l)" = 0

# 1. Record the before state
docker image ls --no-trunc --digests --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Digest}}' | sort > "$B/images-before.txt"
ctr -n moby images ls -q | sort > "$B/ctr-images-before.txt"
ctr -n moby content ls -q | sort > "$B/ctr-content-before.txt"
docker volume ls -q | sort > "$B/volumes-before.txt"
df -h / /home > "$B/df-before.txt"
cp -a /etc/containerd/config.toml "$B/config.toml.orig"

# 2. Stop (socket first so nothing re-activates docker)
systemctl stop docker.socket docker.service containerd.service
findmnt -rn -o TARGET | grep -E '^/var/lib/(docker|containerd)/' && { echo "mounts left, stop"; exit 1; } || true

# 3. Copy (originals stay in place untouched until step 7)
mkdir -p /home/docker-data
rsync -aHAX --numeric-ids --sparse /var/lib/containerd/ /home/docker-data/containerd/
rsync -aHAX --numeric-ids --sparse --exclude '/rootfs/*' /var/lib/docker/ /home/docker-data/docker/
mkdir -p /home/docker-data/docker/rootfs
# verify: a second pass must have nothing to transfer
rsync -aHAXn --numeric-ids --itemize-changes /var/lib/containerd/ /home/docker-data/containerd/ | tee "$B/rsync-verify-containerd.txt"
rsync -aHAXn --numeric-ids --itemize-changes --exclude '/rootfs/*' /var/lib/docker/ /home/docker-data/docker/ | tee "$B/rsync-verify-docker.txt"
test ! -s "$B/rsync-verify-containerd.txt" && test ! -s "$B/rsync-verify-docker.txt"

# 4. Configure
printf '{\n  "data-root": "/home/docker-data/docker"\n}\n' > /etc/docker/daemon.json
sed -i 's|^#root = "/var/lib/containerd"$|root = "/home/docker-data/containerd"|' /etc/containerd/config.toml
grep -n '^root = "/home/docker-data/containerd"$' /etc/containerd/config.toml
for s in containerd docker; do
  mkdir -p /etc/systemd/system/$s.service.d
  printf '[Unit]\nRequiresMountsFor=/home/docker-data\n' > /etc/systemd/system/$s.service.d/home-storage.conf
done
systemctl daemon-reload

# 5. Start and check the roots
systemctl start containerd docker.socket docker
docker info -f '{{.DockerRootDir}}'                                   # /home/docker-data/docker
containerd config dump | grep -E '^root = '                          # root = "/home/docker-data/containerd"
```

## Checks afterwards

```bash
docker image ls --no-trunc --digests --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Digest}}' | sort > "$B/images-after.txt"
ctr -n moby images ls -q | sort > "$B/ctr-images-after.txt"
ctr -n moby content ls -q | sort > "$B/ctr-content-after.txt"
docker volume ls -q | sort > "$B/volumes-after.txt"
for f in images ctr-images ctr-content volumes; do diff "$B/$f-before.txt" "$B/$f-after.txt" && echo "same: $f"; done
docker run --rm --network none openru/protoru:bench-latest uhd_config_info --version   # UHD 4.11.0.0
# as the bench user, in the bench checkout:
#   OPENRU_TAG=bench-latest make BENCH=1 bench-preflight          # PASS (no RF)
df -h / /home | tee "$B/df-after.txt"
```

Pass criteria:

- all four lists are identical, so the images have the same IDs and digests;
- the container reports UHD 4.11;
- `bench-preflight` PASS;
- the volumes are listed.

Then one null-radio bring-up (`RADIO=null scripts/split.sh ran up` / `down`) as a functional check.

## Step 7 (after a passing run, a separate step): free `/`

```bash
rm -rf /var/lib/containerd.pre-move /var/lib/docker.pre-move 2>/dev/null || true
mv /var/lib/containerd /var/lib/containerd.pre-move && mv /var/lib/docker /var/lib/docker.pre-move   # keep a day
# later: rm -rf /var/lib/containerd.pre-move /var/lib/docker.pre-move                              # ~27 GB on /
rm /usr/share/uhd/4.10.0/images/usrp_n3xx_fs.sdimg /usr/share/uhd/4.10.0/images/usrp_n3xx_fs.sdimg.bmap   # 15.9 GB
```

Moving with `mv` first (rather than deleting) keeps the rollback below possible until the final `rm`.

## Rollback (any time before the final rm)

```bash
systemctl stop docker.socket docker.service containerd.service
rm -f /etc/docker/daemon.json /etc/systemd/system/{containerd,docker}.service.d/home-storage.conf
cp -a "$B/config.toml.orig" /etc/containerd/config.toml
[ -d /var/lib/containerd.pre-move ] && mv /var/lib/containerd.pre-move /var/lib/containerd
[ -d /var/lib/docker.pre-move ] && mv /var/lib/docker.pre-move /var/lib/docker
systemctl daemon-reload && systemctl start containerd docker.socket docker
docker info -f '{{.DockerRootDir}}'   # /var/lib/docker; then the same image/volume diff as above
```

## Paths that change

Docker volumes move from `/var/lib/docker/volumes/...` to `/home/docker-data/docker/volumes/...`.

- No script in this repo hard-codes the old path.
- The bench-notes runners on the bench host do (`ab_timing.sh`, `trace_wake.sh` and others). They should read the
  path with `docker volume inspect -f '{{.Mountpoint}}' openru_protoru-logs`.
- Logs written during runs then land on `/home`. `bench_disk_check.sh` checks both `/` and Docker's data root.
