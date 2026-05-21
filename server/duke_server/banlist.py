"""Persistent IP ban list backed by a JSON file.

The ban list is intentionally simple: it maps an IP address string to a
small record that stores the nickname seen at ban time (for operator
orientation) and the UTC timestamp of the ban action.

Thread-safety
-------------
:meth:`BanList.is_banned` is a plain dict lookup — safe to call from any
asyncio coroutine without acquiring the lock because dict reads in CPython
are atomic at the C level.  Mutating operations (:meth:`ban`,
:meth:`unban`) take an asyncio :class:`asyncio.Lock` to serialise
concurrent writes and to guard the file-I/O.
"""

from __future__ import annotations

import asyncio
import datetime
import json
import logging
from pathlib import Path


logger = logging.getLogger(__name__)


class BanList:
    """In-memory IP ban list with JSON persistence.

    Parameters
    ----------
    path:
        Path to the backing JSON file. The parent directory is created on
        first save if it does not exist yet.
    """

    def __init__(self, path: str) -> None:
        self._path = Path(path)
        self._lock = asyncio.Lock()
        # Mapping: ip_str → {"nickname": str, "banned_at": ISO-8601 str}
        self._bans: dict[str, dict] = {}

    # ── Startup ────────────────────────────────────────────────────────────

    def load(self) -> None:
        """Load bans from disk.  Call once synchronously at server startup."""
        if not self._path.exists():
            return
        try:
            with self._path.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                self._bans = data
                logger.info("Loaded %d ban(s) from %s", len(self._bans), self._path)
        except Exception as exc:
            logger.error("Failed to load ban list from %s: %s", self._path, exc)

    # ── Read ────────────────────────────────────────────────────────────────

    def is_banned(self, ip: str) -> bool:
        """Return ``True`` if *ip* is in the ban list."""
        return ip in self._bans

    def list_bans(self) -> list[dict]:
        """Return a sorted snapshot: ``[{ip, nickname, banned_at}, ...]``."""
        return [
            {"ip": ip, **entry}
            for ip, entry in sorted(self._bans.items())
        ]

    # ── Mutate ─────────────────────────────────────────────────────────────

    async def ban(self, ip: str, nickname: str = "") -> None:
        """Add *ip* to the ban list and persist to disk."""
        async with self._lock:
            self._bans[ip] = {
                "nickname": nickname,
                "banned_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }
            await self._save()

    async def unban(self, ip: str) -> bool:
        """Remove *ip*.  Returns ``True`` when the entry existed."""
        async with self._lock:
            if ip not in self._bans:
                return False
            del self._bans[ip]
            await self._save()
            return True

    # ── Internal ───────────────────────────────────────────────────────────

    async def _save(self) -> None:
        """Atomically write the ban list JSON (caller must hold the lock)."""
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(
                json.dumps(self._bans, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            tmp.replace(self._path)
        except Exception as exc:
            logger.error("Failed to save ban list to %s: %s", self._path, exc)
