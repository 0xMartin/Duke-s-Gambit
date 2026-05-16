## ai_engine.gd
## Chess AI engine using bitboard search state.
## Minimax + alpha-beta, iterative deepening, piece-square evaluation.

class_name ChessAIEngine

const TT_EXACT := 0
const TT_LOWER := 1
const TT_UPPER := 2

const PIECE_VALUES := {
	ChessEnums.PieceType.PAWN:   100,
	ChessEnums.PieceType.KNIGHT: 320,
	ChessEnums.PieceType.BISHOP: 330,
	ChessEnums.PieceType.ROOK:   500,
	ChessEnums.PieceType.QUEEN:  900,
	ChessEnums.PieceType.KING:   40000,
}

const PAWN_SQUARE_TABLE := [
	[  0,   0,   0,   0,   0,   0,   0,   0],
	[ 50,  50,  50,  50,  50,  50,  50,  50],
	[ 10,  10,  20,  30,  30,  20,  10,  10],
	[  5,   5,  10,  25,  25,  10,   5,   5],
	[  0,   0,   0,  20,  20,   0,   0,   0],
	[  5,  -5, -10,   0,   0, -10,  -5,   5],
	[  5,  10,  10, -20, -20,  10,  10,   5],
	[  0,   0,   0,   0,   0,   0,   0,   0],
]

const KNIGHT_SQUARE_TABLE := [
	[-50, -40, -30, -30, -30, -30, -40, -50],
	[-40, -20,   0,   0,   0,   0, -20, -40],
	[-30,   0,  10,  15,  15,  10,   0, -30],
	[-30,   5,  15,  20,  20,  15,   5, -30],
	[-30,   0,  15,  20,  20,  15,   0, -30],
	[-30,   5,  10,  15,  15,  10,   5, -30],
	[-40, -20,   0,   5,   5,   0, -20, -40],
	[-50, -40, -30, -30, -30, -30, -40, -50],
]

const BISHOP_SQUARE_TABLE := [
	[-20, -10, -10, -10, -10, -10, -10, -20],
	[-10,   0,   0,   0,   0,   0,   0, -10],
	[-10,   0,   5,  10,  10,   5,   0, -10],
	[-10,   5,   5,  10,  10,   5,   5, -10],
	[-10,   0,  10,  10,  10,  10,   0, -10],
	[-10,  10,  10,  10,  10,  10,  10, -10],
	[-10,   5,   0,   0,   0,   0,   5, -10],
	[-20, -10, -10, -10, -10, -10, -10, -20],
]

const ROOK_SQUARE_TABLE := [
	[  0,   0,   0,   0,   0,   0,   0,   0],
	[  5,  10,  10,  10,  10,  10,  10,   5],
	[ -5,   0,   0,   0,   0,   0,   0,  -5],
	[ -5,   0,   0,   0,   0,   0,   0,  -5],
	[ -5,   0,   0,   0,   0,   0,   0,  -5],
	[ -5,   0,   0,   0,   0,   0,   0,  -5],
	[ -5,   0,   0,   0,   0,   0,   0,  -5],
	[  0,   0,   0,   5,   5,   0,   0,   0],
]

const QUEEN_SQUARE_TABLE := [
	[-20, -10, -10,  -5,  -5, -10, -10, -20],
	[-10,   0,   0,   0,   0,   0,   0, -10],
	[-10,   0,   5,   5,   5,   5,   0, -10],
	[ -5,   0,   5,   5,   5,   5,   0,  -5],
	[  0,   0,   5,   5,   5,   5,   0,  -5],
	[-10,   5,   5,   5,   5,   5,   0, -10],
	[-10,   0,   5,   0,   0,   0,   0, -10],
	[-20, -10, -10,  -5,  -5, -10, -10, -20],
]

