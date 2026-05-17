## chess_board_state.gd
## Pure chess logic: board state, move generation (incl. castling, en passant,
## promotion), make/undo move, check/checkmate/stalemate detection.
## No Godot scene/visual code — fully testable standalone.

class_name ChessBoardState

# Board: board[col][row], col=0..7 (a..h), row=0..7 (1..8 from white's side)
# Each cell: { type: PieceType, color: PieceColor } or null
var board: Array = []

var active_color: int = ChessEnums.PieceColor.WHITE

# Castling rights bitmask: bit0=W-K, bit1=W-Q, bit2=B-K, bit3=B-Q
var castling_rights: int = 0b1111

# En passant target square (-1,-1 if none)
var en_passant_sq: Vector2i = Vector2i(-1, -1)

var halfmove_clock: int = 0   # for 50-move rule
var fullmove_number: int = 1

var move_history: Array = []   # Array[ChessMove]

# default starting position (can be overridden for custom setups)
# lowercase = white, uppercase = black, . = empty
# p,P = pawn, r,R = rook, n,N = knight, b,B = bishop, q,Q = queen, k,K = king
# default placement:
# 	"RNBQKBNR",
#	"PPPPPPPP",
#	"........",
#	"........",
#	"........",
#	"........",
#	"pppppppp",
#	"rnbqkbnr",
const DEFAULT_START_LAYOUT: Array[String] = [
	"RNBQKBNR",
	"PPPPPPPP",
	"........",
	"........",
	"........",
	"........",
	"pppppppp",
	"rnbqkbnr",
]

# ── Signals (connected by GameController) ──────────────────────────────────
@warning_ignore("unused_signal")
signal pawn_promotion_required(sq: Vector2i, color: int)

# ──────────────────────────────────────────────────────────────────────────
func _init() -> void:
	_init_board()
	setup_start_position()

func _init_board() -> void:
	board = []
	for c in range(8):
		var col: Array = []
		for r in range(8):
			col.append(null)
		board.append(col)

# ── Setup ──────────────────────────────────────────────────────────────────
func setup_start_position(layout: Array[String] = DEFAULT_START_LAYOUT) -> void:
	_init_board()
	active_color = ChessEnums.PieceColor.WHITE
	castling_rights = 0
	en_passant_sq = Vector2i(-1, -1)
	halfmove_clock = 0
	fullmove_number = 1
	move_history.clear()

	for row in range(8):
		if row >= layout.size():
			continue
		var line: String = layout[7 - row]
		for col in range(min(line.length(), 8)):
			var ch: String = line.substr(7 - col, 1)
			match ch:
				"P": _place(col, row, ChessEnums.PieceType.PAWN,   ChessEnums.PieceColor.BLACK)
				"R": _place(col, row, ChessEnums.PieceType.ROOK,   ChessEnums.PieceColor.BLACK)
				"N": _place(col, row, ChessEnums.PieceType.KNIGHT, ChessEnums.PieceColor.BLACK)
				"B": _place(col, row, ChessEnums.PieceType.BISHOP, ChessEnums.PieceColor.BLACK)
				"Q": _place(col, row, ChessEnums.PieceType.QUEEN,  ChessEnums.PieceColor.BLACK)
				"K": _place(col, row, ChessEnums.PieceType.KING,   ChessEnums.PieceColor.BLACK)
				"p": _place(col, row, ChessEnums.PieceType.PAWN,   ChessEnums.PieceColor.WHITE)
				"r": _place(col, row, ChessEnums.PieceType.ROOK,   ChessEnums.PieceColor.WHITE)
				"n": _place(col, row, ChessEnums.PieceType.KNIGHT, ChessEnums.PieceColor.WHITE)
				"b": _place(col, row, ChessEnums.PieceType.BISHOP, ChessEnums.PieceColor.WHITE)
				"q": _place(col, row, ChessEnums.PieceType.QUEEN,  ChessEnums.PieceColor.WHITE)
				"k": _place(col, row, ChessEnums.PieceType.KING,   ChessEnums.PieceColor.WHITE)
				_: pass

	castling_rights = _compute_initial_castling_rights()

func _place(col: int, row: int, type: int, color: int) -> void:
	board[col][row] = { "type": type, "color": color }

