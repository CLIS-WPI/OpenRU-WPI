#!/usr/bin/env bash
# Emit raise-only sysctl assignments for the UHD socket buffers.
#
# Usage: scripts/sysctl_raise.sh [KEY...]
#
# For each key (default: net.core.wmem_max net.core.rmem_max) prints
#   KEY = max(current, FLOOR)
# where current comes from `sysctl -n KEY`. It never asks the kernel to lower
# an existing higher value. Set SYSCTL_RAISE_CURRENT to a fake current value
# (tests only) and SYSCTL_RAISE_FLOOR to change the 33554432 floor.
set -euo pipefail

FLOOR="${SYSCTL_RAISE_FLOOR:-33554432}"

keys=("$@")
if [[ ${#keys[@]} -eq 0 ]]; then
  keys=(net.core.wmem_max net.core.rmem_max)
fi

for key in "${keys[@]}"; do
  if [[ -n "${SYSCTL_RAISE_CURRENT:-}" ]]; then
    current="$SYSCTL_RAISE_CURRENT"
  else
    current="$(sysctl -n "$key")"
  fi

  if [[ ! "$current" =~ ^[0-9]+$ ]]; then
    echo "sysctl_raise: invalid current value for $key: '$current'" >&2
    exit 2
  fi

  if (( current < FLOOR )); then
    current="$FLOOR"
  fi

  printf '%s = %s\n' "$key" "$current"
done
