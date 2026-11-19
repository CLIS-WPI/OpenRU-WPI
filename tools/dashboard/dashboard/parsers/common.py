"""Small, dependency-free helpers shared by the log parsers."""

from __future__ import annotations

import datetime as _dt
import re
from typing import Dict, Optional

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

_ISO_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+"
)

_KV_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(\[[^\]]*\]|[^\s;]+)")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def strip_docker_timestamp(text: str) -> tuple[str, Optional[float]]:
    """Split a ``docker logs --timestamps`` prefix from the message.

    Returns ``(message, epoch_seconds)``. ``epoch_seconds`` is ``None`` when
    the line did not start with an RFC3339 timestamp.
    """

    match = _ISO_RE.match(text)
    if not match:
        return text, None
    stamp = match.group(1)
    if stamp.endswith("Z"):
        stamp = stamp[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(stamp)
    except ValueError:
        return text[match.end() :], None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return text[match.end() :], parsed.timestamp()


def parse_kv(text: str) -> Dict[str, str]:
    """Parse ``key=value`` pairs, including bracketed values with spaces."""

    out: Dict[str, str] = {}
    for key, value in _KV_RE.findall(text):
        if value.startswith("[") and value.endswith("]"):
            value = value[1:-1]
        out[key] = value
    return out


def parse_usec(value: str) -> Optional[float]:
    if value is None:
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", str(value))
    if not match:
        return None
    return float(match.group(0))


def parse_number(value, cast=float):
    if value is None:
        return None
    text = str(value).strip().strip('"')
    if not text or text.upper() in {"N/A", "NA", "-"}:
        return None
    try:
        return cast(text)
    except (TypeError, ValueError):
        return None


def first_int(pattern: re.Pattern[str], text: str) -> Optional[int]:
    match = pattern.search(text)
    return int(match.group(1)) if match else None
