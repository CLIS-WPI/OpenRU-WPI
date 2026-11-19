"""Thread-safe in-memory state shared by collectors and the web app."""

from __future__ import annotations

import re
import threading
import time
from collections import deque
from typing import Deque, Dict, Optional

from .config import Settings
from .redact import redact_obj, redact_text

_LEVEL_RE = re.compile(r"\[(I|W|E|D|C|F|INFO|WARN|WARNING|ERROR|DEBUG|CRITICAL)\]", re.IGNORECASE)
_LEVEL_MAP = {
    "I": "info",
    "INFO": "info",
    "D": "debug",
    "DEBUG": "debug",
    "W": "warn",
    "WARN": "warn",
    "WARNING": "warn",
    "E": "error",
    "ERROR": "error",
    "C": "critical",
    "CRITICAL": "critical",
    "F": "critical",
}


def detect_level(text: str) -> str:
    match = _LEVEL_RE.search(text)
    if not match:
        lower = text.lower()
        if "error" in lower or "fail" in lower:
            return "error"
        if "warn" in lower:
            return "warn"
        return "info"
    return _LEVEL_MAP.get(match.group(1).upper(), "info")


class DashboardState:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._lock = threading.RLock()
        self._seq = 0
        self._logs: Deque[dict] = deque(maxlen=settings.max_log_lines)
        self._ru_latest: Optional[dict] = None
        self._ru_history: Deque[dict] = deque(maxlen=300)
        self._du = {
            "cell": {},
            "cell_up": False,
            "mac": None,
            "ofh": None,
            "sched": None,
            "errors": {},
            "error_series": [],
        }
        self._du_history: Deque[dict] = deque(maxlen=300)
        self._core = {
            "gnbs": [],
            "gnb_count": 0,
            "gnb_up": False,
            "counts": {},
            "auth": {},
            "ues": [],
            "ue_count": 0,
            "rejects": [],
        }
        self._stack = {"services": {}, "status": "unknown", "stack_up": False}
        self._host = {}
        self._modems: Dict[str, dict] = {}
        self._modem_history: Dict[str, Deque[dict]] = {
            "A": deque(maxlen=300),
            "B": deque(maxlen=300),
        }
        self._collectors: Dict[str, dict] = {}
        self._updated = time.time()
        self._replay = False

    # -- setters ---------------------------------------------------------
    def set_stack(self, snapshot: dict) -> None:
        with self._lock:
            self._stack = snapshot
            self._updated = time.time()

    def set_host(self, snapshot: dict) -> None:
        with self._lock:
            self._host = snapshot
            self._updated = time.time()

    def set_core(self, snapshot: dict) -> None:
        with self._lock:
            self._core = snapshot
            self._updated = time.time()

    def set_du(self, snapshot: dict, point: Optional[dict] = None) -> None:
        with self._lock:
            self._du = snapshot
            if point:
                self._du_history.append(point)
            self._updated = time.time()

    def add_ru(self, point: dict) -> None:
        with self._lock:
            self._ru_latest = point
            self._ru_history.append(point)
            self._updated = time.time()

    def set_modem(self, label: str, snapshot: dict) -> None:
        with self._lock:
            self._modems[label] = snapshot
            self._modem_history.setdefault(label, deque(maxlen=300)).append(
                {
                    "ts": snapshot.get("updated", time.time()),
                    "rsrp_dbm": (snapshot.get("serving") or {}).get("rsrp_dbm"),
                    "rsrq_db": (snapshot.get("serving") or {}).get("rsrq_db"),
                    "sinr_db": (snapshot.get("serving") or {}).get("sinr_db"),
                    "registered": snapshot.get("registered"),
                    "cfun": snapshot.get("cfun"),
                }
            )
            self._updated = time.time()

    def add_log(self, source: str, line: str, ts: Optional[float] = None) -> Optional[dict]:
        text = redact_text(line or "", mask_imsis=True).rstrip()
        if not text:
            return None
        if len(text) > 2000:
            text = text[:1997] + "..."
        with self._lock:
            self._seq += 1
            entry = {
                "seq": self._seq,
                "ts": round(time.time() if ts is None else ts, 3),
                "source": source,
                "level": detect_level(text),
                "text": text,
            }
            self._logs.append(entry)
            return entry

    def set_collector(self, name: str, ok: bool, error: Optional[str] = None) -> None:
        with self._lock:
            previous = self._collectors.get(name) or {}
            self._collectors[name] = {
                "ok": ok,
                "error": redact_text(error) if error else None,
                "since": previous.get("since") if previous.get("ok") == ok else time.time(),
            }

    def collector_error(self, name: str, error: str) -> None:
        self.set_collector(name, False, error)

    def load_replay(self, payload: dict) -> None:
        """Load a captured snapshot for offline UI review (no collectors)."""

        with self._lock:
            ru = payload.get("ru") or {}
            self._ru_latest = ru.get("latest")
            self._ru_history = deque(
                ru.get("history") or [], maxlen=self._ru_history.maxlen
            )
            if self._ru_latest and self._ru_history:
                shift = time.time() - 1.0 - self._ru_history[-1]["ts"]
                for point in self._ru_history:
                    point["ts"] = round(point["ts"] + shift, 3)
                self._ru_latest["ts"] = round(self._ru_latest["ts"] + shift, 3)
            self._du = payload.get("du") or self._du
            self._du_history = deque(
                payload.get("du_history") or [], maxlen=self._du_history.maxlen
            )
            self._core = payload.get("core") or self._core
            self._stack = payload.get("stack") or self._stack
            self._host = payload.get("host") or self._host
            self._modems = payload.get("modems") or self._modems
            for label, history in (payload.get("modem_history") or {}).items():
                self._modem_history[label] = deque(
                    history or [], maxlen=self._modem_history[label].maxlen
                )
            logs = payload.get("logs") or []
            self._logs = deque(logs, maxlen=self._logs.maxlen)
            self._seq = max((int(line.get("seq", 0)) for line in logs), default=0)
            self._collectors = payload.get("collectors") or {}
            self._replay = True
            self._updated = time.time()

    # -- snapshot --------------------------------------------------------
    def snapshot(self) -> dict:
        now = time.time()
        with self._lock:
            data = {
                "ts": round(now, 3),
                "release": self.settings.release,
                "hostname": self.settings.hostname,
                "read_only": True,
                "stack": self._stack,
                "ru": {
                    "latest": self._ru_latest,
                    "history": list(self._ru_history),
                },
                "du": self._du,
                "du_history": list(self._du_history),
                "core": self._core,
                "host": self._host,
                "modems": self._modems,
                "modem_history": {
                    label: list(history)
                    for label, history in self._modem_history.items()
                },
                "logs": list(self._logs),
                "log_seq": self._seq,
                "collectors": self._collectors,
                "replay": self._replay,
                "updated": round(self._updated, 3),
                "age_s": round(now - self._updated, 1),
            }
        return redact_obj(data)
