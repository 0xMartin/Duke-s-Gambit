#include "ai_state.h"

#include <cstdlib>

namespace godot {
namespace dukes_ai {

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

	static const int knight_offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
	for (const auto &off : knight_offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int code = board[sq_to_index(c, r)];
		if (code != 0 && piece_color_from_code(code) == by_color && piece_type_from_code(code) == PIECE_KNIGHT) {
			return true;
		}
	}

	const int pawn_dir = by_color == WHITE ? -1 : 1;
	for (int dc : {-1, 1}) {
		const int c = col + dc;
		const int r = row + pawn_dir;
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int code = board[sq_to_index(c, r)];
		if (code != 0 && piece_color_from_code(code) == by_color && piece_type_from_code(code) == PIECE_PAWN) {
			return true;
		}
	}

	static const int king_offsets[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	for (const auto &off : king_offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int code = board[sq_to_index(c, r)];
		if (code != 0 && piece_color_from_code(code) == by_color && piece_type_from_code(code) == PIECE_KING) {
			return true;
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
	int king_idx = -1;
	for (int i = 0; i < 64; ++i) {
		if ((bb >> i) & 1ULL) {
			king_idx = i;
			break;
		}
	}
	if (king_idx < 0) {
		return false;
	}
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

	history.push_back(st);

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
	active_color = 1 - active_color;
}

void SearchState::unmake_move() {
	if (history.empty()) {
		return;
	}
	UndoState st = history.back();
	history.pop_back();

	active_color = 1 - active_color;
	castling_rights = st.prev_castling;
	en_passant_index = st.prev_en_passant;
	halfmove_clock = st.prev_halfmove;
	fullmove_number = st.prev_fullmove;

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

std::vector<Move> SearchState::pawn_moves(int idx, int color) const {
	std::vector<Move> moves;
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
					moves.push_back({idx, one_idx, MOVE_PROMOTION, PIECE_PAWN, color, PIECE_NONE, pt});
				}
			} else {
				moves.push_back({idx, one_idx, MOVE_NORMAL, PIECE_PAWN, color, PIECE_NONE, PIECE_QUEEN});
			}
			if (row == start_row) {
				const int two_row = row + dir * 2;
				const int two_idx = sq_to_index(col, two_row);
				if (board[two_idx] == 0) {
					moves.push_back({idx, two_idx, MOVE_NORMAL, PIECE_PAWN, color, PIECE_NONE, PIECE_QUEEN});
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
					moves.push_back({idx, cap_idx, MOVE_PROMO_CAPTURE, PIECE_PAWN, color, cap_type, pt});
				}
			} else {
				moves.push_back({idx, cap_idx, MOVE_CAPTURE, PIECE_PAWN, color, cap_type, PIECE_QUEEN});
			}
		} else if (en_passant_index == cap_idx) {
			moves.push_back({idx, cap_idx, MOVE_EN_PASSANT, PIECE_PAWN, color, PIECE_PAWN, PIECE_QUEEN});
		}
	}

