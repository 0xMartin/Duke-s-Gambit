"""Server-side chess game: wraps python-chess board and authoritative clock."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional

import chess


WHITE = 0
BLACK = 1

COLOR_NAMES = {WHITE: "white", BLACK: "black"}


def color_from_name(name: str) -> int:
    n = (name or "").lower()
    if n == "white":
        return WHITE
    if n == "black":
        return BLACK
    raise ValueError("color must be 'white' or 'black'")


@dataclass
class MoveResult:
    uci: str
    from_sq: str
    to_sq: str
    promotion: Optional[str]
    fen: str
    active: str               # "white"/"black"
    white_ms: int
    black_ms: int
    ply: int
    game_over: bool
    winner: Optional[str]     # "white"/"black"/"draw"/None
    reason: Optional[str]


@dataclass
class ChessGame:
    """Authoritative chess game state with a per-side clock."""

    time_ms: int = 0          # initial clock per side (0 = unlimited)
    _board: chess.Board = field(default_factory=chess.Board)
    _white_ms: int = 0
    _black_ms: int = 0
    _turn_started_monotonic: float = 0.0
    _started: bool = False
    _game_over: bool = False
    _winner: Optional[str] = None
    _reason: Optional[str] = None

    def __post_init__(self) -> None:
        self._white_ms = self.time_ms
        self._black_ms = self.time_ms

    # ── Lifecycle ──────────────────────────────────────────────────────────
    def start(self) -> None:
        self._started = True
        self._turn_started_monotonic = time.monotonic()

    @property
    def started(self) -> bool:
        return self._started

    @property
    def fen(self) -> str:
        return self._board.fen()

    @property
    def active(self) -> str:
        return "white" if self._board.turn == chess.WHITE else "black"

    @property
    def ply(self) -> int:
        return self._board.ply()

    @property
    def game_over(self) -> bool:
        return self._game_over

    @property
    def winner(self) -> Optional[str]:
        return self._winner

    @property
    def reason(self) -> Optional[str]:
        return self._reason

    @property
    def has_time_limit(self) -> bool:
        return self.time_ms > 0

    # ── Clock ──────────────────────────────────────────────────────────────
    def remaining_ms(self) -> tuple[int, int]:
        """Return (white_ms, black_ms) snapshot accounting for elapsed turn time."""
        if not self._started or self._game_over or not self.has_time_limit:
            return self._white_ms, self._black_ms
        elapsed_ms = int((time.monotonic() - self._turn_started_monotonic) * 1000)
        if self._board.turn == chess.WHITE:
            return max(0, self._white_ms - elapsed_ms), self._black_ms
        else:
            return self._white_ms, max(0, self._black_ms - elapsed_ms)

    def check_timeout(self) -> Optional[str]:
        """Return loser color name ('white'/'black') if their clock hit zero."""
        if not self.has_time_limit or self._game_over or not self._started:
            return None
        white_ms, black_ms = self.remaining_ms()
        if self._board.turn == chess.WHITE and white_ms <= 0:
            self._finish("black", "time")
            return "white"
        if self._board.turn == chess.BLACK and black_ms <= 0:
            self._finish("white", "time")
            return "black"
        return None

    # ── Moves ──────────────────────────────────────────────────────────────
    def apply_move(self, color: int, uci: str) -> MoveResult:
        if not self._started:
            raise BadState("game not started")
        if self._game_over:
            raise BadState("game already over")
        if (self._board.turn == chess.WHITE and color != WHITE) or (
            self._board.turn == chess.BLACK and color != BLACK
        ):
            raise NotYourTurn("not your turn")

        # Deduct elapsed time from active side before applying.
        if self.has_time_limit:
            elapsed_ms = int((time.monotonic() - self._turn_started_monotonic) * 1000)
            if self._board.turn == chess.WHITE:
                self._white_ms = max(0, self._white_ms - elapsed_ms)
                if self._white_ms == 0:
                    self._finish("black", "time")
                    return self._snapshot_after_terminal("(time)")
            else:
                self._black_ms = max(0, self._black_ms - elapsed_ms)
                if self._black_ms == 0:
                    self._finish("white", "time")
                    return self._snapshot_after_terminal("(time)")

        try:
            move = chess.Move.from_uci(uci.strip())
        except ValueError as exc:
            raise IllegalMove(f"malformed uci: {exc}") from exc
        if move not in self._board.legal_moves:
            raise IllegalMove(f"illegal move: {uci}")

        from_sq = chess.square_name(move.from_square)
        to_sq = chess.square_name(move.to_square)
        promotion = chess.piece_symbol(move.promotion).lower() if move.promotion else None

        self._board.push(move)
        self._turn_started_monotonic = time.monotonic()

        self._detect_terminal()

        white_ms, black_ms = self.remaining_ms()
        return MoveResult(
            uci=move.uci(),
            from_sq=from_sq,
            to_sq=to_sq,
            promotion=promotion,
            fen=self._board.fen(),
            active=self.active,
            white_ms=white_ms,
            black_ms=black_ms,
            ply=self._board.ply(),
            game_over=self._game_over,
            winner=self._winner,
            reason=self._reason,
        )

    def force_resign(self, color: int) -> MoveResult:
        loser = COLOR_NAMES[color]
        winner = "black" if loser == "white" else "white"
        self._finish(winner, "resign")
        return self._snapshot_after_terminal("(resign)")

    def force_draw(self, reason: str = "agreement") -> MoveResult:
        self._finish("draw", reason)
        return self._snapshot_after_terminal("(draw)")

    # ── Internals ──────────────────────────────────────────────────────────
    def _detect_terminal(self) -> None:
        outcome = self._board.outcome(claim_draw=True)
        if outcome is None:
            return
        if outcome.winner is None:
            self._finish("draw", outcome.termination.name.lower())
        else:
            self._finish("white" if outcome.winner == chess.WHITE else "black",
                         outcome.termination.name.lower())

    def _finish(self, winner: str, reason: str) -> None:
        if self._game_over:
            return
        self._game_over = True
        self._winner = winner
        self._reason = reason

    def _snapshot_after_terminal(self, fallback_uci: str) -> MoveResult:
        white_ms, black_ms = self.remaining_ms()
        return MoveResult(
            uci=fallback_uci,
            from_sq="",
            to_sq="",
            promotion=None,
            fen=self._board.fen(),
            active=self.active,
            white_ms=white_ms,
            black_ms=black_ms,
            ply=self._board.ply(),
            game_over=True,
            winner=self._winner,
            reason=self._reason,
        )


class GameError(Exception):
    pass


class BadState(GameError):
    pass


class NotYourTurn(GameError):
    pass


class IllegalMove(GameError):
    pass
