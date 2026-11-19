"""Configuration for the read-only OpenRU bench dashboard."""

from __future__ import annotations

import ipaddress
import os
import socket
import struct
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional

try:
    import fcntl
except ImportError:  # pragma: no cover - non-Linux fallback
    fcntl = None  # type: ignore[assignment]

SIOCGIFADDR = 0x8915


def _read_env_file(path: Path) -> dict:
    values = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def _git(root: Path, *args: str) -> Optional[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        )
        return result.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


VPN_PREFIXES = ("tailscale", "wg", "tun", "tap", "ppp", "zt", "nebula")  # no-secrets-ok


def _interface_ipv4s() -> List[tuple[str, str]]:
    """Return (interface, IPv4) for VPN-like interfaces only.

    The default bind list must never expose the dashboard on a physical lab
    NIC (radio, management, docker bridge).  An operator who really wants a
    specific private address can set OPENRU_DASH_BIND explicitly.
    """

    if fcntl is None:
        return []
    out: List[tuple[str, str]] = []
    try:
        names = [name for _, name in socket.if_nameindex()]
    except OSError:
        return []
    for name in names:
        if not name.startswith(VPN_PREFIXES):
            continue
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            packed = fcntl.ioctl(
                sock.fileno(), SIOCGIFADDR, struct.pack("256s", name[:15].encode())
            )
        except OSError:
            continue
        finally:
            sock.close()
        address = socket.inet_ntoa(packed[20:24])
        if _is_private_or_loopback(address):
            out.append((name, address))
    return sorted(out, key=lambda item: item[1])


