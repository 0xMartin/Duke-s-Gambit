#include "ai_eval.h"

#include "ai_state.h"
#include "ai_constants.h"

#include <algorithm>
#include <bit>
#include <godot_cpp/classes/time.hpp>

namespace godot {
namespace dukes_ai {

static int count_material(const SearchState &state) {
	int total = 0;
	for (int pt : {PIECE_PAWN, PIECE_KNIGHT, PIECE_BISHOP, PIECE_ROOK, PIECE_QUEEN}) {
		total += std::popcount(state.piece_bb[pt])     * PIECE_VALUES[pt];
		total += std::popcount(state.piece_bb[pt + 6]) * PIECE_VALUES[pt];
	}
	return total;
}

static int pst_value(int piece_type, int color, int col, int row, int material) {
	// PST tables are indexed rank8→rank1 (top to bottom from white's view).
	// Board uses row 0=rank1, row 7=rank8, so white needs (7-row), black needs row.
	const int table_row = color == WHITE ? (7 - row) : row;
	const int table_col = col;
	switch (piece_type) {
		case PIECE_PAWN:   return PAWN_PST[table_row][table_col];
		case PIECE_KNIGHT: return KNIGHT_PST[table_row][table_col];
		case PIECE_BISHOP: return BISHOP_PST[table_row][table_col];
		case PIECE_ROOK:   return ROOK_PST[table_row][table_col];
		case PIECE_QUEEN:  return QUEEN_PST[table_row][table_col];
		case PIECE_KING:   return material < 1000 ? KING_END[table_row][table_col] : KING_EARLY[table_row][table_col];
		default:           return 0;
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
	static constexpr uint64_t FILE_A = 0x0101010101010101ULL;

	// Scan white pawns via bitboard
	uint64_t bb = state.piece_bb[PIECE_PAWN];
	while (bb) {
		const int idx = std::countr_zero(bb);
		bb &= bb - 1;

		const int col = SearchState::idx_col(idx);

		// Passed pawn
		if (is_passed_pawn(idx, WHITE, state)) {
			score += passed_pawn_bonus(idx, WHITE) * 2;
		}

		// Doubled pawns: white pawns on this file strictly above this pawn
		const uint64_t file_mask    = FILE_A << col;
		const uint64_t above_mask   = ~((uint64_t(2) << idx) - 1);
		const int doubled_count = std::popcount(state.piece_bb[PIECE_PAWN] & file_mask & above_mask);
		if (doubled_count > 0) score -= 20 * doubled_count;

		// Isolated pawn: no white pawn on adjacent files
		const uint64_t left_file  = (col > 0) ? (file_mask >> 1) : 0ULL;
		const uint64_t right_file = (col < 7) ? (file_mask << 1) : 0ULL;
		if ((state.piece_bb[PIECE_PAWN] & (left_file | right_file)) == 0) score -= 15;
	}

	// Scan black pawns via bitboard
	bb = state.piece_bb[PIECE_PAWN + 6];
	while (bb) {
		const int idx = std::countr_zero(bb);
		bb &= bb - 1;

		const int col = SearchState::idx_col(idx);

		// Passed pawn
		if (is_passed_pawn(idx, BLACK, state)) {
			score -= passed_pawn_bonus(idx, BLACK) * 2;
		}

		// Doubled pawns: black pawns on this file strictly below this pawn
		const uint64_t file_mask    = FILE_A << col;
		const uint64_t below_mask   = (uint64_t(1) << idx) - 1;
		const int doubled_count = std::popcount(state.piece_bb[PIECE_PAWN + 6] & file_mask & below_mask);
		if (doubled_count > 0) score += 20 * doubled_count;

		// Isolated pawn: no black pawn on adjacent files
		const uint64_t left_file  = (col > 0) ? (file_mask >> 1) : 0ULL;
		const uint64_t right_file = (col < 7) ? (file_mask << 1) : 0ULL;
		if ((state.piece_bb[PIECE_PAWN + 6] & (left_file | right_file)) == 0) score += 15;
	}

	return score;
}

// Evaluate piece bonuses
static int evaluate_piece_bonuses(const SearchState &state, int material) {
	int score = 0;

	// Pawn counts for material adjustments
	const int w_pawns = std::popcount(state.piece_bb[PIECE_PAWN]);
	const int b_pawns = std::popcount(state.piece_bb[PIECE_PAWN + 6]);

	// Bishop pair bonus
	if (std::popcount(state.piece_bb[PIECE_BISHOP])     >= 2) score += 30;
	if (std::popcount(state.piece_bb[PIECE_BISHOP + 6]) >= 2) score -= 30;

	// Knight gains value with more pawns; rook gains value with fewer pawns (CPW n_adj/r_adj)
	static constexpr int n_adj[9] = {-20, -16, -12, -8, -4,  0,  4,  8, 12};
	static constexpr int r_adj[9] = { 15,  12,   9,  6,  3,  0, -3, -6, -9};
	score += std::popcount(state.piece_bb[PIECE_KNIGHT])     * n_adj[w_pawns];
	score -= std::popcount(state.piece_bb[PIECE_KNIGHT + 6]) * n_adj[b_pawns];
	score += std::popcount(state.piece_bb[PIECE_ROOK])       * r_adj[w_pawns];
	score -= std::popcount(state.piece_bb[PIECE_ROOK + 6])   * r_adj[b_pawns];

	// Rook on 7th/2nd rank bonus (rank masks: row 6 = bits 48-55, row 1 = bits 8-15)
	static constexpr uint64_t RANK7_MASK = 0x00FF000000000000ULL;
	static constexpr uint64_t RANK2_MASK = 0x000000000000FF00ULL;
	score += std::popcount(state.piece_bb[PIECE_ROOK]     & RANK7_MASK) * 20;
	score -= std::popcount(state.piece_bb[PIECE_ROOK + 6] & RANK2_MASK) * 20;

	// Rook on open/semi-open file (file masks)
	static constexpr uint64_t FILE_A = 0x0101010101010101ULL;
	for (int col = 0; col < 8; ++col) {
		const uint64_t file_mask = FILE_A << col;
		const int pawn_count = std::popcount((state.piece_bb[PIECE_PAWN] | state.piece_bb[PIECE_PAWN + 6]) & file_mask);
		const int wr_on_file = std::popcount(state.piece_bb[PIECE_ROOK]     & file_mask);
		const int br_on_file = std::popcount(state.piece_bb[PIECE_ROOK + 6] & file_mask);
		if (pawn_count == 0) {
			score += wr_on_file * 10;
			score -= br_on_file * 10;
		} else if (pawn_count == 1) {
			score += wr_on_file * 5;
			score -= br_on_file * 5;
		}
	}

	// --- King Tropism ---
	// Bonus for pieces close to the enemy king (Manhattan distance).
	// Weights: knight*3, bishop*2, rook*2, queen*3.

	const int wk_sq = std::countr_zero(state.piece_bb[PIECE_KING]);
	const int bk_sq = std::countr_zero(state.piece_bb[PIECE_KING + 6]);
	const int wkc = SearchState::idx_col(wk_sq), wkr = SearchState::idx_row(wk_sq);
	const int bkc = SearchState::idx_col(bk_sq), bkr = SearchState::idx_row(bk_sq);

	// White knights: tropism*3 towards black king
	uint64_t bb = state.piece_bb[PIECE_KNIGHT];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score += 3 * std::max(0, 7 - (std::abs(row - bkr) + std::abs(col - bkc)));
	}

	// Black knights: tropism*3 towards white king
	bb = state.piece_bb[PIECE_KNIGHT + 6];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score -= 3 * std::max(0, 7 - (std::abs(row - wkr) + std::abs(col - wkc)));
	}

