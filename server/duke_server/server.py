"""Asynchronous WebSocket server: dispatch, handlers, broadcasts.

This is the orchestration layer that glues together every other module:

* :mod:`~duke_server.config` provides the read-only :class:`ServerConfig`.
* :mod:`~duke_server.tls` produces an :class:`ssl.SSLContext` when
  TLS is enabled.
* :mod:`~duke_server.lobby` tracks rooms and connected clients.
* :mod:`~duke_server.room` and :mod:`~duke_server.game` implement
  per-room state and chess rules.
* :mod:`~duke_server.protocol` names the wire messages and error codes.
* :mod:`~duke_server.auth` issues and verifies session tokens.

Concurrency model
-----------------
The server is single-process / single-threaded asyncio. One coroutine
per WebSocket (:meth:`Server._handler`) reads framed JSON messages and
dispatches them through :meth:`Server._dispatch`. Mutating a game
requires the owning :class:`~duke_server.room.Room`'s ``asyncio.Lock``
so clock deduction and move application are serialised per room while
still allowing other rooms to progress.

Background tasks
----------------
* :meth:`Server._watch_room_clock` — one per playing room with a time
  limit; polls :meth:`ChessGame.check_timeout` every 500 ms.
* :meth:`Server._reconnect_timeout` — one per disconnected in-game
  member; forfeits the player when the grace window expires.

Failure handling
----------------
Handler-raised :class:`_ClientError` is reflected to the client as a
:data:`~duke_server.protocol.S_ERROR` envelope. Any other exception is
logged and surfaced as :data:`~duke_server.protocol.ERR_INTERNAL`.
Connection drops always go through :meth:`Server._on_disconnect`.
"""

from __future__ import annotations

import asyncio
import datetime
import http
import json
import logging
import os
import re
import signal
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import websockets
from websockets.server import WebSocketServerProtocol

from . import auth
from . import protocol as P
from .banlist import BanList
from .cli import start_cli_server
from .config import ServerConfig
from .log_setup import setup_logging
from .game import BLACK, COLOR_NAMES, WHITE, IllegalMove, NotYourTurn, BadState, color_from_name
from .lobby import Lobby
from .room import Room, ROOM_STATE_PLAYING, ROOM_STATE_WAITING, ROOM_STATE_FINISHED
from .tls import ensure_cert, make_ssl_context


logger = logging.getLogger("duke_server")

NICKNAME_RE = re.compile(r"^[A-Za-z0-9_.\- ]{1,15}$")
MAX_PASSWORD_LEN = 64
MAX_ROOM_NAME_LEN = 40
MAX_MACHINE_ID_LEN = 64
MAX_VERSION_LEN = 32
PROTOCOL_VERSION = P.PROTOCOL_VERSION
MAX_MESSAGE_SIZE = 8 * 1024


def _parse_version(raw: Any) -> Optional[tuple[int, ...]]:
    """Parse a dotted version string (e.g. ``"1.2.3"``) into an int tuple.

    Accepts an int (treated as a single component) for backwards compatibility
    with older clients that sent the protocol version. Returns ``None`` if the
    value is missing, empty, or contains non-numeric components.
    """
    if raw is None:
        return None
    if isinstance(raw, int):
        return (raw,)
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s or len(s) > MAX_VERSION_LEN:
        return None
    parts = s.split(".")
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return None


@dataclass
class ClientCtx:
    """Per-connection mutable state kept by the dispatcher.

    Attached to the underlying ``WebSocketServerProtocol`` as
    ``conn._duke_ctx`` so that other handlers (e.g. duplicate-nickname
    detection) can read it from a peer connection.

    Attributes
    ----------
    conn:
        The live ``websockets`` server protocol instance.
    nickname:
        Set after a successful :data:`~duke_server.protocol.C_HELLO`.
        ``None`` means the connection is still pre-auth.
    session_token:
        Last token issued to this connection; may be re-sent by the
        client on reconnect.
    room_id:
        Id of the room this client is currently a member of, if any.
    in_lobby:
        True when the client is subscribed to lobby room-list updates.
    last_msg_ts / msg_count_window / window_start:
        Rate-limit bookkeeping — see :meth:`Server._rate_limit_ok`.
    """

    conn: WebSocketServerProtocol
    nickname: Optional[str] = None
    session_token: Optional[str] = None
    room_id: Optional[str] = None
    machine_id: Optional[str] = None
    in_lobby: bool = False
    kicked: bool = False
    last_msg_ts: float = field(default_factory=time.monotonic)
    msg_count_window: int = 0
    window_start: float = field(default_factory=time.monotonic)


