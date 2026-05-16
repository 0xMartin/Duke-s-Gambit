## ai_bitboard_state.gd
## AI-only search position using 12 bitboards + mailbox.
## Designed for fast make/unmake during minimax search.

class_name AIBitboardState

const WHITE := ChessEnums.PieceColor.WHITE
const BLACK := ChessEnums.PieceColor.BLACK

const W_PAWN := 1
const W_KNIGHT := 2
const W_BISHOP := 3
const W_ROOK := 4
const W_QUEEN := 5
const W_KING := 6
const B_PAWN := 7
const B_KNIGHT := 8
const B_BISHOP := 9
const B_ROOK := 10
const B_QUEEN := 11
const B_KING := 12

var board: Array = []               # 64 entries, piece codes 0..12
var piece_bb: Array = []            # bitboard per piece code index
var active_color: int = WHITE
var castling_rights: int = 0b1111
var en_passant_index: int = -1      # 0..63 or -1
var halfmove_clock: int = 0
var fullmove_number: int = 1

var _history: Array = []

func duplicate_state() -> AIBitboardState:
	var copy := AIBitboardState.new()
	copy.board = board.duplicate()
	copy.piece_bb = piece_bb.duplicate()
	copy.active_color = active_color
	copy.castling_rights = castling_rights
	copy.en_passant_index = en_passant_index
	copy.halfmove_clock = halfmove_clock
	copy.fullmove_number = fullmove_number
	return copy

func hash_key() -> String:
	var parts := PackedStringArray()
	parts.append(str(active_color))
	parts.append(str(castling_rights))
	parts.append(str(en_passant_index))
	parts.append(str(halfmove_clock))
	for code in range(1, 13):
		parts.append(str(piece_bb[code]))
	return "|".join(parts)

func _init() -> void:
	board.resize(64)
	for i in range(64):
		board[i] = 0
	piece_bb.resize(13)
	for i in range(13):
		piece_bb[i] = 0

static func from_chess_board(source: ChessBoardState) -> AIBitboardState:
	var s: AIBitboardState = AIBitboardState.new()
	for col in range(8):
		for row in range(8):
			var raw_piece: Variant = source.board[col][row]
			if raw_piece == null:
				continue
			var piece: Dictionary = raw_piece
			if piece.is_empty():
				continue
			var idx: int = _sq_to_index(col, row)
			var code: int = s._piece_code(piece["type"], piece["color"])
			s.board[idx] = code
			s.piece_bb[code] |= (1 << idx)
	s.active_color = source.active_color
	s.castling_rights = source.castling_rights
	s.en_passant_index = -1
	if source.en_passant_sq.x >= 0:
		s.en_passant_index = _sq_to_index(source.en_passant_sq.x, source.en_passant_sq.y)
	s.halfmove_clock = source.halfmove_clock
	s.fullmove_number = source.fullmove_number
	return s

func generate_legal_moves() -> Array:
	var pseudo: Array = _generate_pseudo_legal_moves_for_color(active_color)
	var legal: Array = []
	for mv in pseudo:
		var moving_color: int = active_color
		make_move(mv)
		if not is_in_check(moving_color):
			legal.append(mv)
		unmake_move()
	return legal

func generate_legal_moves_for_color(color: int) -> Array:
	var saved_color: int = active_color
	active_color = color
	var legal: Array = generate_legal_moves()
	active_color = saved_color
	return legal

func count_pseudo_moves(color: int) -> int:
	return _generate_pseudo_legal_moves_for_color(color).size()


