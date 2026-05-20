// ai_state.h
// Duke's Gambit AI — Move, MoveList, UndoState and SearchState.

#ifndef DUKES_AI_STATE_H
#define DUKES_AI_STATE_H

#include "ai_constants.h"

#include <array>
#include <cstdint>

namespace dukes_ai {

// ---------------------------------------------------------------------------
// Move — packed 16-bit encoding (Stockfish-style).
//   bits  0-5 : from square
//   bits  6-11: to square
//   bits 12-13: promotion piece type minus knight (0=N, 1=B, 2=R, 3=Q)
//   bits 14-15: MoveFlag
// ---------------------------------------------------------------------------
struct Move {
	uint16_t data;

	constexpr Move() : data(0) {}
	constexpr explicit Move(uint16_t d) : data(d) {}

	static constexpr Move make(int from, int to, MoveFlag flag = MF_NORMAL, int promo_pt = KNIGHT) {
		uint16_t d = uint16_t(from & 0x3F)
				| (uint16_t(to & 0x3F) << 6)
				| (uint16_t((promo_pt - KNIGHT) & 0x3) << 12)
				| (uint16_t(flag & 0x3) << 14);
		return Move(d);
	}

	constexpr int from()     const { return data & 0x3F; }
	constexpr int to()       const { return (data >> 6) & 0x3F; }
	constexpr MoveFlag flag() const { return MoveFlag((data >> 14) & 0x3); }
	constexpr int promotion_type() const { return KNIGHT + ((data >> 12) & 0x3); }
	constexpr bool is_null()  const { return data == 0; }
	constexpr bool operator==(Move o) const { return data == o.data; }
	constexpr bool operator!=(Move o) const { return data != o.data; }
};

inline constexpr Move MOVE_NONE = Move(0);

// ---------------------------------------------------------------------------
// MoveList — stack-allocated buffer used by the move generator.
// No heap allocation. Max 256 covers all legal chess positions.
// ---------------------------------------------------------------------------
struct MoveList {
	std::array<Move, 256> moves;
	std::array<int32_t, 256> scores;
	int count = 0;

	void clear() { count = 0; }
	void add(Move m) { moves[count] = m; scores[count] = 0; ++count; }
	int size() const { return count; }
	Move operator[](int i) const { return moves[i]; }
};

// ---------------------------------------------------------------------------
// UndoState — everything needed to reverse one make_move().
// ---------------------------------------------------------------------------
struct UndoState {
	uint64_t zobrist;       // Hash before the move.
	uint8_t  castling;      // Castling rights before the move.
	int8_t   ep_square;     // En passant target before the move (-1 if none).
	uint8_t  halfmove_clock;// 50-move clock before the move.
	uint8_t  captured_type; // PieceType captured (PT_NONE if quiet/non-capture).
	uint8_t  captured_color;// Color of captured piece (only valid if captured_type < PT_NONE).
	int8_t   captured_sq;   // Square the captured piece was on (handles EP).
	uint8_t  moved_type;    // Piece type that moved (cached, useful for unmake).
};

// ---------------------------------------------------------------------------
// SearchState — pure bitboard representation. No 8x8 mailbox in the hot loop.
// ---------------------------------------------------------------------------
struct SearchState {
	// pieces[color][type] = bitboard of pieces of that color and type.
	Bitboard pieces[NUM_COLORS][NUM_PIECE_TYPES] = {};
	// occupancy[color] = union of all pieces of that color.
	Bitboard occupancy[NUM_COLORS] = { 0, 0 };
	// occupancy_all = occupancy[WHITE] | occupancy[BLACK].
	Bitboard occupancy_all = 0;

	uint8_t  side_to_move = WHITE;
	uint8_t  castling_rights = 0;
	int8_t   ep_square = -1;
	uint8_t  halfmove_clock = 0;
	uint16_t fullmove_number = 1;
	uint16_t ply = 0; // Plies from the search root (0 at root).

	uint64_t zobrist = 0;

	// History of undo records (one per make_move).
	std::array<UndoState, 1024> undo_stack {};
	int undo_count = 0;

	// Position-hash history for repetition detection (parallel to undo stack).
	std::array<uint64_t, 1024> hash_history {};
	int hash_history_count = 0;

	// ---- Setup ----------------------------------------------------------------
	void clear();
	// Load from a Godot Dictionary already parsed into raw fields.
	//   board[64] uses the external piece code (0..12).
	//   side: 0 = white to move, 1 = black.
	//   castling: bitmask CR_*.
	//   ep_index: -1 or 0..63 (LERF, square 0 = a1).
	void load_position(const int32_t board[64], int side, int castling,
			int ep_index, int halfmove, int fullmove);

	// Recompute zobrist from scratch (used after load_position).
	void recompute_zobrist();

	// ---- Queries --------------------------------------------------------------
	uint8_t piece_type_on(int sq) const;
	uint8_t color_on(int sq) const;

	Bitboard attackers_to(int sq, Bitboard occ) const;
	bool is_square_attacked(int sq, int by_color) const;
	bool in_check() const;
	bool in_check(int color) const;

	// Repetition: returns true if current zobrist appears at least once earlier.
	bool is_repetition() const;

	// ---- Move generation ------------------------------------------------------
	// Pseudo-legal generation. Callers must filter for legality (king safety).
	void generate_pseudo_moves(MoveList &out) const;
	void generate_tactical_moves(MoveList &out) const; // Captures + promotions.

	// Tests legality of a pseudo-legal move from generate_*.
	bool is_legal(Move m) const;

	// ---- Make / Unmake --------------------------------------------------------
	void make_move(Move m);
	void unmake_move(Move m);

	// Null move (skip turn). Used by null-move pruning in search.
	void make_null_move();
	void unmake_null_move();

private:
	// Bitboard mutation helpers (XOR-based, also update zobrist).
	void place_piece(int color, int type, int sq);
	void remove_piece(int color, int type, int sq);
	void move_piece(int color, int type, int from, int to);
};

} // namespace dukes_ai

#endif // DUKES_AI_STATE_H
