"""Interactive admin CLI served over a Unix socket inside the container.

:func:`start_cli_server` runs as a background asyncio task and listens on
``/tmp/duke-cli.sock``.  Each ``docker exec`` session that connects via
:mod:`duke_server._cli_client` gets an independent CLI session; typing
``exit`` (or pressing Ctrl-C) ends only that session — the server keeps
running.

Usage via the helper script (recommended)::

    ./server-cli.sh

Manual::

    docker exec -it dukes-gambit-server python3 -m duke_server._cli_client
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import os
import time
from typing import Awaitable, Callable

import chess

from .banlist import BanList
from .lobby import Lobby
from .room import ROOM_STATE_PLAYING

CLI_SOCKET_PATH = "/tmp/duke-cli.sock"


logger = logging.getLogger(__name__)

_SEP = "─" * 52

_HELP = f"""\
Duke's Gambit — admin CLI
{_SEP}
  status                 Server uptime & stats
  who                    List connected players
  kick <nick> [reason]   Kick a player by nickname
  kickip <ip> [reason]   Kick all connections from an IP
  rooms                  List all active rooms
  game <room_id>         Show game state (board, clocks, ...)
  close <room_id>        Force-close a room (draw if playing)
  config                 Show server configuration
{_SEP}
  ban <ip> [nick]        Ban an IP address
  unban <ip>             Remove a ban by IP
  unban_nick <nick>      Remove a ban by nickname
  bans                   List all banned IPs
{_SEP}
  shutdown               Kick all players and stop the server
  exit                   Detach CLI (server keeps running)
  help                   Show this help
{_SEP}
  Disconnect:  type 'exit'  or press Ctrl-C
  (Ctrl-C closes your session only — server keeps running)"""


# ── Formatting helpers ──────────────────────────────────────────────────────

def _fmt_uptime(start: float) -> str:
    total = int(time.monotonic() - start)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h {m}m {s}s"


def _fmt_ms(ms: int) -> str:
    """Format milliseconds as ``M:SS`` or ``unlimited``."""
    if ms <= 0:
        return "0:00"
    total_s = ms // 1000
    return f"{total_s // 60}:{total_s % 60:02d}"


def _fmt_board(fen: str) -> str:
    """Render a FEN position as an annotated ASCII board (white on bottom)."""
    board = chess.Board(fen)
    ranks = str(board).splitlines()   # python-chess gives rank 8 first
    files = "    a b c d e f g h"
    lines = [files, "  ┌─────────────────┐"]
    for i, rank_str in enumerate(ranks):
        rank_num = 8 - i
        lines.append(f"{rank_num} │ {rank_str} │")
    lines.append("  └─────────────────┘")
    lines.append(files)
    return "\n".join(lines)


# ── Command handlers ────────────────────────────────────────────────────────

def _cmd_status(lobby: Lobby, start_time: float, stats: dict, emit: Callable) -> None:
    rooms = lobby._rooms
    playing = sum(1 for r in rooms.values() if r.state == ROOM_STATE_PLAYING)
    waiting = sum(1 for r in rooms.values() if r.state != ROOM_STATE_PLAYING and r.state != "finished")

    # Average connections per hour for today.
    now = datetime.datetime.now()
    day_start = datetime.datetime.combine(now.date(), datetime.time.min)
    elapsed_h = (now - day_start).total_seconds() / 3600
    connects_today = stats["connects_today"]
    # If the server started after midnight, today_date might differ — reset handled server-side.
    avg_per_h = connects_today / elapsed_h if elapsed_h >= 0.01 else connects_today

    emit(f"Uptime   : {_fmt_uptime(start_time)}")
    emit(f"Players  : {lobby.online_count} connected  (peak: {stats['peak_players']})")
    emit(f"Today    : {connects_today} connections  (avg {avg_per_h:.1f}/h)")
    emit(f"Rooms    : {len(rooms)} total  ({playing} playing, {waiting} waiting)")


def _cmd_who(lobby: Lobby, emit: Callable) -> None:
    clients = lobby.all_clients()
    if not clients:
        emit("No players connected.")
        return
    emit(f"{'Nickname':<20} {'IP':<18} {'Room ID':<14} Location")
    emit("─" * 72)
    for conn in sorted(clients, key=lambda c: getattr(getattr(c, "_duke_ctx", None), "nickname", "") or ""):
        ctx = getattr(conn, "_duke_ctx", None)
        nick = ctx.nickname if ctx else "(pre-hello)"
        addr = getattr(conn, "remote_address", None)
        ip = addr[0] if addr else "?"
        room_id = ctx.room_id if ctx else None
        location = room_id if room_id else "(lobby)"
        emit(f"{nick:<20} {ip:<18} {(room_id or ''):<14} {location}")


async def _cmd_kick(lobby: Lobby, kick_fn: Callable[..., Awaitable[bool]],
                    parts: list[str], emit: Callable) -> None:
    if len(parts) < 2:
        emit("Usage: kick <nickname> [reason]")
        return
    nick = parts[1]
    reason = " ".join(parts[2:]) if len(parts) > 2 else "kicked by admin"
    if await kick_fn(nick, reason):
        logger.info("KICK       nick=%r reason=%r (via CLI)", nick, reason)
        emit(f"Kicked {nick!r}  ({reason})")
    else:
        emit(f"Player {nick!r} not found or already disconnected.")


async def _cmd_kickip(lobby: Lobby, kickip_fn: Callable[..., Awaitable[int]],
                      parts: list[str], emit: Callable) -> None:
    if len(parts) < 2:
        emit("Usage: kickip <ip> [reason]")
        return
    ip = parts[1]
    reason = " ".join(parts[2:]) if len(parts) > 2 else "kicked by admin"
    count = await kickip_fn(ip, reason)
    if count:
        logger.info("KICKIP     ip=%s count=%d reason=%r (via CLI)", ip, count, reason)
        emit(f"Kicked {count} connection(s) from {ip}.")
    else:
        emit(f"No active connections from {ip}.")


def _cmd_rooms(lobby: Lobby, emit: Callable) -> None:
    rooms = {rid: r for rid, r in lobby._rooms.items()}
    if not rooms:
        emit("No active rooms.")
        return
    emit(f"{'Room ID':<14} {'Name':<24} {'State':<10} {'Players':<10} Clock")
    emit("─" * 72)
    for room in sorted(rooms.values(), key=lambda r: r.created_at):
        members_str = "/".join(m.nickname for m in room.members.values())
        clock = _fmt_ms(room.time_ms) if room.time_ms else "unlimited"
        emit(f"{room.room_id:<14} {room.name:<24} {room.state:<10} {members_str:<10} {clock}")


def _cmd_game(lobby: Lobby, parts: list[str], emit: Callable) -> None:
    if len(parts) < 2:
        emit("Usage: game <room_id>")
        return
    room_id = parts[1]
    room = lobby.get(room_id)
    if room is None:
        emit(f"Room {room_id!r} not found.")
        return

    emit(f"\nRoom   : {room.name!r}  [{room.room_id}]")
    emit(f"State  : {room.state}")
    emit(f"Host   : {room.host_nickname}")

    # Members / colors
    for m in room.members.values():
        color = m.color  # 0=WHITE, 1=BLACK
        color_name = "white" if color == 0 else "black" if color == 1 else "?"
        status = "connected" if m.conn is not None else "disconnected"
        emit(f"  {color_name.capitalize():<6}: {m.nickname}  [{status}]")

    if room.state != ROOM_STATE_PLAYING or room.game is None:
        emit("(game not in progress)")
        return

    g = room.game
    white_ms, black_ms = g.remaining_ms()
    turn = g.active   # "white" or "black"
    emit(f"Turn   : {turn}  (ply {g.ply})")
    emit(f"Clock  : white {_fmt_ms(white_ms)}  |  black {_fmt_ms(black_ms)}")
    emit(f"\n{_fmt_board(g.fen)}\n")


async def _cmd_close(close_room_fn: Callable, parts: list[str], emit: Callable) -> None:
    if len(parts) < 2:
        emit("Usage: close <room_id>")
        return
    room_id = parts[1]
    reason = " ".join(parts[2:]) if len(parts) > 2 else "closed by admin"
    found = await close_room_fn(room_id, reason)
    if found:
        emit(f"Room {room_id!r} closed.")
    else:
        emit(f"Room {room_id!r} not found.")


def _cmd_config(config: object, emit: Callable) -> None:
    from .config import ServerConfig
    c: ServerConfig = config  # type: ignore[assignment]
    tls = "enabled (WSS)" if c.tls_enabled else "disabled (WS — LAN/dev only)"
    ver = c.min_client_version or "(any)"
    emit(f"Host              : {c.host}:{c.port}")
    emit(f"TLS               : {tls}")
    emit(f"Max rooms         : {c.max_rooms}")
    emit(f"Max clients       : {c.max_clients}")
    emit(f"Room idle timeout : {c.room_idle_timeout_s}s")
    emit(f"Reconnect grace   : {c.reconnect_grace_s}s")
    emit(f"Move max age      : {c.move_max_age_s}s")
    emit(f"Heartbeat         : {c.heartbeat_interval_s}s")
    emit(f"Log level         : {c.log_level}")
    emit(f"Min client ver    : {ver}")
    emit(f"Ban file          : {c.ban_file}")
    emit(f"Cert dir          : {c.cert_dir}")



async def _handle_cli_connection(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    banlist: BanList,
    lobby: Lobby,
    kick_fn: Callable[..., Awaitable[bool]],
    kickip_fn: Callable[..., Awaitable[int]],
    close_room_fn: Callable[..., Awaitable[bool]],
    shutdown_fn: Callable[[], None],
    start_time: float,
    stats: dict,
    config: object,
) -> None:
    """Handle one interactive CLI session over the Unix socket."""

    def emit(text: str) -> None:
        writer.write((text + "\n").encode())

    emit(_HELP)

    while True:
        try:
            await writer.drain()
            raw_bytes = await reader.readline()
        except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
            break
        if not raw_bytes:   # EOF — client disconnected (e.g. Ctrl-C)
            break

        parts = raw_bytes.decode(errors="replace").strip().split()
        if not parts:
            continue
        cmd = parts[0].lower()

        # ── Info commands ──────────────────────────────────────────────────
        if cmd == "help":
            emit(_HELP)

        elif cmd == "exit":
            emit("CLI detached. Server keeps running.")
            break

        elif cmd == "status":
            _cmd_status(lobby, start_time, stats, emit)

        elif cmd == "who":
            _cmd_who(lobby, emit)

        elif cmd == "kick":
            await _cmd_kick(lobby, kick_fn, parts, emit)

        elif cmd == "kickip":
            await _cmd_kickip(lobby, kickip_fn, parts, emit)

        elif cmd == "rooms":
            _cmd_rooms(lobby, emit)

        elif cmd == "game":
            _cmd_game(lobby, parts, emit)

        elif cmd == "close":
            await _cmd_close(close_room_fn, parts, emit)

        elif cmd == "config":
            _cmd_config(config, emit)

        elif cmd == "shutdown":
            emit("Shutting down server…")
            logger.info("SHUTDOWN   (via CLI)")
            await kickip_fn("*", "Server is shutting down.")
            shutdown_fn()
            break

        # ── Ban commands ───────────────────────────────────────────────────
        elif cmd == "ban":
            if len(parts) < 2:
                emit("Usage: ban <ip> [nickname]")
                continue
            ip = parts[1]
            nick = " ".join(parts[2:]) if len(parts) > 2 else ""
            await banlist.ban(ip, nick)
            logger.info("BAN        ip=%s nick=%r (via CLI)", ip, nick)
            suffix = f" (nick: {nick!r})" if nick else ""
            emit(f"Banned {ip}{suffix}")
            count = await kickip_fn(ip, "You are banned from this server.", is_ban=True)
            if count:
                emit(f"Kicked {count} active connection(s) from {ip}.")

        elif cmd == "unban":
            if len(parts) < 2:
                emit("Usage: unban <ip>")
                continue
            ip = parts[1]
            if await banlist.unban(ip):
                logger.info("UNBAN      ip=%s (via CLI)", ip)
                emit(f"Unbanned {ip}")
            else:
                emit(f"{ip} is not in the ban list")

        elif cmd == "unban_nick":
            if len(parts) < 2:
                emit("Usage: unban_nick <nickname>")
                continue
            target_nick = parts[1]
            removed = [
                e["ip"] for e in banlist.list_bans()
                if e.get("nickname") == target_nick
            ]
            if not removed:
                emit(f"No ban found for nickname {target_nick!r}.")
            else:
                for ip in removed:
                    await banlist.unban(ip)
                    logger.info("UNBAN      ip=%s (nick=%r, via CLI)", ip, target_nick)
                emit(f"Removed {len(removed)} ban(s) for {target_nick!r}: {', '.join(removed)}")

        elif cmd == "bans":
            entries = banlist.list_bans()
            if not entries:
                emit("No bans.")
            else:
                emit(f"{'IP':<20} {'Nickname':<20} {'Banned at (UTC)'}")
                emit("─" * 70)
                for e in entries:
                    emit(f"{e['ip']:<20} {e['nickname']:<20} {e['banned_at']}")

        else:
            emit(f"Unknown command: {cmd!r}  (type 'help' for a list)")

    try:
        await writer.drain()
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


# ── Socket server ────────────────────────────────────────────────────────────

async def start_cli_server(
    banlist: BanList,
    lobby: Lobby,
    kick_fn: Callable[..., Awaitable[bool]],
    kickip_fn: Callable[..., Awaitable[int]],
    close_room_fn: Callable[..., Awaitable[bool]],
    shutdown_fn: Callable[[], None],
    start_time: float,
    stats: dict,
    config: object,
    socket_path: str = CLI_SOCKET_PATH,
) -> None:
    """Listen on a Unix socket for admin CLI connections.

    Each session is independent — disconnecting one client (via ``exit`` or
    Ctrl-C) does not affect the server or other sessions.
    """
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    def _on_connect(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        asyncio.ensure_future(
            _handle_cli_connection(
                reader, writer,
                banlist, lobby, kick_fn, kickip_fn, close_room_fn, shutdown_fn,
                start_time, stats, config,
            )
        )

    server = await asyncio.start_unix_server(_on_connect, path=socket_path)
    logger.info("CLI socket: %s", socket_path)
    async with server:
        await server.serve_forever()