# ── Accessors ─────────────────────────────────────────────────────────────
func get_piece(sq: Vector2i) -> Dictionary:
	if not _in_bounds(sq):
		return {}
	return board[sq.x][sq.y] if board[sq.x][sq.y] != null else {}

func is_empty(sq: Vector2i) -> bool:
	return _in_bounds(sq) and board[sq.x][sq.y] == null

func is_enemy(sq: Vector2i, color: int) -> bool:
	if not _in_bounds(sq) or board[sq.x][sq.y] == null:
		return false
	return board[sq.x][sq.y]["color"] != color

func is_friend(sq: Vector2i, color: int) -> bool:
	if not _in_bounds(sq) or board[sq.x][sq.y] == null:
		return false
	return board[sq.x][sq.y]["color"] == color

func _in_bounds(sq: Vector2i) -> bool:
	return sq.x >= 0 and sq.x < 8 and sq.y >= 0 and sq.y < 8

# ── Move Generation ────────────────────────────────────────────────────────
## Returns all legal moves for the active color (filters out moves leaving king in check)
func get_legal_moves(color: int) -> Array:
	var pseudo := _get_pseudo_legal_moves(color)
	var legal: Array = []
	for mv in pseudo:
		if not _move_leaves_king_in_check(mv, color):
			legal.append(mv)
	return legal

## Legal moves for a single square
func get_legal_moves_from(sq: Vector2i) -> Array:
	var piece: Dictionary = get_piece(sq)
	if piece.is_empty():
		return []
	var all: Array = get_legal_moves(piece["color"])
	var result: Array = []
	for mv in all:
		if mv.from_sq == sq:
			result.append(mv)
	return result

func _get_pseudo_legal_moves(color: int) -> Array:
	var moves: Array = []
	for c in range(8):
		for r in range(8):
			var sq := Vector2i(c, r)
			if is_empty(sq):
				continue
			var p: Dictionary = board[c][r]
			if p["color"] != color:
				continue
			match p["type"]:
				ChessEnums.PieceType.PAWN:
					moves.append_array(_pawn_moves(sq, color))
				ChessEnums.PieceType.ROOK:
					moves.append_array(_slider_moves(sq, color, [[1,0],[-1,0],[0,1],[0,-1]]))
				ChessEnums.PieceType.BISHOP:
					moves.append_array(_slider_moves(sq, color, [[1,1],[1,-1],[-1,1],[-1,-1]]))
				ChessEnums.PieceType.QUEEN:
					moves.append_array(_slider_moves(sq, color, [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]]))
				ChessEnums.PieceType.KNIGHT:
					moves.append_array(_knight_moves(sq, color))
				ChessEnums.PieceType.KING:
					moves.append_array(_king_moves(sq, color))
	return moves

func _pawn_moves(sq: Vector2i, color: int) -> Array:
	var moves: Array = []
	var dir: int = 1 if color == ChessEnums.PieceColor.WHITE else -1
	var start_row: int = 1 if color == ChessEnums.PieceColor.WHITE else 6
	var promo_row: int = 7 if color == ChessEnums.PieceColor.WHITE else 0

	# Single push
	var fwd: Vector2i = sq + Vector2i(0, dir)
	if _in_bounds(fwd) and is_empty(fwd):
		if fwd.y == promo_row:
			for pt: int in [ChessEnums.PieceType.QUEEN, ChessEnums.PieceType.ROOK,
						ChessEnums.PieceType.BISHOP, ChessEnums.PieceType.KNIGHT]:
				moves.append(ChessMove.new(sq, fwd, ChessEnums.MoveType.PROMOTION, ChessEnums.PieceType.PAWN, color, ChessEnums.PieceType.NONE, pt))
		else:
			moves.append(ChessMove.new(sq, fwd, ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.PAWN, color))
		# Double push from start
		if sq.y == start_row:
			var fwd2: Vector2i = sq + Vector2i(0, dir * 2)
			if is_empty(fwd2):
				moves.append(ChessMove.new(sq, fwd2, ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.PAWN, color))

	# Captures
	for dc: int in [-1, 1]:
		var cap_sq: Vector2i = sq + Vector2i(dc, dir)
		if not _in_bounds(cap_sq):
			continue
		if is_enemy(cap_sq, color):
			var cap_type: int = board[cap_sq.x][cap_sq.y]["type"]
			if cap_sq.y == promo_row:
				for pt: int in [ChessEnums.PieceType.QUEEN, ChessEnums.PieceType.ROOK,
							ChessEnums.PieceType.BISHOP, ChessEnums.PieceType.KNIGHT]:
					moves.append(ChessMove.new(sq, cap_sq, ChessEnums.MoveType.PROMOTION_CAPTURE, ChessEnums.PieceType.PAWN, color, cap_type, pt))
			else:
				moves.append(ChessMove.new(sq, cap_sq, ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.PAWN, color, cap_type))
		# En passant
		elif cap_sq == en_passant_sq:
			moves.append(ChessMove.new(sq, cap_sq, ChessEnums.MoveType.EN_PASSANT, ChessEnums.PieceType.PAWN, color, ChessEnums.PieceType.PAWN))

	return moves