# Delta-based make_move/unmake_move for fast search
func make_move(mv: ChessMove) -> void:
	var from_idx: int = _sq_to_index(mv.from_sq.x, mv.from_sq.y)
	var to_idx: int = _sq_to_index(mv.to_sq.x, mv.to_sq.y)
	var moving_code: int = board[from_idx]
	var captured_code: int = board[to_idx]
	var prev_en_passant := en_passant_index
	var prev_castling := castling_rights
	var prev_halfmove := halfmove_clock
	var prev_fullmove := fullmove_number

	var rook_from := -1
	var rook_to := -1
	var rook_code := 0

	# Special for en passant
	var ep_capture_idx := -1
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		ep_capture_idx = _sq_to_index(mv.to_sq.x, mv.from_sq.y)

	# Special for castling
	if mv.move_type == ChessEnums.MoveType.CASTLING_KINGSIDE:
		rook_from = _sq_to_index(0, mv.from_sq.y)
		rook_to = _sq_to_index(2, mv.from_sq.y)
		rook_code = board[rook_from]
	elif mv.move_type == ChessEnums.MoveType.CASTLING_QUEENSIDE:
		rook_from = _sq_to_index(7, mv.from_sq.y)
		rook_to = _sq_to_index(4, mv.from_sq.y)
		rook_code = board[rook_from]

	_history.append({
		"from_idx": from_idx,
		"to_idx": to_idx,
		"moving_code": moving_code,
		"captured_code": captured_code,
		"prev_en_passant": prev_en_passant,
		"prev_castling": prev_castling,
		"prev_halfmove": prev_halfmove,
		"prev_fullmove": prev_fullmove,
		"rook_from": rook_from,
		"rook_to": rook_to,
		"rook_code": rook_code,
		"ep_capture_idx": ep_capture_idx,
		"ep_capture_code": ep_capture_idx >= 0 ? board[ep_capture_idx] : 0,
	})

	# Halfmove clock reset on pawn move or capture.
	if mv.piece_type == ChessEnums.PieceType.PAWN or mv.is_capture():
		halfmove_clock = 0
	else:
		halfmove_clock += 1

	# Update en passant target.
	en_passant_index = -1
	if mv.piece_type == ChessEnums.PieceType.PAWN and abs(mv.to_sq.y - mv.from_sq.y) == 2:
		en_passant_index = _sq_to_index(mv.from_sq.x, int((mv.from_sq.y + mv.to_sq.y) / 2))

	# Remove moving piece from source.
	_clear_square(from_idx)

	# Handle captures.
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		_clear_square(ep_capture_idx)
	elif captured_code != 0:
		_clear_square(to_idx)

	# Place moved/promoted piece.
	var placed_code: int = moving_code
	if mv.move_type == ChessEnums.MoveType.PROMOTION or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		placed_code = _piece_code(mv.promotion_type, mv.piece_color)
	_set_square(to_idx, placed_code)

	# Castling rook movement.
	if mv.move_type == ChessEnums.MoveType.CASTLING_KINGSIDE or mv.move_type == ChessEnums.MoveType.CASTLING_QUEENSIDE:
		_clear_square(rook_from)
		_set_square(rook_to, rook_code)

	_update_castling_rights(mv)
	if active_color == BLACK:
		fullmove_number += 1
	active_color = 1 - active_color

func unmake_move() -> void:
	if _history.is_empty():
		return
	var st: Dictionary = _history.pop_back()

	# Restore meta
	active_color = 1 - active_color
	castling_rights = st["prev_castling"]
	en_passant_index = st["prev_en_passant"]
	halfmove_clock = st["prev_halfmove"]
	fullmove_number = st["prev_fullmove"]

	# Undo castling rook
	if st["rook_from"] != -1:
		_clear_square(st["rook_to"])
		_set_square(st["rook_from"], st["rook_code"])

	# Undo move
	_clear_square(st["to_idx"])
	_set_square(st["from_idx"], st["moving_code"])

	# Undo capture
	if st["ep_capture_idx"] != -1:
		_set_square(st["ep_capture_idx"], st["ep_capture_code"])
	elif st["captured_code"] != 0:
		_set_square(st["to_idx"], st["captured_code"])

func is_in_check(color: int) -> bool:
	var king_code := W_KING if color == WHITE else B_KING
	var king_bb: int = piece_bb[king_code]
	if king_bb == 0:
		return false
	var king_idx := _first_bit_index(king_bb)
	return _is_square_attacked(king_idx, 1 - color)

