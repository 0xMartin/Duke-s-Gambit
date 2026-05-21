"""Interactive admin CLI that reads commands from stdin.

Run :func:`run_cli` as a background asyncio task.  It blocks a single
thread-pool thread on ``sys.stdin.readline`` while the rest of the event
loop continues processing WebSocket traffic normally.

In Docker, attach to the container's stdin to send commands::

    docker attach dukes-gambit-server    # Ctrl-P Ctrl-Q to detach

The preferred way for scripted access is ``docker attach``.
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import sys
import time
from typing import Awaitable, Callable

import chess

from .banlist import BanList
from .lobby import Lobby
from .log_setup import CliLogFilter
from .room import ROOM_STATE_PLAYING


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
{_SEP}
  ban <ip> [nick]        Ban an IP address
  unban <ip>             Remove a ban by IP
  unban_nick <nick>      Remove a ban by nickname
  bans                   List all banned IPs
{_SEP}
  logon / logoff         Toggle log output to this console
  shutdown               Kick all players and stop the server
  exit                   Detach CLI (server keeps running)
  help                   Show this help"""


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

def _cmd_status(lobby: Lobby, start_time: float, stats: dict) -> None:
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

    print(f"Uptime   : {_fmt_uptime(start_time)}", flush=True)
    print(f"Players  : {lobby.online_count} connected  (peak: {stats['peak_players']})", flush=True)
    print(f"Today    : {connects_today} connections  (avg {avg_per_h:.1f}/h)", flush=True)
    print(f"Rooms    : {len(rooms)} total  ({playing} playing, {waiting} waiting)", flush=True)


def _cmd_who(lobby: Lobby) -> None:
    clients = lobby.all_clients()
    if not clients:
        print("No players connected.", flush=True)
        return
    print(f"{'Nickname':<20} {'IP':<18} {'Room ID':<14} Location", flush=True)
    print("─" * 72, flush=True)
    for conn in sorted(clients, key=lambda c: getattr(getattr(c, "_duke_ctx", None), "nickname", "") or ""):
        ctx = getattr(conn, "_duke_ctx", None)
        nick = ctx.nickname if ctx else "(pre-hello)"
        addr = getattr(conn, "remote_address", None)
        ip = addr[0] if addr else "?"
        room_id = ctx.room_id if ctx else None
        location = room_id if room_id else "(lobby)"
        print(f"{nick:<20} {ip:<18} {(room_id or ''):<14} {location}", flush=True)


async def _cmd_kick(lobby: Lobby, kick_fn: Callable[..., Awaitable[bool]],
                    parts: list[str]) -> None:
    if len(parts) < 2:
        print("Usage: kick <nickname> [reason]", flush=True)
        return
    nick = parts[1]
    reason = " ".join(parts[2:]) if len(parts) > 2 else "kicked by admin"
    if await kick_fn(nick, reason):
        logger.info("KICK       nick=%r reason=%r (via CLI)", nick, reason)
        print(f"Kicked {nick!r}  ({reason})", flush=True)
    else:
        print(f"Player {nick!r} not found or already disconnected.", flush=True)


async def _cmd_kickip(lobby: Lobby, kickip_fn: Callable[..., Awaitable[int]],
                      parts: list[str]) -> None:
    if len(parts) < 2:
        print("Usage: kickip <ip> [reason]", flush=True)
        return
    ip = parts[1]
    reason = " ".join(parts[2:]) if len(parts) > 2 else "kicked by admin"
    count = await kickip_fn(ip, reason)
    if count:
        logger.info("KICKIP     ip=%s count=%d reason=%r (via CLI)", ip, count, reason)
        print(f"Kicked {count} connection(s) from {ip}.", flush=True)
    else:
        print(f"No active connections from {ip}.", flush=True)


def _cmd_rooms(lobby: Lobby) -> None:
    rooms = {rid: r for rid, r in lobby._rooms.items()}
    if not rooms:
        print("No active rooms.", flush=True)
        return
    print(f"{'Room ID':<14} {'Name':<24} {'State':<10} {'Players':<10} Clock", flush=True)
    print("─" * 72, flush=True)
    for room in sorted(rooms.values(), key=lambda r: r.created_at):
        members_str = "/".join(m.nickname for m in room.members.values())
        clock = _fmt_ms(room.time_ms) if room.time_ms else "unlimited"
        print(
            f"{room.room_id:<14} {room.name:<24} {room.state:<10} {members_str:<10} {clock}",
            flush=True,
        )