func _slider_moves(sq: Vector2i, color: int, dirs: Array) -> Array:
	var moves: Array = []
	for d: Array in dirs:
		var cur: Vector2i = sq + Vector2i(int(d[0]), int(d[1]))
		while _in_bounds(cur):
			if is_empty(cur):
				moves.append(ChessMove.new(sq, cur, ChessEnums.MoveType.NORMAL,
					board[sq.x][sq.y]["type"], color))
			elif is_enemy(cur, color):
				moves.append(ChessMove.new(sq, cur, ChessEnums.MoveType.CAPTURE,
					board[sq.x][sq.y]["type"], color, board[cur.x][cur.y]["type"]))
				break
			else:
				break
			cur += Vector2i(int(d[0]), int(d[1]))
	return moves

func _knight_moves(sq: Vector2i, color: int) -> Array:
	var moves: Array = []
	for offset: Vector2i in [Vector2i(2,1),Vector2i(2,-1),Vector2i(-2,1),Vector2i(-2,-1),
					Vector2i(1,2),Vector2i(1,-2),Vector2i(-1,2),Vector2i(-1,-2)]:
		var t: Vector2i = sq + offset
		if not _in_bounds(t):
			continue
		if is_empty(t):
			moves.append(ChessMove.new(sq, t, ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.KNIGHT, color))
		elif is_enemy(t, color):
			moves.append(ChessMove.new(sq, t, ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.KNIGHT, color, board[t.x][t.y]["type"]))
	return moves

func _king_moves(sq: Vector2i, color: int) -> Array:
	var moves: Array = []
	for offset: Vector2i in [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1),
					Vector2i(1,1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(-1,-1)]:
		var t: Vector2i = sq + offset
		if not _in_bounds(t):
			continue
		if is_empty(t):
			moves.append(ChessMove.new(sq, t, ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.KING, color))
		elif is_enemy(t, color):
			moves.append(ChessMove.new(sq, t, ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.KING, color, board[t.x][t.y]["type"]))

	# Castling
	var row: int = 0 if color == ChessEnums.PieceColor.WHITE else 7
	var ks_bit: int = 0 if color == ChessEnums.PieceColor.WHITE else 2  # kingside bit
	var qs_bit: int = 1 if color == ChessEnums.PieceColor.WHITE else 3  # queenside bit

	if ((castling_rights >> ks_bit) & 1) and _can_castle_kingside(color, sq):
		moves.append(ChessMove.new(sq, Vector2i(1, row), ChessEnums.MoveType.CASTLING_KINGSIDE, ChessEnums.PieceType.KING, color))

	if ((castling_rights >> qs_bit) & 1) and _can_castle_queenside(color, sq):
		moves.append(ChessMove.new(sq, Vector2i(5, row), ChessEnums.MoveType.CASTLING_QUEENSIDE, ChessEnums.PieceType.KING, color))

	return moves