const KING_EARLY_GAME := [
	[-30, -40, -40, -50, -50, -40, -40, -30],
	[-30, -40, -40, -50, -50, -40, -40, -30],
	[-30, -40, -40, -50, -50, -40, -40, -30],
	[-30, -40, -40, -50, -50, -40, -40, -30],
	[-20, -30, -30, -40, -40, -30, -30, -20],
	[-10, -20, -20, -20, -20, -20, -20, -10],
	[ 20,  20,   0,   0,   0,   0,  20,  20],
	[ 20,  30,  10,   0,   0,  10,  30,  20],
]

const KING_END_GAME := [
	[-50, -40, -30, -20, -20, -30, -40, -50],
	[-30, -20, -10,   0,   0, -10, -20, -30],
	[-30, -10,  20,  30,  30,  20, -10, -30],
	[-30, -10,  30,  40,  40,  30, -10, -30],
	[-30, -10,  30,  40,  40,  30, -10, -30],
	[-30, -10,  20,  30,  30,  20, -10, -30],
	[-30, -30,   0,   0,   0,   0, -30, -30],
	[-50, -30, -30, -30, -30, -30, -30, -50],
]

var _killer_moves := {}
var _transposition_table := {}

func find_best_move(board: ChessBoardState, legal_moves: Array, depth: int, time_limit_ms: int = 5000) -> ChessMove:
	var state := AIBitboardState.from_chess_board(board)
	return find_best_move_in_state(state, legal_moves, depth, time_limit_ms)

func find_best_move_in_state(state: AIBitboardState, legal_moves: Array, depth: int, time_limit_ms: int = 5000) -> ChessMove:
	var deadline_ms := Time.get_ticks_msec() + time_limit_ms
	var result := search_root_subset(state, legal_moves, depth, deadline_ms)
	return result.get("move") as ChessMove

func search_root_subset(state: AIBitboardState, root_moves: Array, depth: int, deadline_ms: int) -> Dictionary:
	if root_moves.is_empty():
		return {"move": null, "score": -100000, "reached_depth": 0}

	_killer_moves.clear()
	_transposition_table.clear()
	var best_move: ChessMove = root_moves[0]
	var best_score: int = -100000
	var reached_depth: int = 0

	for current_depth in range(1, depth + 1):
		if Time.get_ticks_msec() >= deadline_ms:
			break

		var alpha := -100000
		var beta := 100000
		var depth_best_score := -100000
		var depth_best_move := best_move
		var timed_out := false

		_order_moves(root_moves)

		for mv in root_moves:
			if Time.get_ticks_msec() >= deadline_ms:
				timed_out = true
				break

			state.make_move(mv)
			var mv_score := -_minimax(state, current_depth - 1, -beta, -alpha, deadline_ms)
			state.unmake_move()

			if mv_score > depth_best_score:
				depth_best_score = mv_score
				depth_best_move = mv

			alpha = maxi(alpha, mv_score)
			if alpha >= beta:
				break

		if timed_out:
			break

		best_move = depth_best_move
		best_score = depth_best_score
		reached_depth = current_depth

	return {
		"move": best_move,
		"score": best_score,
		"reached_depth": reached_depth,
	}

