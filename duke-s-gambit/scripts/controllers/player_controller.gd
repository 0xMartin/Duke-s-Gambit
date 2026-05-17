## player_controller.gd
## Abstract base for a "player" — either a human (HumanController) or AI placeholder.
## GameController calls request_move() and listens for move_chosen signal.

class_name PlayerController
extends RefCounted

@warning_ignore("unused_signal")
signal move_chosen(move: ChessMove)

var color: int = ChessEnums.PieceColor.WHITE
var player_name: String = "Player"
var is_ai: bool = false

## Called by GameController when it is this player's turn.
## Subclass must emit move_chosen when done.
func request_move(_board: ChessBoardState, _legal_moves: Array) -> void:
	pass  # override in subclass
