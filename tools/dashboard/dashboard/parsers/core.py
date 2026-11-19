"""Parser for the Open5GS AMF/SMF log lines we care about.

Open5GS' default log level is ``info``.  At that level the AMF logs NG setup,
registration requests/rejects and PDU session IP assignments, but not the
per-UE registration accept or authentication request/response messages (those
are ``debug``).  The parser understands both levels and simply leaves fields
alone when a message is not present.
"""

from __future__ import annotations

import re
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Deque, Dict, List, Optional

from .common import strip_ansi

IMSI_RE = re.compile(r"(imsi-\d{5,15})")
BRACKET_IMSI_RE = re.compile(r"\[(imsi-\d{5,15})\]")
SUPI_RE = re.compile(r"SUPI\s*\(?\[?(imsi-\d{5,15})\]?\)?")

GNB_ACCEPTED_RE = re.compile(
    r"gNB-N2 accepted\[(?P<addr>[^\]]+)\](?::(?P<port>\d+))?"
)
GNB_REFUSED_RE = re.compile(
    r"gNB-N2\[(?P<addr>[^\]]+)\] connection refused"
)
GNB_STREAMS_RE = re.compile(
    r"gNB-N2\[(?P<addr>[^\]]+)\] max_num_of_ostreams\s*:\s*(?P<streams>\d+)"
)

REG_REJECT_RE = re.compile(
    r"Registration reject\s*(?:\[(?P<cause>\d+)\])?", re.IGNORECASE
)
PDU_REJECT_RE = re.compile(
    r"PDU Session Establishment Reject", re.IGNORECASE
)
UE_IP_RE = re.compile(
    r"UE SUPI\[(?P<supi>imsi-\d+)\] DNN\[(?P<dnn>[^\]]*)\] "
    r"IPv4\[(?P<ipv4>[^\]]*)\] IPv6\[(?P<ipv6>[^\]]*)\]"
)
UE_IP_LEGACY_RE = re.compile(
    r"UE IMSI\[(?P<imsi>\d+)\] APN\[(?P<dnn>[^\]]*)\] "
    r"IPv4\[(?P<ipv4>[^\]]*)\] IPv6\[(?P<ipv6>[^\]]*)\]"
)

CAUSE_NAMES = {
    2: "IMSI unknown in HSS",
    3: "Illegal UE",
    5: "PEI not accepted",
    6: "Illegal ME",
    7: "5GS services not allowed",
    9: "UE identity cannot be derived",
    10: "Implicitly deregistered",
    11: "PLMN not allowed",
    12: "Tracking area not allowed",
    13: "Roaming not allowed",
    15: "No suitable cells",
    20: "MAC failure",
    21: "Synch failure",
    22: "Congestion",
    23: "UE security capabilities mismatch",
    24: "Security mode rejected",
    26: "N1 mode not allowed",
    27: "Restricted service area",
    72: "Non-3GPP access not allowed",
    73: "Serving network not authorized",
}


def _imsi(text: str) -> Optional[str]:
    for regex in (BRACKET_IMSI_RE, SUPI_RE, IMSI_RE):
        match = regex.search(text)
        if match:
            value = match.group(1)
            return value if value.startswith("imsi-") else f"imsi-{value}"
    return None


def _cause_name(cause: Optional[int]) -> Optional[str]:
    if cause is None:
        return None
    return CAUSE_NAMES.get(cause, f"cause {cause}")


