## Simple GDScript fallback AI — used when the native DukesAINative extension is unavailable.
## Implements 2-ply negamax with alpha-beta pruning and basic material evaluation.
## Runs synchronously on the main thread; typical think time is well under one second.
class_name SimpleAIFallback

# Centipawn material values
const _VALUES: Dictionary = {
	ChessEnums.PieceType.PAWN:   100,
	ChessEnums.PieceType.KNIGHT: 300,
	ChessEnums.PieceType.BISHOP: 320,
	ChessEnums.PieceType.ROOK:   500,
	ChessEnums.PieceType.QUEEN:  900,
	ChessEnums.PieceType.KING:   20000,
}

# Pawn advancement bonus: row distance from own back rank, per pawn (white row 0, black row 7).
# Encourages pushing pawns toward promotion without large overhead.
const _PAWN_ADVANCE_BONUS := 8   # centipawns per rank advanced

# Search depth (plies). 2 = look at own move + opponent response ≈ 900 nodes worst case.
const _DEPTH := 2

## Return the best ChessMove from legal_moves using a shallow search.
## board.active_color is the side to move.
static func choose_move(board: ChessBoardState, legal_moves: Array) -> ChessMove:
	if legal_moves.is_empty():
		return null
	var best_move: ChessMove = legal_moves[0]
	var best_score := -9999999
	var alpha := -9999999
	for mv: ChessMove in legal_moves:
		_make(board, mv)
		var score := -_negamax(board, _DEPTH - 1, -9999999, -alpha)
		_undo(board, mv)
		if score > best_score:
			best_score = score
			best_move = mv
			if score > alpha:
				alpha = score
	return best_move

# ── Search ─────────────────────────────────────────────────────────────────

static func _negamax(board: ChessBoardState, depth: int, alpha: int, beta: int) -> int:
	if depth == 0:
		return _evaluate(board)
	var moves: Array = board.get_legal_moves(board.active_color)
	if moves.is_empty():
		# No legal moves: checkmate or stalemate
		return -999000 if board.is_in_check(board.active_color) else 0
	for mv: ChessMove in moves:
		_make(board, mv)
		var score := -_negamax(board, depth - 1, -beta, -alpha)
		_undo(board, mv)
		if score >= beta:
			return beta   # beta cutoff
		if score > alpha:
			alpha = score
	return alpha

# ── Evaluation ─────────────────────────────────────────────────────────────

## Material score (+ small positional bonus) from the perspective of board.active_color.
static func _evaluate(board: ChessBoardState) -> int:
	var score := 0
	var color := board.active_color
	for col in range(8):
		for row in range(8):
			var p: Variant = board.board[col][row]
			if p == null:
				continue
			var pd: Dictionary = p as Dictionary
			var ptype: int = pd.get("type", -1)
			var pcolor: int = pd.get("color", -1)
			var val: int = _VALUES.get(ptype, 0)
			# Pawn advancement bonus
			if ptype == ChessEnums.PieceType.PAWN:
				var advance := row if pcolor == ChessEnums.PieceColor.WHITE else (7 - row)
				val += advance * _PAWN_ADVANCE_BONUS
			if pcolor == color:
				score += val
			else:
				score -= val
	return score

# ── Make / Undo for search (bypasses move_history to keep board state clean) ──

static func _make(board: ChessBoardState, mv: ChessMove) -> void:
	mv.prev_en_passant_sq   = board.en_passant_sq
	mv.prev_castling_rights = board.castling_rights
	mv.prev_halfmove_clock  = board.halfmove_clock
	board._apply_move_internal(mv)
	board.active_color = 1 - board.active_color

static func _undo(board: ChessBoardState, mv: ChessMove) -> void:
	board._undo_move_internal(mv)
	board.active_color = 1 - board.active_color
