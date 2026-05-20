// ai_eval.cpp
// Duke's Gambit AI — Tapered PeSTO Piece-Square Table evaluation.
//
// Reference PeSTO tables by Ronald Friederich (public domain), as published on
// the Chess Programming Wiki. We combine the per-piece material value into the
// PSQT and pre-flip black squares so the hot path is a simple bitboard sum.

#include "ai_eval.h"

#include <atomic>
#include <bit>

namespace dukes_ai {

// ---------------------------------------------------------------------------
// PeSTO base material values (centipawns), MG and EG.
// ---------------------------------------------------------------------------
static constexpr int MG_VALUE[6] = { 82, 337, 365, 477, 1025, 0 };
static constexpr int EG_VALUE[6] = { 94, 281, 297, 512,  936, 0 };

// PeSTO Piece-Square Tables. Index 0 = a1 (LERF), index 63 = h8.
// White tables. Black tables are mirrored at runtime (sq ^ 56).
// Tables are laid out rank 8..rank 1 visually (top-down) for readability —
// we flip to LERF when building the combined PSQT.

// ----- Middle game -----
static constexpr int MG_PAWN_TABLE[64] = {
	  0,   0,   0,   0,   0,   0,  0,   0,
	 98, 134,  61,  95,  68, 126, 34, -11,
	 -6,   7,  26,  31,  65,  56, 25, -20,
	-14,  13,   6,  21,  23,  12, 17, -23,
	-27,  -2,  -5,  12,  17,   6, 10, -25,
	-26,  -4,  -4, -10,   3,   3, 33, -12,
	-35,  -1, -20, -23, -15,  24, 38, -22,
	  0,   0,   0,   0,   0,   0,  0,   0,
};
static constexpr int MG_KNIGHT_TABLE[64] = {
	-167, -89, -34, -49,  61, -97, -15, -107,
	 -73, -41,  72,  36,  23,  62,   7,  -17,
	 -47,  60,  37,  65,  84, 129,  73,   44,
	  -9,  17,  19,  53,  37,  69,  18,   22,
	 -13,   4,  16,  13,  28,  19,  21,   -8,
	 -23,  -9,  12,  10,  19,  17,  25,  -16,
	 -29, -53, -12,  -3,  -1,  18, -14,  -19,
	-105, -21, -58, -33, -17, -28, -19,  -23,
};
static constexpr int MG_BISHOP_TABLE[64] = {
	-29,   4, -82, -37, -25, -42,   7,  -8,
	-26,  16, -18, -13,  30,  59,  18, -47,
	-16,  37,  43,  40,  35,  50,  37,  -2,
	 -4,   5,  19,  50,  37,  37,   7,  -2,
	 -6,  13,  13,  26,  34,  12,  10,   4,
	  0,  15,  15,  15,  14,  27,  18,  10,
	  4,  15,  16,   0,   7,  21,  33,   1,
	-33,  -3, -14, -21, -13, -12, -39, -21,
};
static constexpr int MG_ROOK_TABLE[64] = {
	 32,  42,  32,  51, 63,  9,  31,  43,
	 27,  32,  58,  62, 80, 67,  26,  44,
	 -5,  19,  26,  36, 17, 45,  61,  16,
	-24, -11,   7,  26, 24, 35,  -8, -20,
	-36, -26, -12,  -1,  9, -7,   6, -23,
	-45, -25, -16, -17,  3,  0,  -5, -33,
	-44, -16, -20,  -9, -1, 11,  -6, -71,
	-19, -13,   1,  17, 16,  7, -37, -26,
};
static constexpr int MG_QUEEN_TABLE[64] = {
	-28,   0,  29,  12,  59,  44,  43,  45,
	-24, -39,  -5,   1, -16,  57,  28,  54,
	-13, -17,   7,   8,  29,  56,  47,  57,
	-27, -27, -16, -16,  -1,  17,  -2,   1,
	 -9, -26,  -9, -10,  -2,  -4,   3,  -3,
	-14,   2, -11,  -2,  -5,   2,  14,   5,
	-35,  -8,  11,   2,   8,  15,  -3,   1,
	 -1, -18,  -9,  10, -15, -25, -31, -50,
};
static constexpr int MG_KING_TABLE[64] = {
	-65,  23,  16, -15, -56, -34,   2,  13,
	 29,  -1, -20,  -7,  -8,  -4, -38, -29,
	 -9,  24,   2, -16, -20,   6,  22, -22,
	-17, -20, -12, -27, -30, -25, -14, -36,
	-49,  -1, -27, -39, -46, -44, -33, -51,
	-14, -14, -22, -46, -44, -30, -15, -27,
	  1,   7,  -8, -64, -43, -16,   9,   8,
	-15,  36,  12, -54,   8, -28,  24,  14,
};

// ----- End game -----
static constexpr int EG_PAWN_TABLE[64] = {
	  0,   0,   0,   0,   0,   0,   0,   0,
	178, 173, 158, 134, 147, 132, 165, 187,
	 94, 100,  85,  67,  56,  53,  82,  84,
	 32,  24,  13,   5,  -2,   4,  17,  17,
	 13,   9,  -3,  -7,  -7,  -8,   3,  -1,
	  4,   7,  -6,   1,   0,  -5,  -1,  -8,
	 13,   8,   8,  10,  13,   0,   2,  -7,
	  0,   0,   0,   0,   0,   0,   0,   0,
};
static constexpr int EG_KNIGHT_TABLE[64] = {
	-58, -38, -13, -28, -31, -27, -63, -99,
	-25,  -8, -25,  -2,  -9, -25, -24, -52,
	-24, -20,  10,   9,  -1,  -9, -19, -41,
	-17,   3,  22,  22,  22,  11,   8, -18,
	-18,  -6,  16,  25,  16,  17,   4, -18,
	-23,  -3,  -1,  15,  10,  -3, -20, -22,
	-42, -20, -10,  -5,  -2, -20, -23, -44,
	-29, -51, -23, -15, -22, -18, -50, -64,
};
static constexpr int EG_BISHOP_TABLE[64] = {
	-14, -21, -11,  -8, -7,  -9, -17, -24,
	 -8,  -4,   7, -12, -3, -13,  -4, -14,
	  2,  -8,   0,  -1, -2,   6,   0,   4,
	 -3,   9,  12,   9, 14,  10,   3,   2,
	 -6,   3,  13,  19,  7,  10,  -3,  -9,
	-12,  -3,   8,  10, 13,   3,  -7, -15,
	-14, -18,  -7,  -1,  4,  -9, -15, -27,
	-23,  -9, -23,  -5, -9, -16,  -5, -17,
};
static constexpr int EG_ROOK_TABLE[64] = {
	13, 10, 18, 15, 12,  12,   8,   5,
	11, 13, 13, 11, -3,   3,   8,   3,
	 7,  7,  7,  5,  4,  -3,  -5,  -3,
	 4,  3, 13,  1,  2,   1,  -1,   2,
	 3,  5,  8,  4, -5,  -6,  -8, -11,
	-4,  0, -5, -1, -7, -12,  -8, -16,
	-6, -6,  0,  2, -9,  -9, -11,  -3,
	-9,  2,  3, -1, -5, -13,   4, -20,
};
static constexpr int EG_QUEEN_TABLE[64] = {
	 -9,  22,  22,  27,  27,  19,  10,  20,
	-17,  20,  32,  41,  58,  25,  30,   0,
	-20,   6,   9,  49,  47,  35,  19,   9,
	  3,  22,  24,  45,  57,  40,  57,  36,
	-18,  28,  19,  47,  31,  34,  39,  23,
	-16, -27,  15,   6,   9,  17,  10,   5,
	-22, -23, -30, -16, -16, -23, -36, -32,
	-33, -28, -22, -43,  -5, -32, -20, -41,
};
static constexpr int EG_KING_TABLE[64] = {
	-74, -35, -18, -18, -11,  15,   4, -17,
	-12,  17,  14,  17,  17,  38,  23,  11,
	 10,  17,  23,  15,  20,  45,  44,  13,
	 -8,  22,  24,  27,  26,  33,  26,   3,
	-18,  -4,  21,  24,  27,  23,   9, -11,
	-19,  -3,  11,  21,  23,  16,   7,  -9,
	-27, -11,   4,  13,  14,   4,  -5, -17,
	-53, -34, -21, -11, -28, -14, -24, -43,
};

// ---------------------------------------------------------------------------
// Combined PSQT tables (material + positional) per phase, indexed by
// [color][piece_type][square]. Built in init_eval().
// ---------------------------------------------------------------------------
static int MG_TABLE[NUM_COLORS][NUM_PIECE_TYPES][NUM_SQUARES];
static int EG_TABLE[NUM_COLORS][NUM_PIECE_TYPES][NUM_SQUARES];

static const int *MG_RAW[6] = {
	MG_PAWN_TABLE, MG_KNIGHT_TABLE, MG_BISHOP_TABLE,
	MG_ROOK_TABLE, MG_QUEEN_TABLE,  MG_KING_TABLE,
};
static const int *EG_RAW[6] = {
	EG_PAWN_TABLE, EG_KNIGHT_TABLE, EG_BISHOP_TABLE,
	EG_ROOK_TABLE, EG_QUEEN_TABLE,  EG_KING_TABLE,
};

// The raw tables above list rank 8 first, rank 1 last (chessboard top-down).
// Our internal squares use LERF (a1 = 0). Map raw_index -> LERF.
static inline int raw_to_lerf(int raw_idx) {
	int raw_file = raw_idx & 7;
	int raw_rank_from_top = raw_idx >> 3;     // 0 = rank 8, 7 = rank 1
	int rank = 7 - raw_rank_from_top;         // LERF rank
	return (rank << 3) | raw_file;
}

// Game-phase weights (PeSTO). Pawn/king contribute 0.
static constexpr int PHASE_WEIGHT[6] = { 0, 1, 1, 2, 4, 0 };
static constexpr int MAX_PHASE = 24;

static std::atomic<bool> g_eval_ready{ false };

void init_eval() {
	if (g_eval_ready.load(std::memory_order_acquire)) {
		return;
	}
	for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
		for (int raw = 0; raw < 64; ++raw) {
			int sq_white = raw_to_lerf(raw);
			int sq_black = sq_white ^ 56;
			MG_TABLE[WHITE][pt][sq_white] = MG_VALUE[pt] + MG_RAW[pt][raw];
			EG_TABLE[WHITE][pt][sq_white] = EG_VALUE[pt] + EG_RAW[pt][raw];
			MG_TABLE[BLACK][pt][sq_black] = MG_VALUE[pt] + MG_RAW[pt][raw];
			EG_TABLE[BLACK][pt][sq_black] = EG_VALUE[pt] + EG_RAW[pt][raw];
		}
	}
	g_eval_ready.store(true, std::memory_order_release);
}

