#!/usr/bin/env bash
# Refuse a bench start when / or Docker's data root has less than BENCH_MIN_FREE_GB (default 10) free: the DU and
# ProtO-RU logs grow inside Docker volumes during a run, and a full / stops the stack mid-run.
set -euo pipefail
min=${BENCH_MIN_FREE_GB:-10}
root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
for p in / "$root"; do
  [[ -e "$p" ]] || continue
  avail_kb=$(df -Pk "$p" | awk 'NR == 2 {print $4}')
  (( avail_kb >= min * 1048576 )) || {
    echo "[disk] FAIL: $p has $((avail_kb / 1048576)) GB free; bench runs need >= $min GB (BENCH_MIN_FREE_GB)" >&2; exit 1; }
done
echo "[disk] OK: / and $root have >= $min GB free"
