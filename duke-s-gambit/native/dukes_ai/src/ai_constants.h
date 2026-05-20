// ai_constants.h
// Duke's Gambit AI — Core constants, enums and global table externs.
// Part 1 of the engine: board representation, magic bitboards, move generation.
//
// Conventions:
//   * Squares are LERF (Little-Endian Rank-File). a1 = 0, h1 = 7, a8 = 56, h8 = 63.
//   * Files run a..h as bits 0..7 within a rank.
//   * External piece codes (Godot side): 0 = empty, 1..6 = white P/N/B/R/Q/K,
//     7..12 = black P/N/B/R/Q/K.
//   * Internal: PieceType { PAWN=0, KNIGHT, BISHOP, ROOK, QUEEN, KING, NONE=6 }
//                Color    { WHITE=0, BLACK=1 }

#ifndef DUKES_AI_CONSTANTS_H
#define DUKES_AI_CONSTANTS_H

#include <array>
#include <cstdint>

namespace dukes_ai {

inline constexpr const char *AI_VERSION = "1.0.1-cpp";

// ---------------------------------------------------------------------------
// Basic types
// ---------------------------------------------------------------------------
using Bitboard = uint64_t;

enum Color : uint8_t {
	WHITE = 0,
	BLACK = 1,
	NUM_COLORS = 2,
};

enum PieceType : uint8_t {
	PAWN = 0,
	KNIGHT = 1,
	BISHOP = 2,
	ROOK = 3,
	QUEEN = 4,
	KING = 5,
	NUM_PIECE_TYPES = 6,
	PT_NONE = 6,
};

enum Square : int8_t {
	SQ_NONE = -1,
	A1 = 0, B1, C1, D1, E1, F1, G1, H1,
	A2,     B2, C2, D2, E2, F2, G2, H2,
	A3,     B3, C3, D3, E3, F3, G3, H3,
	A4,     B4, C4, D4, E4, F4, G4, H4,
	A5,     B5, C5, D5, E5, F5, G5, H5,
	A6,     B6, C6, D6, E6, F6, G6, H6,
	A7,     B7, C7, D7, E7, F7, G7, H7,
	A8,     B8, C8, D8, E8, F8, G8, H8,
	NUM_SQUARES = 64,
};

// Castling-rights bitmask. Matches the Godot side convention.
enum CastlingFlag : uint8_t {
	CR_WK = 1, // White king-side
	CR_WQ = 2, // White queen-side
	CR_BK = 4, // Black king-side
	CR_BQ = 8, // Black queen-side
	CR_WHITE = CR_WK | CR_WQ,
	CR_BLACK = CR_BK | CR_BQ,
	CR_ALL = 15,
};

// Move flag (top 2 bits of Move::data).
enum MoveFlag : uint8_t {
	MF_NORMAL = 0,
	MF_PROMOTION = 1,
	MF_EN_PASSANT = 2,
	MF_CASTLING = 3,
};

// ---------------------------------------------------------------------------
// File / Rank constants
// ---------------------------------------------------------------------------
inline constexpr Bitboard FILE_A_BB = 0x0101010101010101ULL;
inline constexpr Bitboard FILE_B_BB = FILE_A_BB << 1;
inline constexpr Bitboard FILE_C_BB = FILE_A_BB << 2;
inline constexpr Bitboard FILE_D_BB = FILE_A_BB << 3;
inline constexpr Bitboard FILE_E_BB = FILE_A_BB << 4;
inline constexpr Bitboard FILE_F_BB = FILE_A_BB << 5;
inline constexpr Bitboard FILE_G_BB = FILE_A_BB << 6;
inline constexpr Bitboard FILE_H_BB = FILE_A_BB << 7;

inline constexpr Bitboard RANK_1_BB = 0x00000000000000FFULL;
inline constexpr Bitboard RANK_2_BB = RANK_1_BB << (8 * 1);
inline constexpr Bitboard RANK_3_BB = RANK_1_BB << (8 * 2);
inline constexpr Bitboard RANK_4_BB = RANK_1_BB << (8 * 3);
inline constexpr Bitboard RANK_5_BB = RANK_1_BB << (8 * 4);
inline constexpr Bitboard RANK_6_BB = RANK_1_BB << (8 * 5);
inline constexpr Bitboard RANK_7_BB = RANK_1_BB << (8 * 6);
inline constexpr Bitboard RANK_8_BB = RANK_1_BB << (8 * 7);

inline constexpr Bitboard EDGES_BB = FILE_A_BB | FILE_H_BB | RANK_1_BB | RANK_8_BB;

inline constexpr int file_of(int sq) { return sq & 7; }
inline constexpr int rank_of(int sq) { return sq >> 3; }
inline constexpr int square_of(int file, int rank) { return (rank << 3) | file; }

inline constexpr Bitboard square_bb(int sq) { return Bitboard(1) << sq; }

// ---------------------------------------------------------------------------
// Piece values (centipawns). Used for MVV-LVA, SEE and material eval.
// ---------------------------------------------------------------------------
inline constexpr int PIECE_VALUE_MG[NUM_PIECE_TYPES] = {
	100,   // PAWN
	320,   // KNIGHT
	330,   // BISHOP
	500,   // ROOK
	900,   // QUEEN
	20000, // KING
};

inline constexpr int PIECE_VALUE_EG[NUM_PIECE_TYPES] = {
	120,   // PAWN
	320,   // KNIGHT
	330,   // BISHOP
	520,   // ROOK
	930,   // QUEEN
	20000, // KING
};

// MVV-LVA: simple value used by move-ordering (victim - attacker scaled).
inline constexpr int MVV_LVA_VICTIM[NUM_PIECE_TYPES] = {
	100, 320, 330, 500, 900, 20000,
};

// ---------------------------------------------------------------------------
// Godot piece-type mapping. The Godot side (ChessEnums.PieceType) uses:
//     NONE=0, PAWN=1, ROOK=2, KNIGHT=3, BISHOP=4, QUEEN=5, KING=6
// External codes on the wire are: code = godot_piece_type + (BLACK ? 6 : 0).
// We translate to/from our internal PieceType (PAWN=0..KING=5) via tables.
// ---------------------------------------------------------------------------
inline constexpr uint8_t GODOT_TO_INTERNAL_PT[7] = {
	PT_NONE, // 0 = NONE
	PAWN,    // 1 = PAWN
	ROOK,    // 2 = ROOK
	KNIGHT,  // 3 = KNIGHT
	BISHOP,  // 4 = BISHOP
	QUEEN,   // 5 = QUEEN
	KING,    // 6 = KING
};

inline constexpr int INTERNAL_TO_GODOT_PT[NUM_PIECE_TYPES] = {
	1, // PAWN   -> Godot PAWN
	3, // KNIGHT -> Godot KNIGHT
	4, // BISHOP -> Godot BISHOP
	2, // ROOK   -> Godot ROOK
	5, // QUEEN  -> Godot QUEEN
	6, // KING   -> Godot KING
};

// External piece code (Godot wire) -> internal (color, piece_type). Returns
// piece_type == PT_NONE for empty squares.
struct ExternalPiece {
	uint8_t color;
	uint8_t type;
};

inline constexpr ExternalPiece decode_external_piece(int code) {
	if (code <= 0 || code > 12) {
		return { WHITE, PT_NONE };
	}
	uint8_t c = (code <= 6) ? WHITE : BLACK;
	int godot_pt = (code <= 6) ? code : (code - 6);
	return { c, GODOT_TO_INTERNAL_PT[godot_pt] };
}

inline constexpr int encode_external_piece(uint8_t color, uint8_t type) {
	if (type >= PT_NONE) {
		return 0;
	}
	return INTERNAL_TO_GODOT_PT[type] + (color == BLACK ? 6 : 0);
}

// ---------------------------------------------------------------------------
// Zobrist hashing tables (initialised by init_tables()).
// ---------------------------------------------------------------------------
extern uint64_t ZOBRIST_PIECES[NUM_COLORS][NUM_PIECE_TYPES][NUM_SQUARES];
extern uint64_t ZOBRIST_CASTLING[16];
extern uint64_t ZOBRIST_EP_FILE[8];
extern uint64_t ZOBRIST_SIDE;

// ---------------------------------------------------------------------------
// Pre-computed non-sliding attack tables (initialised by init_tables()).
// ---------------------------------------------------------------------------
extern Bitboard KNIGHT_ATTACKS[NUM_SQUARES];
extern Bitboard KING_ATTACKS[NUM_SQUARES];
extern Bitboard PAWN_ATTACKS[NUM_COLORS][NUM_SQUARES];

// ---------------------------------------------------------------------------
// Plain Magic Bitboard tables (initialised by init_tables()).
// Each square has its own attack table indexed by:
//      idx = ((occupancy & mask) * magic) >> shift
// ---------------------------------------------------------------------------
struct Magic {
	Bitboard mask;       // Relevant blocker mask (edges excluded along the ray).
	Bitboard magic;      // Magic multiplier.
	const Bitboard *attacks; // Pointer into the per-square attack table.
	uint8_t shift;       // 64 - popcount(mask).
};

extern Magic ROOK_MAGICS[NUM_SQUARES];
extern Magic BISHOP_MAGICS[NUM_SQUARES];

// One-time initialisation. Safe to call multiple times.
void init_tables();

inline Bitboard rook_attacks(int sq, Bitboard occ) {
	const Magic &m = ROOK_MAGICS[sq];
	return m.attacks[((occ & m.mask) * m.magic) >> m.shift];
}

inline Bitboard bishop_attacks(int sq, Bitboard occ) {
	const Magic &m = BISHOP_MAGICS[sq];
	return m.attacks[((occ & m.mask) * m.magic) >> m.shift];
}

inline Bitboard queen_attacks(int sq, Bitboard occ) {
	return rook_attacks(sq, occ) | bishop_attacks(sq, occ);
}

} // namespace dukes_ai

#endif // DUKES_AI_CONSTANTS_H
