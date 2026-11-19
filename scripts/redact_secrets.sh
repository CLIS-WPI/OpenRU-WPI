#!/usr/bin/env bash
# Redact subscriber credentials from logs copied into bench evidence.
# stdin -> stdout. SUBSCRIBER_DB is a comma-separated IMSI/K/OPc/... value.
set -euo pipefail
sed -E 's/(^|[^A-Za-z0-9_])SUBSCRIBER_DB=[^[:space:]]+/\1SUBSCRIBER_DB=<redacted: local secrets only>/g'
