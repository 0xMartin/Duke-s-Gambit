#include "ai_search.h"

#include "ai_constants.h"
#include "ai_eval.h"
#include "ai_state.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>

namespace godot {
namespace dukes_ai {

static uint64_t now_ms() {
	return Time::get_singleton()->get_ticks_msec();
}

static int minimax(SearchState &state, int depth, int alpha, int beta, SearchContext &ctx) {
	if (now_ms() >= ctx.deadline_ms) {
		ctx.timed_out = true;
		return quiescence(state, alpha, beta, ctx);
	}

	if (depth == 0) {
		return quiescence(state, alpha, beta, ctx);
	}

	const int alpha_orig = alpha;
	const uint64_t key = state.hash_key();
	auto it = ctx.tt.find(key);
	if (it != ctx.tt.end() && it->second.depth >= depth) {
		const TTEntry &e = it->second;
		if (e.flag == TT_EXACT) {
			return e.score;
		}
		if (e.flag == TT_LOWER) {
			alpha = std::max(alpha, e.score);
		} else if (e.flag == TT_UPPER) {
			beta = std::min(beta, e.score);
		}
		if (alpha >= beta) {
			return e.score;
		}
	}

	std::vector<Move> legal = state.generate_legal_moves();
	if (legal.empty()) {
		if (state.is_in_check(state.active_color)) {
			return -MATE_SCORE;
		}
		return 0;
	}

	order_moves(legal);
	int best_score = alpha;
	for (const Move &mv : legal) {
		state.make_move(mv);
		const int score = -minimax(state, depth - 1, -beta, -best_score, ctx);
		state.unmake_move();

		best_score = std::max(best_score, score);
		if (best_score >= beta) {
			if (!mv.is_capture()) {
				ctx.killer_moves[depth] = mv;
			}
			break;
		}
	}

	TTEntry store;
	store.depth = depth;
	store.score = best_score;
	store.flag = TT_EXACT;
	if (best_score <= alpha_orig) {
		store.flag = TT_UPPER;
	} else if (best_score >= beta) {
		store.flag = TT_LOWER;
	}
	ctx.tt[key] = store;

	return best_score;
}

static SearchState parse_position(const Dictionary &position, bool &ok) {
	SearchState s;
	ok = false;

	Variant board_var = position.get("board", PackedInt32Array());
	if (board_var.get_type() != Variant::PACKED_INT32_ARRAY) {
		return s;
	}
	PackedInt32Array packed = board_var;
	if (packed.size() != 64) {
		return s;
	}

	for (int i = 0; i < 64; ++i) {
		const int code = packed[i];
		s.board[i] = code;
		if (code >= 1 && code <= 12) {
			s.piece_bb[code] |= (uint64_t(1) << i);
		}
	}

	s.active_color = int(position.get("active_color", WHITE));
	s.castling_rights = int(position.get("castling_rights", 0b1111));
	s.en_passant_index = int(position.get("en_passant_index", -1));
	s.halfmove_clock = int(position.get("halfmove_clock", 0));
	s.fullmove_number = int(position.get("fullmove_number", 1));

	ok = true;
	return s;
}

static Dictionary move_to_dict(const Move &mv, int score, int reached_depth) {
	Dictionary d;
	d["from_col"] = SearchState::idx_col(mv.from);
	d["from_row"] = SearchState::idx_row(mv.from);
	d["to_col"] = SearchState::idx_col(mv.to);
	d["to_row"] = SearchState::idx_row(mv.to);
	d["move_type"] = mv.move_type;
	d["piece_type"] = mv.piece_type;
	d["piece_color"] = mv.piece_color;
	d["captured_type"] = mv.captured_type;
	d["promotion_type"] = mv.promotion_type;
	d["score"] = score;
	d["reached_depth"] = reached_depth;
	d["ok"] = true;
	return d;
}

Dictionary find_best_move_internal(Dictionary position, int32_t depth, int32_t time_limit_ms) {
	bool ok = false;
	SearchState state = parse_position(position, ok);
	if (!ok) {
		Dictionary err;
		err["ok"] = false;
		err["error"] = String("Invalid position payload");
		return err;
	}

	// Initialize zobrist hash from scratch
	state.zobrist_hash = 0;
	for (int idx = 0; idx < 64; ++idx) {
		const int code = state.board[idx];
		if (code != 0) {
			state.zobrist_hash ^= ZOBRIST_PIECES[code][idx];
		}
	}
	state.zobrist_hash ^= ZOBRIST_CASTLING[state.castling_rights];
	if (state.en_passant_index >= 0) {
		state.zobrist_hash ^= ZOBRIST_EN_PASSANT[state.en_passant_index % 8];
	}
	if (state.active_color == BLACK) {
		state.zobrist_hash ^= ZOBRIST_ACTIVE_COLOR;
	}

	if (depth <= 0) {
		depth = 1;
	}
	if (time_limit_ms <= 0) {
		time_limit_ms = 1000;
	}

	SearchContext ctx;
	ctx.deadline_ms = now_ms() + uint64_t(time_limit_ms);

	std::vector<Move> root_moves = state.generate_legal_moves();
	if (root_moves.empty()) {
		Dictionary none;
		none["ok"] = false;
		none["error"] = String("No legal moves");
		return none;
	}

	Move best_move = root_moves[0];
	int best_score = -100000;
	int reached_depth = 0;

	for (int current_depth = 1; current_depth <= depth; ++current_depth) {
		if (now_ms() >= ctx.deadline_ms) {
			break;
		}
		order_moves(root_moves);
		int alpha = -100000;
		const int beta = 100000;
		int depth_best_score = -100000;
		Move depth_best_move = best_move;
		bool timed_out = false;

		for (const Move &mv : root_moves) {
			if (now_ms() >= ctx.deadline_ms) {
				timed_out = true;
				break;
			}
			state.make_move(mv);
			const int mv_score = -minimax(state, current_depth - 1, -beta, -alpha, ctx);
			state.unmake_move();
			if (mv_score > depth_best_score) {
				depth_best_score = mv_score;
				depth_best_move = mv;
			}
			alpha = std::max(alpha, mv_score);
			if (alpha >= beta) {
				break;
			}
		}

		if (timed_out || ctx.timed_out) {
			break;
		}

		best_move = depth_best_move;
		best_score = depth_best_score;
		reached_depth = current_depth;
	}

	return move_to_dict(best_move, best_score, reached_depth);
}

} // namespace dukes_ai
} // namespace godot