	// White bishops: tropism*2
	bb = state.piece_bb[PIECE_BISHOP];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score += 2 * std::max(0, 7 - (std::abs(row - bkr) + std::abs(col - bkc)));
	}

	// Black bishops: tropism*2
	bb = state.piece_bb[PIECE_BISHOP + 6];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score -= 2 * std::max(0, 7 - (std::abs(row - wkr) + std::abs(col - wkc)));
	}

	// White rooks: tropism*2
	bb = state.piece_bb[PIECE_ROOK];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score += 2 * std::max(0, 7 - (std::abs(row - bkr) + std::abs(col - bkc)));
	}

	// Black rooks: tropism*2
	bb = state.piece_bb[PIECE_ROOK + 6];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score -= 2 * std::max(0, 7 - (std::abs(row - wkr) + std::abs(col - wkc)));
	}

	// White queens: tropism*3
	bb = state.piece_bb[PIECE_QUEEN];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score += 3 * std::max(0, 7 - (std::abs(row - bkr) + std::abs(col - bkc)));
	}

	// Black queens: tropism*3
	bb = state.piece_bb[PIECE_QUEEN + 6];
	while (bb) {
		const int idx = std::countr_zero(bb); bb &= bb - 1;
		const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
		score -= 3 * std::max(0, 7 - (std::abs(row - wkr) + std::abs(col - wkc)));
	}

	// Queen out early penalty: bitboard traversal, 5x5 box only when queen is advanced
	if (material > 3000) {
		uint64_t wq_bb = state.piece_bb[PIECE_QUEEN];
		while (wq_bb) {
			const int idx = std::countr_zero(wq_bb); wq_bb &= wq_bb - 1;
			const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
			if (row >= 5) {
				int defenders = 0;
				for (int dr = -2; dr <= 2; ++dr) {
					for (int dc = -2; dc <= 2; ++dc) {
						if (dr == 0 && dc == 0) continue;
						const int c = col + dc, r = row + dr;
						if (c < 0 || c > 7 || r < 0 || r > 7) continue;
						const int code = state.board[SearchState::sq_to_index(c, r)];
						if (code != 0 && SearchState::piece_color_from_code(code) == WHITE) defenders++;
					}
				}
				if (defenders <= 2) score -= 10;
			}
		}
		uint64_t bq_bb = state.piece_bb[PIECE_QUEEN + 6];
		while (bq_bb) {
			const int idx = std::countr_zero(bq_bb); bq_bb &= bq_bb - 1;
			const int col = SearchState::idx_col(idx), row = SearchState::idx_row(idx);
			if (row <= 2) {
				int defenders = 0;
				for (int dr = -2; dr <= 2; ++dr) {
					for (int dc = -2; dc <= 2; ++dc) {
						if (dr == 0 && dc == 0) continue;
						const int c = col + dc, r = row + dr;
						if (c < 0 || c > 7 || r < 0 || r > 7) continue;
						const int code = state.board[SearchState::sq_to_index(c, r)];
						if (code != 0 && SearchState::piece_color_from_code(code) == BLACK) defenders++;
					}
				}
				if (defenders <= 2) score += 10;
			}
		}
	}

	return score;
}