func _generate_pseudo_legal_moves_for_color(color: int) -> Array:
	var moves: Array = []
	var start_code: int = W_PAWN if color == WHITE else B_PAWN
	for code in range(start_code, start_code + 6):
		var bb: int = piece_bb[code]
		while bb != 0:
			var lsb: int = bb & -bb
			var idx: int = _first_bit_index(lsb)
			bb &= bb - 1
			match _piece_type_from_code(code):
				ChessEnums.PieceType.PAWN:
					moves.append_array(_pawn_moves(idx, color))
				ChessEnums.PieceType.KNIGHT:
					moves.append_array(_knight_moves(idx, color))
				ChessEnums.PieceType.BISHOP:
					moves.append_array(_slider_moves(idx, color, [[1, 1], [1, -1], [-1, 1], [-1, -1]]))
				ChessEnums.PieceType.ROOK:
					moves.append_array(_slider_moves(idx, color, [[1, 0], [-1, 0], [0, 1], [0, -1]]))
				ChessEnums.PieceType.QUEEN:
					moves.append_array(_slider_moves(idx, color, [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]))
				ChessEnums.PieceType.KING:
					moves.append_array(_king_moves(idx, color))
	return moves

func _pawn_moves(idx: int, color: int) -> Array:
	var moves: Array = []
	var col: int = idx % 8
	var row: int = int(idx / 8)
	var dir: int = 1 if color == WHITE else -1
	var start_row: int = 1 if color == WHITE else 6
	var promo_row: int = 7 if color == WHITE else 0

	var one_row: int = row + dir
	if one_row >= 0 and one_row < 8:
		var one_idx: int = _sq_to_index(col, one_row)
		if board[one_idx] == 0:
			if one_row == promo_row:
				for pt in [ChessEnums.PieceType.QUEEN, ChessEnums.PieceType.ROOK, ChessEnums.PieceType.BISHOP, ChessEnums.PieceType.KNIGHT]:
					moves.append(ChessMove.new(Vector2i(col, row), Vector2i(col, one_row), ChessEnums.MoveType.PROMOTION, ChessEnums.PieceType.PAWN, color, ChessEnums.PieceType.NONE, pt))
			else:
				moves.append(ChessMove.new(Vector2i(col, row), Vector2i(col, one_row), ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.PAWN, color))

			if row == start_row:
				var two_row: int = row + dir * 2
				var two_idx: int = _sq_to_index(col, two_row)
				if board[two_idx] == 0:
					moves.append(ChessMove.new(Vector2i(col, row), Vector2i(col, two_row), ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.PAWN, color))

	for dc in [-1, 1]:
		var c: int = col + dc
		var r: int = row + dir
		if c < 0 or c > 7 or r < 0 or r > 7:
			continue
		var cap_idx: int = _sq_to_index(c, r)
		var cap_code: int = board[cap_idx]
		if cap_code != 0 and _piece_color_from_code(cap_code) != color:
			var cap_type: int = _piece_type_from_code(cap_code)
			if r == promo_row:
				for pt_cap in [ChessEnums.PieceType.QUEEN, ChessEnums.PieceType.ROOK, ChessEnums.PieceType.BISHOP, ChessEnums.PieceType.KNIGHT]:
					moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.PROMOTION_CAPTURE, ChessEnums.PieceType.PAWN, color, cap_type, pt_cap))
			else:
				moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.PAWN, color, cap_type))
		elif en_passant_index == cap_idx:
			moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.EN_PASSANT, ChessEnums.PieceType.PAWN, color, ChessEnums.PieceType.PAWN))

	return moves

func _knight_moves(idx: int, color: int) -> Array:
	var moves: Array = []
	var col: int = idx % 8
	var row: int = int(idx / 8)
	for o in [[2, 1], [2, -1], [-2, 1], [-2, -1], [1, 2], [1, -2], [-1, 2], [-1, -2]]:
		var c: int = col + int(o[0])
		var r: int = row + int(o[1])
		if c < 0 or c > 7 or r < 0 or r > 7:
			continue
		var t_idx: int = _sq_to_index(c, r)
		var target: int = board[t_idx]
		if target == 0:
			moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.KNIGHT, color))
		elif _piece_color_from_code(target) != color:
			moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.KNIGHT, color, _piece_type_from_code(target)))
	return moves