@dataclass
class CoreAccumulator:
    gnbs: Dict[str, dict] = field(default_factory=dict)
    ues: Dict[str, dict] = field(default_factory=dict)
    counts: Dict[str, int] = field(
        default_factory=lambda: {
            "reg_requested": 0,
            "reg_accepted": 0,
            "reg_rejected": 0,
            "reg_completed": 0,
            "auth_requested": 0,
            "auth_success": 0,
            "auth_failure": 0,
            "pdu_established": 0,
            "pdu_rejected": 0,
        }
    )
    rejects: Deque[dict] = field(default_factory=lambda: deque(maxlen=20))
    last_auth_cause: Optional[str] = None
    parsed_lines: int = 0

    def _ue(self, imsi: str, ts: float) -> dict:
        record = self.ues.setdefault(
            imsi,
            {
                "supi": imsi,
                "first_seen": ts,
                "reg_requested_ts": None,
                "registered_ts": None,
                "auth_requested_ts": None,
                "auth_success_ts": None,
                "auth_failure_ts": None,
                "pdu_ts": None,
                "dnn": None,
                "ipv4": None,
                "ipv6": None,
                "last_reject_cause": None,
            },
        )
        record["last_seen"] = ts
        return record

    def process(self, line: str, ts: Optional[float] = None) -> None:
        now = time.time() if ts is None else ts
        text = strip_ansi(line).rstrip("\r\n")
        if not text:
            return
        self.parsed_lines += 1

        match = GNB_ACCEPTED_RE.search(text)
        if match:
            addr = match.group("addr")
            record = self.gnbs.setdefault(addr, {"addr": addr, "accepted": False})
            record.update(
                {
                    "accepted": True,
                    "port": int(match.group("port")) if match.group("port") else None,
                    "accepted_ts": now,
                    "last_seen": now,
                    "last_error": None,
                }
            )
            return

        match = GNB_REFUSED_RE.search(text)
        if match:
            addr = match.group("addr")
            record = self.gnbs.setdefault(addr, {"addr": addr, "accepted": False})
            record.update(
                {
                    "accepted": False,
                    "last_seen": now,
                    "last_error": "connection refused",
                }
            )
            return

        match = GNB_STREAMS_RE.search(text)
        if match:
            addr = match.group("addr")
            record = self.gnbs.setdefault(addr, {"addr": addr, "accepted": False})
            record.update(
                {
                    "streams": int(match.group("streams")),
                    "last_seen": now,
                }
            )
            return

        imsi = _imsi(text)

        if "Registration request" in text:
            self.counts["reg_requested"] += 1
            if imsi:
                self._ue(imsi, now)["reg_requested_ts"] = now
            return

        if "Registration accept" in text:
            self.counts["reg_accepted"] += 1
            if imsi:
                record = self._ue(imsi, now)
                record["registered_ts"] = now
                record["last_reject_cause"] = None
            return

        if "Registration complete" in text:
            self.counts["reg_completed"] += 1
            if imsi:
                self._ue(imsi, now)["registered_ts"] = now
            return

        reject = REG_REJECT_RE.search(text)
        if reject:
            cause = int(reject.group("cause")) if reject.group("cause") else None
            self.counts["reg_rejected"] += 1
            entry = {
                "ts": now,
                "supi": imsi,
                "cause": cause,
                "cause_name": _cause_name(cause),
                "text": text[:300],
            }
            self.rejects.append(entry)
            if imsi:
                record = self._ue(imsi, now)
                record["last_reject_cause"] = cause
                record["last_reject_ts"] = now
            return

        if "Authentication request" in text:
            self.counts["auth_requested"] += 1
            if imsi:
                self._ue(imsi, now)["auth_requested_ts"] = now
            return

        if "Authentication response" in text:
            self.counts["auth_success"] += 1
            self.last_auth_cause = None
            if imsi:
                self._ue(imsi, now)["auth_success_ts"] = now
            return

        if "Authentication failure" in text:
            self.counts["auth_failure"] += 1
            cause_match = re.search(r"Authentication failure\s*\[(\d+)\]", text)
            cause = int(cause_match.group(1)) if cause_match else None
            if cause is None and "Synch failure" in text:
                cause = 21
            if cause is None and "MAC failure" in text:
                cause = 20
            self.last_auth_cause = _cause_name(cause)
            if imsi:
                record = self._ue(imsi, now)
                record["auth_failure_ts"] = now
                record["last_auth_cause"] = self.last_auth_cause
            return

        match = UE_IP_RE.search(text)
        if not match:
            match = UE_IP_LEGACY_RE.search(text)
        if match:
            if "supi" in match.groupdict():
                supi = match.group("supi")
            else:
                supi = f"imsi-{match.group('imsi')}"
            record = self._ue(supi, now)
            record.update(
                {
                    "pdu_ts": now,
                    "dnn": match.group("dnn") or None,
                    "ipv4": match.group("ipv4") or None,
                    "ipv6": match.group("ipv6") or None,
                }
            )
            self.counts["pdu_established"] += 1
            return

        if PDU_REJECT_RE.search(text):
            self.counts["pdu_rejected"] += 1
            cause_match = re.search(r"\[(?:cause|Cause):?\s*(\d+)\]", text)
            cause = int(cause_match.group(1)) if cause_match else None
            self.rejects.append(
                {
                    "ts": now,
                    "supi": imsi,
                    "cause": cause,
                    "cause_name": _cause_name(cause),
                    "text": text[:300],
                    "pdu": True,
                }
            )

    def snapshot(self, now: Optional[float] = None) -> dict:
        now = time.time() if now is None else now
        gnbs: List[dict] = []
        for record in self.gnbs.values():
            item = dict(record)
            item["age_s"] = round(now - record["last_seen"], 1)
            gnbs.append(item)
        gnbs.sort(key=lambda item: item["addr"])

        ues: List[dict] = []
        for record in self.ues.values():
            state = "seen"
            if record.get("pdu_ts"):
                state = "pdu"
            elif record.get("registered_ts"):
                state = "registered"
            elif record.get("auth_success_ts"):
                state = "auth_ok"
            elif record.get("reg_requested_ts"):
                state = "requesting"
            item = dict(record)
            item["state"] = state
            item["age_s"] = round(now - record.get("last_seen", now), 1)
            ues.append(item)
        ues.sort(key=lambda item: item.get("last_seen", 0), reverse=True)

        connected = [item for item in gnbs if item.get("accepted")]
        return {
            "gnbs": gnbs,
            "gnb_count": len(connected),
            "gnb_up": bool(connected),
            "counts": dict(self.counts),
            "auth": {
                "last_cause": self.last_auth_cause,
                "requested": self.counts["auth_requested"],
                "success": self.counts["auth_success"],
                "failure": self.counts["auth_failure"],
            },
            "ues": ues[:200],
            "ue_count": len(ues),
            "rejects": list(self.rejects)[-10:],
            "parsed_lines": self.parsed_lines,
        }
