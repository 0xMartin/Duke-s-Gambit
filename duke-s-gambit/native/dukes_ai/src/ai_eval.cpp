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

// Helper: detect if a pawn is passed (no opposing pawns can stop it)
static bool is_passed_pawn(int pawn_idx, int pawn_color, const SearchState &state) {
	const int col = SearchState::idx_col(pawn_idx);
	const int row = SearchState::idx_row(pawn_idx);
	const int enemy_color = 1 - pawn_color;
	const int enemy_pawn_code = PIECE_PAWN + (enemy_color == BLACK ? 6 : 0);
	
	// For white pawn: check rows above; for black pawn: check rows below
	if (pawn_color == WHITE) {
		// Check columns c-1, c, c+1 for rows row+1 to row+7
		for (int r = row + 1; r <= 7; ++r) {
			for (int c = col - 1; c <= col + 1; ++c) {
				if (c >= 0 && c <= 7 && state.board[SearchState::sq_to_index(c, r)] == enemy_pawn_code) {
					return false;
				}
			}
		}
	} else {
		// Check columns c-1, c, c+1 for rows 0 to row-1
		for (int r = row - 1; r >= 0; --r) {
			for (int c = col - 1; c <= col + 1; ++c) {
				if (c >= 0 && c <= 7 && state.board[SearchState::sq_to_index(c, r)] == enemy_pawn_code) {
					return false;
				}
			}
		}
	}
	return true;
}

// Evaluate passed pawn bonus (scales with advancement)
static int passed_pawn_bonus(int pawn_idx, int pawn_color) {
	const int row = SearchState::idx_row(pawn_idx);
	if (pawn_color == WHITE) {
		// Bonus increases as pawn advances towards rank 8
		if (row == 6) return 100;      // 7th rank
		if (row == 5) return 50;       // 6th rank
		if (row == 4) return 25;       // 5th rank
		if (row == 3) return 10;       // 4th rank
		return 5;                      // 2nd-3rd rank
	} else {
		// Black: symmetrical (rank 1 is row 0)
		if (row == 1) return 100;      // 2nd rank
		if (row == 2) return 50;       // 3rd rank
		if (row == 3) return 25;       // 4th rank
		if (row == 4) return 10;       // 5th rank
		return 5;                      // 6th-7th rank
	}
}

// Evaluate pawn structure
static int evaluate_pawn_structure(const SearchState &state) {
	int score = 0;
	const int wp_code = PIECE_PAWN;
	const int bp_code = PIECE_PAWN + 6;
	
	// Scan white pawns
	for (int idx = 0; idx < 64; ++idx) {
		if (state.board[idx] != wp_code) continue;
		
		const int col = SearchState::idx_col(idx);
		const int row = SearchState::idx_row(idx);
		
		// Passed pawn
		if (is_passed_pawn(idx, WHITE, state)) {
			score += passed_pawn_bonus(idx, WHITE) * 2;  // 2x weight for passed pawns
		}
		
		// Doubled pawns (penalty)
		int doubled_count = 0;
		for (int r = row + 1; r <= 7; ++r) {
			if (state.board[SearchState::sq_to_index(col, r)] == wp_code) {
				doubled_count++;
			}
		}
		if (doubled_count > 0) score -= 20 * doubled_count;  // -20 per doubled pawn
		
		// Isolated pawn (no friendly pawn on adjacent files)
		bool isolated = true;
		for (int c = col - 1; c <= col + 1; c += 2) {
			if (c >= 0 && c <= 7) {
				for (int r = 0; r <= 7; ++r) {
					if (state.board[SearchState::sq_to_index(c, r)] == wp_code) {
						isolated = false;
						break;
					}
				}
			}
			if (!isolated) break;
		}
		if (isolated) score -= 15;  // Isolated pawn penalty
	}
	
	// Scan black pawns (symmetrical)
	for (int idx = 0; idx < 64; ++idx) {
		if (state.board[idx] != bp_code) continue;
		
		const int col = SearchState::idx_col(idx);
		const int row = SearchState::idx_row(idx);
		
		// Passed pawn
		if (is_passed_pawn(idx, BLACK, state)) {
			score -= passed_pawn_bonus(idx, BLACK) * 2;
		}
		
		// Doubled pawns (penalty)
		int doubled_count = 0;
		for (int r = row - 1; r >= 0; --r) {
			if (state.board[SearchState::sq_to_index(col, r)] == bp_code) {
				doubled_count++;
			}
		}
		if (doubled_count > 0) score += 20 * doubled_count;
		
		// Isolated pawn
		bool isolated = true;
		for (int c = col - 1; c <= col + 1; c += 2) {
			if (c >= 0 && c <= 7) {
				for (int r = 0; r <= 7; ++r) {
					if (state.board[SearchState::sq_to_index(c, r)] == bp_code) {
						isolated = false;
						break;
					}
				}
			}
			if (!isolated) break;
		}
		if (isolated) score += 15;
	}
	
	return score;
}

