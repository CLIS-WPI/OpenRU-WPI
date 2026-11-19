"""Parsers for the read-only Quectel AT command set used by the bench.

No command in this module changes modem state.  The collector only sends the
allow-listed queries documented in ``collectors/modem.py``.
"""

from __future__ import annotations

import csv
import io
import re
from typing import Dict, List, Optional

from .common import parse_number

CFUN_RE = re.compile(r"\+CFUN:\s*(\d+)")
CSQ_RE = re.compile(r"\+CSQ:\s*(\d+)\s*,\s*(\d+)")
CIMI_RE = re.compile(r"\+CIMI:\s*(\d{5,20})")
CGPADDR_RE = re.compile(r"\+CGPADDR:\s*(\d+)\s*,\s*\"?([^\",]*)\"?")
COPS_RE = re.compile(r"\+COPS:\s*(.+)")
QNWINFO_RE = re.compile(r"\+QNWINFO:\s*(.+)")
REG_RE = re.compile(r"\+C(5G|E)REG:\s*(.+)")

REG_STATES = {
    0: "not registered",
    1: "registered (home)",
    2: "searching",
    3: "registration denied",
    4: "unknown",
    5: "registered (roaming)",
}

CFUN_STATES = {
    0: "minimum",
    1: "full",
    4: "airplane",
    5: "rx only",
}

ACT_NAMES = {
    0: "GSM",
    1: "GSM compact",
    2: "UTRAN",
    3: "GSM/EGPRS",
    4: "UTRAN/HSDPA",
    5: "UTRAN/HSUPA",
    6: "UTRAN/HSPA",
    7: "LTE",
    10: "NR5G-SAI",
    11: "NR5G-SAB",
    12: "NR5G-SA",
    13: "NR5G-NSA",
}


def _csv(line: str) -> List[str]:
    body = line.split(":", 1)[1].strip() if ":" in line else line
    try:
        row = next(csv.reader(io.StringIO(body), skipinitialspace=True))
    except (csv.Error, StopIteration):
        return []
    return [cell.strip().strip('"') for cell in row]


def _num(value: Optional[str], cast=float):
    return parse_number(value, cast)


def parse_cfun(text: str) -> Optional[int]:
    match = CFUN_RE.search(text)
    if not match:
        return None
    return int(match.group(1))


def parse_csq(text: str) -> dict:
    match = CSQ_RE.search(text)
    if not match:
        return {"rssi": None, "ber": None, "dbm": None}
    rssi = int(match.group(1))
    ber = int(match.group(2))
    dbm = -113 + 2 * rssi if 0 <= rssi <= 31 else None
    return {"rssi": rssi, "ber": ber, "dbm": dbm}


def parse_registration(text: str) -> dict:
    """Return both EPS and 5GS registration state found in a response."""

    out = {
        "eps": {"raw": None, "stat": None, "stat_name": None},
        "fivegs": {"raw": None, "stat": None, "stat_name": None},
    }
    for match in REG_RE.finditer(text):
        kind = "fivegs" if match.group(1) == "5G" else "eps"
        row = _csv(match.group(0))
        if len(row) < 2:
            continue
        stat = _num(row[1], int)
        entry = {
            "raw": match.group(0).strip(),
            "n": _num(row[0], int),
            "stat": stat,
            "stat_name": REG_STATES.get(stat, "unknown"),
            "tac": _num(row[2], int) if len(row) > 2 else None,
            "cell_id": row[3] if len(row) > 3 else None,
            "act": _num(row[4], int) if len(row) > 4 else None,
            "reject_cause": _num(row[6], int) if len(row) > 6 else None,
        }
        out[kind] = entry
    for key in out:
        if out[key].get("act") is not None:
            out[key]["act_name"] = ACT_NAMES.get(out[key]["act"], str(out[key]["act"]))
    return out


def parse_cgpaddr(text: str) -> Dict[int, List[str]]:
    addresses: Dict[int, List[str]] = {}
    for match in CGPADDR_RE.finditer(text):
        cid = int(match.group(1))
        value = match.group(2).strip()
        if value:
            addresses.setdefault(cid, []).append(value)
    return addresses


def parse_cgdcont(text: str) -> List[dict]:
    contexts: List[dict] = []
    for line in text.splitlines():
        if not line.strip().startswith("+CGDCONT:"):
            continue
        row = _csv(line)
        if len(row) < 3:
            continue
        contexts.append(
            {
                "cid": _num(row[0], int),
                "pdp_type": row[1] or None,
                "apn": row[2] or None,
                "address": row[3] or None if len(row) > 3 else None,
            }
        )
    return contexts


