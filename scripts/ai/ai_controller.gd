## AI player controller backed only by native C++ GDExtension AI.

class_name AIController
extends PlayerController

enum Difficulty {
	CASUAL = 1,
	CHALLENGER = 2,
	MASTER = 3,
	GRANDMASTER = 4,
}

const _NATIVE_CLASS := "DukesAINative"

var difficulty: int = Difficulty.CASUAL
var _native_available: bool = false
var _search_in_progress: bool = false
var _search_payload: Dictionary = {}
var _result_mutex := Mutex.new()


func _init() -> void:
	is_ai = true
	player_name = "AI"
	_native_available = ClassDB.class_exists(_NATIVE_CLASS)

func request_move(board: ChessBoardState, legal_moves: Array) -> void:
	if legal_moves.is_empty() or _search_in_progress:
		return

	var fallback_move: ChessMove = legal_moves[0]
	if not _native_available:
		push_warning("AIController: native AI class '%s' not found. Using fallback move." % _NATIVE_CLASS)
		emit_signal("move_chosen", fallback_move)
		return

	var search_depth := 4
	var time_limit_ms := 2000
	match difficulty:
		Difficulty.CASUAL:
			search_depth = 4
			time_limit_ms = 2000
		Difficulty.CHALLENGER:
			search_depth = 8
			time_limit_ms = 4000
		Difficulty.MASTER:
			search_depth = 12
			time_limit_ms = 8000
		Difficulty.GRANDMASTER:
			search_depth = 15
			time_limit_ms = 12000

	var position_payload: Dictionary = _build_native_position(board)
	var fallback_payload: Dictionary = _serialize_move(fallback_move)
	var t := Engine.get_main_loop() as SceneTree

	_search_in_progress = true
	_search_payload = {}

	await _run_native_search(position_payload, search_depth, time_limit_ms, fallback_payload, t)
	_search_in_progress = false

	var chosen: ChessMove = _resolve_payload_to_move(legal_moves, fallback_move)
	emit_signal("move_chosen", chosen)

func _run_native_search(position_payload: Dictionary, search_depth: int, time_limit_ms: int, fallback_payload: Dictionary, tree: SceneTree) -> void:
	var task_id := WorkerThreadPool.add_task(
		_run_native_search_task.bind(position_payload, search_depth, time_limit_ms, fallback_payload),
		false,
		"Chess Native AI Search"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		if tree:
			await tree.process_frame
		else:
			break
	WorkerThreadPool.wait_for_task_completion(task_id)

func _run_native_search_task(position_payload: Dictionary, search_depth: int, time_limit_ms: int, fallback_payload: Dictionary) -> void:
	var result_payload: Dictionary = {
		"ok": false,
		"fallback": fallback_payload,
	}

	var native_obj: Object = ClassDB.instantiate(_NATIVE_CLASS)
	if native_obj != null and native_obj.has_method("find_best_move"):
		var raw_result: Variant = native_obj.call("find_best_move", position_payload, search_depth, time_limit_ms)
		if raw_result is Dictionary:
			result_payload = raw_result
			if not result_payload.has("fallback"):
				result_payload["fallback"] = fallback_payload

	_result_mutex.lock()
	_search_payload = result_payload
	_result_mutex.unlock()

func _resolve_payload_to_move(legal_moves: Array, fallback_move: ChessMove) -> ChessMove:
	_result_mutex.lock()
	var payload: Dictionary = _search_payload.duplicate()
	_result_mutex.unlock()

	if payload.is_empty():
		return fallback_move

	if bool(payload.get("ok", false)):
		for mv in legal_moves:
			if _move_matches_payload(mv as ChessMove, payload):
				return mv

	var fallback_payload: Dictionary = payload.get("fallback", {})
	for mv in legal_moves:
		if _move_matches_payload(mv as ChessMove, fallback_payload):
			return mv

	return fallback_move

func _move_matches_payload(mv: ChessMove, data: Dictionary) -> bool:
	if mv == null or data.is_empty():
		return false
	if mv.from_sq.x != int(data.get("from_col", -9)):
		return false
	if mv.from_sq.y != int(data.get("from_row", -9)):
		return false
	if mv.to_sq.x != int(data.get("to_col", -9)):
		return false
	if mv.to_sq.y != int(data.get("to_row", -9)):
		return false
	if mv.move_type != int(data.get("move_type", -1)):
		return false
	if mv.piece_type != int(data.get("piece_type", -1)):
		return false
	if mv.piece_color != int(data.get("piece_color", -1)):
		return false
	if mv.move_type == ChessEnums.MoveType.PROMOTION or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		if mv.promotion_type != int(data.get("promotion_type", -1)):
			return false
	return true

func _serialize_move(mv: ChessMove) -> Dictionary:
	return {
		"from_col": mv.from_sq.x,
		"from_row": mv.from_sq.y,
		"to_col": mv.to_sq.x,
		"to_row": mv.to_sq.y,
		"move_type": mv.move_type,
		"piece_type": mv.piece_type,
		"piece_color": mv.piece_color,
		"captured_type": mv.captured_type,
		"promotion_type": mv.promotion_type,
	}

func _build_native_position(board: ChessBoardState) -> Dictionary:
	var packed_board := PackedInt32Array()
	packed_board.resize(64)
	for i in range(64):
		packed_board[i] = 0

	for col in range(8):
		for row in range(8):
			var raw_piece: Variant = board.board[col][row]
			if raw_piece == null:
				continue
			var p: Dictionary = raw_piece
			if p.is_empty():
				continue
			var piece_type: int = int(p.get("type", ChessEnums.PieceType.NONE))
			var piece_color: int = int(p.get("color", ChessEnums.PieceColor.WHITE))
			var code: int = piece_type + (6 if piece_color == ChessEnums.PieceColor.BLACK else 0)
			packed_board[row * 8 + col] = code

	var en_passant_index := -1
	if board.en_passant_sq.x >= 0 and board.en_passant_sq.y >= 0:
		en_passant_index = board.en_passant_sq.y * 8 + board.en_passant_sq.x

	return {
		"board": packed_board,
		"active_color": board.active_color,
		"castling_rights": board.castling_rights,
		"en_passant_index": en_passant_index,
		"halfmove_clock": board.halfmove_clock,
		"fullmove_number": board.fullmove_number,
	}
