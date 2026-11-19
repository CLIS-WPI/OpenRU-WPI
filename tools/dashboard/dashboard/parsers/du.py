"""Parsers and a rolling accumulator for the DU (gnb) log.

The DU writes most of its output to ``/tmp/gnb.log`` rather than stdout.  The
collector follows that file inside the container and feeds every line here.

Important classes of OFH trouble are counted as *events*:

* ``sequence identifier ... from the past`` (eCPRI sequence errors)
* ``missed incoming User-Plane PRACH`` (missed PRACH occasions)
* ``nof_late_ul_req`` deltas (late PRACH / UL request grants)
"""

from __future__ import annotations

import re
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from typing import Deque, Dict, Optional, Tuple

from .common import parse_kv, parse_number, parse_usec, strip_ansi

MAC_RE = re.compile(
    r"\[METRICS\s*\] MAC cell pci=(?P<pci>\d+) metrics: "
    r"slots=\[(?P<slot_start>.*?)\) nof_slots=(?P<nof_slots>\d+) "
    r"slot_duration=(?P<slot_duration>\d+)usec "
    r".*?nof_involuntary_context_switches=(?P<involuntary>\d+) "
    r".*?wall_clock_latency=\[avg=(?P<wall_avg>\d+)usec "
    r"max=(?P<wall_max>\d+)usec max_slot=(?P<wall_max_slot>[^\]]+)\]"
    r".*?sched_latency=\[avg=(?P<sched_avg>\d+)usec "
    r"max=(?P<sched_max>\d+)usec"
    r".*?dl_tti_req_latency=\[avg=(?P<dl_tti_avg>\d+)usec "
    r"max=(?P<dl_tti_max>\d+)usec"
    r".*?tx_data_req_latency=\[avg=(?P<tx_data_avg>\d+)usec "
    r"max=(?P<tx_data_max>\d+)usec"
    r".*?ul_tti_req_latency=\[avg=(?P<ul_tti_avg>\d+)usec "
    r"max=(?P<ul_tti_max>\d+)usec"
    r".*?slot_ind_dequeue_latency=\[avg=(?P<slot_deq_avg>\d+)usec "
    r"max=(?P<slot_deq_max>\d+)usec"
)

OFH_RE = re.compile(
    r"\[METRICS\s*\] OFH sector#(?P<sector>\d+) metrics: pci=(?P<pci>\d+) "
    r"received messages stats: rx_total=(?P<rx_total>\d+) "
    r"rx_early=(?P<rx_early>\d+) rx_on_time=(?P<rx_on_time>\d+) "
    r"rx_late=(?P<rx_late>\d+) "
    r".*?nof_missed_uplink_symbols=(?P<missed_symbols>\d+) "
    r"nof_missed_prach_occasions=(?P<missed_prach_occasions>\d+) "
    r".*?ecpri: nof_past_seqid_msg=(?P<past_seqid>\d+) "
    r"nof_future_seqid_msg=(?P<future_seqid>\d+)\s*;?\s*"
    r"rcv_prach: nof_dropped_msg=(?P<prach_dropped>\d+) "
    r".*?rcv_ul: nof_dropped_msg=(?P<ul_dropped>\d+)\s*;?\s*"
    r".*?tx_kpis: nof_late_dl_rgs=(?P<late_dl_rgs>\d+) "
    r"nof_late_ul_req=(?P<late_ul_req>\d+) "
    r"nof_late_cp_dl=(?P<late_cp_dl>\d+) "
    r"nof_late_up_dl=(?P<late_up_dl>\d+) "
    r"nof_late_cp_ul=(?P<late_cp_ul>\d+)"
)

SCHED_RE = re.compile(
    r"\[METRICS\s*\] Scheduler cell pci=(?P<pci>\d+) metrics: "
    r"total_dl_brate=\s*(?P<dl_rate>[0-9.]+)\s*(?P<dl_unit>[kKmM]?)bps "
    r"total_ul_brate=\s*(?P<ul_rate>[0-9.]+)\s*(?P<ul_unit>[kKmM]?)bps "
    r".*?nof_ues=(?P<nof_ues>\d+)"
)

