"""Collector threads.

Every collector is read-only:

* Docker: ``GET /containers/...`` and log/exec streams only.
* DU: ``tail -F`` of ``/tmp/gnb.log`` inside the DU container.
* Modems: an allow-listed set of AT *queries* only (no ``=`` commands).
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections import deque
from pathlib import Path
from typing import Deque, Optional, Tuple

from ..config import Settings
from ..parsers.common import strip_ansi, strip_docker_timestamp
from ..parsers.core import CoreAccumulator
from ..parsers.du import DuAccumulator, LATE_PRACH_RE, MISSED_PRACH_RE, SEQ_PAST_PATTERNS
from ..parsers.host import host_snapshot
from ..parsers.modem import parse_response
from ..parsers.protoru import parse_row
from ..parsers.stack import container_from_api, stack_snapshot
from ..redact import redact_text
from ..state import DashboardState
from .docker_client import DockerClient, DockerError

log = logging.getLogger("openru.dashboard.collectors")

MODEM_COMMANDS = (
    "AT",
    'AT+CFUN?',
    'AT+QENG="servingcell"',
    "AT+C5GREG?",
    "AT+CEREG?",
    "AT+CGPADDR=1",
    "AT+CGDCONT?",
    "AT+CIMI",
    "AT+QNWINFO",
    "AT+COPS?",
    "AT+CSQ",
)


class _Collector(threading.Thread):
    def __init__(self, manager: "CollectorManager", name: str):
        super().__init__(name=f"openru-dash-{name}", daemon=True)
        self.manager = manager
        self.state = manager.state
        self.settings = manager.settings
        self.docker = manager.docker
        self.stop_event = manager.stop_event

    def run(self) -> None:
        try:
            self.loop()
        except Exception as exc:  # pragma: no cover - defensive
            log.exception("collector %s crashed", self.name)
            self.state.collector_error(self.name, f"crashed: {exc}")

    def loop(self) -> None:  # pragma: no cover - abstract
        raise NotImplementedError


class StackCollector(_Collector):
    def __init__(self, manager: "CollectorManager"):
        super().__init__(manager, "docker")

    def loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                items = self.docker.containers(all_=True)
                containers = []
                for item in items:
                    inspect = None
                    try:
                        inspect = self.docker.inspect(item.get("Id", ""))
                    except DockerError:
                        pass
                    containers.append(container_from_api(item, inspect))
                snapshot = stack_snapshot(
                    containers,
                    time.time(),
                    expected=("core", "du", "protoru"),
                    required=("du", "protoru"),
                )
                self.state.set_stack(snapshot)
                self.state.set_collector("docker", True)
            except Exception as exc:
                self.state.collector_error("docker", str(exc))
            self.stop_event.wait(2.0)


class HostCollector(_Collector):
    def __init__(self, manager: "CollectorManager"):
        super().__init__(manager, "host")

    def loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                self.state.set_host(host_snapshot(self.settings.bench_env))
                self.state.set_collector("host", True)
            except Exception as exc:
                self.state.collector_error("host", str(exc))
            self.stop_event.wait(5.0)


class _DockerLogCollector(_Collector):
    service = ""
    source = ""
    tail = 300

    def __init__(self, manager: "CollectorManager"):
        super().__init__(manager, self.source)
        self._last_ts: Optional[float] = None
        self._seen: Deque[Tuple[Optional[float], str]] = deque(maxlen=800)
        self._seen_set = set()
        self._last_text = ""

    def find_container(self) -> Optional[str]:
        for item in self.docker.containers(all_=True):
            labels = item.get("Labels") or {}
            if labels.get("com.docker.compose.service") == self.service:
                return item.get("Id")
            name = (item.get("Names") or [""])[0].lstrip("/")
            if name == f"openru-{self.service}-1":
                return item.get("Id")
        return None

    def _duplicate(self, ts: Optional[float], text: str) -> bool:
        if ts is not None:
            key = (round(ts, 6), text[:160])
        else:
            key = (None, text[:160])
        if key in self._seen_set:
            return True
        if len(self._seen) == self._seen.maxlen:
            old = self._seen.popleft()
            self._seen_set.discard(old)
        self._seen.append(key)
        self._seen_set.add(key)
        return False

    def handle_line(self, text: str, ts: float) -> None:  # pragma: no cover - abstract
        raise NotImplementedError

    def loop(self) -> None:
        while not self.stop_event.is_set():
            container_id = None
            try:
                container_id = self.find_container()
                if not container_id:
                    self.state.set_collector(self.source, False, f"{self.service} container not found")
                    self.stop_event.wait(3.0)
                    continue
                self.state.set_collector(self.source, True)
                with self.docker.logs_stream(
                    container_id, tail=self.tail, since=self._last_ts
                ) as stream:
                    self.manager.track(stream)
                    try:
                        for raw in stream:
                            if self.stop_event.is_set():
                                break
                            text, stamp = strip_docker_timestamp(raw)
                            text = strip_ansi(text).rstrip()
                            if not text:
                                continue
                            if stamp is not None:
                                if self._last_ts is not None and stamp < self._last_ts - 5:
                                    # Container was recreated and logs restarted.
                                    self._last_ts = None
                                self._last_ts = max(self._last_ts or stamp, stamp)
                            if self._duplicate(stamp, text):
                                continue
                            self._last_text = text
                            self.handle_line(text, stamp if stamp is not None else time.time())
                    finally:
                        self.manager.untrack(stream)
            except Exception as exc:
                self.state.collector_error(self.source, str(exc))
            self.stop_event.wait(1.0 if container_id else 3.0)


class ProtoruCollector(_DockerLogCollector):
    service = "protoru"
    source = "ru"
    tail = 300

    def handle_line(self, text: str, ts: float) -> None:
        sample = parse_row(text, time.time())
        if sample is not None:
            self.state.add_ru(sample.to_point())
        self.state.add_log("ru", text, ts)


class CoreCollector(_DockerLogCollector):
    service = "core"
    source = "core"
    tail = 500

    def __init__(self, manager: "CollectorManager"):
        super().__init__(manager)
        self.acc = CoreAccumulator()
        self._last_publish = 0.0

    def handle_line(self, text: str, ts: float) -> None:
        self.acc.process(text, time.time())
        self.state.add_log("core", text, ts)
        now = time.time()
        if now - self._last_publish >= 1.0:
            self.state.set_core(self.acc.snapshot(now))
            self._last_publish = now


class DuCollector(_Collector):
    """Follow /tmp/gnb.log inside the DU container (read-only tail)."""

    def __init__(self, manager: "CollectorManager"):
        super().__init__(manager, "du")
        self.acc = DuAccumulator()
        self._last_publish = 0.0
        self._last_metric_log = 0.0
        self._last_error_log = 0.0
        self._last_line_ts: Optional[float] = None
        self._last_line_text = ""
        self._seeded: set[str] = set()

    def find_container(self) -> Optional[str]:
        for item in self.docker.containers(all_=True):
            labels = item.get("Labels") or {}
            if labels.get("com.docker.compose.service") == "du":
                return item.get("Id")
            name = (item.get("Names") or [""])[0].lstrip("/")
            if name == "openru-du-1":
                return item.get("Id")
        return None

    def _seed(self, container_id: str) -> None:
        if container_id in self._seeded:
            return
        self._seeded.add(container_id)
        try:
            with self.docker.exec_stream(
                container_id, ["head", "-n", "500", self.settings.du_log_path]
            ) as stream:
                self.manager.track(stream)
                try:
                    for raw in stream:
                        text = strip_ansi(raw).rstrip()
                        if text:
                            self.acc.process(text, time.time())
                finally:
                    self.manager.untrack(stream)
            # Seed only the static config/cell state; do not let the historical
            # startup burst inflate the live error window.
            from ..parsers.du import ErrorTracker

            self.acc.errors = ErrorTracker()
            self.acc.last_late_ul_req = None
            self.state.set_du(self.acc.snapshot(time.time()), self.acc.point())
        except Exception:
            # `head` is a convenience; tail still works if exec is unavailable.
            pass

    def _maybe_log(self, text: str, now: float) -> None:
        if "Cell creation" in text or "SSB " in text or re.match(r"^\s*(pci|dl_arfcn|band):", text):
            self.state.add_log("du", text, now)
            return
        if "[METRICS" in text:
            if now - self._last_metric_log < 2.0:
                return
            self._last_metric_log = now
        elif (
            any(pattern.search(text) for pattern in SEQ_PAST_PATTERNS)
            or MISSED_PRACH_RE.search(text)
            or LATE_PRACH_RE.search(text)
        ):
            if now - self._last_error_log < 1.0:
                return
            self._last_error_log = now
        self.state.add_log("du", text, now)

    def _accept_line(self, text: str) -> bool:
        _body, stamp = strip_docker_timestamp(text)
        if stamp is None:
            return True
        if self._last_line_ts is not None:
            if stamp < self._last_line_ts - 10.0:
                self._last_line_ts = None
            elif stamp < self._last_line_ts:
                return False
            elif stamp == self._last_line_ts and text == self._last_line_text:
                return False
        self._last_line_ts = stamp
        self._last_line_text = text
        return True

    def loop(self) -> None:
        while not self.stop_event.is_set():
            container_id = None
            try:
                container_id = self.find_container()
                if not container_id:
                    self.state.set_collector("du", False, "du container not found")
                    self.stop_event.wait(3.0)
                    continue
                self._seed(container_id)
                with self.docker.exec_stream(
                    container_id,
                    [
                        "timeout",
                        "600",
                        "tail",
                        "-F",
                        "-n",
                        "200",
                        self.settings.du_log_path,
                    ],
                ) as stream:
                    self.manager.track(stream)
                    self.state.set_collector("du", True)
                    try:
                        for raw in stream:
                            if self.stop_event.is_set():
                                break
                            text = strip_ansi(raw).rstrip()
                            if not text or not self._accept_line(text):
                                continue
                            now = time.time()
                            self.acc.process(text, now)
                            self._maybe_log(text, now)
                            if now - self._last_publish >= 0.5:
                                self.state.set_du(
                                    self.acc.snapshot(now), self.acc.point()
                                )
                                self._last_publish = now
                    finally:
                        self.manager.untrack(stream)
            except Exception as exc:
                self.state.collector_error("du", str(exc))
            self.stop_event.wait(1.0 if container_id else 3.0)


def _at_query(ser, command: str, timeout: float = 0.8) -> str:
    ser.reset_input_buffer()
    ser.write((command + "\r").encode())
    ser.flush()
    lines = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        raw = ser.readline()
        if not raw:
            continue
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            continue
        lines.append(line)
        if line in {"OK", "ERROR"} or line.startswith("+CME ERROR"):
            break
    return "\n".join(lines)


class ModemCollector(_Collector):
    def __init__(self, manager: "CollectorManager", label: str):
        super().__init__(manager, f"modem_{label}")
        self.label = label
        self.port = self.settings.modem_ports.get(label)

    def _absent(self, reason: str, connected: bool = False) -> None:
        self.state.set_modem(
            self.label,
            {
                "label": self.label,
                "port": self.port,
                "present": bool(self.port and Path(self.port).exists()),
                "connected": connected,
                "error": reason,
                "updated": time.time(),
                "sim": {"imsi": None, "present": False},
                "signal": {},
                "registration": {},
                "serving": None,
                "pdn": None,
                "operator": {},
                "network": {},
                "cfun": None,
                "cfun_name": None,
                "registered": False,
            },
        )

    def loop(self) -> None:
        if not self.settings.modem_enabled:
            self._absent("modems disabled by OPENRU_MODEM_DISABLE")
            self.state.set_collector(f"modem_{self.label}", False, "disabled")
            return
        if not self.port:
            self._absent("no modem port configured")
            self.state.set_collector(f"modem_{self.label}", False, "no port")
            return
        try:
            import serial  # type: ignore
        except Exception:
            self._absent("pyserial is not installed")
            self.state.set_collector(f"modem_{self.label}", False, "pyserial missing")
            return

        last_error = None
        while not self.stop_event.is_set():
            if not Path(self.port).exists():
                self._absent("port not present")
                self.state.set_collector(
                    f"modem_{self.label}", False, "port not present"
                )
                self.stop_event.wait(5.0)
                continue
            ser = None
            try:
                ser = serial.Serial(
                    self.port,
                    self.settings.modem_baud,
                    timeout=0.4,
                    write_timeout=0.5,
                    exclusive=True,
                )
                text = ""
                for command in MODEM_COMMANDS:
                    text += _at_query(ser, command) + "\n"
                    if self.stop_event.is_set():
                        break
                snapshot = parse_response(text)
                snapshot.update(
                    {
                        "label": self.label,
                        "port": self.port,
                        "present": True,
                        "connected": True,
                        "error": None,
                        "updated": time.time(),
                    }
                )
                self.state.set_modem(self.label, snapshot)
                self.state.set_collector(f"modem_{self.label}", True)
                last_error = None
            except Exception as exc:
                message = redact_text(str(exc))
                if message != last_error:
                    log.warning("modem %s: %s", self.label, message)
                    last_error = message
                self._absent(message, connected=ser is not None)
                self.state.set_collector(f"modem_{self.label}", False, message)
            finally:
                if ser is not None:
                    try:
                        ser.close()
                    except Exception:
                        pass
            self.stop_event.wait(5.0)


class CollectorManager:
    def __init__(self, settings: Settings, state: DashboardState):
        self.settings = settings
        self.state = state
        self.stop_event = threading.Event()
        self._streams = set()
        self._streams_lock = threading.Lock()
        self.docker = DockerClient(settings.docker_host, settings.compose_project)
        self._threads = []

    def track(self, stream) -> None:
        with self._streams_lock:
            self._streams.add(stream)

    def untrack(self, stream) -> None:
        with self._streams_lock:
            self._streams.discard(stream)

    def start(self) -> None:
        for label in ("A", "B"):
            port = self.settings.modem_ports.get(label)
            self.state.set_modem(
                label,
                {
                    "label": label,
                    "port": port,
                    "present": bool(port and Path(port).exists()),
                    "connected": False,
                    "error": None if port else "no modem port configured",
                    "updated": time.time(),
                    "sim": {"imsi": None, "present": False},
                    "signal": {},
                    "registration": {},
                    "serving": None,
                    "pdn": None,
                    "operator": {},
                    "network": {},
                    "cfun": None,
                    "cfun_name": None,
                    "registered": False,
                },
            )
        self._threads = [
            StackCollector(self),
            HostCollector(self),
            ProtoruCollector(self),
            CoreCollector(self),
            DuCollector(self),
            ModemCollector(self, "A"),
            ModemCollector(self, "B"),
        ]
        for thread in self._threads:
            thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        with self._streams_lock:
            streams = list(self._streams)
        for stream in streams:
            try:
                stream.close()
            except Exception:
                pass
        for thread in self._threads:
            thread.join(timeout=3.0)
