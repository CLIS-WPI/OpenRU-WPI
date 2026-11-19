#!/usr/bin/env python3
"""Run the read-only OpenRU bench dashboard.

Collectors are started exactly once here (not in FastAPI lifespan) and the web
app is served on each configured bind address by a separate uvicorn thread.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import uvicorn  # noqa: E402

from dashboard.app import create_app  # noqa: E402
from dashboard.collectors import CollectorManager  # noqa: E402
from dashboard.config import load_settings  # noqa: E402
from dashboard.state import DashboardState  # noqa: E402


def main() -> int:
    settings = load_settings()
    for warning in settings.warnings:
        print(f"[dashboard] {warning}", file=sys.stderr)
    if not settings.token:
        print("[dashboard] refusing to start without a token", file=sys.stderr)
        return 2
    generated = not bool(__import__("os").environ.get("OPENRU_DASH_TOKEN"))
    if generated:
        print(f"[dashboard] one-time token: {settings.token}", file=sys.stderr)
    if settings.allow_anon:
        print(
            "[dashboard] AUTH DISABLED (OPENRU_DASH_ALLOW_ANON=1); "
            "only use this on localhost for screenshots",
            file=sys.stderr,
        )

    state = DashboardState(settings)
    replay_path = os.environ.get("OPENRU_DASH_REPLAY")
    manager = None
    if replay_path:
        path = Path(replay_path).expanduser()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"[dashboard] replay load failed: {exc}", file=sys.stderr)
            return 2
        state.load_replay(payload)
        print(f"[dashboard] REPLAY mode: {path} (no collectors started)", file=sys.stderr)
    else:
        manager = CollectorManager(settings, state)
    app = create_app(settings, state)

    servers = []
    threads = []
    for host in settings.binds:
        config = uvicorn.Config(
            app,
            host=host,
            port=settings.port,
            log_level="warning",
            access_log=False,
            lifespan="off",
        )
        server = uvicorn.Server(config)
        thread = threading.Thread(
            target=server.run,
            name=f"uvicorn-{host}",
            daemon=True,
        )
        thread.start()
        servers.append((host, server))
        threads.append(thread)

    deadline = time.time() + 5.0
    while time.time() < deadline and not any(server.started for _, server in servers):
        time.sleep(0.1)

    started = [(host, server) for host, server in servers if server.started]
    if not started:
        print("[dashboard] no bind address could be served", file=sys.stderr)
        if manager:
            manager.stop()
        return 1
    for host, _server in started:
        print(f"[dashboard] http://{host}:{settings.port}/  (read-only, token auth)")
    for host, server in servers:
        if not server.started:
            print(f"[dashboard] WARNING: could not bind {host}:{settings.port}", file=sys.stderr)

    if manager:
        manager.start()
    print(
        f"[dashboard] profile={settings.profile} tag={settings.release.get('tag')} "
        f"commit={settings.release.get('commit')}",
        file=sys.stderr,
    )

    stop = threading.Event()

    def _signal(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGINT, _signal)
    signal.signal(signal.SIGTERM, _signal)

    try:
        while not stop.wait(0.5):
            if all(server.should_exit for _, server in servers):
                break
    except KeyboardInterrupt:
        pass
    finally:
        if manager:
            manager.stop()
        for _host, server in servers:
            server.should_exit = True
        for thread in threads:
            thread.join(timeout=3.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
