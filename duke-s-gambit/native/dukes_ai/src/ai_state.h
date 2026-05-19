#ifndef DUKES_AI_STATE_H
#define DUKES_AI_STATE_H

#include "ai_constants.h"

#include <array>
#include <cstdint>
#include <string>

namespace godot {
namespace dukes_ai {

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

// Stack-allocated move list — zero heap allocation in the search tree.
struct MoveList {
	std::array<Move, 256> moves;
	int count = 0;
	inline void push(const Move &m) { moves[count++] = m; }
	inline Move *begin() { return moves.data(); }
	inline Move *end() { return moves.data() + count; }
	inline size_t size() const { return static_cast<size_t>(count); }
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
	uint64_t prev_zobrist_hash = 0;
};

struct TTEntry {
	uint64_t key = 0;
	int depth = -1;
	int score = 0;
	int flag = TT_EXACT;
	uint32_t generation = 0;
};

struct SearchState {
	std::array<int, 64> board{};
	std::array<uint64_t, 13> piece_bb{};
	int active_color = WHITE;
	int castling_rights = 0b1111;
	int en_passant_index = -1;
	int halfmove_clock = 0;
	int fullmove_number = 1;
	std::array<UndoState, 512> history_stack;
	int history_count = 0;
	uint64_t zobrist_hash = 0;

	static int sq_to_index(int col, int row);
	static int idx_col(int idx);
	static int idx_row(int idx);
	static int piece_code(int piece_type, int color);
	static int piece_type_from_code(int code);
	static int piece_color_from_code(int code);

	void clear_square(int idx);
	void set_square(int idx, int code);
	bool is_square_attacked(int idx, int by_color) const;
	bool is_in_check(int color) const;
	void update_castling_rights(const Move &mv);
	void make_move(const Move &mv);
	void unmake_move();
	bool can_castle_kingside(int color, int king_idx) const;
	bool can_castle_queenside(int color, int king_idx) const;
	void pawn_moves(int idx, int color, MoveList &list) const;
	void knight_moves(int idx, int color, MoveList &list) const;
	void slider_moves(int idx, int color, const int (*dirs)[2], int ndir, MoveList &list) const;
	void king_moves(int idx, int color, MoveList &list) const;
	void generate_pseudo_legal_moves_for_color(int color, MoveList &list) const;
	void generate_legal_moves(MoveList &list);
	void generate_tactical_moves(MoveList &list);
	int count_pseudo_moves(int color) const;
	uint64_t hash_key() const;
};

struct SearchContext {
	std::array<Move, 64> killer_moves;
	Move counter_moves[64][64]; // counter move for previous (from,to)
	int history[64][64]; // history[from][to] for quiet move ordering
	uint64_t deadline_ms = 0;
	bool timed_out = false;
	SearchContext() : killer_moves(), deadline_ms(0), timed_out(false) {
		for (int i = 0; i < 64; ++i)
			for (int j = 0; j < 64; ++j)
				counter_moves[i][j] = Move();
		for (int i = 0; i < 64; ++i)
			for (int j = 0; j < 64; ++j)
				history[i][j] = 0;
	}
};

} // namespace dukes_ai
} // namespace godot

// Must be called once before any search - initializes Zobrist random tables
namespace godot { namespace dukes_ai { void init_zobrist(); } }

#endif // DUKES_AI_STATE_H