	return moves;
}

std::vector<Move> SearchState::knight_moves(int idx, int color) const {
	std::vector<Move> moves;
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	static const int offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
	for (const auto &off : offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int t_idx = sq_to_index(c, r);
		const int target = board[t_idx];
		if (target == 0) {
			moves.push_back({idx, t_idx, MOVE_NORMAL, PIECE_KNIGHT, color, PIECE_NONE, PIECE_QUEEN});
		} else if (piece_color_from_code(target) != color) {
			moves.push_back({idx, t_idx, MOVE_CAPTURE, PIECE_KNIGHT, color, piece_type_from_code(target), PIECE_QUEEN});
		}
	}
	return moves;
}

std::vector<Move> SearchState::slider_moves(int idx, int color, const std::vector<std::array<int, 2>> &dirs) const {
	std::vector<Move> moves;
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	const int piece_type = piece_type_from_code(board[idx]);
	for (const auto &d : dirs) {
		int c = col + d[0];
		int r = row + d[1];
		while (c >= 0 && c < 8 && r >= 0 && r < 8) {
			const int t_idx = sq_to_index(c, r);
			const int target = board[t_idx];
			if (target == 0) {
				moves.push_back({idx, t_idx, MOVE_NORMAL, piece_type, color, PIECE_NONE, PIECE_QUEEN});
			} else if (piece_color_from_code(target) != color) {
				moves.push_back({idx, t_idx, MOVE_CAPTURE, piece_type, color, piece_type_from_code(target), PIECE_QUEEN});
				break;
			} else {
				break;
			}
			c += d[0];
			r += d[1];
		}
	}
	return moves;
}

std::vector<Move> SearchState::king_moves(int idx, int color) const {
	std::vector<Move> moves;
	const int col = idx_col(idx);
	const int row = idx_row(idx);
	static const int offsets[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
	for (const auto &off : offsets) {
		const int c = col + off[0];
		const int r = row + off[1];
		if (c < 0 || c > 7 || r < 0 || r > 7) {
			continue;
		}
		const int t_idx = sq_to_index(c, r);
		const int target = board[t_idx];
		if (target == 0) {
			moves.push_back({idx, t_idx, MOVE_NORMAL, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
		} else if (piece_color_from_code(target) != color) {
			moves.push_back({idx, t_idx, MOVE_CAPTURE, PIECE_KING, color, piece_type_from_code(target), PIECE_QUEEN});
		}
	}
	const int ks_bit = color == WHITE ? 0 : 2;
	const int qs_bit = color == WHITE ? 1 : 3;
	if (((castling_rights >> ks_bit) & 1) == 1 && can_castle_kingside(color, idx)) {
		moves.push_back({idx, sq_to_index(1, row), MOVE_CASTLE_K, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
	}
	if (((castling_rights >> qs_bit) & 1) == 1 && can_castle_queenside(color, idx)) {
		moves.push_back({idx, sq_to_index(5, row), MOVE_CASTLE_Q, PIECE_KING, color, PIECE_NONE, PIECE_QUEEN});
	}
	return moves;
}

std::vector<Move> SearchState::generate_pseudo_legal_moves_for_color(int color) const {
	std::vector<Move> moves;
	const int start_code = color == WHITE ? 1 : 7;
	for (int code = start_code; code < start_code + 6; ++code) {
		uint64_t bb = piece_bb[code];
		for (int idx = 0; idx < 64; ++idx) {
			if (((bb >> idx) & 1ULL) == 0ULL) {
				continue;
			}
			const int pt = piece_type_from_code(code);
			if (pt == PIECE_PAWN) {
				auto pm = pawn_moves(idx, color);
				moves.insert(moves.end(), pm.begin(), pm.end());
			} else if (pt == PIECE_KNIGHT) {
				auto km = knight_moves(idx, color);
				moves.insert(moves.end(), km.begin(), km.end());
			} else if (pt == PIECE_BISHOP) {
				auto sm = slider_moves(idx, color, {{{1,1}, {1,-1}, {-1,1}, {-1,-1}}});
				moves.insert(moves.end(), sm.begin(), sm.end());
			} else if (pt == PIECE_ROOK) {
				auto sm = slider_moves(idx, color, {{{1,0}, {-1,0}, {0,1}, {0,-1}}});
				moves.insert(moves.end(), sm.begin(), sm.end());
			} else if (pt == PIECE_QUEEN) {
				auto sm = slider_moves(idx, color, {{{1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {1,-1}, {-1,1}, {-1,-1}}});
				moves.insert(moves.end(), sm.begin(), sm.end());
			} else if (pt == PIECE_KING) {
				auto km = king_moves(idx, color);
				moves.insert(moves.end(), km.begin(), km.end());
			}
		}
	}
	return moves;
}

std::vector<Move> SearchState::generate_legal_moves() {
	std::vector<Move> pseudo = generate_pseudo_legal_moves_for_color(active_color);
	std::vector<Move> legal;
	legal.reserve(pseudo.size());
	for (const Move &mv : pseudo) {
		const int moving_color = active_color;
		make_move(mv);
		if (!is_in_check(moving_color)) {
			legal.push_back(mv);
		}
		unmake_move();
	}
	return legal;
}

int SearchState::count_pseudo_moves(int color) const {
	return static_cast<int>(generate_pseudo_legal_moves_for_color(color).size());
}

std::string SearchState::hash_key() const {
	std::string out;
	out.reserve(256);
	out += std::to_string(active_color);
	out += '|';
	out += std::to_string(castling_rights);
	out += '|';
	out += std::to_string(en_passant_index);
	out += '|';
	out += std::to_string(halfmove_clock);
	for (int i = 1; i <= 12; ++i) {
		out += '|';
		out += std::to_string(piece_bb[i]);
	}
	return out;
}

} // namespace dukes_ai
} // namespace godot
