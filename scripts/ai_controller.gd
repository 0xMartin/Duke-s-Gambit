## ai_controller.gd
## AI player placeholder. Currently picks a random legal move.
## Replace random_move() with a real engine (minimax, etc.) when needed.
## The "strength" setting is wired in but unused until a real engine is added.

class_name AIController
extends PlayerController

## 1 = random, higher = deeper search (not yet implemented)
@export var strength: int = 1

func _init() -> void:
	is_ai = true
	player_name = "AI"

func request_move(board: ChessBoardState, legal_moves: Array) -> void:
	if legal_moves.is_empty():
		return
	# Tiny async delay so the UI can show "AI is thinking..." first
	var t := Engine.get_main_loop() as SceneTree
	if t:
		await t.create_timer(0.6 + randf() * 0.4).timeout
	var chosen: ChessMove = _pick_move(legal_moves)
	emit_signal("move_chosen", chosen)

func _pick_move(legal: Array) -> ChessMove:
	# TODO: replace with real search when AI is implemented
	legal.shuffle()
	return legal[0]
