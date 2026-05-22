"""Authoritative chess game engine with per-side clock.

This module is the single source of truth for legality and timing during
a match. The server constructs one :class:`ChessGame` per room when the
host starts the game and feeds every client move through
:meth:`ChessGame.apply_move`. A background watcher task polls
:meth:`ChessGame.check_timeout` to detect flag-falls when nobody is
moving.

The wrapped board is a regular ``python-chess`` :class:`chess.Board`;
the clock state is intentionally kept inside this dataclass so that the
entire game state can be inspected (or snapshotted for reconnects) from
a single object.

Clock semantics
---------------
* ``time_ms == 0`` means an unlimited game; ``remaining_ms`` then
  returns a constant ``(0, 0)`` and :meth:`check_timeout` is a no-op.
* Otherwise the active side's clock counts down from the moment
  ``_turn_started_monotonic`` was set (either by :meth:`start` or by
  the previous successful move).
* No increment / Fischer bonus is implemented.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional

import chess


WHITE = 0
BLACK = 1

COLOR_NAMES = {WHITE: "white", BLACK: "black"}


def color_from_name(name: str) -> int:
    """Convert the wire color string ``"white"`` / ``"black"`` to an int.

    Raises
    ------
    ValueError
        If ``name`` is neither ``"white"`` nor ``"black"`` (case-insensitive).
    """
    n = (name or "").lower()
    if n == "white":
        return WHITE
    if n == "black":
        return BLACK
    raise ValueError("color must be 'white' or 'black'")


def _estimate_animation_ms(board: chess.Board, move: chess.Move) -> int:
    """Estimate how long the client takes to animate ``move``.

    The new active player's clock must not start ticking on the server
    while the *opposing* client is still playing the move animation,
    otherwise the player sees a time jump the moment they click (server
    has already silently deducted the animation duration).  These
    numbers are deliberate over-estimates aligned with the client-side
    piece movement / FX timings (see ``base_piece.gd`` MOVE_SPEED=1 tile/s
    plus attack trails ~1\u20131.5 s).
    """
    fx, fy = chess.square_file(move.from_square), chess.square_rank(move.from_square)
    tx, ty = chess.square_file(move.to_square), chess.square_rank(move.to_square)
    # Chebyshev distance \u2248 number of tiles the piece walks (one tile / s).
    distance = max(abs(fx - tx), abs(fy - ty))

    piece = board.piece_at(move.from_square)
    is_knight = piece is not None and piece.piece_type == chess.KNIGHT
    is_capture = board.is_capture(move)
    is_castle = board.is_castling(move)
    is_promotion = move.promotion is not None

    if is_castle:
        # Castling animates king + rook; queenside is the slow case.
        return 3500

    if is_knight:
        # Knight jump animation is fixed ~0.92\u202fs regardless of distance.
        grace = 1100
    else:
        grace = distance * 1000

    if is_capture:
        grace += 1500   # attack trail + hit FX
    if is_promotion:
        grace += 500    # promotion transform

    grace += 400        # safety buffer for network / FX tail
    return grace


@dataclass
class MoveResult:
    """Result of applying a move (or forcing a terminal event).

    This is the payload broadcast in :data:`~duke_server.protocol.S_MOVE_APPLIED`
    and :data:`~duke_server.protocol.S_GAME_OVER`. When the move ended
    the game, ``game_over`` is true, ``winner`` is one of
    ``"white"`` / ``"black"`` / ``"draw"`` and ``reason`` is the
    ``python-chess`` termination name (e.g. ``"checkmate"``,
    ``"stalemate"``, ``"insufficient_material"``) or one of the
    server-injected reasons ``"resign"`` / ``"time"`` / ``"agreement"``.

    For forced terminals (resign / draw / timeout), ``uci`` carries a
    synthetic tag like ``"(resign)"`` and the square fields are empty
    strings.
    """

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
    # Estimated client-side animation duration after which the next player's
    # clock actually begins ticking on the server.  Clients can use this for
    # display sync; the server enforces it independently.
    clock_starts_in_ms: int = 0


@dataclass
class ChessGame:
    """Authoritative chess game state with a per-side clock.

    Wraps a ``python-chess`` :class:`chess.Board` and adds:

    * a sudden-death clock per side (``time_ms`` total, 0 = unlimited);
    * a started/finished lifecycle (no moves are accepted until
      :meth:`start` is called);
    * helpers to detect natural terminations (checkmate, stalemate,
      threefold, 50-move, insufficient material via
      :meth:`chess.Board.outcome` with ``claim_draw=True``) and forced
      terminations (resign, draw agreement, timeout).

    Thread safety: instances are *not* internally synchronised. The
    server protects each game by holding the owning room's
    :attr:`Room.lock` for the duration of any mutating call.
    """

    time_ms: int = 0          # initial clock per side (0 = unlimited)
    _board: chess.Board = field(default_factory=chess.Board)
    _white_ms: int = 0
    _black_ms: int = 0
    _turn_started_monotonic: float = 0.0
    _last_grace_ms: int = 0
    _started: bool = False
    _game_over: bool = False
    _winner: Optional[str] = None
    _reason: Optional[str] = None

    def __post_init__(self) -> None:
        self._white_ms = self.time_ms
        self._black_ms = self.time_ms

    # ── Lifecycle ──────────────────────────────────────────────────────────
    def start(self) -> None:
        """Mark the game as started and arm White's clock.

        Must be called exactly once, before any :meth:`apply_move` call.
        Sets ``_turn_started_monotonic`` so that the elapsed-time
        calculation in :meth:`remaining_ms` has a defined origin.  A small
        initial grace (1 s) lets the client finish its kickoff intro before
        the white clock starts ticking.
        """
        self._started = True
        self._last_grace_ms = 1000
        self._turn_started_monotonic = time.monotonic() + self._last_grace_ms / 1000.0

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
        """Return ``(white_ms, black_ms)`` accounting for elapsed turn time.

        For the side whose turn it is, the elapsed time since
        ``_turn_started_monotonic`` is subtracted from their stored clock
        so that the value is monotonically decreasing in real time even
        when no move has been pushed yet. Values are clamped at zero.

        If the game has no time limit, or has not started, or is over,
        the raw stored values are returned unchanged.
        """
        if not self._started or self._game_over or not self.has_time_limit:
            return self._white_ms, self._black_ms
        # Clamp at 0 — during the post-move grace period (animation),
        # ``_turn_started_monotonic`` is in the future, so elapsed is negative
        # and must be treated as zero (no deduction yet).
        elapsed_ms = max(0, int((time.monotonic() - self._turn_started_monotonic) * 1000))
        if self._board.turn == chess.WHITE:
            return max(0, self._white_ms - elapsed_ms), self._black_ms
        else:
            return self._white_ms, max(0, self._black_ms - elapsed_ms)

    def check_timeout(self) -> Optional[str]:
        """Detect flag-fall on the side to move.

        Called periodically by the room's clock watcher task. If the
        active side's remaining time has reached zero, the game is
        finished with reason ``"time"`` and the loser's color name is
        returned. Otherwise returns ``None``.
        """
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
        """Validate and apply a UCI move from ``color``.

        Steps:

        1. Reject if the game has not been started or has already ended.
        2. Reject if it is not ``color``'s turn.
        3. Deduct elapsed time from the active clock; if the clock
           reached zero during the deduction, finish the game with
           reason ``"time"`` (the move itself is then discarded).
        4. Parse the UCI string, reject if malformed or illegal.
        5. Push the move, reset the turn timer, and run
           :meth:`_detect_terminal` to capture natural terminations.

        Parameters
        ----------
        color:
            The mover's color as an integer (:data:`WHITE` / :data:`BLACK`).
        uci:
            The move in UCI notation (``"e2e4"``, ``"e7e8q"``…).

        Returns
        -------
        MoveResult
            Snapshot of the position after the move, including the
            updated clocks and any terminal information.

        Raises
        ------
        BadState
            If the game has not started or is already over.
        NotYourTurn
            If it is the other side's move.
        IllegalMove
            If the UCI is malformed or not in ``board.legal_moves``.
        """
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
            elapsed_ms = max(0, int((time.monotonic() - self._turn_started_monotonic) * 1000))
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

        # Estimate the client-side animation duration so the next player's
        # clock doesn't tick while their opponent's move is still animating.
        grace_ms = _estimate_animation_ms(self._board, move)

        self._board.push(move)
        self._last_grace_ms = grace_ms
        self._turn_started_monotonic = time.monotonic() + grace_ms / 1000.0

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
            clock_starts_in_ms=grace_ms if not self._game_over else 0,
        )

    def force_resign(self, color: int) -> MoveResult:
        """Resign on behalf of ``color`` (manual surrender or disconnect).

        The opposite color is declared the winner with reason ``"resign"``.
        Idempotent: calling this after the game is over is a no-op that
        returns the current terminal snapshot.
        """
        loser = COLOR_NAMES[color]
        winner = "black" if loser == "white" else "white"
        self._finish(winner, "resign")
        return self._snapshot_after_terminal("(resign)")

    def force_draw(self, reason: str = "agreement") -> MoveResult:
        """Conclude the game as a draw with a server-supplied ``reason``.

        Used after both players accept a draw offer (``reason='agreement'``)
        or whenever the server needs to terminate without a winner.
        """
        self._finish("draw", reason)
        return self._snapshot_after_terminal("(draw)")

    # ── Internals ──────────────────────────────────────────────────────────
    def _detect_terminal(self) -> None:
        """Inspect ``board.outcome(claim_draw=True)`` and finish if terminal.

        ``claim_draw=True`` enables threefold-repetition and 50-move-rule
        draws to be auto-claimed by the server so that clients do not
        have to send an explicit claim message.
        """
        outcome = self._board.outcome(claim_draw=True)
        if outcome is None:
            return
        if outcome.winner is None:
            self._finish("draw", outcome.termination.name.lower())
        else:
            self._finish("white" if outcome.winner == chess.WHITE else "black",
                         outcome.termination.name.lower())

    def _finish(self, winner: str, reason: str) -> None:
        """Record terminal state idempotently.

        Subsequent calls are ignored so that, e.g., a timeout discovered
        during clock deduction does not get overwritten by a later
        natural-termination check.
        """
        if self._game_over:
            return
        self._game_over = True
        self._winner = winner
        self._reason = reason

    def _snapshot_after_terminal(self, fallback_uci: str) -> MoveResult:
        """Build a :class:`MoveResult` describing the terminal position.

        ``fallback_uci`` is the synthetic ``uci`` field (``"(resign)"``,
        ``"(draw)"``, ``"(time)"``) used when there is no real move to
        report.
        """
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
    """Base class for all game-layer errors."""


class BadState(GameError):
    """Raised when an operation is invoked in the wrong lifecycle state."""


class NotYourTurn(GameError):
    """Raised when a move is submitted by the side that is not to move."""


class IllegalMove(GameError):
    """Raised when a UCI string is malformed or not a legal move."""
