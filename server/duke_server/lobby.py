"""Lobby registry: rooms, connected clients, and listener subscriptions.

The lobby owns three logical sets:

* **clients** — every WebSocket currently connected and past hello.
* **listeners** — the subset of clients that have subscribed to room-list
  updates (i.e. they are looking at the lobby screen). Joining/creating
  a room removes a client from the listener set.
* **rooms** — every active :class:`~duke_server.room.Room`. Rooms in
  state ``"finished"`` are kept briefly (for late ``game_over`` reads)
  but filtered out of :meth:`Lobby.list_rooms`.

All mutating operations take an asyncio :class:`asyncio.Lock` so that
concurrent ``join_room`` / ``create_room`` flows do not race on the
``max_rooms`` cap. Read-only accessors return snapshots (defensive
copies) so callers can iterate without holding the lock.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Dict, Optional, Set

from .room import Room


logger = logging.getLogger(__name__)


class Lobby:
    """In-memory registry of rooms and connected WebSocket clients.

    Parameters
    ----------
    max_rooms:
        Hard cap on the number of concurrent rooms. Further
        :meth:`add_room` calls return ``False`` once this is reached.
    """

    def __init__(self, max_rooms: int) -> None:
        self.max_rooms = max_rooms
        self._rooms: Dict[str, Room] = {}
        self._clients: Set[object] = set()
        self._lock = asyncio.Lock()
        self._listeners: Set[object] = set()

    # ── Clients ────────────────────────────────────────────────────────────
    async def add_client(self, conn) -> None:
        """Register a connection as online (called after ``hello`` succeeds)."""
        async with self._lock:
            self._clients.add(conn)

    async def remove_client(self, conn) -> None:
        """Drop a connection from both the client and listener sets."""
        async with self._lock:
            self._clients.discard(conn)
            self._listeners.discard(conn)

    @property
    def online_count(self) -> int:
        """Number of currently connected clients (past hello)."""
        return len(self._clients)

    # ── Lobby subscribers (only clients on the room-list view) ─────────────
    def add_listener(self, conn) -> None:
        """Subscribe a connection to ``room_list`` / ``online_count`` updates."""
        self._listeners.add(conn)

    def remove_listener(self, conn) -> None:
        """Unsubscribe from room-list updates (called on join/create/leave)."""
        self._listeners.discard(conn)

    def listeners(self) -> Set[object]:
        """Snapshot of the listener set, safe to iterate without the lock."""
        return set(self._listeners)

    def all_clients(self) -> Set[object]:
        """Snapshot of the connected-clients set."""
        return set(self._clients)

    # ── Rooms ──────────────────────────────────────────────────────────────
    def list_rooms(self) -> list[dict]:
        """Public room listings for the lobby screen.

        Finished rooms are filtered out so the lobby never advertises
        a game that cannot be joined. Each entry follows the
        :meth:`Room.public_listing` schema (``members`` is an integer
        member count, not a list).
        """
        return [r.public_listing() for r in self._rooms.values()
                if r.state != "finished"]

    def get(self, room_id: str) -> Optional[Room]:
        """Look up a room by id, returning ``None`` if it does not exist."""
        return self._rooms.get(room_id)

    async def add_room(self, room: Room) -> bool:
        """Register a freshly created room.

        Returns
        -------
        bool
            ``True`` on success, ``False`` if the ``max_rooms`` cap has
            already been reached. The caller must then surface
            :data:`~duke_server.protocol.ERR_FULL` to the client.
        """
        async with self._lock:
            if len(self._rooms) >= self.max_rooms:
                return False
            self._rooms[room.room_id] = room
            return True

    async def remove_room(self, room_id: str) -> None:
        """Remove a room from the registry. No-op if it is already gone."""
        async with self._lock:
            self._rooms.pop(room_id, None)

