#include "dukes_ai_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

namespace {

constexpr int WHITE = 0;
constexpr int BLACK = 1;

constexpr int PIECE_NONE = 0;
constexpr int PIECE_PAWN = 1;
constexpr int PIECE_ROOK = 2;
constexpr int PIECE_KNIGHT = 3;
constexpr int PIECE_BISHOP = 4;
constexpr int PIECE_QUEEN = 5;
constexpr int PIECE_KING = 6;

constexpr int MOVE_NORMAL = 0;
constexpr int MOVE_CAPTURE = 1;
constexpr int MOVE_EN_PASSANT = 2;
constexpr int MOVE_CASTLE_K = 3;
constexpr int MOVE_CASTLE_Q = 4;
constexpr int MOVE_PROMOTION = 5;
constexpr int MOVE_PROMO_CAPTURE = 6;

constexpr int TT_EXACT = 0;
constexpr int TT_LOWER = 1;
constexpr int TT_UPPER = 2;

constexpr int MATE_SCORE = 30000;

const std::array<int, 7> PIECE_VALUES = {0, 100, 500, 320, 330, 900, 40000};

const int PAWN_PST[8][8] = {
	{0, 0, 0, 0, 0, 0, 0, 0},
	{50, 50, 50, 50, 50, 50, 50, 50},
	{10, 10, 20, 30, 30, 20, 10, 10},
	{5, 5, 10, 25, 25, 10, 5, 5},
	{0, 0, 0, 20, 20, 0, 0, 0},
	{5, -5, -10, 0, 0, -10, -5, 5},
	{5, 10, 10, -20, -20, 10, 10, 5},
	{0, 0, 0, 0, 0, 0, 0, 0},
};

const int KNIGHT_PST[8][8] = {
	{-50, -40, -30, -30, -30, -30, -40, -50},
	{-40, -20, 0, 0, 0, 0, -20, -40},
	{-30, 0, 10, 15, 15, 10, 0, -30},
	{-30, 5, 15, 20, 20, 15, 5, -30},
	{-30, 0, 15, 20, 20, 15, 0, -30},
	{-30, 5, 10, 15, 15, 10, 5, -30},
	{-40, -20, 0, 5, 5, 0, -20, -40},
	{-50, -40, -30, -30, -30, -30, -40, -50},
};

const int BISHOP_PST[8][8] = {
	{-20, -10, -10, -10, -10, -10, -10, -20},
	{-10, 0, 0, 0, 0, 0, 0, -10},
	{-10, 0, 5, 10, 10, 5, 0, -10},
	{-10, 5, 5, 10, 10, 5, 5, -10},
	{-10, 0, 10, 10, 10, 10, 0, -10},
	{-10, 10, 10, 10, 10, 10, 10, -10},
	{-10, 5, 0, 0, 0, 0, 5, -10},
	{-20, -10, -10, -10, -10, -10, -10, -20},
};

const int ROOK_PST[8][8] = {
	{0, 0, 0, 0, 0, 0, 0, 0},
	{5, 10, 10, 10, 10, 10, 10, 5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{0, 0, 0, 5, 5, 0, 0, 0},
};

const int QUEEN_PST[8][8] = {
	{-20, -10, -10, -5, -5, -10, -10, -20},
	{-10, 0, 0, 0, 0, 0, 0, -10},
	{-10, 0, 5, 5, 5, 5, 0, -10},
	{-5, 0, 5, 5, 5, 5, 0, -5},
	{0, 0, 5, 5, 5, 5, 0, -5},
	{-10, 5, 5, 5, 5, 5, 0, -10},
	{-10, 0, 5, 0, 0, 0, 0, -10},
	{-20, -10, -10, -5, -5, -10, -10, -20},
};

const int KING_EARLY[8][8] = {
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-20, -30, -30, -40, -40, -30, -30, -20},
	{-10, -20, -20, -20, -20, -20, -20, -10},
	{20, 20, 0, 0, 0, 0, 20, 20},
	{20, 30, 10, 0, 0, 10, 30, 20},
};

const int KING_END[8][8] = {
	{-50, -40, -30, -20, -20, -30, -40, -50},
	{-30, -20, -10, 0, 0, -10, -20, -30},
	{-30, -10, 20, 30, 30, 20, -10, -30},
	{-30, -10, 30, 40, 40, 30, -10, -30},
	{-30, -10, 30, 40, 40, 30, -10, -30},
	{-30, -10, 20, 30, 30, 20, -10, -30},
	{-30, -30, 0, 0, 0, 0, -30, -30},
	{-50, -30, -30, -30, -30, -30, -30, -50},
};

struct Move {
	int from = -1;
	int to = -1;
	int move_type = MOVE_NORMAL;
	int piece_type = PIECE_NONE;
	int piece_color = WHITE;
	int captured_type = PIECE_NONE;
	int promotion_type = PIECE_QUEEN;