func _slider_moves(idx: int, color: int, dirs: Array) -> Array:
	var moves: Array = []
	var col: int = idx % 8
	var row: int = int(idx / 8)
	var piece_type: int = _piece_type_from_code(board[idx])
	for d in dirs:
		var c: int = col + int(d[0])
		var r: int = row + int(d[1])
		while c >= 0 and c < 8 and r >= 0 and r < 8:
			var t_idx: int = _sq_to_index(c, r)
			var target: int = board[t_idx]
			if target == 0:
				moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.NORMAL, piece_type, color))
			elif _piece_color_from_code(target) != color:
				moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.CAPTURE, piece_type, color, _piece_type_from_code(target)))
				break
			else:
				break
			c += int(d[0])
			r += int(d[1])
	return moves

func _king_moves(idx: int, color: int) -> Array:
	var moves: Array = []
	var col: int = idx % 8
	var row: int = int(idx / 8)
	for o in [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]:
		var c: int = col + int(o[0])
		var r: int = row + int(o[1])
		if c < 0 or c > 7 or r < 0 or r > 7:
			continue
		var t_idx: int = _sq_to_index(c, r)
		var target: int = board[t_idx]
		if target == 0:
			moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.NORMAL, ChessEnums.PieceType.KING, color))
		elif _piece_color_from_code(target) != color:
			moves.append(ChessMove.new(Vector2i(col, row), Vector2i(c, r), ChessEnums.MoveType.CAPTURE, ChessEnums.PieceType.KING, color, _piece_type_from_code(target)))

	# Castling
	var ks_bit: int = 0 if color == WHITE else 2
	var qs_bit: int = 1 if color == WHITE else 3
	if ((castling_rights >> ks_bit) & 1) == 1 and _can_castle_kingside(color, idx):
		moves.append(ChessMove.new(Vector2i(col, row), Vector2i(1, row), ChessEnums.MoveType.CASTLING_KINGSIDE, ChessEnums.PieceType.KING, color))
	if ((castling_rights >> qs_bit) & 1) == 1 and _can_castle_queenside(color, idx):
		moves.append(ChessMove.new(Vector2i(col, row), Vector2i(5, row), ChessEnums.MoveType.CASTLING_QUEENSIDE, ChessEnums.PieceType.KING, color))

	return moves

func _can_castle_kingside(color: int, king_idx: int) -> bool:
	var row: int = 0 if color == WHITE else 7
	if king_idx != _sq_to_index(3, row):
		return false
	var rook_idx := _sq_to_index(0, row)
	if board[king_idx] != _piece_code(ChessEnums.PieceType.KING, color):
		return false
	if board[rook_idx] != _piece_code(ChessEnums.PieceType.ROOK, color):
		return false
	if board[_sq_to_index(2, row)] != 0 or board[_sq_to_index(1, row)] != 0:
		return false
	if _is_square_attacked(king_idx, 1 - color):
		return false
	if _is_square_attacked(_sq_to_index(2, row), 1 - color) or _is_square_attacked(_sq_to_index(1, row), 1 - color):
		return false
	return true

func _can_castle_queenside(color: int, king_idx: int) -> bool:
	var row: int = 0 if color == WHITE else 7
	if king_idx != _sq_to_index(3, row):
		return false
	var rook_idx := _sq_to_index(7, row)
	if board[king_idx] != _piece_code(ChessEnums.PieceType.KING, color):
		return false
	if board[rook_idx] != _piece_code(ChessEnums.PieceType.ROOK, color):
		return false
	if board[_sq_to_index(4, row)] != 0 or board[_sq_to_index(5, row)] != 0 or board[_sq_to_index(6, row)] != 0:
		return false
	if _is_square_attacked(king_idx, 1 - color):
		return false
	if _is_square_attacked(_sq_to_index(4, row), 1 - color) or _is_square_attacked(_sq_to_index(5, row), 1 - color):
		return false
	return true

