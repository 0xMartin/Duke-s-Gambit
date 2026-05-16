#ifndef DUKES_AI_STATE_H
#define DUKES_AI_STATE_H

#include "ai_constants.h"

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

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
	std::vector<Move> pawn_moves(int idx, int color) const;
	std::vector<Move> knight_moves(int idx, int color) const;
	std::vector<Move> slider_moves(int idx, int color, const std::vector<std::array<int, 2>> &dirs) const;
	std::vector<Move> king_moves(int idx, int color) const;
	std::vector<Move> generate_pseudo_legal_moves_for_color(int color) const;
	std::vector<Move> generate_legal_moves();
	int count_pseudo_moves(int color) const;
	uint64_t hash_key() const;
};

struct SearchContext {
	std::unordered_map<int, Move> killer_moves;
	std::unordered_map<uint64_t, TTEntry> tt;
	uint64_t deadline_ms = 0;
	bool timed_out = false;
};

} // namespace dukes_ai
} // namespace godot

// Must be called once before any search - initializes Zobrist random tables
namespace godot { namespace dukes_ai { void init_zobrist(); } }

#endif // DUKES_AI_STATE_H
