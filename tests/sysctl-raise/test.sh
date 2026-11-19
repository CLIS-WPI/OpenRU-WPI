#!/usr/bin/env bash
# Tiny test for scripts/sysctl_raise.sh: the emitted value is max(current, floor).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/sysctl_raise.sh"
FLOOR=33554432

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

below="$(SYSCTL_RAISE_CURRENT=$((FLOOR - 1)) "$SCRIPT" net.core.wmem_max net.core.rmem_max)"
expected_below="$(
  printf 'net.core.wmem_max = %s\nnet.core.rmem_max = %s\n' "$FLOOR" "$FLOOR"
)"
[[ "$below" == "$expected_below" ]] || fail "current below floor was not raised:
$below"

above="$(SYSCTL_RAISE_CURRENT=$((FLOOR + 16445568)) "$SCRIPT" net.core.wmem_max net.core.rmem_max)"
expected_above="$(
  printf 'net.core.wmem_max = %s\nnet.core.rmem_max = %s\n' \
    "$((FLOOR + 16445568))" "$((FLOOR + 16445568))"
)"
[[ "$above" == "$expected_above" ]] || fail "current above floor was lowered:
$above"

echo "PASS: sysctl_raise writes max(current, $FLOOR)"