SSB_RE = re.compile(
    r"SSB derived parameters for cell: (?P<cell>\d+), band: (?P<band>\d+), "
    r"dl_arfcn:(?P<arfcn>\d+), nof_crbs: (?P<nof_crbs>\d+) "
    r"scs:(?P<scs>\d+)kHz, ssb_scs:(?P<ssb_scs>\d+)kHz"
)
SSB_ARFCN_RE = re.compile(r"SSB arfcn:(?P<ssb_arfcn>\d+)")
CELL_CREATION_RE = re.compile(r"Cell creation(?: idx=(?P<idx>\d+))?")
CELL_PARAM_RE = re.compile(
    r"^\s*(?P<key>pci|dl_arfcn|band|common_scs|channel_bandwidth_MHz|ru_bandwidth_MHz)"
    r"\s*:\s*(?P<value>[0-9.]+)\s*$"
)

SEQ_PAST_PATTERNS = (
    re.compile(r"sequence identifier (?:field )?is from the past", re.IGNORECASE),
    re.compile(r"sequence identifier '[^']*' from the past", re.IGNORECASE),
)
MISSED_PRACH_RE = re.compile(
    r"missed incoming User-Plane PRACH messages", re.IGNORECASE
)
LATE_PRACH_RE = re.compile(
    r"\b(?:late|lateness)\b[^\n]{0,80}\bPRACH\b|\bPRACH\b[^\n]{0,80}\b(?:late|lateness)\b",
    re.IGNORECASE,
)

ERROR_CLASSES = ("seq_past", "missed_prach", "late_prach")


def _rate_bps(value: Optional[str], unit: Optional[str]) -> Optional[float]:
    number = parse_number(value, float)
    if number is None:
        return None
    multiplier = {"": 1.0, "k": 1e3, "K": 1e3, "m": 1e6, "M": 1e6}.get(unit or "", 1.0)
    return number * multiplier


@dataclass
class MacSample:
    ts: float
    pci: int
    slot_start: str
    nof_slots: int
    slot_duration_us: int
    involuntary_context_switches: int
    wall_avg_us: float
    wall_max_us: float
    wall_max_slot: str
    sched_avg_us: float
    sched_max_us: float
    dl_tti_avg_us: float
    dl_tti_max_us: float
    tx_data_avg_us: float
    tx_data_max_us: float
    ul_tti_avg_us: float
    ul_tti_max_us: float
    slot_deq_avg_us: float
    slot_deq_max_us: float

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class OfhSample:
    ts: float
    sector: int
    pci: int
    rx_total: int
    rx_early: int
    rx_on_time: int
    rx_late: int
    missed_symbols: int
    missed_prach_occasions: int
    past_seqid_msg: int
    future_seqid_msg: int
    prach_dropped: int
    ul_dropped: int
    late_dl_rgs: int
    late_ul_req: int
    late_cp_dl: int
    late_up_dl: int
    late_cp_ul: int

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class SchedSample:
    ts: float
    pci: int
    dl_bps: Optional[float]
    ul_bps: Optional[float]
    nof_ues: int

    def to_dict(self) -> dict:
        return asdict(self)


class ErrorTracker:
    """Count events in a rolling 60 second window and in total."""

    def __init__(self, window_s: int = 60, max_seconds: int = 900):
        self.window_s = window_s
        self.max_seconds = max_seconds
        self._seconds: Dict[int, Dict[str, int]] = {}
        self._totals: Dict[str, int] = {name: 0 for name in ERROR_CLASSES}
        self._last_ts: Dict[str, Optional[float]] = {name: None for name in ERROR_CLASSES}

    def add(self, name: str, ts: float, count: int = 1) -> None:
        if name not in self._totals or count <= 0:
            return
        second = int(ts)
        bucket = self._seconds.setdefault(second, {})
        bucket[name] = bucket.get(name, 0) + count
        self._totals[name] += count
        self._last_ts[name] = ts
        cutoff = second - self.max_seconds
        for key in [key for key in self._seconds if key < cutoff]:
            del self._seconds[key]

    def count(self, name: str, now: float) -> int:
        cutoff = now - self.window_s
        return sum(
            bucket.get(name, 0)
            for second, bucket in self._seconds.items()
            if second > cutoff
        )

    def series(self, now: float, seconds: int = 60) -> list[dict]:
        start = int(now) - seconds + 1
        out = []
        for second in range(start, int(now) + 1):
            bucket = self._seconds.get(second, {})
            out.append(
                {
                    "ts": second,
                    **{name: bucket.get(name, 0) for name in ERROR_CLASSES},
                }
            )
        return out

    def snapshot(self, now: float) -> dict:
        return {
            name: {
                "per_min": self.count(name, now),
                "total": self._totals[name],
                "last_ts": self._last_ts[name],
                "age_s": (
                    round(now - self._last_ts[name], 1)
                    if self._last_ts[name] is not None
                    else None
                ),
            }
            for name in ERROR_CLASSES
        }


