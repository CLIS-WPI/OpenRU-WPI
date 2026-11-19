#!/usr/bin/env bash
# Ensure bench-evidence redaction removes the whole SUBSCRIBER_DB value.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(printf '%s\n' 'x SUBSCRIBER_DB=001010123456780,00112233445566778899aabbccddeeff,opc,63bfa50ee6523365ff14c1f45f88737d,8000,9,10.45.1.2' | "$ROOT/scripts/redact_secrets.sh")"  # no-secrets-ok
[[ "$out" == *"SUBSCRIBER_DB=<redacted: local secrets only>"* ]] || { echo "FAIL: $out" >&2; exit 1; }
[[ "$out" != *"00112233445566778899aabbccddeeff"* ]]  # no-secrets-ok || { echo "FAIL: key survived: $out" >&2; exit 1; }
echo "PASS: SUBSCRIBER_DB redacted"