int game_phase(const SearchState &s) {
	int phase = 0;
	for (int c = 0; c < NUM_COLORS; ++c) {
		phase += std::popcount(s.pieces[c][KNIGHT]) * PHASE_WEIGHT[KNIGHT];
		phase += std::popcount(s.pieces[c][BISHOP]) * PHASE_WEIGHT[BISHOP];
		phase += std::popcount(s.pieces[c][ROOK])   * PHASE_WEIGHT[ROOK];
		phase += std::popcount(s.pieces[c][QUEEN])  * PHASE_WEIGHT[QUEEN];
	}
	if (phase > MAX_PHASE) phase = MAX_PHASE;
	return phase;
}

int evaluate(const SearchState &s) {
	int mg[2] = { 0, 0 };
	int eg[2] = { 0, 0 };

	for (int c = 0; c < NUM_COLORS; ++c) {
		for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
			Bitboard b = s.pieces[c][pt];
			while (b) {
				int sq = std::countr_zero(b);
				b &= b - 1;
				mg[c] += MG_TABLE[c][pt][sq];
				eg[c] += EG_TABLE[c][pt][sq];
			}
		}
	}

	const int us = s.side_to_move;
	const int them = 1 - us;
	const int mg_score = mg[us] - mg[them];
	const int eg_score = eg[us] - eg[them];

	// Linear interpolation by phase: full MG at phase==24, full EG at phase==0.
	int phase = game_phase(s);
	int score = (mg_score * phase + eg_score * (MAX_PHASE - phase)) / MAX_PHASE;

	// ---- King safety / castling bonus (MG only) ----------------------------
	// Reward an already-castled king and, to a lesser extent, retained castling
	// rights so the engine actually spends a tempo on castling. Scaled by phase
	// so the term fades to 0 in the endgame where the king belongs in the centre.
	constexpr int CASTLED_BONUS = 40;
	constexpr int RIGHTS_BONUS  = 15;
	auto king_safety = [&](int c) -> int {
		int ksq = std::countr_zero(s.pieces[c][KING]);
		if (c == WHITE) {
			if (ksq == G1 || ksq == C1) return CASTLED_BONUS;
			if (s.castling_rights & CR_WHITE) return RIGHTS_BONUS;
		} else {
			if (ksq == G8 || ksq == C8) return CASTLED_BONUS;
			if (s.castling_rights & CR_BLACK) return RIGHTS_BONUS;
		}
		return 0;
	};
	int ks_diff = king_safety(us) - king_safety(them);
	score += (ks_diff * phase) / MAX_PHASE;

	return score;
}

} // namespace dukes_ai
