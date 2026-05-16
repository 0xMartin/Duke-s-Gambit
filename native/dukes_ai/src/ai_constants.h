#ifndef DUKES_AI_CONSTANTS_H
#define DUKES_AI_CONSTANTS_H

#include <array>
#include <cstdint>

namespace godot {
namespace dukes_ai {

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
constexpr const char *AI_VERSION = "dukes_ai_native/1.0.0";
constexpr int QSEARCH_MAX_DEPTH = 6;  // Increased for better tactical vision

inline constexpr std::array<int, 7> PIECE_VALUES = {0, 100, 500, 320, 330, 900, 40000};

// Zobrist random numbers - initialized at runtime via init_zobrist() with a fixed seed.
// Must call init_zobrist() once before any search.
extern uint64_t ZOBRIST_PIECES[13][64];
extern uint64_t ZOBRIST_ACTIVE_COLOR;
extern uint64_t ZOBRIST_CASTLING[16];
extern uint64_t ZOBRIST_EN_PASSANT[8];

inline constexpr int PAWN_PST[8][8] = {
	{0, 0, 0, 0, 0, 0, 0, 0},
	{50, 50, 50, 50, 50, 50, 50, 50},
	{10, 10, 20, 30, 30, 20, 10, 10},
	{5, 5, 10, 25, 25, 10, 5, 5},
	{0, 0, 0, 20, 20, 0, 0, 0},
	{5, -5, -10, 0, 0, -10, -5, 5},
	{5, 10, 10, -20, -20, 10, 10, 5},
	{0, 0, 0, 0, 0, 0, 0, 0},
};

inline constexpr int KNIGHT_PST[8][8] = {
	{-50, -40, -30, -30, -30, -30, -40, -50},
	{-40, -20, 0, 0, 0, 0, -20, -40},
	{-30, 0, 10, 15, 15, 10, 0, -30},
	{-30, 5, 15, 20, 20, 15, 5, -30},
	{-30, 0, 15, 20, 20, 15, 0, -30},
	{-30, 5, 10, 15, 15, 10, 5, -30},
	{-40, -20, 0, 5, 5, 0, -20, -40},
	{-50, -40, -30, -30, -30, -30, -40, -50},
};

inline constexpr int BISHOP_PST[8][8] = {
	{-20, -10, -10, -10, -10, -10, -10, -20},
	{-10, 0, 0, 0, 0, 0, 0, -10},
	{-10, 0, 5, 10, 10, 5, 0, -10},
	{-10, 5, 5, 10, 10, 5, 5, -10},
	{-10, 0, 10, 10, 10, 10, 0, -10},
	{-10, 10, 10, 10, 10, 10, 10, -10},
	{-10, 5, 0, 0, 0, 0, 5, -10},
	{-20, -10, -10, -10, -10, -10, -10, -20},
};

inline constexpr int ROOK_PST[8][8] = {
	{0, 0, 0, 0, 0, 0, 0, 0},
	{5, 10, 10, 10, 10, 10, 10, 5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{-5, 0, 0, 0, 0, 0, 0, -5},
	{0, 0, 0, 5, 5, 0, 0, 0},
};

inline constexpr int QUEEN_PST[8][8] = {
	{-20, -10, -10, -5, -5, -10, -10, -20},
	{-10, 0, 0, 0, 0, 0, 0, -10},
	{-10, 0, 5, 5, 5, 5, 0, -10},
	{-5, 0, 5, 5, 5, 5, 0, -5},
	{0, 0, 5, 5, 5, 5, 0, -5},
	{-10, 5, 5, 5, 5, 5, 0, -10},
	{-10, 0, 5, 0, 0, 0, 0, -10},
	{-20, -10, -10, -5, -5, -10, -10, -20},
};

inline constexpr int KING_EARLY[8][8] = {
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-30, -40, -40, -50, -50, -40, -40, -30},
	{-20, -30, -30, -40, -40, -30, -30, -20},
	{-10, -20, -20, -20, -20, -20, -20, -10},
	{20, 20, 0, 0, 0, 0, 20, 20},
	{20, 30, 10, 0, 0, 10, 30, 20},
};

inline constexpr int KING_END[8][8] = {
	{-50, -40, -30, -20, -20, -30, -40, -50},
	{-30, -20, -10, 0, 0, -10, -20, -30},
	{-30, -10, 20, 30, 30, 20, -10, -30},
	{-30, -10, 30, 40, 40, 30, -10, -30},
	{-30, -10, 30, 40, 40, 30, -10, -30},
	{-30, -10, 20, 30, 30, 20, -10, -30},
	{-30, -30, 0, 0, 0, 0, -30, -30},
	{-50, -30, -30, -30, -30, -30, -30, -50},
};

} // namespace dukes_ai
} // namespace godot

#endif // DUKES_AI_CONSTANTS_H