func _can_castle_kingside(color: int, king_sq: Vector2i) -> bool:
	var row: int = 0 if color == ChessEnums.PieceColor.WHITE else 7
	if king_sq != Vector2i(3, row):
		return false
	var king_piece := get_piece(king_sq)
	if king_piece.is_empty() or king_piece["type"] != ChessEnums.PieceType.KING or king_piece["color"] != color:
		return false
	var rook_sq := Vector2i(0, row)
	var rook_piece := get_piece(rook_sq)
	if rook_piece.is_empty() or rook_piece["type"] != ChessEnums.PieceType.ROOK or rook_piece["color"] != color:
		return false
	if not is_empty(Vector2i(2, row)) or not is_empty(Vector2i(1, row)):
		return false
	if _square_attacked(king_sq, color):
		return false
	if _square_attacked(Vector2i(2, row), color) or _square_attacked(Vector2i(1, row), color):
		return false
	return true

func _can_castle_queenside(color: int, king_sq: Vector2i) -> bool:
	var row: int = 0 if color == ChessEnums.PieceColor.WHITE else 7
	if king_sq != Vector2i(3, row):
		return false
	var king_piece := get_piece(king_sq)
	if king_piece.is_empty() or king_piece["type"] != ChessEnums.PieceType.KING or king_piece["color"] != color:
		return false
	var rook_sq := Vector2i(7, row)
	var rook_piece := get_piece(rook_sq)
	if rook_piece.is_empty() or rook_piece["type"] != ChessEnums.PieceType.ROOK or rook_piece["color"] != color:
		return false
	if not is_empty(Vector2i(4, row)) or not is_empty(Vector2i(5, row)) or not is_empty(Vector2i(6, row)):
		return false
	if _square_attacked(king_sq, color):
		return false
	if _square_attacked(Vector2i(4, row), color) or _square_attacked(Vector2i(5, row), color):
		return false
	return true

func _compute_initial_castling_rights() -> int:
	var rights := 0
	var white_king := get_piece(Vector2i(3, 0))
	if not white_king.is_empty() and white_king["type"] == ChessEnums.PieceType.KING and white_king["color"] == ChessEnums.PieceColor.WHITE:
		var white_rook_h := get_piece(Vector2i(0, 0))
		if not white_rook_h.is_empty() and white_rook_h["type"] == ChessEnums.PieceType.ROOK and white_rook_h["color"] == ChessEnums.PieceColor.WHITE:
			rights |= 0b0001
		var white_rook_a := get_piece(Vector2i(7, 0))
		if not white_rook_a.is_empty() and white_rook_a["type"] == ChessEnums.PieceType.ROOK and white_rook_a["color"] == ChessEnums.PieceColor.WHITE:
			rights |= 0b0010
	var black_king := get_piece(Vector2i(3, 7))
	if not black_king.is_empty() and black_king["type"] == ChessEnums.PieceType.KING and black_king["color"] == ChessEnums.PieceColor.BLACK:
		var black_rook_h := get_piece(Vector2i(0, 7))
		if not black_rook_h.is_empty() and black_rook_h["type"] == ChessEnums.PieceType.ROOK and black_rook_h["color"] == ChessEnums.PieceColor.BLACK:
			rights |= 0b0100
		var black_rook_a := get_piece(Vector2i(7, 7))
		if not black_rook_a.is_empty() and black_rook_a["type"] == ChessEnums.PieceType.ROOK and black_rook_a["color"] == ChessEnums.PieceColor.BLACK:
			rights |= 0b1000
	return rights

