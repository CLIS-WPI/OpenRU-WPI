"""FastAPI application for the read-only OpenRU bench dashboard."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import time
import urllib.parse
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    RedirectResponse,
    Response,
    StreamingResponse,
)

from .config import Settings
from .state import DashboardState

COOKIE_NAME = "openru_dash"
INDEX = Path(__file__).resolve().parent / "static" / "index.html"
LOGIN = Path(__file__).resolve().parent / "static" / "login.html"

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
    "Content-Security-Policy": (
        "default-src 'self'; script-src 'self'; style-src 'self'; "
        "img-src 'self' data:; connect-src 'self'; font-src 'self'; "
        "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    ),
}


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _sign(settings: Settings, issued: int, nonce: str) -> str:
    message = f"{issued}:{nonce}".encode()
    signature = hmac.new(settings.token.encode(), message, hashlib.sha256).digest()
    return f"{issued}:{nonce}:{_b64(signature)}"


def _verify(settings: Settings, value: Optional[str]) -> bool:
    if not value:
        return False
    try:
        issued_text, nonce, signature = value.split(":", 2)
        issued = int(issued_text)
    except (ValueError, TypeError):
        return False
    if issued > time.time() + 60 or time.time() - issued > settings.session_ttl_s:
        return False
    expected = _sign(settings, issued, nonce).split(":", 2)[2]
    return hmac.compare_digest(signature, expected)


def _cookie(settings: Settings, response: Response) -> None:
    issued = int(time.time())
    nonce = base64.urlsafe_b64encode(hashlib.sha256(str(time.time_ns()).encode()).digest())[
        :12
    ].decode()
    response.set_cookie(
        COOKIE_NAME,
        _sign(settings, issued, nonce),
        max_age=settings.session_ttl_s,
        httponly=True,
        samesite="lax",
        secure=settings.cookie_secure,
        path="/",
    )


def _authed(settings: Settings, request: Request) -> bool:
    if settings.allow_anon:
        return True
    return _verify(settings, request.cookies.get(COOKIE_NAME))


def _guard(settings: Settings, request: Request) -> None:
    if not _authed(settings, request):
        raise HTTPException(status_code=401, detail="authentication required")


def _json_for_script(data) -> str:
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False).replace(
        "</", "<\\/"
    )


def create_app(settings: Settings, state: DashboardState) -> FastAPI:
    app = FastAPI(
        title="OpenRU bench dashboard",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = settings
    app.state.dashboard = state

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        for key, value in SECURITY_HEADERS.items():
            response.headers.setdefault(key, value)
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/healthz")
    async def healthz():
        return {"ok": True, "read_only": True}

    @app.get("/login", response_class=HTMLResponse)
    async def login_page(request: Request, error: Optional[str] = None):
        if _authed(settings, request):
            return RedirectResponse("/", status_code=303)
        html = LOGIN.read_text(encoding="utf-8")
        banner = '<p class="login-error">Invalid token.</p>' if error else ""
        return HTMLResponse(html.replace("__ERROR__", banner))

    @app.post("/login")
    async def login(request: Request):
        body = (await request.body()).decode("utf-8", errors="replace")
        form = urllib.parse.parse_qs(body)
        supplied = (form.get("token") or [""])[0]
        if not hmac.compare_digest(str(supplied), str(settings.token)):
            return RedirectResponse("/login?error=1", status_code=303)
        response = RedirectResponse("/", status_code=303)
        _cookie(settings, response)
        return response

    @app.post("/logout")
    async def logout():
        response = RedirectResponse("/login", status_code=303)
        response.delete_cookie(COOKIE_NAME, path="/")
        return response

    @app.get("/", response_class=HTMLResponse)
    async def index(request: Request):
        if not _authed(settings, request):
            return RedirectResponse("/login", status_code=303)
        snapshot = state.snapshot()
        snapshot["auth_disabled"] = settings.allow_anon
        snapshot["auth_mode"] = "disabled" if settings.allow_anon else "token"
        html = INDEX.read_text(encoding="utf-8")
        html = html.replace("__BOOTSTRAP__", _json_for_script(snapshot))
        response = HTMLResponse(html)
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/api/state")
    async def api_state(request: Request):
        _guard(settings, request)
        data = state.snapshot()
        data["auth_disabled"] = settings.allow_anon
        data["auth_mode"] = "disabled" if settings.allow_anon else "token"
        return JSONResponse(data)

    @app.get("/api/events")
    async def api_events(request: Request):
        _guard(settings, request)

        async def stream():
            while True:
                if await request.is_disconnected():
                    break
                data = state.snapshot()
                data["auth_disabled"] = settings.allow_anon
                data["auth_mode"] = "disabled" if settings.allow_anon else "token"
                payload = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
                yield f"event: state\ndata: {payload}\n\n"
                await asyncio.sleep(1.0)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    @app.get("/static/{path:path}")
    async def static_file(path: str):
        base = Path(__file__).resolve().parent / "static"
        candidate = (base / path).resolve()
        if base not in candidate.parents or not candidate.is_file():
            raise HTTPException(status_code=404)
        media = {
            ".js": "text/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
        }.get(candidate.suffix, "application/octet-stream")
        return FileResponse(candidate, media_type=media, headers={"Cache-Control": "no-cache"})

    @app.get("/favicon.ico")
    async def favicon():
        return Response(status_code=204)

    @app.exception_handler(404)
    async def not_found(request: Request, exc):
        if request.url.path.startswith("/api/"):
            return JSONResponse({"detail": "not found"}, status_code=404)
        return RedirectResponse("/", status_code=303)

    return app
