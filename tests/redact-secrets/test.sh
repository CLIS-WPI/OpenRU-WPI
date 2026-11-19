#!/usr/bin/env bash
# Ensure bench-evidence redaction removes the whole SUBSCRIBER_DB value.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
out="$(printf '%s\n' 'x SUBSCRIBER_DB=001010123456780,00112233445566778899aabbccddeeff,opc,63bfa50ee6523365ff14c1f45f88737d,8000,9,10.45.1.2' | "$ROOT/scripts/redact_secrets.sh")"  # no-secrets-ok
[[ "$out" == *"SUBSCRIBER_DB=<redacted: local secrets only>"* ]] || { echo "FAIL: $out" >&2; exit 1; }
[[ "$out" != *"00112233445566778899aabbccddeeff"* ]] || { echo "FAIL: key survived: $out" >&2; exit 1; }  # no-secrets-ok
printf '%s\n' 'core log: SUBSCRIBER_DB=001010123456780,00112233445566778899aabbccddeeff' > "$TMP/core.log"  # no-secrets-ok
"$ROOT/scripts/save_evidence_log.sh" "$TMP/core.log" "$TMP/evidence.log"
grep -q 'SUBSCRIBER_DB=<redacted: local secrets only>' "$TMP/evidence.log"
! grep -q '00112233445566778899aabbccddeeff' "$TMP/evidence.log" || { echo "FAIL: saved evidence leaked a key" >&2; exit 1; }  # no-secrets-ok
# The test framework's evidence copier must use the same redactor.
. "$ROOT/tests/lib/common.sh"
test_copy_evidence "$TMP/core.log" "$TMP/evidence2.log"
! grep -q '00112233445566778899aabbccddeeff' "$TMP/evidence2.log" || { echo "FAIL: test_copy_evidence leaked a key" >&2; exit 1; }  # no-secrets-ok
echo "PASS: SUBSCRIBER_DB redacted from saved evidence"
