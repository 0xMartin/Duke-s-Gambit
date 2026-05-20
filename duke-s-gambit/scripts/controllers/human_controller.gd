## human_controller.gd
## Human player: waits for the GameController to pipe click events through
## select_piece() and try_move(), then emits move_chosen.

class_name HumanController
extends PlayerController

var _pending_legal: Array = []
var _board_ref: ChessBoardState = null

func _init() -> void:
	is_ai = false

func request_move(board: ChessBoardState, legal_moves: Array) -> void:
	_board_ref    = board
	_pending_legal = legal_moves
	# GameController will now route clicks to select_piece() / try_move()

## Called by GameController when player clicks a destination square
func try_move(move: ChessMove) -> void:
	emit_signal("move_chosen", move)
	_pending_legal = []
	_board_ref = null

func get_legal_moves_from(sq: Vector2i) -> Array:
	var result: Array = []
	for mv in _pending_legal:
		if mv.from_sq == sq:
			result.append(mv)
	return result