class Server:
    """Top-level WebSocket server.

    Owns the :class:`~duke_server.lobby.Lobby`, the set of background
    clock-watcher and reconnect-grace tasks, and a stop event used by
    :meth:`run` / :meth:`stop` for graceful shutdown.
    """

    def __init__(self, config: ServerConfig) -> None:
        """Build a server bound to ``config`` (does not start listening)."""
        self.config = config
        self.lobby = Lobby(max_rooms=config.max_rooms)
        self.banlist = BanList(config.ban_file)
        self._start_time = time.monotonic()
        self._stop_event = asyncio.Event()
        # Per-room timeout watcher task.
        self._room_watchers: dict[str, asyncio.Task] = {}
        # Per-room reconnect timers.
        self._reconnect_timers: dict[tuple[str, str], asyncio.Task] = {}
        # TLS bootstrap data served via HTTP for TOFU certificate pinning.
        self._cert_pem: Optional[bytes] = None
        self._fingerprint: Optional[str] = None
        # Live stats exposed to the admin CLI.
        self._stats: dict = {
            "peak_players": 0,
            "connects_today": 0,
            "today_date": datetime.date.today(),
        }

    # ── Lifecycle ──────────────────────────────────────────────────────────
    async def run(self) -> None:
        """Bind the listener and serve until :meth:`stop` is called.

        Ensures a self-signed cert exists when TLS is enabled, logs the
        cert SHA-256 fingerprint so admins / clients can pin it, then
        delegates to :func:`websockets.serve` with the configured ping
        interval and an 8 KB per-message size cap.
        """
        ssl_context = None
        scheme = "ws"
        self.banlist.load()
        if self.config.tls_enabled:
            cert_path, key_path, fingerprint = ensure_cert(self.config.cert_dir)
            ssl_context = make_ssl_context(cert_path, key_path)
            scheme = "wss"
            self._cert_pem = cert_path.read_bytes()
            self._fingerprint = fingerprint
            logger.info("TLS enabled. Cert: %s", cert_path)
            logger.info("Cert SHA-256 fingerprint: %s", fingerprint)
            logger.info(
                "Clients can auto-fetch the cert at http://%s:%d/cert",
                self.config.host, self.config.port,
            )
        else:
            logger.warning("TLS DISABLED — server speaks plain ws://. Use only on trusted LAN.")

        logger.info("Listening on %s://%s:%d", scheme, self.config.host, self.config.port)

        async with websockets.serve(
            self._handler,
            host=self.config.host,
            port=self.config.port,
            ssl=ssl_context,
            max_size=MAX_MESSAGE_SIZE,
            ping_interval=self.config.heartbeat_interval_s,
            ping_timeout=self.config.heartbeat_interval_s * 2,
            process_request=self._http_process_request,
        ):
            asyncio.ensure_future(start_cli_server(
                self.banlist,
                self.lobby,
                self._kick_user,
                self._kick_by_ip,
                self._close_room,
                self.stop,
                self._start_time,
                self._stats,
                self.config,
            ))
            await self._stop_event.wait()
        logger.info("Server stopped.")

    def stop(self) -> None:
        """Signal :meth:`run` to exit; safe to call from a signal handler."""
        self._stop_event.set()

    # ── HTTP bootstrap endpoint ────────────────────────────────────────────
    async def _http_process_request(
        self, path: str, request_headers
    ) -> Optional[tuple]:
        """Intercept plain HTTP GET requests for TOFU certificate distribution.

        Clients that connect over WSS with a self-signed cert can call
        ``GET http://host:port/cert`` (plain HTTP, same port) once to
        download the PEM and pin it for all subsequent TLS connections.
        ``GET /fingerprint`` returns just the SHA-256 fingerprint line.

        Any other path falls through (returns ``None``) so WebSocket
        upgrades are handled normally.
        """
        if path == "/cert" and self._cert_pem is not None:
            return (
                http.HTTPStatus.OK,
                {"Content-Type": "application/x-pem-file"},
                self._cert_pem,
            )
        if path == "/fingerprint" and self._fingerprint is not None:
            body = (self._fingerprint + "\n").encode()
            return (
                http.HTTPStatus.OK,
                {"Content-Type": "text/plain; charset=utf-8"},
                body,
            )
        return None

    # ── Connection handler ──────────────────────────────────────────────────────
    async def _handler(self, conn: WebSocketServerProtocol) -> None:
        """Per-connection event loop.

        Enforces the global ``max_clients`` cap, then reads framed JSON
        messages one at a time. Each message is rate-limited
        (:meth:`_rate_limit_ok`), parsed (:meth:`_parse`) and dispatched
        (:meth:`_dispatch`). Protocol errors are translated to
        :data:`~duke_server.protocol.S_ERROR` payloads; unexpected
        exceptions are logged and reported as ``ERR_INTERNAL``. The
        ``finally`` block guarantees :meth:`_on_disconnect` runs even on
        crashes.
        """
        ctx = ClientCtx(conn=conn)
        ip = conn.remote_address[0] if conn.remote_address else None
        if ip and self.banlist.is_banned(ip):
            logger.info("BANNED     ip=%s (connection refused)", ip)
            ban_msg = "You are banned from this server."
            await self._send(conn, P.S_ERROR, code=P.ERR_BANNED, message=ban_msg)
            await _close_conn(conn, code=4001, reason=ban_msg)
            return
        if len(self.lobby.all_clients()) >= self.config.max_clients:
            await self._send(conn, P.S_ERROR, code=P.ERR_FULL, message="server full")
            await conn.close()
            return
        await self.lobby.add_client(conn)
        try:
            async for raw in conn:
                if not await self._rate_limit_ok(ctx):
                    await self._send(conn, P.S_ERROR, code=P.ERR_RATE_LIMITED,
                                     message="too many messages")
                    continue
                try:
                    msg = self._parse(raw)
                except ValueError as exc:
                    await self._send(conn, P.S_ERROR, code=P.ERR_PROTOCOL, message=str(exc))
                    continue
                try:
                    await self._dispatch(ctx, msg)
                except _ClientError as exc:
                    await self._send(conn, P.S_ERROR, code=exc.code, message=exc.message)
                except Exception:
                    logger.exception("Unhandled error while dispatching %s", msg.get("type"))
                    await self._send(conn, P.S_ERROR, code=P.ERR_INTERNAL,
                                     message="internal error")
        except websockets.ConnectionClosed:
            pass
        finally:
            await self._on_disconnect(ctx)

    # ── Dispatch ───────────────────────────────────────────────────────────
    async def _dispatch(self, ctx: ClientCtx, msg: dict) -> None:
        """Route a single decoded message to its handler.

        :data:`~duke_server.protocol.C_HELLO` is the only message type
        accepted before authentication. All other types require
        ``ctx.nickname`` to be set and raise :data:`ERR_AUTH` otherwise.
        Unknown types are reported as :data:`ERR_PROTOCOL`.
        """
        mtype = msg.get("type")
        if mtype is None:
            raise _ClientError(P.ERR_PROTOCOL, "missing 'type'")

        # Hello is the only message permitted before handshake.
        if mtype == P.C_HELLO:
            await self._handle_hello(ctx, msg)
            return
        if ctx.nickname is None:
            raise _ClientError(P.ERR_AUTH, "say hello first")

        handler = {
            P.C_LIST_ROOMS: self._handle_list_rooms,
            P.C_CREATE_ROOM: self._handle_create_room,
            P.C_JOIN_ROOM: self._handle_join_room,
            P.C_LEAVE_ROOM: self._handle_leave_room,
            P.C_DELETE_ROOM: self._handle_delete_room,
            P.C_START_GAME: self._handle_start_game,
            P.C_CLIENT_READY: self._handle_client_ready,
            P.C_MOVE: self._handle_move,
            P.C_SURRENDER: self._handle_surrender,
            P.C_OFFER_DRAW: self._handle_offer_draw,
            P.C_ACCEPT_DRAW: self._handle_accept_draw,
            P.C_DECLINE_DRAW: self._handle_decline_draw,
            P.C_PING: self._handle_ping,
        }.get(mtype)

        if handler is None:
            raise _ClientError(P.ERR_PROTOCOL, f"unknown type '{mtype}'")
        await handler(ctx, msg)

    # ── Handlers ───────────────────────────────────────────────────────────
    async def _handle_hello(self, ctx: ClientCtx, msg: dict) -> None:
        """Authenticate a fresh connection and optionally resume a session.

        Flow:

        1. Validate the supplied nickname against :data:`NICKNAME_RE`.
        2. If a previous ``token`` is supplied, verify it; the embedded
           nickname must match (otherwise ``ERR_AUTH``).
        3. Reject duplicate concurrent connections for the same
           nickname (``ERR_FORBIDDEN``).
        4. Issue a fresh session token, send :data:`S_WELCOME`.
        5. If a room contains a :class:`Member` with this nickname whose
           ``conn`` is ``None`` (i.e. a pending reconnect), reattach the
           connection, cancel the grace timer, and replay
           :data:`S_ROOM_JOINED` and :data:`S_GAME_START` so the client
           can rebuild local state.
        """
        nickname = str(msg.get("nickname", "")).strip()
        if not NICKNAME_RE.match(nickname):
            raise _ClientError(P.ERR_BAD_REQUEST, "invalid nickname")
        # Enforce minimum client version if configured.
        min_ver_str = self.config.min_client_version
        if min_ver_str:
            min_ver = _parse_version(min_ver_str)
            client_ver = _parse_version(msg.get("client_version"))
            if min_ver is not None and (client_ver is None or client_ver < min_ver):
                raise _ClientError(
                    P.ERR_OUTDATED_CLIENT,
                    f"Client is outdated. Minimum required version: {min_ver_str}",
                )
        token = msg.get("token")
        # If client supplied a previous token, verify it; nickname must match.
        if token:
            session = auth.verify_token(token, self.config.session_secret)
            if session is None or session.nickname != nickname:
                raise _ClientError(P.ERR_AUTH, "invalid or expired token")
        # Reject duplicate nickname connections (single connection per nickname).
        for other in list(self.lobby.all_clients()):
            if other is ctx.conn:
                continue
            other_ctx = getattr(other, "_duke_ctx", None)
            if other_ctx and other_ctx.nickname == nickname:
                raise _ClientError(P.ERR_FORBIDDEN, "nickname already in use")
        # Reject duplicate device connections (one connection per machine).
        machine_id = str(msg.get("machine_id", "")).strip()[:MAX_MACHINE_ID_LEN]
        if machine_id:
            for other in list(self.lobby.all_clients()):
                if other is ctx.conn:
                    continue
                other_ctx = getattr(other, "_duke_ctx", None)
                if other_ctx and other_ctx.machine_id == machine_id:
                    raise _ClientError(P.ERR_FORBIDDEN, "already connected from this device")
        ctx.nickname = nickname
        ctx.machine_id = machine_id or None
        ctx.session_token = auth.issue_token(nickname, self.config.session_secret)
        ctx.conn._duke_ctx = ctx  # type: ignore[attr-defined]

        # Check for reconnect: did this nickname have a room with a pending grace?
        rejoined_room: Optional[Room] = None
        for room in list(self.lobby._rooms.values()):  # snapshot
            member = room.members.get(nickname)
            if member and member.conn is None:
                # Reattach.
                member.conn = ctx.conn
                member.disconnected_at = None
                ctx.room_id = room.room_id
                rejoined_room = room
                # Cancel pending grace timer.
                key = (room.room_id, nickname)
                t = self._reconnect_timers.pop(key, None)
                if t:
                    t.cancel()
                break

        await self._send(ctx.conn, P.S_WELCOME,
                         protocol=PROTOCOL_VERSION,
                         session_token=ctx.session_token,
                         online_count=self.lobby.online_count,
                         max_clients=self.config.max_clients)

        if rejoined_room:
            logger.info(
                "RECONNECT  nick=%r ip=%s room_id=%s",
                nickname, _peer_ip(ctx), rejoined_room.room_id,
            )
            await self._send(ctx.conn, P.S_ROOM_JOINED,
                             room=rejoined_room.public_detail(nickname),
                             role="host" if rejoined_room.is_host(nickname) else "guest")
            await self._broadcast_room(rejoined_room)
            # Re-send game state if game is ongoing.
            if rejoined_room.state == ROOM_STATE_PLAYING and rejoined_room.game is not None:
                color = rejoined_room.member_color(nickname)
                await self._send(ctx.conn, P.S_GAME_START,
                                 room_id=rejoined_room.room_id,
                                 white=_get_member_by_color(rejoined_room, WHITE),
                                 black=_get_member_by_color(rejoined_room, BLACK),
                                 time_ms=rejoined_room.time_ms,
                                 fen=rejoined_room.game.fen,
                                 active=rejoined_room.game.active,
                                 your_color=COLOR_NAMES.get(color) if color is not None else None,
                                 white_ms=rejoined_room.game.remaining_ms()[0],
                                 black_ms=rejoined_room.game.remaining_ms()[1],
                                 ply=rejoined_room.game.ply)
        else:
            logger.info("CONNECT    nick=%r ip=%s", nickname, _peer_ip(ctx))
            self._record_connect()

        await self._broadcast_online_count()

    async def _handle_list_rooms(self, ctx: ClientCtx, _msg: dict) -> None:
        """Subscribe the client to room-list updates and send a snapshot.

        Adds the connection to the lobby's listener set so subsequent
        room create/join/leave events trigger an automatic
        :data:`S_ROOM_LIST` broadcast.
        """
        ctx.in_lobby = True
        self.lobby.add_listener(ctx.conn)
        await self._send(ctx.conn, P.S_ROOM_LIST,
                         rooms=self.lobby.list_rooms(),
                         online_count=self.lobby.online_count)

    async def _handle_create_room(self, ctx: ClientCtx, msg: dict) -> None:
        """Create a new room with this client as the host.

        Validates the room name (clamped to :data:`MAX_ROOM_NAME_LEN`),
        password length, host color (``"white"`` / ``"black"``) and time
        control (``0`` … 24 h, in milliseconds). On success the client
        is removed from the lobby listener set, the new room is
        registered, and a :data:`S_ROOM_CREATED` envelope is sent.
        """
        if ctx.room_id is not None:
            raise _ClientError(P.ERR_BAD_STATE, "already in a room")
        name = str(msg.get("name", "")).strip()[:MAX_ROOM_NAME_LEN]
        password = str(msg.get("password", ""))[:MAX_PASSWORD_LEN]
        host_color = str(msg.get("host_color", "white")).lower()
        if host_color not in ("white", "black"):
            raise _ClientError(P.ERR_BAD_REQUEST, "host_color must be white/black")
        try:
            time_ms = int(msg.get("time_ms", 0))
        except (TypeError, ValueError):
            raise _ClientError(P.ERR_BAD_REQUEST, "time_ms must be integer")
        if time_ms < 0 or time_ms > 24 * 3600 * 1000:
            raise _ClientError(P.ERR_BAD_REQUEST, "time_ms out of range")

        room = Room.create(name=name, host_nickname=ctx.nickname,
                           host_color_name=host_color, time_ms=time_ms,
                           password=password)
        if not await self.lobby.add_room(room):
            raise _ClientError(P.ERR_FULL, "too many rooms")
        member = room.members[ctx.nickname]
        member.conn = ctx.conn
        ctx.room_id = room.room_id
        ctx.in_lobby = False
        self.lobby.remove_listener(ctx.conn)

        logger.info(
            "ROOM_CREATE nick=%r ip=%s room_id=%s room=%r",
            ctx.nickname, _peer_ip(ctx), room.room_id, room.name,
        )
        await self._send(ctx.conn, P.S_ROOM_CREATED,
                         room=room.public_detail(ctx.nickname), role="host")
        await self._broadcast_lobby()

    async def _handle_join_room(self, ctx: ClientCtx, msg: dict) -> None:
        """Add the client to an existing room as a guest.

        Rejects with the appropriate :data:`ERR_*` code if the room does
        not exist, is full, has a different password, or is no longer
        in the ``waiting`` state. Sends :data:`S_ROOM_JOINED` to the
        joiner and broadcasts an updated room view to all members.

        Joining does *not* auto-start the game — the host must issue
        :data:`C_START_GAME`.
        """
        if ctx.room_id is not None:
            raise _ClientError(P.ERR_BAD_STATE, "already in a room")
        room_id = str(msg.get("room_id", ""))
        password = str(msg.get("password", ""))[:MAX_PASSWORD_LEN]
        room = self.lobby.get(room_id)
        if room is None or room.state == ROOM_STATE_FINISHED:
            raise _ClientError(P.ERR_NOT_FOUND, "room not found")
        if room.is_full() and ctx.nickname not in room.members:
            raise _ClientError(P.ERR_FULL, "room is full")
        if not room.check_password(password):
            raise _ClientError(P.ERR_FORBIDDEN, "wrong password")
        if room.state != ROOM_STATE_WAITING and ctx.nickname not in room.members:
            raise _ClientError(P.ERR_BAD_STATE, "game already in progress")

        member = room.join(ctx.nickname)
        member.conn = ctx.conn
        ctx.room_id = room.room_id
        ctx.in_lobby = False
        self.lobby.remove_listener(ctx.conn)

        role = "host" if room.is_host(ctx.nickname) else "guest"
        logger.info(
            "ROOM_JOIN   nick=%r ip=%s room_id=%s room=%r",
            ctx.nickname, _peer_ip(ctx), room.room_id, room.name,
        )
        await self._send(ctx.conn, P.S_ROOM_JOINED,
                         room=room.public_detail(ctx.nickname), role=role)
        await self._broadcast_room(room)
        await self._broadcast_lobby()

    async def _handle_start_game(self, ctx: ClientCtx, _msg: dict) -> None:
        """Host-only: transition the room from WAITING to PLAYING.

        Refuses if the caller is not the host, the room is not in
        WAITING state, or :meth:`Room.can_start` is false (e.g. the
        opponent has disconnected). Delegates the actual game start to
        :meth:`_start_game`.
        """
        room = self._require_room(ctx)
        if not room.is_host(ctx.nickname):
            raise _ClientError(P.ERR_FORBIDDEN, "only the host can start the game")
        if room.state != ROOM_STATE_WAITING:
            raise _ClientError(P.ERR_BAD_STATE, "game already started")
        if not room.can_start():
            raise _ClientError(P.ERR_BAD_STATE, "both players must be present")
        await self._start_game(room)

    async def _handle_client_ready(self, ctx: ClientCtx, _msg: dict) -> None:
        """Client signals it finished loading/intro and is ready to play.

        Tracks readiness per nickname; the server clock is armed only
        once both members report ready, which prevents a slow-loading
        client from bleeding time during the spawn cutscene. Sending
        this message after the clock has been armed is a no-op.
        """
        room = self._require_room(ctx)
        if room.game is None or room.state != ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game not in progress")
        if room.member_color(ctx.nickname) is None:
            raise _ClientError(P.ERR_FORBIDDEN, "not a player")
        if room.game.started:
            # Already running — still echo the ready state so a reconnecting
            # client gets an unblocking signal.
            await self._broadcast_ready_state(room)
            return
        async with room.lock:
            all_ready = room.mark_ready(ctx.nickname)
            if all_ready:
                room.arm_clock()
            await self._broadcast_ready_state(room)

    async def _broadcast_ready_state(self, room: Room) -> None:
        """Tell both members which players have finished loading."""
        ready_colors = []
        for nick in room.ready_members:
            c = room.member_color(nick)
            if c is not None:
                ready_colors.append(COLOR_NAMES[c])
        all_ready = bool(room.game and room.game.started)
        for m in room.members.values():
            if m.conn is not None:
                await self._send(m.conn, P.S_READY_STATE,
                                 ready=ready_colors,
                                 all_ready=all_ready)

    async def _handle_leave_room(self, ctx: ClientCtx, _msg: dict) -> None:
        """Client wants to leave; mid-game this counts as a resignation."""
        await self._leave_room(ctx, reason="left")

    async def _handle_delete_room(self, ctx: ClientCtx, _msg: dict) -> None:
        """Host-only: destroy a room that is not currently in progress."""
        if not ctx.room_id:
            raise _ClientError(P.ERR_BAD_STATE, "not in a room")
        room = self.lobby.get(ctx.room_id)
        if room is None:
            raise _ClientError(P.ERR_NOT_FOUND, "room not found")
        if not room.is_host(ctx.nickname):
            raise _ClientError(P.ERR_FORBIDDEN, "only the host can delete the room")
        if room.state == ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game in progress")
        logger.info(
            "ROOM_DELETE nick=%r ip=%s room_id=%s room=%r",
            ctx.nickname, _peer_ip(ctx), room.room_id, room.name,
        )
        await self._destroy_room(room, reason="closed by host")

    async def _handle_move(self, ctx: ClientCtx, msg: dict) -> None:
        """Validate and apply a UCI move under the room's lock.

        Translates :class:`~duke_server.game.IllegalMove` /
        :class:`~duke_server.game.NotYourTurn` /
        :class:`~duke_server.game.BadState` into the matching wire error
        codes. On success, broadcasts :data:`S_MOVE_APPLIED` to both
        members and, if the move ended the game, follows up with
        :data:`S_GAME_OVER`. Any pending draw offer is cleared.
        """
        room = self._require_room(ctx)
        if room.game is None or room.state != ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game not in progress")
        color = room.member_color(ctx.nickname)
        if color is None:
            raise _ClientError(P.ERR_FORBIDDEN, "not a player")
        uci = str(msg.get("uci", "")).strip()
        if not uci or len(uci) > 6:
            raise _ClientError(P.ERR_BAD_REQUEST, "invalid uci")
        async with room.lock:
            try:
                result = room.game.apply_move(color, uci)
            except IllegalMove as exc:
                raise _ClientError(P.ERR_ILLEGAL_MOVE, str(exc))
            except NotYourTurn as exc:
                raise _ClientError(P.ERR_NOT_YOUR_TURN, str(exc))
            except BadState as exc:
                raise _ClientError(P.ERR_BAD_STATE, str(exc))
            room.draw_offer_by = None
            await self._broadcast_move(room, result)
            if result.game_over:
                room.finish()
                await self._broadcast_game_over(room, result)

    async def _handle_surrender(self, ctx: ClientCtx, _msg: dict) -> None:
        """Resign the current game on behalf of the caller's color."""
        room = self._require_room(ctx)
        if room.game is None or room.state != ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game not in progress")
        color = room.member_color(ctx.nickname)
        if color is None:
            raise _ClientError(P.ERR_FORBIDDEN, "not a player")
        async with room.lock:
            result = room.game.force_resign(color)
            room.finish()
            await self._broadcast_game_over(room, result)

    async def _handle_offer_draw(self, ctx: ClientCtx, _msg: dict) -> None:
        """Send a draw offer to the opponent (or auto-accept a pending one).

        If the opponent already has an outstanding offer on the table,
        this call is treated as :meth:`_handle_accept_draw` so the game
        concludes immediately.
        """
        room = self._require_room(ctx)
        if room.game is None or room.state != ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game not in progress")
        color = room.member_color(ctx.nickname)
        if color is None:
            raise _ClientError(P.ERR_FORBIDDEN, "not a player")
        if room.draw_offer_by is not None and room.draw_offer_by != color:
            # opponent already offered; treat as accept
            await self._handle_accept_draw(ctx, _msg)
            return
        room.draw_offer_by = color
        opp = room.color_to_member(WHITE if color == BLACK else BLACK)
        if opp and opp.conn is not None:
            await self._send(opp.conn, P.S_DRAW_OFFER, from_color=COLOR_NAMES[color])

    async def _handle_accept_draw(self, ctx: ClientCtx, _msg: dict) -> None:
        """Accept the opponent's pending draw offer.

        Refuses if there is no pending offer or if the caller is the one
        who issued it.
        """
        room = self._require_room(ctx)
        if room.game is None or room.state != ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game not in progress")
        if room.draw_offer_by is None:
            raise _ClientError(P.ERR_BAD_STATE, "no draw offer pending")
        color = room.member_color(ctx.nickname)
        if color is None or color == room.draw_offer_by:
            raise _ClientError(P.ERR_BAD_STATE, "cannot accept your own offer")
        async with room.lock:
            result = room.game.force_draw("agreement")
            room.finish()
            await self._broadcast_game_over(room, result)

    async def _handle_decline_draw(self, ctx: ClientCtx, _msg: dict) -> None:
        """Decline a pending draw offer; notifies both members. No-op when none pending."""
        room = self._require_room(ctx)
        if room.draw_offer_by is None:
            return
        color = room.member_color(ctx.nickname)
        if color is None or color == room.draw_offer_by:
            return
        room.draw_offer_by = None
        for m in room.members.values():
            if m.conn is not None:
                await self._send(m.conn, P.S_DRAW_DECLINED)

    async def _handle_ping(self, ctx: ClientCtx, _msg: dict) -> None:
        """Reply to a client heartbeat with a :data:`S_PONG` carrying server time."""
        await self._send(ctx.conn, P.S_PONG, t=time.time())

    # ── Helpers ────────────────────────────────────────────────────────────────
    def _require_room(self, ctx: ClientCtx) -> Room:
        """Look up the client's current room or raise a wire-error.

        Raises :data:`ERR_BAD_STATE` if the client is not in a room and
        :data:`ERR_NOT_FOUND` if the referenced room has been destroyed.
        In the latter case ``ctx.room_id`` is cleared so subsequent calls
        do not keep failing the same way.
        """
        if not ctx.room_id:
            raise _ClientError(P.ERR_BAD_STATE, "not in a room")
        room = self.lobby.get(ctx.room_id)
        if room is None:
            ctx.room_id = None
            raise _ClientError(P.ERR_NOT_FOUND, "room no longer exists")
        return room

    async def _start_game(self, room: Room) -> None:
        """Transition a room into PLAYING and notify both members.

        Calls :meth:`Room.start_game` to create the
        :class:`~duke_server.game.ChessGame`, sends a
        :data:`S_GAME_START` to each connected member with the colors,
        initial FEN, and per-side clock, and schedules the timeout
        watcher task when ``time_ms > 0``.
        """
        room.start_game()
        white = _get_member_by_color(room, WHITE)
        black = _get_member_by_color(room, BLACK)
        white_ms, black_ms = room.game.remaining_ms() if room.game else (0, 0)
        logger.info(
            "GAME_START  room_id=%s room=%r white=%r black=%r time_ms=%d",
            room.room_id, room.name, white, black, room.time_ms,
        )
        for m in room.members.values():
            if m.conn is None:
                continue
            await self._send(m.conn, P.S_GAME_START,
                             room_id=room.room_id,
                             white=white,
                             black=black,
                             time_ms=room.time_ms,
                             fen=room.game.fen if room.game else "",
                             active="white",
                             your_color=COLOR_NAMES.get(m.color) if m.color is not None else None,
                             white_ms=white_ms,
                             black_ms=black_ms,
                             ply=0)
        # Start timeout watcher.
        if room.time_ms > 0:
            self._room_watchers[room.room_id] = asyncio.create_task(
                self._watch_room_clock(room.room_id))
        await self._broadcast_lobby()

    async def _watch_room_clock(self, room_id: str) -> None:
        """Background loop that detects time-loss in a playing room.

        Polls every 500 ms. When :meth:`ChessGame.check_timeout` reports
        a loser, the room is finished and :data:`S_GAME_OVER` is
        broadcast. The task exits when the room disappears, the game
        ends, or it is cancelled (e.g. by :meth:`_broadcast_game_over`).
        """
        try:
            while True:
                await asyncio.sleep(0.5)
                room = self.lobby.get(room_id)
                if room is None or room.game is None:
                    return
                if room.state != ROOM_STATE_PLAYING:
                    return
                async with room.lock:
                    loser = room.game.check_timeout()
                    if loser is not None:
                        result = room.game._snapshot_after_terminal("(time)")  # type: ignore[attr-defined]
                        room.finish()
                        await self._broadcast_game_over(room, result)
                        return
        except asyncio.CancelledError:
            return

    async def _broadcast_move(self, room: Room, result) -> None:
        """Send :data:`S_MOVE_APPLIED` with the new position to both members."""
        payload = {
            "uci": result.uci,
            "from": result.from_sq,
            "to": result.to_sq,
            "promotion": result.promotion,
            "fen": result.fen,
            "active": result.active,
            "white_ms": result.white_ms,
            "black_ms": result.black_ms,
            "ply": result.ply,
        }
        for m in room.members.values():
            if m.conn is not None:
                await self._send(m.conn, P.S_MOVE_APPLIED, **payload)

    async def _broadcast_game_over(self, room: Room, result) -> None:
        """Send :data:`S_GAME_OVER`, cancel the clock watcher, refresh lobby."""
        payload = {
            "winner": result.winner,
            "reason": result.reason,
            "white_ms": result.white_ms,
            "black_ms": result.black_ms,
            "fen": result.fen,
        }
        logger.info(
            "GAME_OVER   room_id=%s room=%r winner=%s reason=%s",
            room.room_id, room.name,
            result.winner if result.winner else "draw",
            result.reason,
        )
        for m in room.members.values():
            if m.conn is not None:
                await self._send(m.conn, P.S_GAME_OVER, **payload)
        # Cancel watcher.
        t = self._room_watchers.pop(room.room_id, None)
        if t:
            t.cancel()
        await self._broadcast_lobby()

    async def _broadcast_room(self, room: Room) -> None:
        """Send a per-viewer :data:`S_ROOM_UPDATED` to every connected member."""
        for m in room.members.values():
            if m.conn is None:
                continue
            await self._send(m.conn, P.S_ROOM_UPDATED, room=room.public_detail(m.nickname))

    async def _broadcast_lobby(self) -> None:
        """Push a fresh :data:`S_ROOM_LIST` to every lobby listener.

        Send failures are swallowed individually so that one dead
        connection does not block updates to the others.
        """
        listing = self.lobby.list_rooms()
        online = self.lobby.online_count
        for conn in list(self.lobby.listeners()):
            try:
                await self._send(conn, P.S_ROOM_LIST, rooms=listing, online_count=online)
            except Exception:
                pass

    async def _broadcast_online_count(self) -> None:
        """Push the current :data:`S_ONLINE_COUNT` to every connected client."""
        online = self.lobby.online_count
        for conn in list(self.lobby.all_clients()):
            try:
                await self._send(conn, P.S_ONLINE_COUNT, online_count=online)
            except Exception:
                pass

    async def _leave_room(self, ctx: ClientCtx, reason: str) -> None:
        """Remove the client from their current room.

        Leaving mid-game is treated as a resignation: the game is
        force-resigned, the room is finished, and the remaining member
        (if any) receives :data:`S_GAME_OVER`.

        Pre-game leaves remove the client; if the host leaves, the room
        is destroyed via :meth:`_destroy_room`. Empty rooms are
        garbage-collected from the lobby in either case.
        """
        if not ctx.room_id:
            return
        room = self.lobby.get(ctx.room_id)
        ctx.room_id = None
        if room is None:
            return
        member = room.members.get(ctx.nickname or "")
        if member is None:
            return

        if room.state == ROOM_STATE_PLAYING and room.game is not None and not room.game.game_over:
            # Quitting mid-game = resignation.
            async with room.lock:
                color = member.color or WHITE
                result = room.game.force_resign(color)
                room.finish()
                await self._broadcast_game_over(room, result)
            room.remove(ctx.nickname or "")
            if len(room.members) == 0:
                await self.lobby.remove_room(room.room_id)
                await self._broadcast_lobby()
            return

        # Pre-game leave.
        room.remove(ctx.nickname or "")
        if len(room.members) == 0:
            await self.lobby.remove_room(room.room_id)
        else:
            await self._broadcast_room(room)
            # If host left, destroy the room.
            if ctx.nickname == room.host_nickname:
                await self._destroy_room(room, reason="host left")
                return
        await self._broadcast_lobby()

    async def _destroy_room(self, room: Room, reason: str) -> None:
        """Forcefully tear down a room and notify each member.

        Sends :data:`S_ROOM_DELETED` with the supplied ``reason`` to all
        connected members, clears their ``ctx.room_id``, cancels the
        clock watcher and refreshes the lobby listing.
        """
        for m in list(room.members.values()):
            if m.conn is not None:
                await self._send(m.conn, P.S_ROOM_DELETED,
                                 room_id=room.room_id, reason=reason)
                other_ctx = getattr(m.conn, "_duke_ctx", None)
                if other_ctx is not None:
                    other_ctx.room_id = None
        await self.lobby.remove_room(room.room_id)
        t = self._room_watchers.pop(room.room_id, None)
        if t:
            t.cancel()
        await self._broadcast_lobby()

    async def _on_disconnect(self, ctx: ClientCtx) -> None:
        """Handle an unexpected socket close.

        Always removes the client from the lobby and refreshes the
        global online count. If the client was in a playing room, the
        member's connection is detached and a
        :meth:`_reconnect_timeout` grace task is scheduled. Pre-game
        and finished rooms simply fall through to :meth:`_leave_room`.
        """
        await self.lobby.remove_client(ctx.conn)
        await self._broadcast_online_count()
        if ctx.nickname:
            logger.info("DISCONNECT  nick=%r ip=%s", ctx.nickname, _peer_ip(ctx))
        if not ctx.room_id:
            return
        room = self.lobby.get(ctx.room_id)
        if room is None:
            return
        member = room.members.get(ctx.nickname or "")
        if member is None:
            return
        if room.state == ROOM_STATE_PLAYING and room.game is not None and not room.game.game_over:
            if ctx.kicked:
                # Kicked players resign immediately — no reconnect grace.
                await self._leave_room(ctx, reason="kicked")
            else:
                # Mark disconnected and start grace timer.
                member.conn = None
                member.disconnected_at = time.monotonic()
                await self._broadcast_room(room)
                key = (room.room_id, ctx.nickname or "")
                self._reconnect_timers[key] = asyncio.create_task(
                    self._reconnect_timeout(room.room_id, ctx.nickname or ""))
        else:
            # Pre-game / finished: treat as leave.
            await self._leave_room(ctx, reason="disconnect")

    async def _reconnect_timeout(self, room_id: str, nickname: str) -> None:
        """Forfeit a disconnected player when their grace window expires.

        Sleeps for :attr:`ServerConfig.reconnect_grace_s` seconds. If the
        member has not re-attached a connection by then and the game is
        still in progress, the game is resigned in their name and the
        room is finished. The task is cancelled (and silently exits) if
        the player reconnects in time.
        """
        try:
            await asyncio.sleep(self.config.reconnect_grace_s)
        except asyncio.CancelledError:
            return
        room = self.lobby.get(room_id)
        if room is None:
            return
        member = room.members.get(nickname)
        if member is None or member.conn is not None:
            return
        # Grace expired: forfeit if still playing.
        if room.state == ROOM_STATE_PLAYING and room.game is not None and not room.game.game_over:
            async with room.lock:
                color = member.color or WHITE
                result = room.game.force_resign(color)
                room.finish()
                await self._broadcast_game_over(room, result)
        room.remove(nickname)
        if len(room.members) == 0:
            await self.lobby.remove_room(room_id)
            await self._broadcast_lobby()

    def _record_connect(self) -> None:
        """Increment today's connection counter and refresh peak player count."""
        today = datetime.date.today()
        if today != self._stats["today_date"]:
            self._stats["connects_today"] = 0
            self._stats["today_date"] = today
        self._stats["connects_today"] += 1
        online = self.lobby.online_count
        if online > self._stats["peak_players"]:
            self._stats["peak_players"] = online

    async def _kick_user(self, nickname: str, reason: str) -> bool:
        """Disconnect a player by nickname, sending S_KICKED first.

        Used by the admin CLI. Returns ``True`` if the player was found
        and the kick was sent, ``False`` if no matching connected client
        exists.
        """
        for conn in list(self.lobby.all_clients()):
            ctx = getattr(conn, "_duke_ctx", None)
            if ctx and ctx.nickname == nickname:
                ctx.kicked = True
                await self._send(conn, P.S_KICKED, reason=reason)
                await _close_conn(conn, code=4000, reason=reason)
                return True
        return False

    async def _kick_by_ip(self, ip: str, reason: str, is_ban: bool = False) -> int:
        """Disconnect all connections from *ip*, sending S_KICKED first.

        Pass ``ip="*"`` to kick every connected client (used by shutdown).
        Returns the number of connections closed.
        """
        count = 0
        for conn in list(self.lobby.all_clients()):
            addr = getattr(conn, "remote_address", None)
            conn_ip = addr[0] if addr else None
            if ip == "*" or conn_ip == ip:
                ctx = getattr(conn, "_duke_ctx", None)
                if ctx is not None:
                    ctx.kicked = True
                await self._send(conn, P.S_KICKED, reason=reason, is_ban=is_ban)
                close_code = 4001 if is_ban else 4000
                await _close_conn(conn, code=close_code, reason=reason)
                count += 1
        return count

    async def _close_room(self, room_id: str, reason: str) -> bool:
        """Force-close a room regardless of its state.

        For rooms with an active game, the game is concluded as a draw
        (admin action, no winner).  All connected members receive
        S_ROOM_DELETED.  Reconnect timers are cancelled.

        Returns ``False`` when *room_id* is not found.
        """
        room = self.lobby.get(room_id)
        if room is None:
            return False

        # Cancel any pending reconnect timers for members of this room.
        for nick in list(room.members):
            task = self._reconnect_timers.pop((room_id, nick), None)
            if task:
                task.cancel()

        # Conclude an active game as a draw before destroying.
        if room.state == ROOM_STATE_PLAYING and room.game is not None and not room.game.game_over:
            async with room.lock:
                result = room.game.force_draw("room closed by admin")
                room.finish()
                await self._broadcast_game_over(room, result)

        logger.info("CLOSE_ROOM room_id=%s reason=%r (via CLI)", room_id, reason)
        await self._destroy_room(room, reason=reason)
        return True

    # ── Wire I/O ───────────────────────────────────────────────────────────
    @staticmethod
    def _parse(raw) -> dict:
        """Decode a WebSocket frame into a JSON object.

        Accepts either ``bytes`` or ``str`` frames. Raises
        :class:`ValueError` (translated to :data:`ERR_PROTOCOL` by the
        caller) when the payload is not valid JSON or is not a JSON
        object at the top level.
        """
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", errors="replace")
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid json: {exc}") from exc
        if not isinstance(obj, dict):
            raise ValueError("message must be a JSON object")
        return obj

    @staticmethod
    async def _send(conn: WebSocketServerProtocol, mtype: str, **fields: Any) -> None:
        """JSON-encode a message envelope and send it over ``conn``.

        Closed connections are tolerated: :class:`websockets.ConnectionClosed`
        is swallowed so callers iterating over many recipients do not
        have to special-case dropped peers.
        """
        payload = {"type": mtype, **fields}
        try:
            await conn.send(json.dumps(payload))
        except websockets.ConnectionClosed:
            pass

    async def _rate_limit_ok(self, ctx: ClientCtx) -> bool:
        """Sliding 1-second window rate limit: at most 30 messages / sec."""
        now = time.monotonic()
        if now - ctx.window_start >= 1.0:
            ctx.window_start = now
            ctx.msg_count_window = 0
        ctx.msg_count_window += 1
        return ctx.msg_count_window <= 30


