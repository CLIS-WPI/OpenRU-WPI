#!/usr/bin/env bash
# Fail closed if committed content contains remote-access details.
#
#   scripts/check_no_secrets.sh            # git-tracked first-party files
#   scripts/check_no_secrets.sh --staged   # index (pre-commit hook)
#
# Escape hatch: put `no-secrets-ok` on the same line as a reviewed false positive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode=tracked
case "${1-}" in
  --staged) mode=staged ;;
  "") ;;
  *) echo "usage: $0 [--staged]" >&2; exit 2 ;;
esac

# git grep is the scanner (line-by-line cat of 40k-line reports is too slow).
grep_cmd=(git grep -nI -E)
if [[ "$mode" == "staged" ]]; then
  grep_cmd+=(--cached)
fi
# First-party only.
grep_cmd+=(-- . ':!:external/proto-ru/**' ':!:scripts/check_no_secrets.sh')

fail=0
scan() {
  local pat="$1" msg="$2"
  local out
  out="$("${grep_cmd[@]}" "$pat" 2>/dev/null || true)"
  [[ -z "$out" ]] && return 0
  while IFS= read -r row; do
    [[ "$row" == *no-secrets-ok* ]] && continue
    echo "FAIL $row  ($msg)" >&2
    fail=1
  done <<< "$out"
}

scan '(^|[^0-9])100\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)' 'Tailscale/CGNAT IPv4 (100.x.x.x)'
scan 'tailscale|tailnet|ece107' 'tailscale/tailnet/ece107'
scan 'BEGIN OPENSSH|ssh-ed25519 |ssh-rsa ' 'SSH key material'
scan '(^|[^[:alnum:]_])(ssh|scp|rsync)[^|;]*[[:space:]][A-Za-z0-9._-]+@[A-Za-z0-9.-]+' 'SSH user@host'
scan 'HOST=[A-Za-z0-9._-]+' 'literal HOST=<alias> (use docker/bench.local.env)'
scan '(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*[^$<"'"'"'[:space:]]' 'credential assignment'

if [[ "$fail" -ne 0 ]]; then
  echo "check_no_secrets: FAIL — host-specific access values belong in docker/bench.local.env (gitignored)." >&2
  exit 1
fi
echo "check_no_secrets: PASS"
