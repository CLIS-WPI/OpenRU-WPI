#!/usr/bin/env bash
# Copy a captured log into evidence after redaction.
# Usage: save_evidence_log.sh <source> <destination>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:?source log required}"
dst="${2:?destination required}"
[[ -f "$src" ]] || exit 0
mkdir -p "$(dirname "$dst")"
"$ROOT/scripts/redact_secrets.sh" < "$src" > "$dst"