// Detect structurally trapped pieces and penalize them.
// Board index: idx = row*8 + col, row 0 = rank 1 (white side), col 0 = file a.
// e.g. a1=0, h1=7, a8=56, h8=63.
static int evaluate_blockages(const SearchState &state) {
	int score = 0;

	const int WP = PIECE_PAWN,       BP = PIECE_PAWN + 6;
	const int WN = PIECE_KNIGHT,     BN = PIECE_KNIGHT + 6;
	const int WB = PIECE_BISHOP,     BB_CODE = PIECE_BISHOP + 6;
	const int WK = PIECE_KING,       BK_CODE = PIECE_KING + 6;
	const int WR = PIECE_ROOK,       BR = PIECE_ROOK + 6;

	// --- White pieces ---
	// Bishop on C1(2)/F1(5) can't develop: central pawn on D2(11)/E2(12) is blocked
	if (state.board[2]  == WB && state.board[11] == WP && state.board[19] != 0) score -= 24;
	if (state.board[5]  == WB && state.board[12] == WP && state.board[20] != 0) score -= 24;
	// Knight trapped on A8(56): black pawn on A7(48) or C7(50)
	if (state.board[56] == WN && (state.board[48] == BP || state.board[50] == BP)) score -= 150;
	// Knight trapped on H8(63): black pawn on H7(55) or F7(53)
	if (state.board[63] == WN && (state.board[55] == BP || state.board[53] == BP)) score -= 150;
	// Knight trapped on A7(48): black pawns on A6(40) and B7(49)
	if (state.board[48] == WN && state.board[40] == BP && state.board[49] == BP) score -= 100;
	// Knight trapped on H7(55): black pawns on H6(47) and G7(54)
	if (state.board[55] == WN && state.board[47] == BP && state.board[54] == BP) score -= 100;
	// Bishop trapped on A7(48): black pawn on B6(41)
	if (state.board[48] == WB && state.board[41] == BP) score -= 150;
	// Bishop trapped on H7(55): black pawn on G6(46)
	if (state.board[55] == WB && state.board[46] == BP) score -= 150;
	// Bishop trapped on A6(40): black pawn on B5(33)
	if (state.board[40] == WB && state.board[33] == BP) score -= 50;
	// Bishop trapped on H6(47): black pawn on G5(38)
	if (state.board[47] == WB && state.board[38] == BP) score -= 50;
	// King on F1(5)/G1(6) blocking own rook on G1(6)/H1(7) — kingside
	if ((state.board[5] == WK || state.board[6] == WK) &&
	    (state.board[6] == WR || state.board[7] == WR)) score -= 24;
	// King on B1(1)/C1(2) blocking own rook on A1(0)/B1(1) — queenside
	if ((state.board[1] == WK || state.board[2] == WK) &&
	    (state.board[0] == WR || state.board[1] == WR)) score -= 24;

	// --- Black pieces (mirrored) ---
	// Bishop on C8(58)/F8(61) can't develop: central pawn on D7(51)/E7(52) is blocked
	if (state.board[58] == BB_CODE && state.board[51] == BP && state.board[43] != 0) score += 24;
	if (state.board[61] == BB_CODE && state.board[52] == BP && state.board[44] != 0) score += 24;
	// Knight trapped on A1(0): white pawn on A2(8) or C2(10)
	if (state.board[0]  == BN && (state.board[8] == WP || state.board[10] == WP)) score += 150;
	// Knight trapped on H1(7): white pawn on H2(15) or F2(13)
	if (state.board[7]  == BN && (state.board[15] == WP || state.board[13] == WP)) score += 150;
	// Knight trapped on A2(8): white pawns on A3(16) and B2(9)
	if (state.board[8]  == BN && state.board[16] == WP && state.board[9]  == WP) score += 100;
	// Knight trapped on H2(15): white pawns on H3(23) and G2(14)
	if (state.board[15] == BN && state.board[23] == WP && state.board[14] == WP) score += 100;
	// Bishop trapped on A2(8): white pawn on B3(17)
	if (state.board[8]  == BB_CODE && state.board[17] == WP) score += 150;
	// Bishop trapped on H2(15): white pawn on G3(22)
	if (state.board[15] == BB_CODE && state.board[22] == WP) score += 150;
	// Bishop trapped on A3(16): white pawn on B4(25)
	if (state.board[16] == BB_CODE && state.board[25] == WP) score += 50;
	// Bishop trapped on H3(23): white pawn on G4(30)
	if (state.board[23] == BB_CODE && state.board[30] == WP) score += 50;
	// Black king on F8(61)/G8(62) blocking own rook on G8(62)/H8(63) — kingside
	if ((state.board[61] == BK_CODE || state.board[62] == BK_CODE) &&
	    (state.board[62] == BR      || state.board[63] == BR)) score += 24;
	// Black king on B8(57)/C8(58) blocking own rook on A8(56)/B8(57) — queenside
	if ((state.board[57] == BK_CODE || state.board[58] == BK_CODE) &&
	    (state.board[56] == BR      || state.board[57] == BR)) score += 24;

	return score;
}