	bool is_capture() const {
		return move_type == MOVE_CAPTURE || move_type == MOVE_EN_PASSANT || move_type == MOVE_PROMO_CAPTURE;
	}
};

struct UndoState {
	int from_idx = -1;
	int to_idx = -1;
	int moving_code = 0;
	int captured_code = 0;
	int prev_en_passant = -1;
	int prev_castling = 0;
	int prev_halfmove = 0;
	int prev_fullmove = 1;
	int rook_from = -1;
	int rook_to = -1;
	int rook_code = 0;
	int ep_capture_idx = -1;
	int ep_capture_code = 0;
};

struct TTEntry {
	int depth = -1;
	int score = 0;
	int flag = TT_EXACT;
};

struct SearchState {
	std::array<int, 64> board{};
	std::array<uint64_t, 13> piece_bb{};
	int active_color = WHITE;
	int castling_rights = 0b1111;
	int en_passant_index = -1;
	int halfmove_clock = 0;
	int fullmove_number = 1;
	std::vector<UndoState> history;

	inline static int sq_to_index(int col, int row) { return row * 8 + col; }
	inline static int idx_col(int idx) { return idx % 8; }
	inline static int idx_row(int idx) { return idx / 8; }

	inline static int piece_code(int piece_type, int color) { return piece_type + (color == BLACK ? 6 : 0); }
	inline static int piece_type_from_code(int code) { return code <= 0 ? PIECE_NONE : ((code - 1) % 6) + 1; }
	inline static int piece_color_from_code(int code) { return code <= 6 ? WHITE : BLACK; }

	void clear_square(int idx) {
		const int code = board[idx];
		if (code == 0) {
			return;
		}
		piece_bb[code] &= ~(uint64_t(1) << idx);
		board[idx] = 0;
	}

	void set_square(int idx, int code) {
		board[idx] = code;
		if (code != 0) {
			piece_bb[code] |= (uint64_t(1) << idx);
		}
	}

