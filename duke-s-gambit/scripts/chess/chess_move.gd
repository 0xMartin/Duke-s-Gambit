## chess_move.gd
## Represents a single chess move with all metadata needed for execution and undo.

class_name ChessMove

var from_sq: Vector2i
var to_sq: Vector2i
var move_type: int          # ChessEnums.MoveType
var piece_type: int         # ChessEnums.PieceType (moving piece)
var piece_color: int        # ChessEnums.PieceColor
var captured_type: int      # ChessEnums.PieceType (NONE if no capture)
var promotion_type: int     # ChessEnums.PieceType (used for promotions)

# State needed for undo
var prev_en_passant_sq: Vector2i
var prev_castling_rights: int    # bitmask: bit0=W-K, bit1=W-Q, bit2=B-K, bit3=B-Q
var prev_halfmove_clock: int

# Metadata recorded at move-execution time
var game_time_ms: int = 0           # ms elapsed since game start when move was made
var check_annotation: String = ""   # "+", "#", or "" — computed after make_move
var disambiguation: String = ""     # "a", "1", "a1" etc. — computed before make_move

func _init(f: Vector2i, t: Vector2i, mt: int = ChessEnums.MoveType.NORMAL,
		pt: int = ChessEnums.PieceType.NONE, pc: int = ChessEnums.PieceColor.WHITE,
		cap: int = ChessEnums.PieceType.NONE,
		prom: int = ChessEnums.PieceType.QUEEN) -> void:
	from_sq = f
	to_sq = t
	move_type = mt
	piece_type = pt
	piece_color = pc
	captured_type = cap
	promotion_type = prom
	prev_en_passant_sq = Vector2i(-1, -1)
	prev_castling_rights = 0
	prev_halfmove_clock = 0

func is_capture() -> bool:
	return move_type == ChessEnums.MoveType.CAPTURE \
		or move_type == ChessEnums.MoveType.EN_PASSANT \
		or move_type == ChessEnums.MoveType.PROMOTION_CAPTURE

func to_str() -> String:
	return "%s→%s" % [from_sq, to_sq]