# ── Check Detection ────────────────────────────────────────────────────────
func _square_attacked(sq: Vector2i, defender_color: int) -> bool:
	var attacker := 1 - defender_color
	# Rook / Queen (straight lines)
	for d: Array in [[1,0],[-1,0],[0,1],[0,-1]]:
		var cur: Vector2i = sq + Vector2i(int(d[0]), int(d[1]))
		while _in_bounds(cur):
			if not is_empty(cur):
				if board[cur.x][cur.y]["color"] == attacker:
					var t: int = board[cur.x][cur.y]["type"]
					if t == ChessEnums.PieceType.ROOK or t == ChessEnums.PieceType.QUEEN:
						return true
				break
			cur += Vector2i(int(d[0]), int(d[1]))
	# Bishop / Queen (diagonals)
	for d: Array in [[1,1],[1,-1],[-1,1],[-1,-1]]:
		var cur: Vector2i = sq + Vector2i(int(d[0]), int(d[1]))
		while _in_bounds(cur):
			if not is_empty(cur):
				if board[cur.x][cur.y]["color"] == attacker:
					var t: int = board[cur.x][cur.y]["type"]
					if t == ChessEnums.PieceType.BISHOP or t == ChessEnums.PieceType.QUEEN:
						return true
				break
			cur += Vector2i(int(d[0]), int(d[1]))
	# Knight
	for offset: Vector2i in [Vector2i(2,1),Vector2i(2,-1),Vector2i(-2,1),Vector2i(-2,-1),
					Vector2i(1,2),Vector2i(1,-2),Vector2i(-1,2),Vector2i(-1,-2)]:
		var t: Vector2i = sq + offset
		if _in_bounds(t) and not is_empty(t) \
		and board[t.x][t.y]["color"] == attacker \
		and board[t.x][t.y]["type"] == ChessEnums.PieceType.KNIGHT:
			return true
	# Pawn — attacker pawn is one row BEHIND the attacked square
	# (black attacks from above → pawn_dir=+1; white attacks from below → pawn_dir=-1)
	var pawn_dir: int = 1 if defender_color == ChessEnums.PieceColor.WHITE else -1
	for dc: int in [-1, 1]:
		var t: Vector2i = sq + Vector2i(dc, pawn_dir)
		if _in_bounds(t) and not is_empty(t) \
		and board[t.x][t.y]["color"] == attacker \
		and board[t.x][t.y]["type"] == ChessEnums.PieceType.PAWN:
			return true
	# King
	for offset: Vector2i in [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1),
					Vector2i(1,1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(-1,-1)]:
		var t: Vector2i = sq + offset
		if _in_bounds(t) and not is_empty(t) \
		and board[t.x][t.y]["color"] == attacker \
		and board[t.x][t.y]["type"] == ChessEnums.PieceType.KING:
			return true
	return false

func _find_king(color: int) -> Vector2i:
	for c in range(8):
		for r in range(8):
			if board[c][r] != null \
			and board[c][r]["type"] == ChessEnums.PieceType.KING \
			and board[c][r]["color"] == color:
				return Vector2i(c, r)
	return Vector2i(-1, -1)

func is_in_check(color: int) -> bool:
	var king_sq := _find_king(color)
	if king_sq.x == -1:
		return false
	return _square_attacked(king_sq, color)

func _move_leaves_king_in_check(mv: ChessMove, color: int) -> bool:
	# Must save state here — _apply_move_internal does NOT save it into mv.prev_*
	mv.prev_en_passant_sq   = en_passant_sq
	mv.prev_castling_rights = castling_rights
	mv.prev_halfmove_clock  = halfmove_clock
	_apply_move_internal(mv)
	var in_check := is_in_check(color)
	_undo_move_internal(mv)
	return in_check

# ── Make / Undo Move ───────────────────────────────────────────────────────
## Public: execute a legal move and switch active color. Returns the move.
func make_move(mv: ChessMove) -> ChessMove:
	mv.prev_en_passant_sq = en_passant_sq
	mv.prev_castling_rights = castling_rights
	mv.prev_halfmove_clock = halfmove_clock
	_apply_move_internal(mv)
	move_history.append(mv)
	if active_color == ChessEnums.PieceColor.BLACK:
		fullmove_number += 1
	active_color = 1 - active_color
	return mv

func _apply_move_internal(mv: ChessMove) -> void:
	var piece: Variant = board[mv.from_sq.x][mv.from_sq.y]

	# Update en passant
	en_passant_sq = Vector2i(-1, -1)
	if mv.piece_type == ChessEnums.PieceType.PAWN \
	and abs(mv.to_sq.y - mv.from_sq.y) == 2:
		en_passant_sq = Vector2i(mv.from_sq.x, int((mv.from_sq.y + mv.to_sq.y) / 2.0))

	# Remove captured piece (en passant special case)
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		var cap_row := mv.from_sq.y
		board[mv.to_sq.x][cap_row] = null

	# Halfmove clock
	if mv.piece_type == ChessEnums.PieceType.PAWN or mv.is_capture():
		halfmove_clock = 0
	else:
		halfmove_clock += 1

	# Update castling rights
	_update_castling_rights(mv)

	# Move piece
	board[mv.to_sq.x][mv.to_sq.y] = piece
	board[mv.from_sq.x][mv.from_sq.y] = null

	# Promotion
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
	or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		board[mv.to_sq.x][mv.to_sq.y] = { "type": mv.promotion_type, "color": mv.piece_color }

	# Castling — move rook
	if mv.move_type == ChessEnums.MoveType.CASTLING_KINGSIDE:
		var row := mv.from_sq.y
		board[2][row] = board[0][row]
		board[0][row] = null
	elif mv.move_type == ChessEnums.MoveType.CASTLING_QUEENSIDE:
		var row := mv.from_sq.y
		board[4][row] = board[7][row]
		board[7][row] = null