	bool is_square_attacked(int idx, int by_color) const {
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

	bool is_in_check(int color) const {
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

	void update_castling_rights(const Move &mv) {
		if (mv.piece_type == PIECE_KING) {
			if (mv.piece_color == WHITE) {
				castling_rights &= ~0b0011;
			} else {
				castling_rights &= ~0b1100;
			}
		}
		auto rook_bit = [](int idx) -> int {
			switch (idx) {
				case SearchState::sq_to_index(0, 0): return 0;
				case SearchState::sq_to_index(7, 0): return 1;
				case SearchState::sq_to_index(0, 7): return 2;
				case SearchState::sq_to_index(7, 7): return 3;
				default: return -1;
			}
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

	void make_move(const Move &mv) {
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

	void unmake_move() {
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

	bool can_castle_kingside(int color, int king_idx) const {
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

	bool can_castle_queenside(int color, int king_idx) const {
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

	std::vector<Move> pawn_moves(int idx, int color) const {
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

	std::vector<Move> knight_moves(int idx, int color) const {
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

	std::vector<Move> slider_moves(int idx, int color, const std::vector<std::array<int, 2>> &dirs) const {
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

	std::vector<Move> king_moves(int idx, int color) const {
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

	std::vector<Move> generate_pseudo_legal_moves_for_color(int color) const {
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
					auto sm = slider_moves(idx, color, {{ {1,1}, {1,-1}, {-1,1}, {-1,-1} }});
					moves.insert(moves.end(), sm.begin(), sm.end());
				} else if (pt == PIECE_ROOK) {
					auto sm = slider_moves(idx, color, {{ {1,0}, {-1,0}, {0,1}, {0,-1} }});
					moves.insert(moves.end(), sm.begin(), sm.end());
				} else if (pt == PIECE_QUEEN) {
					auto sm = slider_moves(idx, color, {{ {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {1,-1}, {-1,1}, {-1,-1} }});
					moves.insert(moves.end(), sm.begin(), sm.end());
				} else if (pt == PIECE_KING) {
					auto km = king_moves(idx, color);
					moves.insert(moves.end(), km.begin(), km.end());
				}
			}
		}
		return moves;
	}

	std::vector<Move> generate_legal_moves() {
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

	int count_pseudo_moves(int color) const {
		return static_cast<int>(generate_pseudo_legal_moves_for_color(color).size());
	}

	std::string hash_key() const {
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
};

struct SearchContext {
	std::unordered_map<int, Move> killer_moves;
	std::unordered_map<std::string, TTEntry> tt;
	uint64_t deadline_ms = 0;
	bool timed_out = false;
};

uint64_t now_ms() {
	return Time::get_singleton()->get_ticks_msec();
}

int count_material(const SearchState &state) {
	int total = 0;
	for (int i = 0; i < 64; ++i) {
		const int code = state.board[i];
		if (code == 0) {
			continue;
		}
		const int pt = SearchState::piece_type_from_code(code);
		if (pt != PIECE_KING) {
			total += PIECE_VALUES[pt];
		}
	}
	return total;
}

int pst_value(int piece_type, int color, int col, int row, const SearchState &state) {
	const int table_row = color == WHITE ? row : (7 - row);
	const int table_col = col;
	switch (piece_type) {
		case PIECE_PAWN: return PAWN_PST[table_row][table_col];
		case PIECE_KNIGHT: return KNIGHT_PST[table_row][table_col];
		case PIECE_BISHOP: return BISHOP_PST[table_row][table_col];
		case PIECE_ROOK: return ROOK_PST[table_row][table_col];
		case PIECE_QUEEN: return QUEEN_PST[table_row][table_col];
		case PIECE_KING: {
			const int material = count_material(state);
			return material < 1000 ? KING_END[table_row][table_col] : KING_EARLY[table_row][table_col];
		}
		default: return 0;
	}
}

int evaluate_position(SearchState &state) {
	int score = 0;
	for (int idx = 0; idx < 64; ++idx) {
		const int code = state.board[idx];
		if (code == 0) {
			continue;
		}
		const int pt = SearchState::piece_type_from_code(code);
		const int color = SearchState::piece_color_from_code(code);
		const int col = SearchState::idx_col(idx);
		const int row = SearchState::idx_row(idx);
		const int ps = PIECE_VALUES[pt] + pst_value(pt, color, col, row, state);
		if (color == WHITE) {
			score += ps;
		} else {
			score -= ps;
		}
	}
	const int white_mob = state.count_pseudo_moves(WHITE);
	const int black_mob = state.count_pseudo_moves(BLACK);
	score += (white_mob - black_mob) * 2;
	return score;
}

void order_moves(std::vector<Move> &moves) {
	std::sort(moves.begin(), moves.end(), [](const Move &a, const Move &b) {
		if (a.is_capture() != b.is_capture()) {
			return a.is_capture();
		}
		if (a.is_capture() && b.is_capture()) {
			return PIECE_VALUES[a.captured_type] > PIECE_VALUES[b.captured_type];
		}
		return false;
	});
}

int minimax(SearchState &state, int depth, int alpha, int beta, SearchContext &ctx) {
	if (now_ms() >= ctx.deadline_ms) {
		ctx.timed_out = true;
		const int t_eval = evaluate_position(state);
		return state.active_color == WHITE ? t_eval : -t_eval;
	}

	if (depth == 0) {
		const int eval = evaluate_position(state);
		return state.active_color == WHITE ? eval : -eval;
	}

	const int alpha_orig = alpha;
	const std::string key = state.hash_key();
	auto it = ctx.tt.find(key);
	if (it != ctx.tt.end() && it->second.depth >= depth) {
		const TTEntry &e = it->second;
		if (e.flag == TT_EXACT) {
			return e.score;
		}
		if (e.flag == TT_LOWER) {
			alpha = std::max(alpha, e.score);
		} else if (e.flag == TT_UPPER) {
			beta = std::min(beta, e.score);
		}
		if (alpha >= beta) {
			return e.score;
		}
	}

	std::vector<Move> legal = state.generate_legal_moves();
	if (legal.empty()) {
		if (state.is_in_check(state.active_color)) {
			return -MATE_SCORE;
		}
		return 0;
	}

	order_moves(legal);
	int best_score = alpha;
	for (const Move &mv : legal) {
		state.make_move(mv);
		const int score = -minimax(state, depth - 1, -beta, -best_score, ctx);
		state.unmake_move();

		best_score = std::max(best_score, score);
		if (best_score >= beta) {
			if (!mv.is_capture()) {
				ctx.killer_moves[depth] = mv;
			}
			break;
		}
	}

	TTEntry store;
	store.depth = depth;
	store.score = best_score;
	store.flag = TT_EXACT;
	if (best_score <= alpha_orig) {
		store.flag = TT_UPPER;
	} else if (best_score >= beta) {
		store.flag = TT_LOWER;
	}
	ctx.tt[key] = store;

	return best_score;
}

SearchState parse_position(const Dictionary &position, bool &ok) {
	SearchState s;
	ok = false;

	Variant board_var = position.get("board", PackedInt32Array());
	if (board_var.get_type() != Variant::PACKED_INT32_ARRAY) {
		return s;
	}
	PackedInt32Array packed = board_var;
	if (packed.size() != 64) {
		return s;
	}

	for (int i = 0; i < 64; ++i) {
		const int code = packed[i];
		s.board[i] = code;
		if (code >= 1 && code <= 12) {
			s.piece_bb[code] |= (uint64_t(1) << i);
		}
	}

	s.active_color = int(position.get("active_color", WHITE));
	s.castling_rights = int(position.get("castling_rights", 0b1111));
	s.en_passant_index = int(position.get("en_passant_index", -1));
	s.halfmove_clock = int(position.get("halfmove_clock", 0));
	s.fullmove_number = int(position.get("fullmove_number", 1));

	ok = true;
	return s;
}

Dictionary move_to_dict(const Move &mv, int score, int reached_depth) {
	Dictionary d;
	d["from_col"] = SearchState::idx_col(mv.from);
	d["from_row"] = SearchState::idx_row(mv.from);
	d["to_col"] = SearchState::idx_col(mv.to);
	d["to_row"] = SearchState::idx_row(mv.to);
	d["move_type"] = mv.move_type;
	d["piece_type"] = mv.piece_type;
	d["piece_color"] = mv.piece_color;
	d["captured_type"] = mv.captured_type;
	d["promotion_type"] = mv.promotion_type;
	d["score"] = score;
	d["reached_depth"] = reached_depth;
	d["ok"] = true;
	return d;
}

} // namespace

void DukesAINative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_version"), &DukesAINative::get_version);
	ClassDB::bind_method(D_METHOD("find_best_move", "position", "depth", "time_limit_ms"), &DukesAINative::find_best_move);
}

String DukesAINative::get_version() const {
	return String("dukes_ai_native/1.0.0");
}

Dictionary DukesAINative::find_best_move(Dictionary position, int32_t depth, int32_t time_limit_ms) const {
	bool ok = false;
	SearchState state = parse_position(position, ok);
	if (!ok) {
		Dictionary err;
		err["ok"] = false;
		err["error"] = String("Invalid position payload");
		return err;
	}

	if (depth <= 0) {
		depth = 1;
	}
	if (time_limit_ms <= 0) {
		time_limit_ms = 1000;
	}

	SearchContext ctx;
	ctx.deadline_ms = now_ms() + uint64_t(time_limit_ms);

	std::vector<Move> root_moves = state.generate_legal_moves();
	if (root_moves.empty()) {
		Dictionary none;
		none["ok"] = false;
		none["error"] = String("No legal moves");
		return none;
	}

	Move best_move = root_moves[0];
	int best_score = -100000;
	int reached_depth = 0;

	for (int current_depth = 1; current_depth <= depth; ++current_depth) {
		if (now_ms() >= ctx.deadline_ms) {
			break;
		}
		order_moves(root_moves);
		int alpha = -100000;
		const int beta = 100000;
		int depth_best_score = -100000;
		Move depth_best_move = best_move;
		bool timed_out = false;

		for (const Move &mv : root_moves) {
			if (now_ms() >= ctx.deadline_ms) {
				timed_out = true;
				break;
			}
			state.make_move(mv);
			const int mv_score = -minimax(state, current_depth - 1, -beta, -alpha, ctx);
			state.unmake_move();
			if (mv_score > depth_best_score) {
				depth_best_score = mv_score;
				depth_best_move = mv;
			}
			alpha = std::max(alpha, mv_score);
			if (alpha >= beta) {
				break;
			}
		}

		if (timed_out || ctx.timed_out) {
			break;
		}

		best_move = depth_best_move;
		best_score = depth_best_score;
		reached_depth = current_depth;
	}

	return move_to_dict(best_move, best_score, reached_depth);
}

} // namespace godot
