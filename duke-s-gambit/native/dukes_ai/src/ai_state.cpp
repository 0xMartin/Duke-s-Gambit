#include "ai_state.h"

#include <bit>
#include <cstdlib>

namespace godot {
namespace dukes_ai {

// Zobrist table definitions (declared extern in ai_constants.h)
uint64_t ZOBRIST_PIECES[13][64];
uint64_t ZOBRIST_ACTIVE_COLOR;
uint64_t ZOBRIST_CASTLING[16];
uint64_t ZOBRIST_EN_PASSANT[8];

void init_zobrist() {
	// xorshift64 with fixed seed for deterministic, well-distributed values
	uint64_t s = 0x9e3779b97f4a7c15ULL;
	auto next = [&]() -> uint64_t {
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		return s;
	};
	for (int p = 0; p < 13; ++p) {
		for (int sq = 0; sq < 64; ++sq) {
			ZOBRIST_PIECES[p][sq] = next();
		}
	}
	// piece code 0 (empty square) should always be 0 to avoid hash changes for empty squares
	for (int sq = 0; sq < 64; ++sq) {
		ZOBRIST_PIECES[0][sq] = 0ULL;
	}
	ZOBRIST_ACTIVE_COLOR = next();
	for (int i = 0; i < 16; ++i) {
		ZOBRIST_CASTLING[i] = next();
	}
	for (int i = 0; i < 8; ++i) {
		ZOBRIST_EN_PASSANT[i] = next();
	}
}

int SearchState::sq_to_index(int col, int row) { return row * 8 + col; }
int SearchState::idx_col(int idx) { return idx % 8; }
int SearchState::idx_row(int idx) { return idx / 8; }
int SearchState::piece_code(int piece_type, int color) { return piece_type + (color == BLACK ? 6 : 0); }
int SearchState::piece_type_from_code(int code) { return code <= 0 ? PIECE_NONE : ((code - 1) % 6) + 1; }
int SearchState::piece_color_from_code(int code) { return code <= 6 ? WHITE : BLACK; }

void SearchState::clear_square(int idx) {
	const int code = board[idx];
	if (code == 0) {
		return;
	}
	piece_bb[code] &= ~(uint64_t(1) << idx);
	board[idx] = 0;
}

void SearchState::set_square(int idx, int code) {
	board[idx] = code;
	if (code != 0) {
		piece_bb[code] |= (uint64_t(1) << idx);
	}
}

bool SearchState::is_square_attacked(int idx, int by_color) const {
	const int col = idx_col(idx);
	const int row = idx_row(idx);

	{
		static const int knight_offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
		const int knight_code = piece_code(PIECE_KNIGHT, by_color);
		for (const auto &off : knight_offsets) {
			const int c = col + off[0];
			const int r = row + off[1];
			if (c >= 0 && c < 8 && r >= 0 && r < 8 && board[sq_to_index(c, r)] == knight_code) return true;
		}
	}

	{
		const int pawn_dir = by_color == WHITE ? -1 : 1;
		uint64_t pawn_attacks = 0;
		for (int dc : {-1, 1}) {
			const int c = col + dc;
			const int r = row + pawn_dir;
			if (c >= 0 && c < 8 && r >= 0 && r < 8) {
				pawn_attacks |= uint64_t(1) << sq_to_index(c, r);
			}
		}
		if (pawn_attacks & piece_bb[piece_code(PIECE_PAWN, by_color)]) return true;
	}

	{
		static const int king_offsets[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
		const int king_code = piece_code(PIECE_KING, by_color);
		for (const auto &off : king_offsets) {
			const int c = col + off[0];
			const int r = row + off[1];
			if (c >= 0 && c < 8 && r >= 0 && r < 8 && board[sq_to_index(c, r)] == king_code) return true;
		}
	}

	static const int rook_dirs[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
	for (const auto &d : rook_dirs) {
		int c = col + d[0];
		int r = row + d[1];
		while (c >= 0 && c < 8 && r >= 0 && r < 8) {
			const int code = board[sq_to_index(c, r)];
			if (code != 0) {
				if (piece_color_from_code(code) == by_color) {
					const int pt = piece_type_from_code(code);
					if (pt == PIECE_ROOK || pt == PIECE_QUEEN) {
						return true;
					}
				}
				break;
			}
			c += d[0];
			r += d[1];
		}
	}

	static const int bishop_dirs[4][2] = {{1,1},{1,-1},{-1,1},{-1,-1}};
	for (const auto &d : bishop_dirs) {
		int c = col + d[0];
		int r = row + d[1];
		while (c >= 0 && c < 8 && r >= 0 && r < 8) {
			const int code = board[sq_to_index(c, r)];
			if (code != 0) {
				if (piece_color_from_code(code) == by_color) {
					const int pt = piece_type_from_code(code);
					if (pt == PIECE_BISHOP || pt == PIECE_QUEEN) {
						return true;
					}
				}
				break;
			}
			c += d[0];
			r += d[1];
		}
	}

	return false;
}

bool SearchState::is_in_check(int color) const {
	const int king_code = piece_code(PIECE_KING, color);
	const uint64_t bb = piece_bb[king_code];
	if (bb == 0) {
		return false;
	}
	const int king_idx = std::countr_zero(bb);
	return is_square_attacked(king_idx, 1 - color);
}

void SearchState::update_castling_rights(const Move &mv) {
	if (mv.piece_type == PIECE_KING) {
		if (mv.piece_color == WHITE) {
			castling_rights &= ~0b0011;
		} else {
			castling_rights &= ~0b1100;
		}
	}
	auto rook_bit = [](int idx) -> int {
		if (idx == 0) return 0;
		if (idx == 7) return 1;
		if (idx == 56) return 2;
		if (idx == 63) return 3;
		return -1;
	};
	const int from_bit = rook_bit(mv.from);
	const int to_bit = rook_bit(mv.to);
	if (from_bit >= 0) {
		castling_rights &= ~(1 << from_bit);
	}
	if (to_bit >= 0) {
		castling_rights &= ~(1 << to_bit);
	}
}

void SearchState::make_move(const Move &mv) {
	UndoState st;
	st.from_idx = mv.from;
	st.to_idx = mv.to;
	st.moving_code = board[mv.from];
	st.captured_code = board[mv.to];
	st.prev_en_passant = en_passant_index;
	st.prev_castling = castling_rights;
	st.prev_halfmove = halfmove_clock;
	st.prev_fullmove = fullmove_number;
	st.prev_zobrist_hash = zobrist_hash;

	if (mv.move_type == MOVE_EN_PASSANT) {
		st.ep_capture_idx = sq_to_index(idx_col(mv.to), idx_row(mv.from));
		st.ep_capture_code = board[st.ep_capture_idx];
	}

	if (mv.move_type == MOVE_CASTLE_K) {
		st.rook_from = sq_to_index(0, idx_row(mv.from));
		st.rook_to = sq_to_index(2, idx_row(mv.from));
		st.rook_code = board[st.rook_from];
	} else if (mv.move_type == MOVE_CASTLE_Q) {
		st.rook_from = sq_to_index(7, idx_row(mv.from));
		st.rook_to = sq_to_index(4, idx_row(mv.from));
		st.rook_code = board[st.rook_from];
	}

	history_stack[history_count++] = st;

	if (mv.piece_type == PIECE_PAWN || mv.is_capture()) {
		halfmove_clock = 0;
	} else {
		++halfmove_clock;
	}

	en_passant_index = -1;
	if (mv.piece_type == PIECE_PAWN && std::abs(idx_row(mv.to) - idx_row(mv.from)) == 2) {
		en_passant_index = sq_to_index(idx_col(mv.from), (idx_row(mv.from) + idx_row(mv.to)) / 2);
	}

	clear_square(mv.from);
	if (mv.move_type == MOVE_EN_PASSANT && st.ep_capture_idx >= 0) {
		clear_square(st.ep_capture_idx);
	} else if (st.captured_code != 0) {
		clear_square(mv.to);
	}

	int placed_code = st.moving_code;
	if (mv.move_type == MOVE_PROMOTION || mv.move_type == MOVE_PROMO_CAPTURE) {
		placed_code = piece_code(mv.promotion_type, mv.piece_color);
	}
	set_square(mv.to, placed_code);

	if (st.rook_from >= 0) {
		clear_square(st.rook_from);
		set_square(st.rook_to, st.rook_code);
	}

	update_castling_rights(mv);
	if (active_color == BLACK) {
		++fullmove_number;
	}
	
	// Update zobrist hash - remove pieces from old positions
	zobrist_hash ^= ZOBRIST_PIECES[st.moving_code][mv.from];
	
	// Add piece to new position (handle promotion)
	if (mv.move_type == MOVE_PROMOTION || mv.move_type == MOVE_PROMO_CAPTURE) {
		zobrist_hash ^= ZOBRIST_PIECES[placed_code][mv.to];
	} else {
		zobrist_hash ^= ZOBRIST_PIECES[st.moving_code][mv.to];
	}
	
	// Handle captured piece
	if (st.captured_code != 0) {
		if (mv.move_type == MOVE_EN_PASSANT) {
			zobrist_hash ^= ZOBRIST_PIECES[st.ep_capture_code][st.ep_capture_idx];
		} else {
			zobrist_hash ^= ZOBRIST_PIECES[st.captured_code][mv.to];
		}
	}
	
	// Handle rook moves for castling
	if (st.rook_from >= 0) {
		zobrist_hash ^= ZOBRIST_PIECES[st.rook_code][st.rook_from];
		zobrist_hash ^= ZOBRIST_PIECES[st.rook_code][st.rook_to];
	}
	
	// Update zobrist for side to move
	zobrist_hash ^= ZOBRIST_ACTIVE_COLOR;
	
	// Update castling and en passant
	if (st.prev_castling != castling_rights) {
		zobrist_hash ^= ZOBRIST_CASTLING[st.prev_castling];
		zobrist_hash ^= ZOBRIST_CASTLING[castling_rights];
	}
	if (st.prev_en_passant >= 0) {
		zobrist_hash ^= ZOBRIST_EN_PASSANT[SearchState::idx_col(st.prev_en_passant)];
	}
	if (en_passant_index >= 0) {
		zobrist_hash ^= ZOBRIST_EN_PASSANT[SearchState::idx_col(en_passant_index)];
	}
	
	active_color = 1 - active_color;
}

void SearchState::unmake_move() {
	if (history_count == 0) {
		return;
	}
	const UndoState &st = history_stack[--history_count];

	active_color = 1 - active_color;
	castling_rights = st.prev_castling;
	en_passant_index = st.prev_en_passant;
	halfmove_clock = st.prev_halfmove;
	fullmove_number = st.prev_fullmove;
	zobrist_hash = st.prev_zobrist_hash;

	if (st.rook_from >= 0) {
		clear_square(st.rook_to);
		set_square(st.rook_from, st.rook_code);
	}

	clear_square(st.to_idx);
	set_square(st.from_idx, st.moving_code);

	if (st.ep_capture_idx >= 0) {
		set_square(st.ep_capture_idx, st.ep_capture_code);
	} else if (st.captured_code != 0) {
		set_square(st.to_idx, st.captured_code);
	}
}

bool SearchState::can_castle_kingside(int color, int king_idx) const {
	const int row = color == WHITE ? 0 : 7;
	if (king_idx != sq_to_index(3, row)) {
		return false;
	}
	const int rook_idx = sq_to_index(0, row);
	if (board[king_idx] != piece_code(PIECE_KING, color) || board[rook_idx] != piece_code(PIECE_ROOK, color)) {
		return false;
	}
	if (board[sq_to_index(2, row)] != 0 || board[sq_to_index(1, row)] != 0) {
		return false;
	}
	if (is_square_attacked(king_idx, 1 - color) || is_square_attacked(sq_to_index(2, row), 1 - color) || is_square_attacked(sq_to_index(1, row), 1 - color)) {
		return false;
	}
	return true;
}

bool SearchState::can_castle_queenside(int color, int king_idx) const {
	const int row = color == WHITE ? 0 : 7;
	if (king_idx != sq_to_index(3, row)) {
		return false;
	}
	const int rook_idx = sq_to_index(7, row);
	if (board[king_idx] != piece_code(PIECE_KING, color) || board[rook_idx] != piece_code(PIECE_ROOK, color)) {
		return false;
	}
	if (board[sq_to_index(4, row)] != 0 || board[sq_to_index(5, row)] != 0 || board[sq_to_index(6, row)] != 0) {
		return false;
	}
	if (is_square_attacked(king_idx, 1 - color) || is_square_attacked(sq_to_index(4, row), 1 - color) || is_square_attacked(sq_to_index(5, row), 1 - color)) {
		return false;
	}
	return true;
}

void SearchState::pawn_moves(int idx, int color, MoveList &list) const {
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	const int dir = color == WHITE ? 1 : -1;
	const int start_row = color == WHITE ? 1 : 6;
	const int promo_row = color == WHITE ? 7 : 0;

	const int one_row = row + dir;
	if (one_row >= 0 && one_row < 8) {
		const int one_idx = sq_to_index(col, one_row);
		if (board[one_idx] == 0) {
			if (one_row == promo_row) {
				for (int pt : {PIECE_QUEEN, PIECE_ROOK, PIECE_BISHOP, PIECE_KNIGHT}) {
					list.push({idx, one_idx, MOVE_PROMOTION, PIECE_PAWN, color, PIECE_NONE, pt});
				}
			} else {
				list.push({idx, one_idx, MOVE_NORMAL, PIECE_PAWN, color, PIECE_NONE, PIECE_QUEEN});
			}
			if (row == start_row) {
				const int two_row = row + dir * 2;
				const int two_idx = sq_to_index(col, two_row);
				if (board[two_idx] == 0) {
					list.push({idx, two_idx, MOVE_NORMAL, PIECE_PAWN, color, PIECE_NONE, PIECE_QUEEN});
				}
			}
		}
	}

	for (int dc : {-1, 1}) {
		const int c = col + dc;
		const int r = row + dir;
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int cap_idx = sq_to_index(c, r);
		const int cap_code = board[cap_idx];
		if (cap_code != 0 && piece_color_from_code(cap_code) != color) {
			const int cap_type = piece_type_from_code(cap_code);
			if (r == promo_row) {
				for (int pt : {PIECE_QUEEN, PIECE_ROOK, PIECE_BISHOP, PIECE_KNIGHT}) {
					list.push({idx, cap_idx, MOVE_PROMO_CAPTURE, PIECE_PAWN, color, cap_type, pt});
				}
			} else {
				list.push({idx, cap_idx, MOVE_CAPTURE, PIECE_PAWN, color, cap_type, PIECE_QUEEN});
			}
		} else if (en_passant_index == cap_idx) {
			list.push({idx, cap_idx, MOVE_EN_PASSANT, PIECE_PAWN, color, PIECE_PAWN, PIECE_QUEEN});
		}
	}
}
void SearchState::knight_moves(int idx, int color, MoveList &list) const {
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	static constexpr int offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
	for (const auto &off : offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int t_idx = sq_to_index(c, r);
		const int target = board[t_idx];
		if (target == 0) {
			list.push({idx, t_idx, MOVE_NORMAL, PIECE_KNIGHT, color, PIECE_NONE, PIECE_QUEEN});
		} else if (piece_color_from_code(target) != color) {
			list.push({idx, t_idx, MOVE_CAPTURE, PIECE_KNIGHT, color, piece_type_from_code(target), PIECE_QUEEN});
		}
	}
}

void SearchState::slider_moves(int idx, int color, const int (*dirs)[2], int ndir, MoveList &list) const {
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	const int piece_type = piece_type_from_code(board[idx]);
	for (int di = 0; di < ndir; ++di) {
		int c = col + dirs[di][0];
		int r = row + dirs[di][1];
		while (c >= 0 && c < 8 && r >= 0 && r < 8) {
			const int t_idx = sq_to_index(c, r);
			const int target = board[t_idx];
			if (target == 0) {
				list.push({idx, t_idx, MOVE_NORMAL, piece_type, color, PIECE_NONE, PIECE_QUEEN});
			} else if (piece_color_from_code(target) != color) {
				list.push({idx, t_idx, MOVE_CAPTURE, piece_type, color, piece_type_from_code(target), PIECE_QUEEN});
				break;
			} else {
				break;
			}
			c += dirs[di][0];
			r += dirs[di][1];
		}
	}
}

void SearchState::king_moves(int idx, int color, MoveList &list) const {
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	static constexpr int offsets[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	for (const auto &off : offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int t_idx = sq_to_index(c, r);
		const int target = board[t_idx];
		if (target == 0) {
			list.push({idx, t_idx, MOVE_NORMAL, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
		} else if (piece_color_from_code(target) != color) {
			list.push({idx, t_idx, MOVE_CAPTURE, PIECE_KING, color, piece_type_from_code(target), PIECE_QUEEN});
		}
	}
	const int ks_bit = color == WHITE ? 0 : 2;
	const int qs_bit = color == WHITE ? 1 : 3;
	if (((castling_rights >> ks_bit) & 1) == 1 && can_castle_kingside(color, idx)) {
		list.push({idx, sq_to_index(1, row), MOVE_CASTLE_K, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
	}
	if (((castling_rights >> qs_bit) & 1) == 1 && can_castle_queenside(color, idx)) {
		list.push({idx, sq_to_index(5, row), MOVE_CASTLE_Q, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
	}
}

void SearchState::generate_pseudo_legal_moves_for_color(int color, MoveList &list) const {
	static constexpr int ROOK_DIRS[4][2]   = {{1,0},{-1,0},{0,1},{0,-1}};
	static constexpr int BISHOP_DIRS[4][2] = {{1,1},{1,-1},{-1,1},{-1,-1}};
	static constexpr int QUEEN_DIRS[8][2]  = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};

	const int start_code = color == WHITE ? 1 : 7;
	for (int code = start_code; code < start_code + 6; ++code) {
		uint64_t bb = piece_bb[code];
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int pt = piece_type_from_code(code);
			if      (pt == PIECE_PAWN)   pawn_moves(idx, color, list);
			else if (pt == PIECE_ROOK)   slider_moves(idx, color, ROOK_DIRS, 4, list);
			else if (pt == PIECE_KNIGHT) knight_moves(idx, color, list);
			else if (pt == PIECE_BISHOP) slider_moves(idx, color, BISHOP_DIRS, 4, list);
			else if (pt == PIECE_QUEEN)  slider_moves(idx, color, QUEEN_DIRS, 8, list);
			else if (pt == PIECE_KING)   king_moves(idx, color, list);
		}
	}
}

void SearchState::generate_legal_moves(MoveList &list) {
	MoveList pseudo;
	generate_pseudo_legal_moves_for_color(active_color, pseudo);
	const int moving_color = active_color;
	for (int i = 0; i < pseudo.count; ++i) {
		make_move(pseudo.moves[i]);
		if (!is_in_check(moving_color)) {
			list.push(pseudo.moves[i]);
		}
		unmake_move();
	}
}

// Generates only captures and promotions (no quiet moves).
// Returns pseudo-legal moves; caller must verify legality via make_move + is_in_check.
void SearchState::generate_tactical_moves(MoveList &list) {
	const int color = active_color;
	const int dir    = color == WHITE ? 1 : -1;
	const int promo_row = color == WHITE ? 7 : 0;

	// Pawns: quiet promotions + diagonal captures (including promo-captures + en-passant)
	{
		uint64_t bb = piece_bb[piece_code(PIECE_PAWN, color)];
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int col = idx_col(idx);
			const int row = idx_row(idx);

			// Quiet promotion (single push to back rank)
			const int one_row = row + dir;
			if (one_row == promo_row && one_row >= 0 && one_row < 8) {
				const int one_idx = sq_to_index(col, one_row);
				if (board[one_idx] == 0) {
					for (int pt : {PIECE_QUEEN, PIECE_ROOK, PIECE_BISHOP, PIECE_KNIGHT}) {
						list.push({idx, one_idx, MOVE_PROMOTION, PIECE_PAWN, color, PIECE_NONE, pt});
					}
				}
			}

			// Diagonal captures
			for (int dc : {-1, 1}) {
				const int c = col + dc;
				const int r = row + dir;
				if (c < 0 || c > 7 || r < 0 || r > 7) continue;
				const int cap_idx = sq_to_index(c, r);
				const int cap_code = board[cap_idx];
				if (cap_code != 0 && piece_color_from_code(cap_code) != color) {
					const int cap_type = piece_type_from_code(cap_code);
					if (r == promo_row) {
						for (int pt : {PIECE_QUEEN, PIECE_ROOK, PIECE_BISHOP, PIECE_KNIGHT}) {
							list.push({idx, cap_idx, MOVE_PROMO_CAPTURE, PIECE_PAWN, color, cap_type, pt});
						}
					} else {
						list.push({idx, cap_idx, MOVE_CAPTURE, PIECE_PAWN, color, cap_type, PIECE_QUEEN});
					}
				} else if (en_passant_index == cap_idx) {
					list.push({idx, cap_idx, MOVE_EN_PASSANT, PIECE_PAWN, color, PIECE_PAWN, PIECE_QUEEN});
				}
			}
		}
	}

	// Knights: captures only
	{
		uint64_t bb = piece_bb[piece_code(PIECE_KNIGHT, color)];
		static constexpr int offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int col = idx_col(idx);
			const int row = idx_row(idx);
			for (const auto &off : offsets) {
				const int c = col + off[0];
				const int r = row + off[1];
				if (c < 0 || c > 7 || r < 0 || r > 7) continue;
				const int t_idx = sq_to_index(c, r);
				const int target = board[t_idx];
				if (target != 0 && piece_color_from_code(target) != color) {
					list.push({idx, t_idx, MOVE_CAPTURE, PIECE_KNIGHT, color, piece_type_from_code(target), PIECE_QUEEN});
				}
			}
		}
	}

	// Bishops: captures only
	{
		uint64_t bb = piece_bb[piece_code(PIECE_BISHOP, color)];
		static constexpr int dirs[4][2] = {{1,1},{1,-1},{-1,1},{-1,-1}};
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int col = idx_col(idx);
			const int row = idx_row(idx);
			for (const auto &d : dirs) {
				int c = col + d[0]; int r = row + d[1];
				while (c >= 0 && c < 8 && r >= 0 && r < 8) {
					const int t_idx = sq_to_index(c, r);
					const int target = board[t_idx];
					if (target != 0) {
						if (piece_color_from_code(target) != color)
							list.push({idx, t_idx, MOVE_CAPTURE, PIECE_BISHOP, color, piece_type_from_code(target), PIECE_QUEEN});
						break;
					}
					c += d[0]; r += d[1];
				}
			}
		}
	}

	// Rooks: captures only
	{
		uint64_t bb = piece_bb[piece_code(PIECE_ROOK, color)];
		static constexpr int dirs[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int col = idx_col(idx);
			const int row = idx_row(idx);
			for (const auto &d : dirs) {
				int c = col + d[0]; int r = row + d[1];
				while (c >= 0 && c < 8 && r >= 0 && r < 8) {
					const int t_idx = sq_to_index(c, r);
					const int target = board[t_idx];
					if (target != 0) {
						if (piece_color_from_code(target) != color)
							list.push({idx, t_idx, MOVE_CAPTURE, PIECE_ROOK, color, piece_type_from_code(target), PIECE_QUEEN});
						break;
					}
					c += d[0]; r += d[1];
				}
			}
		}
	}

	// Queens: captures only
	{
		uint64_t bb = piece_bb[piece_code(PIECE_QUEEN, color)];
		static constexpr int dirs[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
		while (bb) {
			const int idx = std::countr_zero(bb);
			bb &= bb - 1;
			const int col = idx_col(idx);
			const int row = idx_row(idx);
			for (const auto &d : dirs) {
				int c = col + d[0]; int r = row + d[1];
				while (c >= 0 && c < 8 && r >= 0 && r < 8) {
					const int t_idx = sq_to_index(c, r);
					const int target = board[t_idx];
					if (target != 0) {
						if (piece_color_from_code(target) != color)
							list.push({idx, t_idx, MOVE_CAPTURE, PIECE_QUEEN, color, piece_type_from_code(target), PIECE_QUEEN});
						break;
					}
					c += d[0]; r += d[1];
				}
			}
		}
	}

	// King: captures only
	{
		uint64_t bb = piece_bb[piece_code(PIECE_KING, color)];
		if (bb) {
			const int idx = std::countr_zero(bb);
			const int col = idx_col(idx);
			const int row = idx_row(idx);
			static constexpr int offsets[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
			for (const auto &off : offsets) {
				const int c = col + off[0];
				const int r = row + off[1];
				if (c < 0 || c > 7 || r < 0 || r > 7) continue;
				const int t_idx = sq_to_index(c, r);
				const int target = board[t_idx];
				if (target != 0 && piece_color_from_code(target) != color) {
					list.push({idx, t_idx, MOVE_CAPTURE, PIECE_KING, color, piece_type_from_code(target), PIECE_QUEEN});
				}
			}
		}
	}
}

int SearchState::count_pseudo_moves(int color) const {
	MoveList list;
	generate_pseudo_legal_moves_for_color(color, list);
	return list.count;
}

uint64_t SearchState::hash_key() const {
	return zobrist_hash;
}

} // namespace dukes_ai
} // namespace godot
