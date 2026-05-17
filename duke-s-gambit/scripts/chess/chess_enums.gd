## chess_enums.gd
## Shared enums and constants for the chess engine.

class_name ChessEnums

enum PieceType {
	NONE   = 0,
	PAWN   = 1,
	ROOK   = 2,
	KNIGHT = 3,
	BISHOP = 4,
	QUEEN  = 5,
	KING   = 6,
}

enum PieceColor {
	WHITE = 0,
	BLACK = 1,
}

enum MoveType {
	NORMAL    = 0,
	CAPTURE   = 1,
	EN_PASSANT = 2,
	CASTLING_KINGSIDE  = 3,
	CASTLING_QUEENSIDE = 4,
	PROMOTION = 5,
	PROMOTION_CAPTURE = 6,
}

enum GameState {
	PLAYING    = 0,
	CHECK      = 1,
	CHECKMATE  = 2,
	STALEMATE  = 3,
	DRAW       = 4,
}
