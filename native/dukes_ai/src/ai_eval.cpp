#include "ai_eval.h"

#include "ai_state.h"
#include "ai_constants.h"

#include <algorithm>
#include <godot_cpp/classes/time.hpp>

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
	// PST tables are indexed rank8→rank1 (top to bottom from white's view).
	// Board uses row 0=rank1, row 7=rank8, so white needs (7-row), black needs row.
	const int table_row = color == WHITE ? (7 - row) : row;
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
	// King safety: pawn shield bonus
	const int material = count_material(state);
	if (material > 1200) {
		// White king shield
		const int wk_code = PIECE_KING; // white king = code 6
		const int bk_code = PIECE_KING + 6; // black king = code 12
		const int wp_code = PIECE_PAWN; // white pawn = code 1
		const int bp_code = PIECE_PAWN + 6; // black pawn = code 7
		int wk_idx = -1, bk_idx = -1;
		for (int i = 0; i < 64; ++i) {
			if (state.board[i] == wk_code) wk_idx = i;
			else if (state.board[i] == bk_code) bk_idx = i;
		}
		if (wk_idx >= 0) {
			const int kc = SearchState::idx_col(wk_idx);
			const int kr = SearchState::idx_row(wk_idx);
			for (int dc = -1; dc <= 1; ++dc) {
				const int c = kc + dc;
				if (c < 0 || c > 7) continue;
				if (kr + 1 <= 7 && state.board[SearchState::sq_to_index(c, kr + 1)] == wp_code) score += 15;
				else if (kr + 2 <= 7 && state.board[SearchState::sq_to_index(c, kr + 2)] == wp_code) score += 7;
			}
		}
		if (bk_idx >= 0) {
			const int kc = SearchState::idx_col(bk_idx);
			const int kr = SearchState::idx_row(bk_idx);
			for (int dc = -1; dc <= 1; ++dc) {
				const int c = kc + dc;
				if (c < 0 || c > 7) continue;
				if (kr - 1 >= 0 && state.board[SearchState::sq_to_index(c, kr - 1)] == bp_code) score -= 15;
				else if (kr - 2 >= 0 && state.board[SearchState::sq_to_index(c, kr - 2)] == bp_code) score -= 7;
			}
		}
	}
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

int quiescence(SearchState &state, int alpha, int beta, SearchContext &ctx, int depth) {
	// Timeout check
	if (godot::Time::get_singleton()->get_ticks_msec() >= ctx.deadline_ms) {
		const int eval = evaluate_position(state);
		return state.active_color == WHITE ? eval : -eval;
	}
	
	// Depth limit
	if (depth <= -QSEARCH_MAX_DEPTH) {
		const int eval = evaluate_position(state);
		return state.active_color == WHITE ? eval : -eval;
	}

	const bool in_check = state.is_in_check(state.active_color);
	int best_value = -100000;

	// Standing pat is only valid when not in check.
	if (!in_check) {
		const int stand_pat = evaluate_position(state);
		const int negamax_stand = state.active_color == WHITE ? stand_pat : -stand_pat;
		best_value = negamax_stand;
		if (negamax_stand >= beta) {
			return beta;
		}
		if (alpha < negamax_stand) {
			alpha = negamax_stand;
		}
	}

	std::vector<Move> legal = state.generate_legal_moves();
	if (legal.empty()) {
		if (in_check) {
			return -MATE_SCORE;
		}
		return best_value;
	}

	std::vector<Move> qmoves;
	if (in_check) {
		// In check, all legal evasions must be searched.
		qmoves = std::move(legal);
	} else {
		for (const Move &mv : legal) {
			if (mv.is_capture()) {
				qmoves.push_back(mv);
			}
		}
		if (qmoves.empty()) {
			return best_value;
		}
	}

	order_moves(qmoves);

	for (const Move &mv : qmoves) {
		state.make_move(mv);
		const int score = -quiescence(state, -beta, -alpha, ctx, depth - 1);
		state.unmake_move();
		
		if (score >= beta) {
			return beta;
		}
		if (score > best_value) {
			best_value = score;
		}
		if (score > alpha) {
			alpha = score;
		}
	}
	
	return best_value;
}

} // namespace dukes_ai
} // namespace godot