class _ClientError(Exception):
    """Internal exception type translated to :data:`S_ERROR` on the wire.

    ``code`` is one of the ``ERR_*`` strings from
    :mod:`duke_server.protocol`; ``message`` is a short human-readable
    explanation. The dispatcher catches these and never lets them
    propagate to the websockets library.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _get_member_by_color(room: Room, color: int) -> Optional[str]:
    """Helper: return the nickname of the player with ``color`` (or ``None``)."""
    m = room.color_to_member(color)
    return m.nickname if m else None


def _peer_ip(ctx: ClientCtx) -> str:
    """Return the remote IP address string of *ctx*'s connection."""
    addr = getattr(ctx.conn, "remote_address", None)
    return addr[0] if addr else "?"


async def _close_conn(conn, code: int = 1000, reason: str = "") -> None:
    """Close a WebSocket connection, ignoring already-closed errors.

    WebSocket close ``reason`` is limited to 123 bytes by RFC 6455;
    we truncate to be safe.
    """
    try:
        truncated = reason.encode("utf-8")[:120].decode("utf-8", errors="ignore")
        await conn.close(code=code, reason=truncated)
    except Exception:
        pass


# ── Entry point ─────────────────────────────────────────────────────────────────────

def main() -> None:
    """Process entry point invoked by ``python -m duke_server``.

    Builds the configuration from environment variables, installs
    ``SIGINT`` / ``SIGTERM`` handlers that gracefully stop the server,
    and runs the asyncio loop until :meth:`Server.run` returns.
    """
    config = ServerConfig.from_env()
    log_dir = os.environ.get("DUKE_LOG_DIR", "logs")
    setup_logging(config.log_level, log_dir=log_dir)

    server = Server(config)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def _shutdown(*_args):
        logger.info("Shutdown signal received.")
        server.stop()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except (NotImplementedError, RuntimeError):
            signal.signal(sig, _shutdown)

    try:
        loop.run_until_complete(server.run())
    finally:
        loop.close()