// Evaluate piece bonuses
static int evaluate_piece_bonuses(const SearchState &state) {
	int score = 0;
	
	// Bishop pair bonus
	int white_bishops = __builtin_popcountll(state.piece_bb[PIECE_BISHOP]);
	int black_bishops = __builtin_popcountll(state.piece_bb[PIECE_BISHOP + 6]);
	if (white_bishops >= 2) score += 30;
	if (black_bishops >= 2) score -= 30;
	
	// Rook on 7th rank bonus
	const int wr_code = PIECE_ROOK;
	const int br_code = PIECE_ROOK + 6;
	for (int idx = 0; idx < 64; ++idx) {
		const int row = SearchState::idx_row(idx);
		if (state.board[idx] == wr_code && row == 6) score += 20;  // White rook on 7th
		if (state.board[idx] == br_code && row == 1) score -= 20;  // Black rook on 2nd
	}
	
	// Rook in open/semi-open file
	for (int col = 0; col < 8; ++col) {
		int pawn_count = 0;
		for (int row = 0; row < 8; ++row) {
			const int code = state.board[SearchState::sq_to_index(col, row)];
			if (code == PIECE_PAWN || code == PIECE_PAWN + 6) {
				pawn_count++;
			}
		}
		
		if (pawn_count == 0) {
			// Open file: rook gets bonus
			for (int row = 0; row < 8; ++row) {
				if (state.board[SearchState::sq_to_index(col, row)] == wr_code) score += 10;
				if (state.board[SearchState::sq_to_index(col, row)] == br_code) score -= 10;
			}
		} else if (pawn_count == 1) {
			// Semi-open file: slight bonus
			for (int row = 0; row < 8; ++row) {
				if (state.board[SearchState::sq_to_index(col, row)] == wr_code) score += 5;
				if (state.board[SearchState::sq_to_index(col, row)] == br_code) score -= 5;
			}
		}
	}
	
	// Knight centrality: knights are better in center
	for (int idx = 0; idx < 64; ++idx) {
		if (state.board[idx] == PIECE_KNIGHT) {
			const int col = SearchState::idx_col(idx);
			const int row = SearchState::idx_row(idx);
			const int center_dist = std::abs(col - 3.5) + std::abs(row - 3.5);
			score += (8 - center_dist) * 2;  // Bonus for centrality
		} else if (state.board[idx] == PIECE_KNIGHT + 6) {
			const int col = SearchState::idx_col(idx);
			const int row = SearchState::idx_row(idx);
			const int center_dist = std::abs(col - 3.5) + std::abs(row - 3.5);
			score -= (8 - center_dist) * 2;
		}
	}
	
	// Queen out early penalty (simple heuristic: queen in opponent's half early is bad)
	const int material = count_material(state);
	if (material > 3000) {  // Early/middlegame
		for (int idx = 0; idx < 64; ++idx) {
			const int row = SearchState::idx_row(idx);
			// White queen advanced too much without support
			if (state.board[idx] == PIECE_QUEEN && row >= 5) {
				// Check if queen is relatively undefended
				int defenders = 0;
				for (int jdx = 0; jdx < 64; ++jdx) {
					if (jdx == idx) continue;
					const int code = state.board[jdx];
					if (code != 0 && SearchState::piece_color_from_code(code) == WHITE) {
						// Simple: count nearby pieces as defenders
						const int dc = std::abs(SearchState::idx_col(jdx) - SearchState::idx_col(idx));
						const int dr = std::abs(SearchState::idx_row(jdx) - SearchState::idx_row(idx));
						if (dc <= 2 && dr <= 2) defenders++;
					}
				}
				if (defenders <= 2) score -= 10;
			}
			// Black queen symmetrical
			if (state.board[idx] == PIECE_QUEEN + 6 && row <= 2) {
				int defenders = 0;
				for (int jdx = 0; jdx < 64; ++jdx) {
					if (jdx == idx) continue;
					const int code = state.board[jdx];
					if (code != 0 && SearchState::piece_color_from_code(code) == BLACK) {
						const int dc = std::abs(SearchState::idx_col(jdx) - SearchState::idx_col(idx));
						const int dr = std::abs(SearchState::idx_row(jdx) - SearchState::idx_row(idx));
						if (dc <= 2 && dr <= 2) defenders++;
					}
				}
				if (defenders <= 2) score += 10;
			}
		}
	}
	
	return score;
}