@dataclass
class DuAccumulator:
    cell: Dict[str, object] = field(default_factory=dict)
    last_mac: Optional[MacSample] = None
    last_ofh: Optional[OfhSample] = None
    last_sched: Optional[SchedSample] = None
    cell_up_ts: Optional[float] = None
    last_late_ul_req: Optional[int] = None
    errors: ErrorTracker = field(default_factory=ErrorTracker)
    parsed_lines: int = 0

    def process(self, line: str, ts: Optional[float] = None) -> None:
        now = time.time() if ts is None else ts
        text = strip_ansi(line).rstrip("\r\n")
        if not text:
            return
        self.parsed_lines += 1

        param = CELL_PARAM_RE.match(text)
        if param:
            key = param.group("key")
            raw = param.group("value")
            cast = int if key in {"pci", "dl_arfcn", "band", "common_scs"} else float
            self.cell[key] = parse_number(raw, cast)
            return

        ssb = SSB_RE.search(text)
        if ssb:
            self.cell.update(
                {
                    "pci": self.cell.get("pci") or None,
                    "band": int(ssb.group("band")),
                    "dl_arfcn": int(ssb.group("arfcn")),
                    "nof_crbs": int(ssb.group("nof_crbs")),
                    "common_scs": int(ssb.group("scs")),
                    "ssb_scs": int(ssb.group("ssb_scs")),
                }
            )
            # The cell line does not carry PCI; the MAC line will fill it in.

        ssb_arfcn = SSB_ARFCN_RE.search(text)
        if ssb_arfcn:
            self.cell["ssb_arfcn"] = int(ssb_arfcn.group("ssb_arfcn"))

        if CELL_CREATION_RE.search(text):
            self.cell_up_ts = now
            if "cell_up" not in self.cell:
                self.cell["cell_up"] = True

        mac = MAC_RE.search(text)
        if mac:
            sample = MacSample(
                ts=now,
                pci=int(mac.group("pci")),
                slot_start=mac.group("slot_start"),
                nof_slots=int(mac.group("nof_slots")),
                slot_duration_us=int(mac.group("slot_duration")),
                involuntary_context_switches=int(mac.group("involuntary")),
                wall_avg_us=float(mac.group("wall_avg")),
                wall_max_us=float(mac.group("wall_max")),
                wall_max_slot=mac.group("wall_max_slot"),
                sched_avg_us=float(mac.group("sched_avg")),
                sched_max_us=float(mac.group("sched_max")),
                dl_tti_avg_us=float(mac.group("dl_tti_avg")),
                dl_tti_max_us=float(mac.group("dl_tti_max")),
                tx_data_avg_us=float(mac.group("tx_data_avg")),
                tx_data_max_us=float(mac.group("tx_data_max")),
                ul_tti_avg_us=float(mac.group("ul_tti_avg")),
                ul_tti_max_us=float(mac.group("ul_tti_max")),
                slot_deq_avg_us=float(mac.group("slot_deq_avg")),
                slot_deq_max_us=float(mac.group("slot_deq_max")),
            )
            self.last_mac = sample
            self.cell["pci"] = sample.pci
            self.cell_up_ts = now
            return

        ofh = OFH_RE.search(text)
        if ofh:
            sample = OfhSample(
                ts=now,
                sector=int(ofh.group("sector")),
                pci=int(ofh.group("pci")),
                rx_total=int(ofh.group("rx_total")),
                rx_early=int(ofh.group("rx_early")),
                rx_on_time=int(ofh.group("rx_on_time")),
                rx_late=int(ofh.group("rx_late")),
                missed_symbols=int(ofh.group("missed_symbols")),
                missed_prach_occasions=int(ofh.group("missed_prach_occasions")),
                past_seqid_msg=int(ofh.group("past_seqid")),
                future_seqid_msg=int(ofh.group("future_seqid")),
                prach_dropped=int(ofh.group("prach_dropped")),
                ul_dropped=int(ofh.group("ul_dropped")),
                late_dl_rgs=int(ofh.group("late_dl_rgs")),
                late_ul_req=int(ofh.group("late_ul_req")),
                late_cp_dl=int(ofh.group("late_cp_dl")),
                late_up_dl=int(ofh.group("late_up_dl")),
                late_cp_ul=int(ofh.group("late_cp_ul")),
            )
            self.last_ofh = sample
            self.cell["pci"] = sample.pci
            if self.last_late_ul_req is not None:
                delta = sample.late_ul_req - self.last_late_ul_req
                if delta > 0:
                    self.errors.add("late_prach", now, delta)
            self.last_late_ul_req = sample.late_ul_req
            self.cell_up_ts = now
            return

        sched = SCHED_RE.search(text)
        if sched:
            self.last_sched = SchedSample(
                ts=now,
                pci=int(sched.group("pci")),
                dl_bps=_rate_bps(sched.group("dl_rate"), sched.group("dl_unit")),
                ul_bps=_rate_bps(sched.group("ul_rate"), sched.group("ul_unit")),
                nof_ues=int(sched.group("nof_ues")),
            )
            return

        if any(pattern.search(text) for pattern in SEQ_PAST_PATTERNS):
            self.errors.add("seq_past", now)
        if MISSED_PRACH_RE.search(text):
            self.errors.add("missed_prach", now)
        elif LATE_PRACH_RE.search(text) and "[METRICS" not in text:
            self.errors.add("late_prach", now)

    def snapshot(self, now: Optional[float] = None) -> dict:
        now = time.time() if now is None else now
        mac_age = round(now - self.last_mac.ts, 1) if self.last_mac else None
        ofh_age = round(now - self.last_ofh.ts, 1) if self.last_ofh else None
        cell_up = bool(
            (mac_age is not None and mac_age <= 5.0)
            or (ofh_age is not None and ofh_age <= 5.0)
        )
        cell = dict(self.cell)
        cell["cell_up"] = cell_up
        return {
            "cell": cell,
            "cell_up": cell_up,
            "mac": self.last_mac.to_dict() if self.last_mac else None,
            "mac_age_s": mac_age,
            "ofh": self.last_ofh.to_dict() if self.last_ofh else None,
            "ofh_age_s": ofh_age,
            "sched": self.last_sched.to_dict() if self.last_sched else None,
            "errors": self.errors.snapshot(now),
            "error_series": self.errors.series(now, 60),
            "parsed_lines": self.parsed_lines,
        }

    def point(self) -> dict:
        mac = self.last_mac
        ofh = self.last_ofh
        sched = self.last_sched
        return {
            "ts": round(mac.ts if mac else (ofh.ts if ofh else time.time()), 3),
            "wall_avg_us": mac.wall_avg_us if mac else None,
            "wall_max_us": mac.wall_max_us if mac else None,
            "sched_max_us": mac.sched_max_us if mac else None,
            "involuntary_cs": mac.involuntary_context_switches if mac else None,
            "rx_total": ofh.rx_total if ofh else None,
            "rx_early": ofh.rx_early if ofh else None,
            "rx_late": ofh.rx_late if ofh else None,
            "rx_on_time": ofh.rx_on_time if ofh else None,
            "nof_ues": sched.nof_ues if sched else None,
            "dl_bps": sched.dl_bps if sched else None,
            "ul_bps": sched.ul_bps if sched else None,
        }


def parse_line(line: str, ts: Optional[float] = None) -> dict:
    """Convenience for tests: parse one line and return its category."""

    acc = DuAccumulator()
    acc.process(line, ts if ts is not None else 0.0)
    out: Dict[str, object] = {"cell": dict(acc.cell)}
    if acc.last_mac:
        out["mac"] = acc.last_mac.to_dict()
    if acc.last_ofh:
        out["ofh"] = acc.last_ofh.to_dict()
    if acc.last_sched:
        out["sched"] = acc.last_sched.to_dict()
    return out
