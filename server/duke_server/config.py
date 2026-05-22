"""Runtime configuration loaded from environment variables.

All knobs live on the immutable :class:`ServerConfig` dataclass and are
populated by :meth:`ServerConfig.from_env`. Use environment variables with
the ``DUKE_*`` prefix to override defaults.

Environment variables
---------------------
``DUKE_HOST``               Interface to bind. Default ``"0.0.0.0"``.
``DUKE_PORT``               TCP port. Default ``8765``.
``DUKE_TLS``                ``"1"``/``"0"`` toggle for WSS vs WS. Default on.
``DUKE_CERT_DIR``           Where the self-signed cert is read/written.
``DUKE_SESSION_SECRET``     HMAC key for session tokens. Random per-boot
                            if unset (clients lose sessions on restart).
``DUKE_MAX_ROOMS``          Hard cap on concurrent rooms.
``DUKE_MAX_CLIENTS``        Hard cap on simultaneous WebSocket clients. Default 1000.
``DUKE_ROOM_IDLE_S``        Auto-close empty rooms after N seconds.
``DUKE_RECONNECT_S``        Reconnect grace window for in-game disconnects.
``DUKE_MOVE_MAX_AGE_S``     Reject moves stamped too far in the past.
``DUKE_HEARTBEAT_S``        WebSocket ping interval.
``DUKE_LOG_LEVEL``          Python logging level (``INFO``, ``DEBUG`` …).
``DUKE_MIN_CLIENT_VERSION`` Minimum required client game version (e.g. ``1.2.0``).
                            Empty/unset disables the check.
"""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    """Parse a truthy environment variable.

    Accepts ``1``/``true``/``yes``/``on`` (case-insensitive) as true.
    Returns ``default`` when the variable is unset or empty.
    """
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int) -> int:
    """Parse an integer environment variable, falling back on parse errors."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        return default


@dataclass(frozen=True)
class ServerConfig:
    """Immutable snapshot of server runtime configuration.

    Built once at startup via :meth:`from_env` and passed read-only to the
    :class:`~duke_server.server.Server`. Keeping it frozen avoids accidental
    mutation while requests are being served.

    Attributes
    ----------
    host:
        Interface address to bind (typically ``0.0.0.0``).
    port:
        TCP port for the WebSocket listener.
    tls_enabled:
        If true, the server speaks ``wss://`` and ensures a self-signed
        certificate exists in :attr:`cert_dir`. If false, it speaks ``ws://``
        (LAN-only / dev fallback).
    cert_dir:
        Directory where ``server.crt`` / ``server.key`` / fingerprint live.
    session_secret:
        HMAC secret used to sign session tokens. When unset in the env,
        a fresh random 32-byte secret is generated on every process start;
        in that case sessions do not survive a server restart.
    max_rooms:
        Maximum number of concurrent rooms accepted by the lobby.
    max_clients:
        Maximum number of concurrent WebSocket connections.
    room_idle_timeout_s:
        Empty rooms older than this are garbage-collected.
    reconnect_grace_s:
        How long a disconnected in-game player may rejoin before being
        forfeited.
    move_max_age_s:
        Upper bound on the age of a client-submitted move timestamp.
    heartbeat_interval_s:
        WebSocket ``ping`` interval in seconds; timeout is twice this.
    log_level:
        Standard Python ``logging`` level name.
    """

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
    min_client_version: str
    ban_file: str

    @classmethod
    def from_env(cls) -> "ServerConfig":
        """Build a :class:`ServerConfig` from process environment variables.

        Missing or unparseable values fall back to safe defaults. The
        ``DUKE_SESSION_SECRET`` variable, when empty, is replaced by a
        cryptographically random 32-byte token so the server can still
        issue valid tokens within its lifetime.
        """
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
            max_clients=_env_int("DUKE_MAX_CLIENTS", 500),
            room_idle_timeout_s=_env_int("DUKE_ROOM_IDLE_S", 600),
            reconnect_grace_s=_env_int("DUKE_RECONNECT_S", 30),
            move_max_age_s=_env_int("DUKE_MOVE_MAX_AGE_S", 30),
            heartbeat_interval_s=_env_int("DUKE_HEARTBEAT_S", 20),
            log_level=os.environ.get("DUKE_LOG_LEVEL", "INFO").upper(),
            min_client_version=os.environ.get("DUKE_MIN_CLIENT_VERSION", "").strip(),
            ban_file=os.environ.get("DUKE_BAN_FILE", "/data/banlist.json"),
        )

