#!/usr/bin/env bash
# Fail closed if committed content contains remote-access details.
#
#   scripts/check_no_secrets.sh            # all git-tracked files (working tree)
#   scripts/check_no_secrets.sh --staged   # the index (for .git/hooks/pre-commit)
#   scripts/check_no_secrets.sh --paths F… # explicit files (unit tests)
#
# Rules (see AGENTS.md "Remote access (do not commit)"):
#   * Tailscale/CGNAT IPv4 100.x.x.x, tailnet names, the tailnet id fragment
#   * SSH key material (BEGIN OPENSSH / ssh-ed25519 / ssh-rsa)
#   * literal SSH targets: `HOST=<alias>` (placeholders like <bench-host>, $HOST and
#     quoted values are fine) and `ssh|scp|rsync … user@host`
#   * credential assignments: password=/passwd=/secret=/token=/api_key=
# Lab-private radio addresses (192.168.x.x) are allowed.
#
# The checker's own fixture file is skipped: it must contain the patterns.
# Escape hatch for a reviewed false positive: add `no-secrets-ok` on the same line.
# Install as a pre-commit hook:
#   printf '#!/bin/sh\nexec scripts/check_no_secrets.sh --staged\n' > .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode=tracked
paths=()
case "${1-}" in
  --staged) mode=staged ;;
  --paths) shift; mode=explicit; [[ $# -gt 0 ]] || { echo "usage: $0 --paths FILE..." >&2; exit 2; }; paths=("$@") ;;
  "") ;;
  *) echo "usage: $0 [--staged | --paths FILE...]" >&2; exit 2 ;;
esac

# One grep per pattern (line-by-line scanning of the 40k-line reports is too slow).
scan() { # <extended-regex> [case-insensitive]
  local pat="$1" icase="${2-}"
  local flags=(-nIE)
  [[ -n "$icase" ]] && flags=(-nIiE)
  case "$mode" in
    staged)   git grep --cached "${flags[@]}" -e "$pat" -- . ':!:external/proto-ru/**' ':!:scripts/check_no_secrets.sh' ':!:tools/bench/test_check_no_secrets.py' 2>/dev/null || true ;;
    tracked)  git grep "${flags[@]}" -e "$pat" -- . ':!:external/proto-ru/**' ':!:scripts/check_no_secrets.sh' ':!:tools/bench/test_check_no_secrets.py' 2>/dev/null || true ;;
    explicit) grep "${flags[@]}" -e "$pat" -- "${paths[@]}" 2>/dev/null || true ;;
  esac | grep -v 'no-secrets-ok' || true
}

fail=0
report() { # <label> <matches>
  local label="$1" matches="$2"
  [[ -n "$matches" ]] || return 0
  while IFS= read -r m; do
    echo "FAIL ${m%%:*}: ${label} — ${m#*:*:}" >&2
  done <<<"$matches"
  fail=1
}

report "Tailscale/CGNAT IPv4 (100.x.x.x)" "$(scan '(^|[^0-9])100\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)')"
report "tailscale/tailnet/ece107"          "$(scan 'tailscale|tailnet|ece107' i)"
report "SSH key material"                  "$(scan 'BEGIN OPENSSH|ssh-ed25519 |ssh-rsa ')"
report "SSH user@host"                     "$(scan '(^|[^[:alnum:]_])(ssh|scp|rsync)[^|;]*[[:space:]][A-Za-z0-9._-]+@[A-Za-z0-9.-]+')"
report "credential assignment"             "$(scan '(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*[^$<"'"'"'[:space:]]' i)"
report "literal HOST=<alias>"              "$(scan 'HOST=[A-Za-z0-9._-]+')"

if [[ "$fail" -ne 0 ]]; then
  echo "check_no_secrets: FAIL — host-specific access values belong in docker/bench.local.env (gitignored)." >&2
  exit 1
fi
echo "check_no_secrets: PASS"