def _cmd_game(lobby: Lobby, parts: list[str]) -> None:
    if len(parts) < 2:
        print("Usage: game <room_id>", flush=True)
        return
    room_id = parts[1]
    room = lobby.get(room_id)
    if room is None:
        print(f"Room {room_id!r} not found.", flush=True)
        return

    print(f"\nRoom   : {room.name!r}  [{room.room_id}]", flush=True)
    print(f"State  : {room.state}", flush=True)
    print(f"Host   : {room.host_nickname}", flush=True)

    # Members / colors
    for m in room.members.values():
        color = m.color  # 0=WHITE, 1=BLACK
        color_name = "white" if color == 0 else "black" if color == 1 else "?"
        status = "connected" if m.conn is not None else "disconnected"
        print(f"  {color_name.capitalize():<6}: {m.nickname}  [{status}]", flush=True)

    if room.state != ROOM_STATE_PLAYING or room.game is None:
        print("(game not in progress)", flush=True)
        return

    g = room.game
    white_ms, black_ms = g.remaining_ms()
    turn = g.active   # "white" or "black"
    print(f"Turn   : {turn}  (ply {g.ply})", flush=True)
    print(f"Clock  : white {_fmt_ms(white_ms)}  |  black {_fmt_ms(black_ms)}", flush=True)
    print(f"\n{_fmt_board(g.fen)}\n", flush=True)


# ── Main loop ────────────────────────────────────────────────────────────────

async def run_cli(
    banlist: BanList,
    lobby: Lobby,
    kick_fn: Callable[..., Awaitable[bool]],
    kickip_fn: Callable[..., Awaitable[int]],
    shutdown_fn: Callable[[], None],
    start_time: float,
    stats: dict,
    log_filter: "CliLogFilter | None" = None,
) -> None:
    """Background task: read admin commands from stdin until EOF."""
    loop = asyncio.get_event_loop()
    print(_HELP, flush=True)

    while True:
        try:
            raw: str = await loop.run_in_executor(None, sys.stdin.readline)
        except Exception:
            break
        if not raw:          # EOF
            break

        parts = raw.strip().split()
        if not parts:
            continue
        cmd = parts[0].lower()

        # ── Info commands ──────────────────────────────────────────────────
        if cmd == "help":
            print(_HELP, flush=True)

        elif cmd == "exit":
            print("CLI detached. Server keeps running.", flush=True)
            break

        elif cmd == "logon":
            if log_filter is not None:
                log_filter.enabled = True
                print("Log output enabled.", flush=True)
            else:
                print("Log filter not available.", flush=True)

        elif cmd == "logoff":
            if log_filter is not None:
                log_filter.enabled = False
                print("Log output disabled.", flush=True)
            else:
                print("Log filter not available.", flush=True)

        elif cmd == "status":
            _cmd_status(lobby, start_time, stats)

        elif cmd == "who":
            _cmd_who(lobby)

        elif cmd == "kick":
            await _cmd_kick(lobby, kick_fn, parts)

        elif cmd == "kickip":
            await _cmd_kickip(lobby, kickip_fn, parts)

        elif cmd == "rooms":
            _cmd_rooms(lobby)

        elif cmd == "game":
            _cmd_game(lobby, parts)

        elif cmd == "shutdown":
            print("Shutting down server…", flush=True)
            logger.info("SHUTDOWN   (via CLI)")
            await kickip_fn("*", "Server is shutting down.")
            shutdown_fn()
            break

        # ── Ban commands ───────────────────────────────────────────────────
        elif cmd == "ban":
            if len(parts) < 2:
                print("Usage: ban <ip> [nickname]", flush=True)
                continue
            ip = parts[1]
            nick = " ".join(parts[2:]) if len(parts) > 2 else ""
            await banlist.ban(ip, nick)
            logger.info("BAN        ip=%s nick=%r (via CLI)", ip, nick)
            suffix = f" (nick: {nick!r})" if nick else ""
            print(f"Banned {ip}{suffix}", flush=True)
            count = await kickip_fn(ip, "You are banned from this server.", is_ban=True)
            if count:
                print(f"Kicked {count} active connection(s) from {ip}.", flush=True)

        elif cmd == "unban":
            if len(parts) < 2:
                print("Usage: unban <ip>", flush=True)
                continue
            ip = parts[1]
            if await banlist.unban(ip):
                logger.info("UNBAN      ip=%s (via CLI)", ip)
                print(f"Unbanned {ip}", flush=True)
            else:
                print(f"{ip} is not in the ban list", flush=True)

        elif cmd == "unban_nick":
            if len(parts) < 2:
                print("Usage: unban_nick <nickname>", flush=True)
                continue
            target_nick = parts[1]
            removed = [
                e["ip"] for e in banlist.list_bans()
                if e.get("nickname") == target_nick
            ]
            if not removed:
                print(f"No ban found for nickname {target_nick!r}.", flush=True)
            else:
                for ip in removed:
                    await banlist.unban(ip)
                    logger.info("UNBAN      ip=%s (nick=%r, via CLI)", ip, target_nick)
                print(f"Removed {len(removed)} ban(s) for {target_nick!r}: {', '.join(removed)}", flush=True)

        elif cmd == "bans":
            entries = banlist.list_bans()
            if not entries:
                print("No bans.", flush=True)
            else:
                print(f"{'IP':<20} {'Nickname':<20} {'Banned at (UTC)'}", flush=True)
                print("─" * 70, flush=True)
                for e in entries:
                    print(
                        f"{e['ip']:<20} {e['nickname']:<20} {e['banned_at']}",
                        flush=True,
                    )

        else:
            print(f"Unknown command: {cmd!r}  (type 'help' for a list)", flush=True)
