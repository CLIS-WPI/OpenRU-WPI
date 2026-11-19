"""Minimal read-only Docker Engine API client.

Only GET requests and log/exec streams are used.  The dashboard never starts,
stops, restarts or modifies a container.
"""

from __future__ import annotations

import http.client
import json
import socket
import urllib.parse
from typing import Generator, Iterable, Optional


class DockerError(RuntimeError):
    pass


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: Optional[float] = 30.0):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout is not None:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def _parse_host(docker_host: str) -> dict:
    if docker_host.startswith("http+unix://"):
        encoded = docker_host[len("http+unix://") :]
        return {"kind": "unix", "path": urllib.parse.unquote(encoded)}
    if docker_host.startswith("unix://"):
        return {"kind": "unix", "path": docker_host[len("unix://") :]}
    if docker_host.startswith("tcp://"):
        parsed = urllib.parse.urlparse("http://" + docker_host[len("tcp://") :])
        return {"kind": "tcp", "host": parsed.hostname or "localhost", "port": parsed.port or 2375}
    if docker_host.startswith(("http://", "https://")):
        parsed = urllib.parse.urlparse(docker_host)
        return {
            "kind": "https" if parsed.scheme == "https" else "tcp",
            "host": parsed.hostname or "localhost",
            "port": parsed.port or (443 if parsed.scheme == "https" else 2375),
        }
    return {"kind": "unix", "path": docker_host}


class DockerClient:
    def __init__(self, docker_host: str = "unix:///var/run/docker.sock", project: str = "openru"):
        self.docker_host = docker_host
        self.project = project
        self._target = _parse_host(docker_host)

    def _connection(self, timeout: Optional[float] = 30.0) -> http.client.HTTPConnection:
        if self._target["kind"] == "unix":
            return _UnixHTTPConnection(self._target["path"], timeout=timeout)
        if self._target["kind"] == "https":
            return http.client.HTTPSConnection(
                self._target["host"], self._target["port"], timeout=timeout
            )
        return http.client.HTTPConnection(
            self._target["host"], self._target["port"], timeout=timeout
        )

    def _request(self, method: str, path: str, body: Optional[dict] = None, timeout: Optional[float] = 30.0):
        connection = self._connection(timeout=timeout)
        headers = {"Host": "docker"}
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(payload))
        try:
            connection.request(method, path, body=payload, headers=headers)
            return connection, connection.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            connection.close()
            raise DockerError(f"{method} {path}: {exc}") from exc

    def json(self, path: str, timeout: float = 10.0):
        connection, response = self._request("GET", path, timeout=timeout)
        try:
            data = response.read()
            if response.status >= 400:
                raise DockerError(
                    f"GET {path}: {response.status} {data[:300].decode(errors='replace')}"
                )
            return json.loads(data.decode() or "null")
        finally:
            connection.close()

    def ping(self) -> bool:
        connection, response = self._request("GET", "/_ping", timeout=3.0)
        try:
            response.read()
            return response.status == 200
        finally:
            connection.close()

    def containers(self, all_: bool = True) -> list:
        filters = json.dumps(
            {"label": [f"com.docker.compose.project={self.project}"]}
        )
        query = urllib.parse.urlencode({"all": "1" if all_ else "0", "filters": filters})
        return self.json(f"/containers/json?{query}")

    def inspect(self, container_id: str) -> dict:
        return self.json(f"/containers/{container_id}/json")

    def image(self, name: str) -> Optional[dict]:
        try:
            return self.json(f"/images/{urllib.parse.quote(name, safe='')}/json")
        except DockerError:
            return None

    def logs_stream(
        self,
        container_id: str,
        tail: int = 200,
        since: Optional[float] = None,
        follow: bool = True,
    ):
        params = {
            "stdout": "1",
            "stderr": "1",
            "timestamps": "1",
            "follow": "1" if follow else "0",
        }
        if since is not None:
            params["since"] = f"{since:.3f}"
            params["tail"] = "all"
        else:
            params["tail"] = str(tail)
        path = f"/containers/{container_id}/logs?{urllib.parse.urlencode(params)}"
        connection, response = self._request("GET", path, timeout=None)
        if response.status >= 400:
            data = response.read()
            connection.close()
            raise DockerError(
                f"logs {container_id}: {response.status} {data[:300].decode(errors='replace')}"
            )
        return _Stream(connection, response)

    def exec_stream(self, container_id: str, cmd: Iterable[str]):
        body = {
            "AttachStdin": False,
            "AttachStdout": True,
            "AttachStderr": True,
            "Tty": False,
            "Cmd": list(cmd),
        }
        connection, response = self._request(
            "POST", f"/containers/{container_id}/exec", body=body, timeout=10.0
        )
        try:
            data = response.read()
            if response.status >= 400:
                raise DockerError(
                    f"exec create {container_id}: {response.status} {data[:300].decode(errors='replace')}"
                )
            exec_id = json.loads(data.decode()).get("Id")
        finally:
            connection.close()
        if not exec_id:
            raise DockerError(f"exec create {container_id}: no exec id")
        body = {"Detach": False, "Tty": False}
        connection, response = self._request(
            "POST",
            f"/exec/{exec_id}/start",
            body=body,
            timeout=None,
        )
        if response.status >= 400:
            data = response.read()
            connection.close()
            raise DockerError(
                f"exec start {exec_id}: {response.status} {data[:300].decode(errors='replace')}"
            )
        return _Stream(connection, response)


class _Stream:
    """Iterate newline-delimited text from a Docker raw/multiplexed stream."""

    def __init__(self, connection: http.client.HTTPConnection, response):
        self.connection = connection
        self.response = response
        self._buffer = b""
        self._raw_mode = False
        self._text_buffer = ""

    def close(self) -> None:
        try:
            self.response.close()
        finally:
            self.connection.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def _yield_text(self, text: str) -> Generator[str, None, None]:
        self._text_buffer += text
        while "\n" in self._text_buffer:
            line, self._text_buffer = self._text_buffer.split("\n", 1)
            yield line.rstrip("\r")

    def __iter__(self) -> Generator[str, None, None]:
        while True:
            try:
                chunk = self.response.read(65536)
            except (OSError, http.client.HTTPException):
                break
            if not chunk:
                break
            self._buffer += chunk
            while True:
                if self._raw_mode:
                    text = self._buffer.decode("utf-8", errors="replace")
                    self._buffer = b""
                    yield from self._yield_text(text)
                    break
                if len(self._buffer) < 8:
                    break
                header = self._buffer[:8]
                stream_type = header[0]
                length = int.from_bytes(header[4:8], "big")
                if stream_type not in (0, 1, 2) or length > 32 * 1024 * 1024:
                    self._raw_mode = True
                    continue
                if len(self._buffer) < 8 + length:
                    break
                payload = self._buffer[8 : 8 + length]
                self._buffer = self._buffer[8 + length :]
                yield from self._yield_text(payload.decode("utf-8", errors="replace"))
        if self._buffer:
            yield from self._yield_text(self._buffer.decode("utf-8", errors="replace"))
        if self._text_buffer:
            yield self._text_buffer.rstrip("\r")
            self._text_buffer = ""