int evaluate_position(SearchState &state) {
	int score = 0;
	const int material = count_material(state);

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
		const int ps = PIECE_VALUES[pt] + pst_value(pt, color, col, row, material);
		if (color == WHITE) {
			score += ps;
		} else {
			score -= ps;
		}
	}
	
	// Pawn structure evaluation
	score += evaluate_pawn_structure(state);
	
	// Piece bonuses (mobility, tropism, rook files, bishop pair, pawn adj)
	score += evaluate_piece_bonuses(state, material);

	// Piece blockage patterns (trapped knights/bishops, king blocking rook)
	score += evaluate_blockages(state);

	// King safety: pawn shield bonus
	if (material > 1200) {
		const int wp_code = PIECE_PAWN;
		const int bp_code = PIECE_PAWN + 6;
		const int wk_idx = state.piece_bb[PIECE_KING]     ? std::countr_zero(state.piece_bb[PIECE_KING])     : -1;
		const int bk_idx = state.piece_bb[PIECE_KING + 6] ? std::countr_zero(state.piece_bb[PIECE_KING + 6]) : -1;
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

	// Low material draw correction (prevents claiming wins in drawn endgames)
	if (score != 0) {
		const int w_piece_mat =
			std::popcount(state.piece_bb[PIECE_KNIGHT]) * PIECE_VALUES[PIECE_KNIGHT] +
			std::popcount(state.piece_bb[PIECE_BISHOP]) * PIECE_VALUES[PIECE_BISHOP] +
			std::popcount(state.piece_bb[PIECE_ROOK])   * PIECE_VALUES[PIECE_ROOK]   +
			std::popcount(state.piece_bb[PIECE_QUEEN])  * PIECE_VALUES[PIECE_QUEEN];
		const int b_piece_mat =
			std::popcount(state.piece_bb[PIECE_KNIGHT + 6]) * PIECE_VALUES[PIECE_KNIGHT] +
			std::popcount(state.piece_bb[PIECE_BISHOP + 6]) * PIECE_VALUES[PIECE_BISHOP] +
			std::popcount(state.piece_bb[PIECE_ROOK + 6])   * PIECE_VALUES[PIECE_ROOK]   +
			std::popcount(state.piece_bb[PIECE_QUEEN + 6])  * PIECE_VALUES[PIECE_QUEEN];
		const bool w_has_pawns = state.piece_bb[PIECE_PAWN] != 0;
		const bool b_has_pawns = state.piece_bb[PIECE_PAWN + 6] != 0;

		if (score > 0 && !w_has_pawns) {
			// White is "stronger" but has no pawns — check draw conditions
			if (w_piece_mat < 400) return 0; // lone minor piece can't force mate
			if (!b_has_pawns && w_piece_mat == 2 * PIECE_VALUES[PIECE_KNIGHT]) return 0; // KNN vs K = draw
			if (w_piece_mat == PIECE_VALUES[PIECE_ROOK] &&
			    (b_piece_mat == PIECE_VALUES[PIECE_BISHOP] || b_piece_mat == PIECE_VALUES[PIECE_KNIGHT])) score /= 2;
			if ((w_piece_mat == PIECE_VALUES[PIECE_ROOK] + PIECE_VALUES[PIECE_BISHOP] ||
			     w_piece_mat == PIECE_VALUES[PIECE_ROOK] + PIECE_VALUES[PIECE_KNIGHT]) &&
			     b_piece_mat == PIECE_VALUES[PIECE_ROOK]) score /= 2;
		} else if (score < 0 && !b_has_pawns) {
			// Black is "stronger" but has no pawns
			if (b_piece_mat < 400) return 0;
			if (!w_has_pawns && b_piece_mat == 2 * PIECE_VALUES[PIECE_KNIGHT]) return 0; // KNN vs K = draw
			if (b_piece_mat == PIECE_VALUES[PIECE_ROOK] &&
			    (w_piece_mat == PIECE_VALUES[PIECE_BISHOP] || w_piece_mat == PIECE_VALUES[PIECE_KNIGHT])) score /= 2;
			if ((b_piece_mat == PIECE_VALUES[PIECE_ROOK] + PIECE_VALUES[PIECE_BISHOP] ||
			     b_piece_mat == PIECE_VALUES[PIECE_ROOK] + PIECE_VALUES[PIECE_KNIGHT]) &&
			     w_piece_mat == PIECE_VALUES[PIECE_ROOK]) score /= 2;
		}
	}

	return score;
}

