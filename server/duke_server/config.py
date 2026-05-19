"""Runtime configuration loaded from environment variables."""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class ServerConfig:
    host: str
    port: int
    tls_enabled: bool
    cert_dir: str
    session_secret: bytes
    max_rooms: int
    max_clients: int
    room_idle_timeout_s: int        # auto-close empty rooms after this
    reconnect_grace_s: int          # how long a disconnected player can rejoin
    move_max_age_s: int             # reject moves stamped too far in the past
    heartbeat_interval_s: int
    log_level: str

    @classmethod
    def from_env(cls) -> "ServerConfig":
        secret_raw = os.environ.get("DUKE_SESSION_SECRET", "").strip()
        if secret_raw:
            secret_bytes = secret_raw.encode("utf-8")
        else:
            secret_bytes = secrets.token_bytes(32)
        return cls(
            host=os.environ.get("DUKE_HOST", "0.0.0.0"),
            port=_env_int("DUKE_PORT", 8765),
            tls_enabled=_env_bool("DUKE_TLS", True),
            cert_dir=os.environ.get("DUKE_CERT_DIR", "./certs"),
            session_secret=secret_bytes,
            max_rooms=_env_int("DUKE_MAX_ROOMS", 256),
            max_clients=_env_int("DUKE_MAX_CLIENTS", 512),
            room_idle_timeout_s=_env_int("DUKE_ROOM_IDLE_S", 600),
            reconnect_grace_s=_env_int("DUKE_RECONNECT_S", 30),
            move_max_age_s=_env_int("DUKE_MOVE_MAX_AGE_S", 30),
            heartbeat_interval_s=_env_int("DUKE_HEARTBEAT_S", 20),
            log_level=os.environ.get("DUKE_LOG_LEVEL", "INFO").upper(),
        )
