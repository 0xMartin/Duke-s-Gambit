"""Lobby: tracks rooms and online clients, broadcasts updates."""

from __future__ import annotations

import asyncio
import logging
from typing import Dict, Optional, Set

from .room import Room


logger = logging.getLogger(__name__)


class Lobby:
    def __init__(self, max_rooms: int) -> None:
        self.max_rooms = max_rooms
        self._rooms: Dict[str, Room] = {}
        self._clients: Set[object] = set()
        self._lock = asyncio.Lock()
        self._listeners: Set[object] = set()

    # ── Clients ────────────────────────────────────────────────────────────
    async def add_client(self, conn) -> None:
        async with self._lock:
            self._clients.add(conn)

    async def remove_client(self, conn) -> None:
        async with self._lock:
            self._clients.discard(conn)
            self._listeners.discard(conn)

    @property
    def online_count(self) -> int:
        return len(self._clients)

    # ── Lobby subscribers (only clients on the room-list view) ─────────────
    def add_listener(self, conn) -> None:
        self._listeners.add(conn)

    def remove_listener(self, conn) -> None:
        self._listeners.discard(conn)

    def listeners(self) -> Set[object]:
        return set(self._listeners)

    def all_clients(self) -> Set[object]:
        return set(self._clients)

    # ── Rooms ──────────────────────────────────────────────────────────────
    def list_rooms(self) -> list[dict]:
        return [r.public_listing() for r in self._rooms.values()
                if r.state != "finished"]

    def get(self, room_id: str) -> Optional[Room]:
        return self._rooms.get(room_id)

    async def add_room(self, room: Room) -> bool:
        async with self._lock:
            if len(self._rooms) >= self.max_rooms:
                return False
            self._rooms[room.room_id] = room
            return True

    async def remove_room(self, room_id: str) -> None:
        async with self._lock:
            self._rooms.pop(room_id, None)