func _minimax(state: AIBitboardState, depth: int, alpha: int, beta: int, deadline_ms: int) -> int:
	if Time.get_ticks_msec() >= deadline_ms:
		var t_eval := _evaluate_position(state)
		return t_eval if state.active_color == ChessEnums.PieceColor.WHITE else -t_eval

	if depth == 0:
		var eval := _evaluate_position(state)
		return eval if state.active_color == ChessEnums.PieceColor.WHITE else -eval

	var alpha_orig := alpha
	var hash_key := state.hash_key()
	var tt_entry: Dictionary = _transposition_table.get(hash_key, {})
	if not tt_entry.is_empty() and int(tt_entry.get("depth", -1)) >= depth:
		var tt_score: int = int(tt_entry.get("score", 0))
		var tt_flag: int = int(tt_entry.get("flag", TT_EXACT))
		match tt_flag:
			TT_EXACT:
				return tt_score
			TT_LOWER:
				alpha = maxi(alpha, tt_score)
			TT_UPPER:
				beta = mini(beta, tt_score)
		if alpha >= beta:
			return tt_score

	var legal_moves := state.generate_legal_moves()
	if legal_moves.is_empty():
		if state.is_in_check(state.active_color):
			return -30000
		return 0

	var best_score := alpha
	_order_moves(legal_moves)

	for mv in legal_moves:
		state.make_move(mv)
		var score := -_minimax(state, depth - 1, -beta, -best_score, deadline_ms)
		state.unmake_move()

		best_score = maxi(best_score, score)
		if best_score >= beta:
			if not mv.is_capture():
				_killer_moves[depth] = mv
			break

	var tt_flag_to_store := TT_EXACT
	if best_score <= alpha_orig:
		tt_flag_to_store = TT_UPPER
	elif best_score >= beta:
		tt_flag_to_store = TT_LOWER
	_transposition_table[hash_key] = {
		"depth": depth,
		"score": best_score,
		"flag": tt_flag_to_store,
	}

	return best_score

func _order_moves(moves: Array) -> void:
	moves.sort_custom(func(a: ChessMove, b: ChessMove) -> bool:
		if a.is_capture() and not b.is_capture():
			return true
		if b.is_capture() and not a.is_capture():
			return false
		if a.is_capture() and b.is_capture():
			var a_victim: int = int(PIECE_VALUES.get(a.captured_type, 0))
			var b_victim: int = int(PIECE_VALUES.get(b.captured_type, 0))
			return a_victim > b_victim
		return false
	)

func _evaluate_position(state: AIBitboardState) -> int:
	var score := 0

	for idx in range(64):
		var code: int = state.board[idx]
		if code == 0:
			continue
		var piece_type: int = _piece_type_from_code(code)
		var color: int = _piece_color_from_code(code)
		var col: int = AIBitboardState.index_to_col(idx)
		var row: int = AIBitboardState.index_to_row(idx)
		var piece_value: int = int(PIECE_VALUES.get(piece_type, 0))
		var pos_bonus: int = _get_square_value(piece_type, col, row, state)
		var piece_score: int = piece_value + pos_bonus
		if color == ChessEnums.PieceColor.WHITE:
			score += piece_score
		else:
			score -= piece_score

	var white_mob := state.count_pseudo_moves(ChessEnums.PieceColor.WHITE)
	var black_mob := state.count_pseudo_moves(ChessEnums.PieceColor.BLACK)
	score += (white_mob - black_mob) * 2

	return score

func _get_square_value(piece_type: int, col: int, row: int, state: AIBitboardState) -> int:
	match piece_type:
		ChessEnums.PieceType.PAWN:
			return PAWN_SQUARE_TABLE[col][row]
		ChessEnums.PieceType.KNIGHT:
			return KNIGHT_SQUARE_TABLE[col][row]
		ChessEnums.PieceType.BISHOP:
			return BISHOP_SQUARE_TABLE[col][row]
		ChessEnums.PieceType.ROOK:
			return ROOK_SQUARE_TABLE[col][row]
		ChessEnums.PieceType.QUEEN:
			return QUEEN_SQUARE_TABLE[col][row]
		ChessEnums.PieceType.KING:
			var material_count := _count_material(state)
			if material_count < 1000:
				return KING_END_GAME[col][row]
			return KING_EARLY_GAME[col][row]
		_:
			return 0

func _count_material(state: AIBitboardState) -> int:
	var total := 0
	for idx in range(64):
		var code: int = state.board[idx]
		if code == 0:
			continue
		var t: int = _piece_type_from_code(code)
		if t != ChessEnums.PieceType.KING:
			total += int(PIECE_VALUES.get(t, 0))
	return total

func _piece_type_from_code(code: int) -> int:
	return ((code - 1) % 6) + 1

func _piece_color_from_code(code: int) -> int:
	return ChessEnums.PieceColor.WHITE if code <= 6 else ChessEnums.PieceColor.BLACK