// Sort by captures first (MVV: most-valuable victim first), then non-captures.
// Uses insertion sort — cache-friendly and fast for small lists (< ~50 moves).
void order_moves(MoveList &moves) {
	for (int i = 1; i < moves.count; ++i) {
		Move key = moves.moves[i];
		int j = i - 1;
		while (j >= 0) {
			const Move &m = moves.moves[j];
			// key should go before m if: key is capture and m is not, or both captures and key victim > m victim
			bool key_goes_before = false;
			if (key.is_capture() && !m.is_capture()) {
				key_goes_before = true;
			} else if (key.is_capture() && m.is_capture()) {
				key_goes_before = PIECE_VALUES[key.captured_type] > PIECE_VALUES[m.captured_type];
			}
			if (!key_goes_before) break;
			moves.moves[j + 1] = moves.moves[j];
			--j;
		}
		moves.moves[j + 1] = key;
	}
}

int quiescence(SearchState &state, int alpha, int beta, SearchContext &ctx, int depth) {
	// Timeout: return static eval immediately, no move generation.
	if (godot::Time::get_singleton()->get_ticks_msec() >= ctx.deadline_ms) {
		const int eval = evaluate_position(state);
		return state.active_color == WHITE ? eval : -eval;
	}

	const bool in_check = state.is_in_check(state.active_color);

	// Depth limit (only when not in check — checks are always extended).
	if (depth <= -QSEARCH_MAX_DEPTH && !in_check) {
		const int eval = evaluate_position(state);
		return state.active_color == WHITE ? eval : -eval;
	}

	int best_value = -100000;

	// Standing pat: valid only when not in check.
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

	// Generate moves: all legal evasions when in check; tactical only otherwise.
	MoveList qmoves;
	const int moving_color = state.active_color;
	if (in_check) {
		state.generate_pseudo_legal_moves_for_color(state.active_color, qmoves);
		if (qmoves.count == 0) {
			return -MATE_SCORE;
		}
	} else {
		state.generate_tactical_moves(qmoves);
		if (qmoves.count == 0) {
			return best_value; // Standing pat
		}
	}

	order_moves(qmoves);

	const int delta_margin = 150;

	for (int i = 0; i < qmoves.count; ++i) {
		const Move &mv = qmoves.moves[i];

		// Delta pruning: skip captures unlikely to raise alpha (not in check only).
		if (!in_check && mv.is_capture() && depth <= -1) {
			if (best_value + PIECE_VALUES[mv.captured_type] + delta_margin <= alpha) {
				continue;
			}
		}

		state.make_move(mv);

		// Legality filter: all paths now use pseudo-legal generation.
		if (state.is_in_check(moving_color)) {
			state.unmake_move();
			continue;
		}

		// Hanging piece heuristic: skip bad trades in shallow qsearch.
		if (mv.is_capture() && depth >= -2) {
			// After make_move, active_color is the opponent; check if they defend mv.to.
			const bool defended = state.is_square_attacked(mv.to, state.active_color);
			if (defended && PIECE_VALUES[mv.captured_type] < PIECE_VALUES[mv.piece_type]) {
				state.unmake_move();
				continue;
			}
		}

		// Check extension: if our move gives check, search one ply deeper.
		const int check_ext = state.is_in_check(state.active_color) ? 1 : 0;

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
