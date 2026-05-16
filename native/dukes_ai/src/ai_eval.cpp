#include "ai_eval.h"

#include <algorithm>

namespace godot {
namespace dukes_ai {

static int count_material(const SearchState &state) {
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

static int pst_value(int piece_type, int color, int col, int row, const SearchState &state) {
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

} // namespace dukes_ai
} // namespace godot