func _undo_move_internal(mv: ChessMove) -> void:
	var piece: Variant = board[mv.to_sq.x][mv.to_sq.y]

	# Undo promotion
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
	or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		piece = { "type": ChessEnums.PieceType.PAWN, "color": mv.piece_color }

	# Move piece back
	board[mv.from_sq.x][mv.from_sq.y] = piece
	board[mv.to_sq.x][mv.to_sq.y] = null

	# Restore captured piece
	if mv.move_type == ChessEnums.MoveType.CAPTURE \
	or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		board[mv.to_sq.x][mv.to_sq.y] = { "type": mv.captured_type, "color": 1 - mv.piece_color }
	elif mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		var cap_row := mv.from_sq.y
		board[mv.to_sq.x][cap_row] = { "type": ChessEnums.PieceType.PAWN, "color": 1 - mv.piece_color }

	# Undo castling rook
	if mv.move_type == ChessEnums.MoveType.CASTLING_KINGSIDE:
		var row := mv.from_sq.y
		board[0][row] = board[2][row]
		board[2][row] = null
	elif mv.move_type == ChessEnums.MoveType.CASTLING_QUEENSIDE:
		var row := mv.from_sq.y
		board[7][row] = board[4][row]
		board[4][row] = null

	# Restore state
	en_passant_sq = mv.prev_en_passant_sq
	castling_rights = mv.prev_castling_rights
	halfmove_clock = mv.prev_halfmove_clock

func _update_castling_rights(mv: ChessMove) -> void:
	# King moves
	if mv.piece_type == ChessEnums.PieceType.KING:
		if mv.piece_color == ChessEnums.PieceColor.WHITE:
			castling_rights &= ~0b0011
		else:
			castling_rights &= ~0b1100
	# Rook moves or captures
	var rook_squares: Dictionary = {
		Vector2i(0, 0): 0,  # W kingside (h1 in mirrored coords)
		Vector2i(7, 0): 1,  # W queenside (a1 in mirrored coords)
		Vector2i(0, 7): 2,  # B kingside
		Vector2i(7, 7): 3,  # B queenside
	}
	for sq: Vector2i in rook_squares:
		if mv.from_sq == sq or mv.to_sq == sq:
			castling_rights &= ~(1 << (rook_squares[sq] as int))

# ── Game State ─────────────────────────────────────────────────────────────
func get_game_state() -> int:
	var legal := get_legal_moves(active_color)
	var in_check := is_in_check(active_color)
	if legal.is_empty():
		if in_check:
			return ChessEnums.GameState.CHECKMATE
		else:
			return ChessEnums.GameState.STALEMATE
	if halfmove_clock >= 100:
		return ChessEnums.GameState.DRAW
	# Insufficient material (K vs K, K+B vs K, K+N vs K)
	if _is_insufficient_material():
		return ChessEnums.GameState.DRAW
	if in_check:
		return ChessEnums.GameState.CHECK
	return ChessEnums.GameState.PLAYING

func _is_insufficient_material() -> bool:
	var pieces := { ChessEnums.PieceColor.WHITE: [], ChessEnums.PieceColor.BLACK: [] }
	for c in range(8):
		for r in range(8):
			if board[c][r] != null:
				pieces[board[c][r]["color"]].append(board[c][r]["type"])
	for color: int in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var p: Array = pieces[color]
		p.erase(ChessEnums.PieceType.KING)
		if p.size() > 1:
			return false
		if p.size() == 1 and p[0] != ChessEnums.PieceType.BISHOP and p[0] != ChessEnums.PieceType.KNIGHT:
			return false
	return true

func last_move() -> ChessMove:
	if move_history.is_empty():
		return null
	return move_history.back()
