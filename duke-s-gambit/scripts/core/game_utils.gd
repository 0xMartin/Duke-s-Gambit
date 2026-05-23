## game_utils.gd
## Pure static helpers used by GameController — no scene / node dependencies.

class_name GameUtils

# ── UCI / notation tables ──────────────────────────────────────────────────
const _FILES := "abcdefgh"

const _PROMO_CHAR: Dictionary = {
	ChessEnums.PieceType.QUEEN:  "q",
	ChessEnums.PieceType.ROOK:   "r",
	ChessEnums.PieceType.BISHOP: "b",
	ChessEnums.PieceType.KNIGHT: "n",
}

const _CHAR_TO_PROMO: Dictionary = {
	"q": ChessEnums.PieceType.QUEEN,
	"r": ChessEnums.PieceType.ROOK,
	"b": ChessEnums.PieceType.BISHOP,
	"n": ChessEnums.PieceType.KNIGHT,
}

# ── UCI conversion ─────────────────────────────────────────────────────────

## Returns the UCI string for ``mv`` (e.g. "e2e4", "e7e8q").
## Engine stores files mirrored vs. standard chess; files are flipped here
## so the server's python-chess sees standard-frame coordinates.
static func move_to_uci(mv: ChessMove) -> String:
	var s := "%s%d%s%d" % [
		_FILES[7 - mv.from_sq.x], mv.from_sq.y + 1,
		_FILES[7 - mv.to_sq.x],   mv.to_sq.y + 1,
	]
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
	or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		s += _PROMO_CHAR.get(mv.promotion_type, "q")
	return s

## Parses a UCI string into {from: Vector2i, to: Vector2i, promotion: int}.
## Returns an empty Dictionary on parse failure.
static func parse_uci(uci: String) -> Dictionary:
	if uci.length() < 4:
		return {}
	var ff := _FILES.find(uci.substr(0, 1).to_lower())
	var fr := int(uci.substr(1, 1)) - 1
	var tf := _FILES.find(uci.substr(2, 1).to_lower())
	var trank := int(uci.substr(3, 1)) - 1
	if ff < 0 or tf < 0 or fr < 0 or fr > 7 or trank < 0 or trank > 7:
		return {}
	var promo_type: int = ChessEnums.PieceType.NONE
	if uci.length() >= 5:
		var ch := uci.substr(4, 1).to_lower()
		promo_type = _CHAR_TO_PROMO.get(ch, ChessEnums.PieceType.NONE)
	# Flip files back into the engine's mirrored frame (see move_to_uci).
	return {
		"from": Vector2i(7 - ff, fr),
		"to":   Vector2i(7 - tf, trank),
		"promotion": promo_type,
	}

# ── Time formatting ────────────────────────────────────────────────────────

## Formats milliseconds as "M:SS" when ≥1 minute, otherwise "S s".
static func format_time(ms: int) -> String:
	var secs: int = int(ms / 1000.0)
	var mins: int = int(secs / 60.0)
	var sec_rem: int = secs % 60
	if mins > 0:
		return "%d:%02d" % [mins, sec_rem]
	return "%d s" % secs

# ── SAN disambiguation ─────────────────────────────────────────────────────

## Fills ``mv.disambiguation`` with the SAN file/rank qualifier needed when
## two pieces of the same type can reach the same destination square.
## Must be called BEFORE make_move() using the pre-move legal-moves array.
static func compute_disambiguation(mv: ChessMove, legal: Array) -> void:
	# Castling and pawns never need disambiguation in SAN.
	if mv.piece_type == ChessEnums.PieceType.PAWN \
			or mv.move_type == ChessEnums.MoveType.CASTLING_KINGSIDE \
			or mv.move_type == ChessEnums.MoveType.CASTLING_QUEENSIDE:
		mv.disambiguation = ""
		return

	# Collect other pieces of the same type that can also reach mv.to_sq.
	var ambiguous: Array = []
	for other in legal:
		if other.piece_type == mv.piece_type \
				and other.to_sq == mv.to_sq \
				and other.from_sq != mv.from_sq:
			ambiguous.append(other)
	if ambiguous.is_empty():
		mv.disambiguation = ""
		return

	var my_file := mv.from_sq.x
	var my_rank := mv.from_sq.y
	var file_unique := true
	var rank_unique := true
	for other in ambiguous:
		if other.from_sq.x == my_file:
			file_unique = false
		if other.from_sq.y == my_rank:
			rank_unique = false

	if file_unique:
		mv.disambiguation = String.chr(97 + (7 - my_file))
	elif rank_unique:
		mv.disambiguation = str(my_rank + 1)
	else:
		mv.disambiguation = "%s%d" % [String.chr(97 + (7 - my_file)), my_rank + 1]
