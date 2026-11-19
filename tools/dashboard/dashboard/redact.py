"""Fail-closed redaction for everything the dashboard renders.

The rules mirror ``scripts/check_no_secrets.sh``.  Redaction happens before
text reaches the browser, including the live log panel.
"""

from __future__ import annotations

import re
from typing import Optional

REDACTED = "[redacted]"

_PATTERNS = (
    (re.compile(r"(?<![\d.])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?![\d.])"), REDACTED),
    (re.compile(r"\b(?:tailscale|tailnet|ece107)\b", re.IGNORECASE), REDACTED),  # no-secrets-ok
    (re.compile(r"\.ts\.net\b", re.IGNORECASE), REDACTED),  # no-secrets-ok
    (re.compile(r"BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY"), REDACTED),
    (re.compile(r"\bssh-(?:ed25519|rsa|dss)\s+[A-Za-z0-9+/=]+"), REDACTED),
    (
        re.compile(
            r"(?i)\b(password|passwd|secret|token|api[_-]?key)"
            r"(\s*[=:]\s*)(?!\[redacted\])[^\s\"'<>]+"
        ),
        r"\1\2" + REDACTED,
    ),
    (
        re.compile(r"(?i)\b(k|ki|key|opc|op|adm)(\s*[=:]\s*)[0-9a-f]{32}\b"),
        r"\1\2" + REDACTED,
    ),
    (re.compile(r"(?i)\b[0-9a-f]{32}\b"), REDACTED),
    (re.compile(r"(?i)\bHOST=[A-Za-z0-9._-]+"), "HOST=" + REDACTED),
    (
        re.compile(
            r"(?i)\b(ssh|scp|rsync)\b[^\n|;]{0,160}?\b[A-Za-z0-9._-]+@[A-Za-z0-9.-]+"
        ),
        r"\1 " + REDACTED,
    ),
)

_IMSI_RE = re.compile(r"\bimsi-(\d{5,15})\b")
_IMSI_PLAIN_RE = re.compile(r"\b(\d{15})\b")


def mask_imsi(value: str) -> str:
    """Mask all but the last four digits of an IMSI/SUPI."""

    def _mask(match: re.Match[str]) -> str:
        digits = match.group(1)
        return "imsi-" + "*" * max(0, len(digits) - 4) + digits[-4:]

    value = _IMSI_RE.sub(_mask, value)
    # Only mask bare 15-digit strings; shorter numbers (ARFCN, cell id) are
    # operational data and are useful on the bench.
    return _IMSI_PLAIN_RE.sub(lambda m: "*" * 11 + m.group(1)[-4:], value)


def redact_text(text: str, *, mask_imsis: bool = True) -> str:
    if not text:
        return text
    out = text
    for pattern, replacement in _PATTERNS:
        out = pattern.sub(replacement, out)
    if mask_imsis:
        out = mask_imsi(out)
    return out


def redact_obj(value, *, mask_imsis: bool = True):
    """Recursively redact strings in a JSON-like object."""

    if isinstance(value, str):
        return redact_text(value, mask_imsis=mask_imsis)
    if isinstance(value, dict):
        return {
            key: redact_obj(item, mask_imsis=mask_imsis)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_obj(item, mask_imsis=mask_imsis) for item in value]
    if isinstance(value, tuple):
        return [redact_obj(item, mask_imsis=mask_imsis) for item in value]
    return value


def assert_clean(text: str) -> Optional[str]:
    """Return the first redaction that would still be needed, for tests."""

    redacted = redact_text(text, mask_imsis=False)
    return None if redacted == text else redacted
