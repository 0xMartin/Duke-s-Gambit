"""Asynchronous WebSocket server."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import signal
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import websockets
from websockets.server import WebSocketServerProtocol

from . import auth
from . import protocol as P
from .config import ServerConfig
from .game import BLACK, COLOR_NAMES, WHITE, IllegalMove, NotYourTurn, BadState, color_from_name
from .lobby import Lobby
from .room import Room, ROOM_STATE_PLAYING, ROOM_STATE_WAITING, ROOM_STATE_FINISHED
from .tls import ensure_cert, make_ssl_context


logger = logging.getLogger("duke_server")

NICKNAME_RE = re.compile(r"^[A-Za-z0-9_.\- ]{1,15}$")
MAX_PASSWORD_LEN = 64
MAX_ROOM_NAME_LEN = 40
PROTOCOL_VERSION = P.PROTOCOL_VERSION
MAX_MESSAGE_SIZE = 8 * 1024


@dataclass
class ClientCtx:
    conn: WebSocketServerProtocol
    nickname: Optional[str] = None
    session_token: Optional[str] = None
    room_id: Optional[str] = None
    in_lobby: bool = False
    last_msg_ts: float = field(default_factory=time.monotonic)
    msg_count_window: int = 0
    window_start: float = field(default_factory=time.monotonic)


class Server:
    def __init__(self, config: ServerConfig) -> None:
        self.config = config
        self.lobby = Lobby(max_rooms=config.max_rooms)
        self._stop_event = asyncio.Event()
        # Per-room timeout watcher task.
        self._room_watchers: dict[str, asyncio.Task] = {}
        # Per-room reconnect timers.
        self._reconnect_timers: dict[tuple[str, str], asyncio.Task] = {}

    # ── Lifecycle ──────────────────────────────────────────────────────────
    async def run(self) -> None:
        ssl_context = None
        scheme = "ws"
        if self.config.tls_enabled:
            cert_path, key_path, fingerprint = ensure_cert(self.config.cert_dir)
            ssl_context = make_ssl_context(cert_path, key_path)
            scheme = "wss"
            logger.info("TLS enabled. Cert: %s", cert_path)
            logger.info("Cert SHA-256 fingerprint: %s", fingerprint)
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
        ):
            await self._stop_event.wait()
        logger.info("Server stopped.")

    def stop(self) -> None:
        self._stop_event.set()

    # ── Connection handler ─────────────────────────────────────────────────
    async def _handler(self, conn: WebSocketServerProtocol) -> None:
        ctx = ClientCtx(conn=conn)
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
        nickname = str(msg.get("nickname", "")).strip()
        if not NICKNAME_RE.match(nickname):
            raise _ClientError(P.ERR_BAD_REQUEST, "invalid nickname")
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
        ctx.nickname = nickname
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
                         online_count=self.lobby.online_count)

        if rejoined_room:
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

        await self._broadcast_online_count()

    async def _handle_list_rooms(self, ctx: ClientCtx, _msg: dict) -> None:
        ctx.in_lobby = True
        self.lobby.add_listener(ctx.conn)
        await self._send(ctx.conn, P.S_ROOM_LIST,
                         rooms=self.lobby.list_rooms(),
                         online_count=self.lobby.online_count)

    async def _handle_create_room(self, ctx: ClientCtx, msg: dict) -> None:
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

        await self._send(ctx.conn, P.S_ROOM_CREATED,
                         room=room.public_detail(ctx.nickname), role="host")
        await self._broadcast_lobby()

    async def _handle_join_room(self, ctx: ClientCtx, msg: dict) -> None:
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
        await self._send(ctx.conn, P.S_ROOM_JOINED,
                         room=room.public_detail(ctx.nickname), role=role)
        await self._broadcast_room(room)
        await self._broadcast_lobby()

    async def _handle_start_game(self, ctx: ClientCtx, _msg: dict) -> None:
        room = self._require_room(ctx)
        if not room.is_host(ctx.nickname):
            raise _ClientError(P.ERR_FORBIDDEN, "only the host can start the game")
        if room.state != ROOM_STATE_WAITING:
            raise _ClientError(P.ERR_BAD_STATE, "game already started")
        if not room.can_start():
            raise _ClientError(P.ERR_BAD_STATE, "both players must be present")
        await self._start_game(room)

    async def _handle_leave_room(self, ctx: ClientCtx, _msg: dict) -> None:
        await self._leave_room(ctx, reason="left")

    async def _handle_delete_room(self, ctx: ClientCtx, _msg: dict) -> None:
        if not ctx.room_id:
            raise _ClientError(P.ERR_BAD_STATE, "not in a room")
        room = self.lobby.get(ctx.room_id)
        if room is None:
            raise _ClientError(P.ERR_NOT_FOUND, "room not found")
        if not room.is_host(ctx.nickname):
            raise _ClientError(P.ERR_FORBIDDEN, "only the host can delete the room")
        if room.state == ROOM_STATE_PLAYING:
            raise _ClientError(P.ERR_BAD_STATE, "game in progress")
        await self._destroy_room(room, reason="closed by host")

    async def _handle_move(self, ctx: ClientCtx, msg: dict) -> None:
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
        await self._send(ctx.conn, P.S_PONG, t=time.time())

    # ── Helpers ────────────────────────────────────────────────────────────
    def _require_room(self, ctx: ClientCtx) -> Room:
        if not ctx.room_id:
            raise _ClientError(P.ERR_BAD_STATE, "not in a room")
        room = self.lobby.get(ctx.room_id)
        if room is None:
            ctx.room_id = None
            raise _ClientError(P.ERR_NOT_FOUND, "room no longer exists")
        return room

    async def _start_game(self, room: Room) -> None:
        room.start_game()
        white = _get_member_by_color(room, WHITE)
        black = _get_member_by_color(room, BLACK)
        white_ms, black_ms = room.game.remaining_ms() if room.game else (0, 0)
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
        payload = {
            "winner": result.winner,
            "reason": result.reason,
            "white_ms": result.white_ms,
            "black_ms": result.black_ms,
            "fen": result.fen,
        }
        for m in room.members.values():
            if m.conn is not None:
                await self._send(m.conn, P.S_GAME_OVER, **payload)
        # Cancel watcher.
        t = self._room_watchers.pop(room.room_id, None)
        if t:
            t.cancel()
        await self._broadcast_lobby()

    async def _broadcast_room(self, room: Room) -> None:
        for m in room.members.values():
            if m.conn is None:
                continue
            await self._send(m.conn, P.S_ROOM_UPDATED, room=room.public_detail(m.nickname))

    async def _broadcast_lobby(self) -> None:
        listing = self.lobby.list_rooms()
        online = self.lobby.online_count
        for conn in list(self.lobby.listeners()):
            try:
                await self._send(conn, P.S_ROOM_LIST, rooms=listing, online_count=online)
            except Exception:
                pass

    async def _broadcast_online_count(self) -> None:
        online = self.lobby.online_count
        for conn in list(self.lobby.all_clients()):
            try:
                await self._send(conn, P.S_ONLINE_COUNT, online_count=online)
            except Exception:
                pass

    async def _leave_room(self, ctx: ClientCtx, reason: str) -> None:
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
        await self.lobby.remove_client(ctx.conn)
        await self._broadcast_online_count()
        if not ctx.room_id:
            return
        room = self.lobby.get(ctx.room_id)
        if room is None:
            return
        member = room.members.get(ctx.nickname or "")
        if member is None:
            return
        if room.state == ROOM_STATE_PLAYING and room.game is not None and not room.game.game_over:
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

    # ── Wire I/O ───────────────────────────────────────────────────────────
    @staticmethod
    def _parse(raw) -> dict:
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
        payload = {"type": mtype, **fields}
        try:
            await conn.send(json.dumps(payload))
        except websockets.ConnectionClosed:
            pass

    async def _rate_limit_ok(self, ctx: ClientCtx) -> bool:
        now = time.monotonic()
        if now - ctx.window_start >= 1.0:
            ctx.window_start = now
            ctx.msg_count_window = 0
        ctx.msg_count_window += 1
        return ctx.msg_count_window <= 30


class _ClientError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _get_member_by_color(room: Room, color: int) -> Optional[str]:
    m = room.color_to_member(color)
    return m.nickname if m else None


# ── Entry point ────────────────────────────────────────────────────────────
def main() -> None:
    config = ServerConfig.from_env()
    logging.basicConfig(
        level=config.log_level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

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
