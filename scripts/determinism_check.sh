#!/usr/bin/env bash
# Two consecutive CPU/null replays must yield identical IQ per slot before golden.
# Usage: determinism_check.sh <iq_dir_a> <iq_dir_b>
set -euo pipefail
A="${1:?iq dir A}"
B="${2:?iq dir B}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "${ROOT}/tools/iq_compare/iq_compare.py" --dut "$A" --golden "$B" --by-slot --threshold 0
echo "[determinism] PASS: identical IQ per slot"
