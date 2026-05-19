## AI player controller backed only by native C++ GDExtension AI.

class_name AIController
extends PlayerController

enum Difficulty {
	CASUAL = 1,
	CHALLENGER = 2,
	MASTER = 3,
}

const _NATIVE_CLASS := "DukesAINative"
const _LOG_TIMINGS := true

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
	var selected_difficulty := maxi(Difficulty.CASUAL, mini(Difficulty.MASTER, difficulty))
	var budget := _compute_search_budget(board, legal_moves.size(), selected_difficulty)
	search_depth = int(budget.get("depth", search_depth))
	time_limit_ms = int(budget.get("time_ms", time_limit_ms))

	var position_payload: Dictionary = _build_native_position(board)
	var fallback_payload: Dictionary = _serialize_move(fallback_move)
	var t := Engine.get_main_loop() as SceneTree
	var search_started_ms := Time.get_ticks_msec()

	_search_in_progress = true
	_search_payload = {}

	await _run_native_search(position_payload, search_depth, time_limit_ms, fallback_payload, t)
	_search_in_progress = false
	if _LOG_TIMINGS:
		_print_search_timing(search_started_ms, legal_moves.size(), selected_difficulty, search_depth, time_limit_ms)

	var chosen: ChessMove = _resolve_payload_to_move(legal_moves, fallback_move)
	emit_signal("move_chosen", chosen)

func _print_search_timing(started_ms: int, legal_count: int, selected_difficulty: int, search_depth: int, time_limit_ms: int) -> void:
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	_result_mutex.lock()
	var payload: Dictionary = _search_payload.duplicate()
	_result_mutex.unlock()

	var reached_depth := int(payload.get("reached_depth", -1))
	var score := int(payload.get("score", 0))
	var ok := bool(payload.get("ok", false))
	print(
		"AI timing | diff=%s | legal=%d | depth_req=%d | depth_hit=%d | limit=%dms | elapsed=%dms | ok=%s | score=%d" % [
			_difficulty_name(selected_difficulty),
			legal_count,
			search_depth,
			reached_depth,
			time_limit_ms,
			elapsed_ms,
			str(ok),
			score,
		]
	)

func _difficulty_name(diff: int) -> String:
	match diff:
		Difficulty.CASUAL:
			return "Casual"
		Difficulty.CHALLENGER:
			return "Challenger"
		Difficulty.MASTER:
			return "Master"
		_:
			return "Unknown"

func _compute_search_budget(board: ChessBoardState, legal_count: int, selected_difficulty: int) -> Dictionary:
	var base_depth := 4
	var base_time_ms := 2000
	var min_time_ms := 900
	var max_time_ms := 2600

	match selected_difficulty:
		Difficulty.CASUAL:
			base_depth = 4
			base_time_ms = 500
			min_time_ms = 300
			max_time_ms = 800
		Difficulty.CHALLENGER:
			base_depth = 8
			base_time_ms = 3300
			min_time_ms = 1400
			max_time_ms = 5200
		Difficulty.MASTER:
			base_depth = 64 # unlimited, will be clamped by depth adjustments below
			base_time_ms = 5200
			min_time_ms = 1800
			max_time_ms = 7200

	var multiplier := 1.0

	# Opening positions are usually theory-heavy and less tactical in this project,
	# so we spend less time there and keep more budget for complex middlegames.
	if board.fullmove_number <= 6:
		multiplier *= 0.72
	elif board.fullmove_number <= 10:
		multiplier *= 0.84

	if legal_count >= 34:
		multiplier *= 1.25
	elif legal_count >= 26:
		multiplier *= 1.12
	elif legal_count <= 10:
		multiplier *= 0.84

	if selected_difficulty == Difficulty.MASTER and legal_count >= 28:
		multiplier *= 0.90

	if board.is_in_check(board.active_color):
		multiplier *= 1.18

	if board.halfmove_clock >= 70:
		multiplier *= 0.88

	var phase := clampf(float(board.fullmove_number) / 24.0, 0.0, 1.0)
	var phase_scale := lerpf(0.95, 1.08, phase)
	var computed_time := int(round(float(base_time_ms) * multiplier * phase_scale))
	computed_time = clampi(computed_time, min_time_ms, max_time_ms)

	var depth_adjust := 0
	if legal_count >= 34:
		depth_adjust -= 1
	if selected_difficulty == Difficulty.MASTER and board.fullmove_number <= 10 and legal_count >= 26:
		depth_adjust -= 1
	elif legal_count <= 9 and board.fullmove_number >= 10:
		depth_adjust += 1

	var computed_depth := clampi(base_depth + depth_adjust, 3, base_depth + 1)
	return {
		"depth": computed_depth,
		"time_ms": computed_time,
	}

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