def _is_private_or_loopback(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.is_loopback:
        return True
    if ip.version == 4:
        return (
            ip in ipaddress.ip_network("10.0.0.0/8")
            or ip in ipaddress.ip_network("172.16.0.0/12")
            or ip in ipaddress.ip_network("192.168.0.0/16")
            or ip in ipaddress.ip_network("100.64.0.0/10")  # no-secrets-ok
        )
    return ip in ipaddress.ip_network("fc00::/7")


def _guard_bind(host: str) -> str:
    host = host.strip()
    if host in {"", "0.0.0.0", "::", "*"}:
        raise ValueError("refusing to bind a wildcard address (use localhost or a private VPN IP)")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        if host in {"localhost"}:
            return host
        raise ValueError(f"invalid bind address: {host}") from None
    if not _is_private_or_loopback(str(ip)):
        raise ValueError(
            f"refusing to bind non-private address {host}; use localhost or a private VPN address"
        )
    return host


def _default_binds() -> List[str]:
    hosts = ["127.0.0.1"]
    for _name, address in _interface_ipv4s():
        if address not in hosts:
            hosts.append(address)
    return hosts


@dataclass
class Settings:
    root: Path
    hostname: str
    token: str
    binds: List[str]
    port: int
    profile: str
    profile_path: Path
    bench_env_path: Path
    bench_env: dict
    release: dict
    docker_host: str
    compose_project: str
    du_log_path: str
    max_log_lines: int
    session_ttl_s: int
    allow_anon: bool
    cookie_secure: bool
    modem_ports: dict
    modem_baud: int
    modem_enabled: bool
    warnings: List[str] = field(default_factory=list)

    @property
    def static_dir(self) -> Path:
        return Path(__file__).resolve().parent / "static"


def _profile_release(root: Path, profile: str) -> dict:
    candidate = root / "profiles" / profile / "protoru.yml"
    null_candidate = root / "profiles" / profile / "protoru-null.yml"
    data = {"profile": profile, "path": str(candidate), "tx_gain": None, "rx_gain": None}
    path = candidate if candidate.exists() else null_candidate
    if not path.exists():
        return data
    data["path"] = str(path)
    try:
        import yaml  # type: ignore
    except Exception:
        return data
    try:
        parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        cells = ((parsed.get("ru_emu") or {}).get("cells") or [])
        if cells:
            cell = cells[0]
            sdr = cell.get("sdr") or {}
            data.update(
                {
                    "tx_gain": sdr.get("tx_gain"),
                    "rx_gain": sdr.get("rx_gain"),
                    "band": cell.get("band"),
                    "dl_arfcn": cell.get("dl_arfcn"),
                    "bandwidth_mhz": cell.get("bandwidth"),
                    "radio": sdr.get("device_driver") or sdr.get("device_args") or None,
                }
            )
    except Exception:
        pass
    return data


def load_settings() -> Settings:
    root = Path(__file__).resolve().parents[3]
    warnings: List[str] = []
    bench_env_path = Path(
        os.environ.get("OPENRU_BENCH_ENV", root / "docker" / "bench.env")
    )
    bench_env = _read_env_file(bench_env_path)

    tag = (
        os.environ.get("OPENRU_TAG")
        or bench_env.get("OPENRU_TAG")
        or "bench-latest"
    )
    commit = (
        os.environ.get("OPENRU_GIT_COMMIT")
        or _git(root, "rev-parse", "--short=12", "HEAD")
        or "unknown"
    )
    submodule = (
        os.environ.get("OPENRU_GIT_SUBMODULE")
        or _git(root / "external" / "protoru", "rev-parse", "--short=12", "HEAD")
        or _git(root / "external" / "proto-ru", "rev-parse", "--short=12", "HEAD")
        or "unknown"
    )
    profile = (
        os.environ.get("OPENRU_PROFILE")
        or os.environ.get("PROFILE")
        or ("bench-20mhz" if (root / "profiles" / "bench-20mhz").exists() else "baseline")
    )
    release = _profile_release(root, profile)
    release.update(
        {
            "tag": tag,
            "commit": commit,
            "submodule": submodule,
            "hostname": socket.gethostname(),
        }
    )

    token = os.environ.get("OPENRU_DASH_TOKEN") or ""  # no-secrets-ok
    if not token:
        import secrets

        token = secrets.token_urlsafe(24)  # no-secrets-ok
        warnings.append(
            "OPENRU_DASH_TOKEN was not set; using a generated token printed below."
        )

    raw_binds = os.environ.get("OPENRU_DASH_BIND")
    if raw_binds:
        binds = []
        for item in raw_binds.split(","):
            host = item.strip()
            if host:
                binds.append(_guard_bind(host))
    else:
        binds = _default_binds()
    binds = list(dict.fromkeys(binds))
    if not binds:
        binds = ["127.0.0.1"]

    port = int(os.environ.get("OPENRU_DASH_PORT", "8787"))
    if not (1 <= port <= 65535):
        raise ValueError("OPENRU_DASH_PORT must be between 1 and 65535")

    docker_host = (
        os.environ.get("OPENRU_DOCKER_HOST")
        or os.environ.get("DOCKER_HOST")
        or "unix:///var/run/docker.sock"
    )

    ports = {}
    for label, env_name in (
        ("A", "OPENRU_MODEM_A_PORT"),
        ("B", "OPENRU_MODEM_B_PORT"),
    ):
        value = os.environ.get(env_name)
        if value:
            ports[label] = value
            continue
        for candidate in ("/dev/ttyUSB0", "/dev/ttyUSB1") if label == "A" else (
            "/dev/ttyUSB1",
            "/dev/ttyUSB0",
        ):
            if Path(candidate).exists() and candidate not in ports.values():
                ports[label] = candidate
                break

    allow_anon = os.environ.get("OPENRU_DASH_ALLOW_ANON", "").lower() in {
        "1",
        "true",
        "yes",
    }
    if allow_anon:
        warnings.append("OPENRU_DASH_ALLOW_ANON is set; remove it outside local screenshots.")

    return Settings(
        root=root,
        hostname=socket.gethostname(),
        token=token,  # no-secrets-ok
        binds=binds,
        port=port,
        profile=profile,
        profile_path=Path(release["path"]),
        bench_env_path=bench_env_path,
        bench_env=bench_env,
        release=release,
        docker_host=docker_host,
        compose_project=os.environ.get("OPENRU_COMPOSE_PROJECT", "openru"),
        du_log_path=os.environ.get("OPENRU_DU_LOG_PATH", "/tmp/gnb.log"),
        max_log_lines=int(os.environ.get("OPENRU_DASH_MAX_LOG_LINES", "750")),
        session_ttl_s=int(os.environ.get("OPENRU_DASH_SESSION_TTL", str(12 * 3600))),
        allow_anon=allow_anon,
        cookie_secure=os.environ.get("OPENRU_DASH_COOKIE_SECURE", "").lower()
        in {"1", "true", "yes"},
        modem_ports=ports,
        modem_baud=int(os.environ.get("OPENRU_MODEM_BAUD", "115200")),
        modem_enabled=os.environ.get("OPENRU_MODEM_DISABLE", "").lower()
        not in {"1", "true", "yes"},
        warnings=warnings,
    )


def auth_token_matches(settings: Settings, supplied: Optional[str]) -> bool:
    if not supplied:
        return False
    import hmac

    return hmac.compare_digest(str(supplied), str(settings.token))
