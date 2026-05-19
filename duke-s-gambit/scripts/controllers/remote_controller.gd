## remote_controller.gd
## Passive player controller for the opponent in online mode. It never emits
## move_chosen on its own — moves arrive through OnlineClient and are applied
## directly by GameController.

class_name RemoteController
extends PlayerController

func _init() -> void:
	is_ai = true   # local input router treats it as "not human"

func request_move(_board: ChessBoardState, _legal_moves: Array) -> void:
	pass
