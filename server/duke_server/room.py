"""Room: lobby entry + chess game wrapper + per-room state machine."""

from __future__ import annotations

import asyncio
import hmac
import secrets
import time
from dataclasses import dataclass, field
from typing import Optional

from .game import BLACK, WHITE, ChessGame, color_from_name


def _hash_password(password: str) -> bytes:
    """Salted-ish HMAC; rooms are ephemeral so plain SHA256 with random salt is OK."""
    import hashlib
    if not password:
        return b""
    salt = b"duke-room-pw"
    return hashlib.sha256(salt + password.encode("utf-8")).digest()


def check_password(stored: bytes, supplied: str) -> bool:
    if not stored:
        return True
    return hmac.compare_digest(stored, _hash_password(supplied or ""))


ROOM_STATE_WAITING = "waiting"
ROOM_STATE_PLAYING = "playing"
ROOM_STATE_FINISHED = "finished"


@dataclass
class Member:
    nickname: str
    color: Optional[int] = None    # WHITE/BLACK or None
    # Live connection — None if currently disconnected (within grace window).
    conn: Optional[object] = None
    disconnected_at: Optional[float] = None


@dataclass
class Room:
    room_id: str
    name: str
    host_nickname: str
    time_ms: int
    has_password: bool
    _password_hash: bytes = b""
    host_color: int = WHITE                  # host's chosen color
    members: dict[str, Member] = field(default_factory=dict)  # nickname → Member
    state: str = ROOM_STATE_WAITING
    game: Optional[ChessGame] = None
    created_at: float = field(default_factory=time.time)
    draw_offer_by: Optional[int] = None      # color who offered
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    # ── Factory ────────────────────────────────────────────────────────────
    @classmethod
    def create(
        cls,
        name: str,
        host_nickname: str,
        host_color_name: str,
        time_ms: int,
        password: str,
    ) -> "Room":
        room_id = secrets.token_urlsafe(10)
        host_color = color_from_name(host_color_name)
        room = cls(
            room_id=room_id,
            name=name.strip() or f"{host_nickname}'s room",
            host_nickname=host_nickname,
            time_ms=max(0, int(time_ms)),
            has_password=bool(password),
            _password_hash=_hash_password(password) if password else b"",
            host_color=host_color,
        )
        room.members[host_nickname] = Member(nickname=host_nickname, color=host_color)
        return room

    # ── Membership ─────────────────────────────────────────────────────────
    def public_listing(self) -> dict:
        return {
            "room_id": self.room_id,
            "name": self.name,
            "host": self.host_nickname,
            "time_ms": self.time_ms,
            "has_password": self.has_password,
            "state": self.state,
            "members": len(self.members),
            "capacity": 2,
        }

    def public_detail(self, viewer_nickname: str) -> dict:
        members = []
        for m in self.members.values():
            members.append({
                "nickname": m.nickname,
                "color": _color_name(m.color),
                "connected": m.conn is not None,
                "is_host": m.nickname == self.host_nickname,
            })
        return {
            **self.public_listing(),
            "members_detail": members,
            "host_color": _color_name(self.host_color),
            "your_color": _color_name(self.member_color(viewer_nickname)),
        }

    def member_color(self, nickname: str) -> Optional[int]:
        m = self.members.get(nickname)
        return m.color if m else None

    def color_to_member(self, color: int) -> Optional[Member]:
        for m in self.members.values():
            if m.color == color:
                return m
        return None

    def is_full(self) -> bool:
        return len(self.members) >= 2

    def is_host(self, nickname: str) -> bool:
        return nickname == self.host_nickname

    def check_password(self, supplied: str) -> bool:
        return check_password(self._password_hash, supplied)

    def join(self, nickname: str) -> Member:
        if nickname in self.members:
            return self.members[nickname]
        # Assign opposite color from host.
        guest_color = BLACK if self.host_color == WHITE else WHITE
        member = Member(nickname=nickname, color=guest_color)
        self.members[nickname] = member
        return member

    def remove(self, nickname: str) -> None:
        self.members.pop(nickname, None)

    # ── Game ───────────────────────────────────────────────────────────────
    def can_start(self) -> bool:
        if self.state != ROOM_STATE_WAITING:
            return False
        if len(self.members) < 2:
            return False
        # both must be connected
        for m in self.members.values():
            if m.conn is None:
                return False
        # both must have a color
        colors = {m.color for m in self.members.values()}
        return WHITE in colors and BLACK in colors

    def start_game(self) -> None:
        self.state = ROOM_STATE_PLAYING
        self.game = ChessGame(time_ms=self.time_ms)
        self.game.start()
        self.draw_offer_by = None

    def finish(self) -> None:
        self.state = ROOM_STATE_FINISHED


def _color_name(c: Optional[int]) -> Optional[str]:
    if c is None:
        return None
    return "white" if c == WHITE else "black"
