#!/usr/bin/env bash
# Copy one bench release to the bench host over SSH (rsync).
#
#   make bench-ship [HOST=<ssh-host>] [RELEASE=/path/to/bench-<sha>]
#
# HOST defaults from docker/bench.local.env (gitignored); do not put host aliases
# or Tailscale addresses in git.  <!-- no-secrets-ok -->
# If the host is not reachable in batch mode,
# prints the manual copy steps.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/docker/bench.local.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  _host_from_cli="${HOST-}"
  source "$ROOT/docker/bench.local.env"
  if [[ -n "$_host_from_cli" ]]; then HOST="$_host_from_cli"; fi
  set +a
  unset _host_from_cli
fi
HOST="${HOST:?usage: HOST=<ssh-host> scripts/bench_ship.sh (or make bench-ship; or docker/bench.local.env)}"
ART_ROOT="${OPENRU_ARTIFACTS_DIR:-$HOME/openru-artifacts}"
REMOTE_DIR="${BENCH_REMOTE_DIR:-openru-artifacts}"

if [[ -n "${RELEASE:-}" ]]; then
  DIR="$RELEASE"
else
  DIR=""
  for d in $(ls -dt "$ART_ROOT"/bench-*/ 2>/dev/null); do
    if [[ -f "$d/RELEASE.json" ]]; then DIR="$d"; break; fi
  done
fi
[[ -n "$DIR" && -f "$DIR/RELEASE.json" ]] || {
  echo "FAIL: no release found (run make bench-release, or pass RELEASE=<dir>)" >&2; exit 1; }

manual() {
  cat >&2 <<EOF
Manual copy (no SSH batch access to $HOST):
  rsync -av --info=progress2 "$DIR/" $HOST:~/$REMOTE_DIR/$(basename "$DIR")/
  # or: tar -C "$(dirname "$DIR")" -czf - "$(basename "$DIR")" | ssh $HOST 'tar -C ~/$REMOTE_DIR -xzf -'
On the bench host:
  cd ~/$REMOTE_DIR/$(basename "$DIR")
  scripts/bench_load.sh .     # from the openru-sw checkout
EOF
}

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
  echo "[ship] $HOST is not reachable over SSH in batch mode."
  manual
  exit 1
fi

REMOTE_PATH="~/$REMOTE_DIR/$(basename "$DIR")"
echo "[ship] $DIR -> $HOST:$REMOTE_PATH"
ssh -o BatchMode=yes "$HOST" "mkdir -p ~/$REMOTE_DIR"
if ! rsync -a --info=progress2 "$DIR/" "$HOST:$REMOTE_PATH/"; then
  echo "[ship] rsync failed (missing on the remote?) — falling back to tar over ssh" >&2
  tar -C "$(dirname "$DIR")" -czf - "$(basename "$DIR")" | ssh -o BatchMode=yes "$HOST" "mkdir -p ~/$REMOTE_DIR && tar -C ~/$REMOTE_DIR -xzf -"
fi
ssh -o BatchMode=yes "$HOST" "cd $REMOTE_PATH && sha256sum -c SHA256SUMS >/dev/null && echo '[ship] remote SHA256SUMS verified'"
echo "[ship] done — on $HOST: scripts/bench_load.sh $(basename "$DIR")"