def parse_cops(text: str) -> dict:
    match = COPS_RE.search(text)
    if not match:
        return {"name": None, "mcc": None, "mnc": None, "act": None}
    row = _csv(match.group(0))
    out: dict = {"name": None, "mcc": None, "mnc": None, "act": None}
    if not row or row[0] == "":
        return out
    if len(row) >= 3:
        out["name"] = row[2] or None
    if len(row) >= 4:
        code = row[2] if row[2].isdigit() else None
        out["act"] = _num(row[3], int)
        out["act_name"] = ACT_NAMES.get(out["act"], str(out["act"])) if out["act"] is not None else None
        if code and 5 <= len(code) <= 6:
            out["mcc"] = code[:3]
            out["mnc"] = code[3:]
    return out


def parse_cimi(text: str) -> Optional[str]:
    match = CIMI_RE.search(text)
    return match.group(1) if match else None


def parse_qnwinfo(text: str) -> dict:
    match = QNWINFO_RE.search(text)
    if not match:
        return {}
    row = _csv(match.group(0))
    if len(row) < 3:
        return {}
    return {
        "duplex": row[0] or None,
        "plmn": row[1] or None,
        "band": row[2] or None,
        "channel": _num(row[3], int) if len(row) > 3 else None,
    }


def parse_qeng_servingcell(text: str) -> Optional[dict]:
    for line in text.splitlines():
        if not line.strip().startswith("+QENG:"):
            continue
        row = _csv(line)
        if len(row) < 3 or row[0].lower() != "servingcell":
            continue
        rat = row[2].upper()
        out = {
            "raw": line.strip(),
            "state": row[1] or None,
            "rat": rat,
            "duplex": None,
            "mcc": None,
            "mnc": None,
            "cell_id": None,
            "pci": None,
            "tac": None,
            "arfcn": None,
            "band": None,
            "bandwidth_mhz": None,
            "rsrp_dbm": None,
            "rsrq_db": None,
            "sinr_db": None,
            "rssi_dbm": None,
        }
        if rat.startswith("NR5G"):
            if len(row) >= 15:
                out.update(
                    {
                        "duplex": row[3] or None,
                        "mcc": row[4] or None,
                        "mnc": row[5] or None,
                        "cell_id": row[6] or None,
                        "pci": _num(row[7], int),
                        "tac": row[8] or None,
                        "arfcn": _num(row[9], int),
                        "band": row[10] or None,
                        "bandwidth_mhz": _num(row[11], float),
                        "rsrp_dbm": _num(row[12], float),
                        "rsrq_db": _num(row[13], float),
                        "sinr_db": _num(row[14], float),
                    }
                )
            return out
        if rat == "LTE":
            if len(row) >= 17:
                out.update(
                    {
                        "duplex": row[3] or None,
                        "mcc": row[4] or None,
                        "mnc": row[5] or None,
                        "cell_id": row[6] or None,
                        "pci": _num(row[7], int),
                        "arfcn": _num(row[8], int),
                        "band": row[9] or None,
                        "bandwidth_mhz": _num(row[11], float),
                        "tac": row[12] or None,
                        "rsrp_dbm": _num(row[13], float),
                        "rsrq_db": _num(row[14], float),
                        "rssi_dbm": _num(row[15], float),
                        "sinr_db": _num(row[16], float),
                    }
                )
            return out
        return out
    return None


def parse_response(text: str) -> dict:
    """Parse a concatenated read-only AT response blob into dashboard fields."""

    registration = parse_registration(text)
    serving = parse_qeng_servingcell(text)
    contexts = parse_cgdcont(text)
    addresses = parse_cgpaddr(text)
    operator = parse_cops(text)
    cfun = parse_cfun(text)
    signal = parse_csq(text)
    cimi = parse_cimi(text)
    network = parse_qnwinfo(text)

    pdn = None
    for context in contexts:
        if context.get("address") or addresses.get(context.get("cid")):
            pdn = dict(context)
            pdn["address"] = pdn.get("address") or (
                addresses.get(context.get("cid"), [None])[0]
            )
            break

    if not operator.get("mcc") and serving:
        operator["mcc"] = serving.get("mcc")
        operator["mnc"] = serving.get("mnc")

    registered = any(
        registration.get(key, {}).get("stat") in (1, 5)
        for key in ("eps", "fivegs")
    )
    errors = len(re.findall(r"^\+?CME ERROR|^ERROR", text, re.MULTILINE))
    ok = len(re.findall(r"^OK\s*$", text, re.MULTILINE))
    return {
        "sim": {"imsi": cimi, "present": bool(cimi)},
        "cfun": cfun,
        "cfun_name": CFUN_STATES.get(cfun, str(cfun) if cfun is not None else None),
        "signal": signal,
        "registration": registration,
        "registered": registered,
        "operator": operator,
        "serving": serving,
        "pdn": pdn,
        "addresses": {str(key): value for key, value in addresses.items()},
        "contexts": contexts,
        "network": network,
        "ok": ok,
        "errors": errors,
    }