int evaluate_position(SearchState &state) {
	int score = 0;
	
	// Material + PST
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
	
	// Pawn structure evaluation
	score += evaluate_pawn_structure(state);
	
	// Piece bonuses
	score += evaluate_piece_bonuses(state);
	
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
		int eval = evaluate_position(state);
		std::vector<Move> legal = state.generate_legal_moves();
		eval += (legal.size() > 0 ? (legal.size() >> 3) : 0) * (state.active_color == WHITE ? 1 : -1);
		return state.active_color == WHITE ? eval : -eval;
	}
	
	// Depth limit - but ONLY if we're not in check (extend checks)
	const bool in_check = state.is_in_check(state.active_color);
	if (depth <= -QSEARCH_MAX_DEPTH && !in_check) {
		int eval = evaluate_position(state);
		std::vector<Move> legal = state.generate_legal_moves();
		eval += (legal.size() > 0 ? (legal.size() >> 3) : 0) * (state.active_color == WHITE ? 1 : -1);
		return state.active_color == WHITE ? eval : -eval;
	}

	int best_value = -100000;

	// Standing pat is only valid when not in check.
	if (!in_check) {
		int stand_pat = evaluate_position(state);
		// Mobility bonus: more options is slightly better
		std::vector<Move> legal = state.generate_legal_moves();
		stand_pat += (legal.size() > 0 ? (legal.size() >> 3) : 0) * (state.active_color == WHITE ? 1 : -1);
		int negamax_stand = state.active_color == WHITE ? stand_pat : -stand_pat;
		best_value = negamax_stand;
		if (negamax_stand >= beta) {
			return beta;  // Beta cutoff
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
		// Not in check: only search captures and some promotions
		for (const Move &mv : legal) {
			if (mv.is_capture() || mv.move_type == MOVE_PROMOTION) {
				qmoves.push_back(mv);
			}
		}
		if (qmoves.empty()) {
			return best_value;
		}
	}

	order_moves(qmoves);
	
	// Delta pruning & hanging piece detection: skip moves unlikely to affect score.
	const int delta_margin = 150;  // Increased from 100 for more aggressive pruning

	for (const Move &mv : qmoves) {
		// Delta pruning: if best_value + capture_value + margin < alpha, skip
		// BUT: Never prune checks - they must be searched!
		if (!in_check && mv.is_capture() && depth <= -1) {
			const int capture_gain = PIECE_VALUES[mv.captured_type];
			if (best_value + capture_gain + delta_margin <= alpha) {
				continue;
			}
		}
		
		// Hanging piece detection in quiescence: avoid capturing undefended pieces if we can be attacked back.
		if (mv.is_capture() && depth >= -2) {
			state.make_move(mv);
			const bool to_sq_attacked = state.is_square_attacked(mv.to, 1 - state.active_color);
			state.unmake_move();
			// If captured piece is defended after capture, reduce penalty.
			if (to_sq_attacked && PIECE_VALUES[mv.captured_type] < PIECE_VALUES[mv.piece_type]) {
				continue; // Skip bad trades in shallow qsearch
			}
		}
		
		state.make_move(mv);
		// Check extensions: if we're giving check, search deeper
		int check_ext = 0;
		if (state.is_in_check(1 - state.active_color)) {
			check_ext = 1;  // One ply extension for checks
		}
		const int score = -quiescence(state, -beta, -alpha, ctx, depth - 1 + check_ext);
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
