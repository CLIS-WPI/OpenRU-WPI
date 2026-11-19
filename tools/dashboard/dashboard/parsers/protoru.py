"""Parser for the ProtO-RU throughput table.

The RU prints one row per second.  Containers prefix the row with
``protoru-1  |`` and ``docker logs --timestamps`` adds an RFC3339 prefix; both
are removed before this parser runs.  The canonical row is::

    | 00:01:14 | 0 | 9080 | 6768 | 0 | 0 | 0/0 | ... | 15184 |

The header is::

    TIME ID RX_TOTAL RX_ON_TIME RX_EARLY RX_LATE RX_SEQ_ERR RX_ON_TIME_C
    RX_EARLY_C RX_LATE_C RX_SEQ_ERR_C RX_ON_TIME_C_U RX_EARLY_C_U
    RX_LATE_C_U RX_SEQ_ERR_C_U RX_SEQ_ERR_PRACH RX_CORRUPT RX_ERR_DROP
    TX_TOTAL
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Iterable, List, Optional

from .common import parse_number, strip_ansi

_TIME_RE = re.compile(r"^\d{2}:\d{2}:\d{2}$")

FIELDS = (
    "time",
    "id",
    "rx_total",
    "rx_on_time",
    "rx_early",
    "rx_late",
    "rx_seq_err",
    "rx_on_time_c",
    "rx_early_c",
    "rx_late_c",
    "rx_seq_err_c",
    "rx_on_time_c_u",
    "rx_early_c_u",
    "rx_late_c_u",
    "rx_seq_err_c_u",
    "rx_seq_err_prach",
    "rx_corrupt",
    "rx_err_drop",
    "tx_total",
)


@dataclass(frozen=True)
class ProtoruSample:
    ts: float
    time: str
    id: Optional[int]
    rx_total: Optional[int]
    rx_on_time: Optional[int]
    rx_early: Optional[int]
    rx_late: Optional[int]
    rx_seq_err: Optional[float]
    rx_on_time_c: Optional[int]
    rx_early_c: Optional[int]
    rx_late_c: Optional[int]
    rx_seq_err_c: Optional[float]
    rx_on_time_c_u: Optional[int]
    rx_early_c_u: Optional[int]
    rx_late_c_u: Optional[int]
    rx_seq_err_c_u: Optional[float]
    rx_seq_err_prach: Optional[float]
    rx_corrupt: Optional[int]
    rx_err_drop: Optional[int]
    tx_total: Optional[int]

    def to_point(self) -> dict:
        data = asdict(self)
        data["ts"] = round(self.ts, 3)
        return data


def _split_fraction(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    text = value.strip()
    if "/" in text:
        text = text.split("/", 1)[0]
    return parse_number(text, float)


def parse_row(line: str, ts: float) -> Optional[ProtoruSample]:
    """Parse a single ProtO-RU table row, or return ``None``."""

    text = strip_ansi(line).rstrip("\r\n")
    if "|" not in text:
        return None

    parts = [part.strip() for part in text.split("|")]
    start = None
    for index, part in enumerate(parts):
        if _TIME_RE.match(part):
            start = index
            break
    if start is None or len(parts) - start < len(FIELDS):
        return None

    cell = parts[start : start + len(FIELDS)]
    if len(cell) != len(FIELDS):
        return None

    return ProtoruSample(
        ts=ts,
        time=cell[0],
        id=parse_number(cell[1], int),
        rx_total=parse_number(cell[2], int),
        rx_on_time=parse_number(cell[3], int),
        rx_early=parse_number(cell[4], int),
        rx_late=parse_number(cell[5], int),
        rx_seq_err=_split_fraction(cell[6]),
        rx_on_time_c=parse_number(cell[7], int),
        rx_early_c=parse_number(cell[8], int),
        rx_late_c=parse_number(cell[9], int),
        rx_seq_err_c=_split_fraction(cell[10]),
        rx_on_time_c_u=parse_number(cell[11], int),
        rx_early_c_u=parse_number(cell[12], int),
        rx_late_c_u=parse_number(cell[13], int),
        rx_seq_err_c_u=_split_fraction(cell[14]),
        rx_seq_err_prach=_split_fraction(cell[15]),
        rx_corrupt=parse_number(cell[16], int),
        rx_err_drop=parse_number(cell[17], int),
        tx_total=parse_number(cell[18], int),
    )


def parse_rows(lines: Iterable[str], ts: float = 0.0) -> List[ProtoruSample]:
    samples: List[ProtoruSample] = []
    for offset, line in enumerate(lines):
        sample = parse_row(line, ts + offset)
        if sample is not None:
            samples.append(sample)
    return samples
