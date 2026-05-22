"""Room: lobby entry, member tracking and chess game wrapper.

A :class:`Room` represents one match slot. It owns:

* Identity (``room_id``, ``name``, ``host_nickname``).
* Configuration (``time_ms`` clock, optional password hash, host color).
* The :class:`~duke_server.game.ChessGame` instance once play starts.
* A small state machine: ``waiting`` → ``playing`` → ``finished``.
* Per-room :class:`asyncio.Lock` used by the server to serialise
  mutating operations (apply move, finish, draw handling).

Passwords
---------
Rooms are ephemeral, so a real KDF is overkill. Passwords are stored as
``SHA-256(salt || password)`` with a fixed package-level salt; verified
in constant time via :func:`hmac.compare_digest`.

Member vs. public view
----------------------
Two serialisation methods exist to avoid leaking information into the
public lobby listing:

* :meth:`Room.public_listing` — cheap summary used in
  :data:`~duke_server.protocol.S_ROOM_LIST`. ``members`` is an integer
  count, not a list.
* :meth:`Room.public_detail` — includes the per-member ``members_detail``
  list and is sent only to clients inside the room.
"""

from __future__ import annotations

import asyncio
import hmac
import secrets
import time
from dataclasses import dataclass, field
from typing import Optional

from .game import BLACK, WHITE, ChessGame, color_from_name


def _hash_password(password: str) -> bytes:
    """Hash a room password (or return empty bytes for no password).

    Uses ``SHA-256(salt || password)`` with a fixed package salt.
    Rooms are throw-away so this is intentionally lightweight — it is
    not a substitute for a proper KDF on user accounts.
    """
    import hashlib
    if not password:
        return b""
    salt = b"duke-room-pw"
    return hashlib.sha256(salt + password.encode("utf-8")).digest()


def check_password(stored: bytes, supplied: str) -> bool:
    """Constant-time password comparison.

    An empty ``stored`` hash means the room has no password and any
    supplied value is accepted.
    """
    if not stored:
        return True
    return hmac.compare_digest(stored, _hash_password(supplied or ""))


ROOM_STATE_WAITING = "waiting"
ROOM_STATE_PLAYING = "playing"
ROOM_STATE_FINISHED = "finished"


@dataclass
class Member:
    """One participant in a room.

    Attributes
    ----------
    nickname:
        Validated display name (unique within a room).
    color:
        :data:`~duke_server.game.WHITE` / :data:`~duke_server.game.BLACK`
        or ``None`` if not yet assigned.
    conn:
        Live WebSocket reference, or ``None`` when the member is within
        the reconnect grace window.
    disconnected_at:
        ``time.monotonic()`` value recorded when ``conn`` became ``None``
        — used by the server to expire the grace window.
    """

    nickname: str
    color: Optional[int] = None    # WHITE/BLACK or None
    # Live connection — None if currently disconnected (within grace window).
    conn: Optional[object] = None
    disconnected_at: Optional[float] = None


@dataclass
class Room:
    """A two-seat match container with lifecycle and broadcast surface.

    Invariants
    ----------
    * ``state == "waiting"`` implies ``game is None``.
    * ``state == "playing"`` implies ``game is not None`` and at least one
      :class:`Member` has each of WHITE / BLACK.
    * ``state == "finished"`` is a terminal state; the room may still be
      browsed briefly before being removed by the lobby.
    * ``host_nickname`` is always present in :attr:`members`.
    * The room's :attr:`lock` must be held when mutating the wrapped
      :class:`~duke_server.game.ChessGame`.
    """

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
    # Nicknames that have signalled C_CLIENT_READY for the current game.
    # The clock is only armed once both members are present in this set,
    # so a slow-loading client cannot lose time before its intro finishes.
    ready_members: set = field(default_factory=set)
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
        """Construct a fresh room with a generated id and the host as sole member.

        Parameters
        ----------
        name:
            Room title shown in the lobby. Blank values are replaced by
            ``"<host>'s room"``.
        host_nickname:
            The creator's nickname; becomes both the host and the first
            :class:`Member`.
        host_color_name:
            ``"white"`` or ``"black"`` — see
            :func:`~duke_server.game.color_from_name`.
        time_ms:
            Initial clock per side in milliseconds (0 = unlimited).
            Clamped to ``>= 0``.
        password:
            Optional plaintext password; stored only as a salted hash.
        """
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
        """Cheap public summary used in the lobby room list.

        Note that ``members`` here is an **integer count**, not a list —
        clients viewing the lobby do not need (and should not see)
        nicknames of players inside private rooms.
        """
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
        """Detailed view shown to clients **inside** the room.

        Includes a ``members_detail`` list with nickname / color /
        connection status / host flag for each member, plus the host's
        chosen color and ``your_color`` resolved for ``viewer_nickname``.
        """
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
        """Color assigned to ``nickname`` (``None`` if not a member)."""
        m = self.members.get(nickname)
        return m.color if m else None

    def color_to_member(self, color: int) -> Optional[Member]:
        """Look up the :class:`Member` playing the given color."""
        for m in self.members.values():
            if m.color == color:
                return m
        return None

    def is_full(self) -> bool:
        """True once both seats are taken (capacity is fixed at 2)."""
        return len(self.members) >= 2

    def is_host(self, nickname: str) -> bool:
        """True if ``nickname`` is the room's host."""
        return nickname == self.host_nickname

    def check_password(self, supplied: str) -> bool:
        """Verify a join attempt against the stored password hash."""
        return check_password(self._password_hash, supplied)

    def join(self, nickname: str) -> Member:
        """Add a guest to the room, auto-assigning the color opposite the host.

        Idempotent: re-joining with the same nickname returns the
        existing :class:`Member` unchanged.
        """
        if nickname in self.members:
            return self.members[nickname]
        # Assign opposite color from host.
        guest_color = BLACK if self.host_color == WHITE else WHITE
        member = Member(nickname=nickname, color=guest_color)
        self.members[nickname] = member
        return member

    def remove(self, nickname: str) -> None:
        """Remove a member by nickname; no-op if not present."""
        self.members.pop(nickname, None)

    # ── Game ───────────────────────────────────────────────────────────────
    def can_start(self) -> bool:
        """Return ``True`` iff the host may issue ``start_game`` now.

        Requires: room in WAITING state, both seats filled, both members
        currently connected, and the two members hold opposite colors.
        """
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
        """Transition to PLAYING and create the :class:`ChessGame`.

        The underlying chess clock is **not** armed here — call
        :meth:`arm_clock` once every member has signalled readiness so
        slow-loading clients do not lose time during the intro cutscene.
        """
        self.state = ROOM_STATE_PLAYING
        self.game = ChessGame(time_ms=self.time_ms)
        self.draw_offer_by = None
        self.ready_members.clear()

    def mark_ready(self, nickname: str) -> bool:
        """Record that ``nickname`` finished loading; return True iff all members ready."""
        if nickname in self.members:
            self.ready_members.add(nickname)
        return len(self.ready_members) >= len(self.members) >= 2

    def arm_clock(self) -> None:
        """Start the chess clock. Idempotent — safe to call once both clients ready."""
        if self.game is not None and not self.game.started:
            self.game.start()

    def finish(self) -> None:
        """Transition to FINISHED. Idempotent; the lobby will GC the room."""
        self.state = ROOM_STATE_FINISHED


def _color_name(c: Optional[int]) -> Optional[str]:
    """Map the integer color (or ``None``) to its wire string form."""
    if c is None:
        return None
    return "white" if c == WHITE else "black"
