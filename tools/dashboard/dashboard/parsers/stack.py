"""Docker stack state (read-only) from the Docker Engine API."""

from __future__ import annotations

import datetime as _dt
import re
from typing import Dict, Iterable, List, Optional

_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$"
)


def parse_rfc3339(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    match = _TS_RE.match(value)
    if not match:
        return None
    base, fraction, zone = match.groups()
    if fraction:
        fraction = (fraction + "000000")[:6]
    stamp = base + (f".{fraction}" if fraction else "") + (zone or "Z")
    if stamp.endswith("Z"):
        stamp = stamp[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(stamp)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.timestamp()


def _label(labels: dict, key: str, default: Optional[str] = None) -> Optional[str]:
    return (labels or {}).get(key, default)


def container_from_api(item: dict, inspect: Optional[dict] = None) -> dict:
    labels = item.get("Labels") or {}
    inspect = inspect or {}
    state = inspect.get("State") or {}
    name = (item.get("Names") or ["?"])[0].lstrip("/")
    status_text = item.get("Status") or ""
    health = (state.get("Health") or {}).get("Status")
    if not health:
        match = re.search(r"\((healthy|unhealthy|starting)\)", status_text)
        health = match.group(1) if match else None
    service = _label(labels, "com.docker.compose.service")
    project = _label(labels, "com.docker.compose.project")
    if not service and name.startswith("openru-"):
        service = name[len("openru-") :].rsplit("-", 1)[0]
    return {
        "id": item.get("Id", "")[:12],
        "name": name,
        "service": service,
        "project": project,
        "image": item.get("Image") or (inspect.get("Config") or {}).get("Image"),
        "state": item.get("State") or state.get("Status"),
        "status": status_text,
        "health": health,
        "running": bool(state.get("Running", item.get("State") == "running")),
        "restart_count": state.get("RestartCount"),
        "started_at": state.get("StartedAt") or item.get("Created"),
        "started_ts": parse_rfc3339(state.get("StartedAt")),
        "created_ts": parse_rfc3339(item.get("Created")),
        "exit_code": state.get("ExitCode"),
        "oom_killed": state.get("OOMKilled"),
        "revision": _label(labels, "org.opencontainers.image.revision"),
        "compose_version": _label(labels, "com.docker.compose.version"),
    }


def stack_snapshot(
    containers: Iterable[dict],
    now: float,
    expected: Iterable[str] = ("core", "du", "protoru"),
    required: Iterable[str] = ("du", "protoru"),
) -> dict:
    services: Dict[str, dict] = {}
    for container in containers:
        service = container.get("service") or container.get("name")
        services[service] = container

    expected_list = list(expected)
    required_list = list(required)
    missing = [name for name in expected_list if name not in services]
    required_missing = [name for name in required_list if name not in services]
    running = [
        name
        for name in expected_list
        if name in services and services[name].get("running")
    ]
    required_running = [
        name
        for name in required_list
        if name in services and services[name].get("running")
    ]
    unhealthy = [
        name
        for name in expected_list
        if name in services
        and services[name].get("health") in {"unhealthy", "starting"}
    ]
    healthy = [
        name
        for name in expected_list
        if name in services and services[name].get("health") == "healthy"
    ]
    started = [
        item["started_ts"]
        for item in services.values()
        if item.get("running") and item.get("started_ts")
    ]
    uptime = round(now - min(started), 1) if started else None

    if not required_running:
        status = "down"
    elif len(required_running) == len(required_list):
        status = "up"
    else:
        status = "partial"

    return {
        "services": services,
        "expected": expected_list,
        "required": required_list,
        "missing": missing,
        "required_missing": required_missing,
        "running": running,
        "required_running": required_running,
        "unhealthy": unhealthy,
        "healthy": healthy,
        "status": status,
        "stack_up": len(required_running) == len(required_list),
        "uptime_s": uptime,
        "container_count": len(services),
    }