func _is_square_attacked(idx: int, by_color: int) -> bool:
	var col: int = idx % 8
	var row: int = int(idx / 8)

	# Knight attacks
	for o in [[2, 1], [2, -1], [-2, 1], [-2, -1], [1, 2], [1, -2], [-1, 2], [-1, -2]]:
		var c: int = col + int(o[0])
		var r: int = row + int(o[1])
		if c < 0 or c > 7 or r < 0 or r > 7:
			continue
		var code: int = board[_sq_to_index(c, r)]
		if code != 0 and _piece_color_from_code(code) == by_color and _piece_type_from_code(code) == ChessEnums.PieceType.KNIGHT:
			return true

	# Pawn attacks
	var pawn_dir: int = -1 if by_color == WHITE else 1
	for dc in [-1, 1]:
		var pc: int = col + dc
		var pr: int = row + pawn_dir
		if pc < 0 or pc > 7 or pr < 0 or pr > 7:
			continue
		var pcode: int = board[_sq_to_index(pc, pr)]
		if pcode != 0 and _piece_color_from_code(pcode) == by_color and _piece_type_from_code(pcode) == ChessEnums.PieceType.PAWN:
			return true

	# King attacks
	for ko in [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]:
		var kc: int = col + int(ko[0])
		var kr: int = row + int(ko[1])
		if kc < 0 or kc > 7 or kr < 0 or kr > 7:
			continue
		var kcode: int = board[_sq_to_index(kc, kr)]
		if kcode != 0 and _piece_color_from_code(kcode) == by_color and _piece_type_from_code(kcode) == ChessEnums.PieceType.KING:
			return true

	# Straight sliders (rook/queen)
	for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var c1: int = col + int(d[0])
		var r1: int = row + int(d[1])
		while c1 >= 0 and c1 < 8 and r1 >= 0 and r1 < 8:
			var scode: int = board[_sq_to_index(c1, r1)]
			if scode != 0:
				if _piece_color_from_code(scode) == by_color:
					var st: int = _piece_type_from_code(scode)
					if st == ChessEnums.PieceType.ROOK or st == ChessEnums.PieceType.QUEEN:
						return true
				break
			c1 += int(d[0])
			r1 += int(d[1])

	# Diagonal sliders (bishop/queen)
	for dd in [[1, 1], [1, -1], [-1, 1], [-1, -1]]:
		var c2: int = col + int(dd[0])
		var r2: int = row + int(dd[1])
		while c2 >= 0 and c2 < 8 and r2 >= 0 and r2 < 8:
			var dcode: int = board[_sq_to_index(c2, r2)]
			if dcode != 0:
				if _piece_color_from_code(dcode) == by_color:
					var dt: int = _piece_type_from_code(dcode)
					if dt == ChessEnums.PieceType.BISHOP or dt == ChessEnums.PieceType.QUEEN:
						return true
				break
			c2 += int(dd[0])
			r2 += int(dd[1])

	return false

func _update_castling_rights(mv: ChessMove) -> void:
	if mv.piece_type == ChessEnums.PieceType.KING:
		if mv.piece_color == WHITE:
			castling_rights &= ~0b0011
		else:
			castling_rights &= ~0b1100

	var rook_squares: Dictionary = {
		_sq_to_index(0, 0): 0,
		_sq_to_index(7, 0): 1,
		_sq_to_index(0, 7): 2,
		_sq_to_index(7, 7): 3,
	}
	var from_idx: int = _sq_to_index(mv.from_sq.x, mv.from_sq.y)
	var to_idx: int = _sq_to_index(mv.to_sq.x, mv.to_sq.y)
	if rook_squares.has(from_idx):
		castling_rights &= ~(1 << int(rook_squares[from_idx]))
	if rook_squares.has(to_idx):
		castling_rights &= ~(1 << int(rook_squares[to_idx]))

func _set_square(idx: int, code: int) -> void:
	board[idx] = code
	if code != 0:
		piece_bb[code] |= (1 << idx)

func _clear_square(idx: int) -> void:
	var code: int = board[idx]
	if code == 0:
		return
	piece_bb[code] &= ~(1 << idx)
	board[idx] = 0

func _piece_code(piece_type: int, color: int) -> int:
	return piece_type + (6 if color == BLACK else 0)

func _piece_type_from_code(code: int) -> int:
	if code <= 0:
		return ChessEnums.PieceType.NONE
	return ((code - 1) % 6) + 1

func _piece_color_from_code(code: int) -> int:
	return WHITE if code <= 6 else BLACK

func _first_bit_index(bits: int) -> int:
	for i in range(64):
		if ((bits >> i) & 1) == 1:
			return i
	return -1

static func _sq_to_index(col: int, row: int) -> int:
	return row * 8 + col

static func index_to_col(idx: int) -> int:
	return idx % 8

static func index_to_row(idx: int) -> int:
	return int(idx / 8)
