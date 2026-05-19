#include "ai_search.h"

#include "ai_constants.h"
#include "ai_eval.h"
#include "ai_state.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <atomic>
#include <unordered_map>
#include <vector>

namespace godot {
namespace dukes_ai {

static std::vector<TTEntry> G_PERSISTENT_TT(1048576);
static std::atomic<uint32_t> G_TT_GENERATION{0};
static constexpr size_t TT_MASK = 1048575;

static bool load_tt_entry(uint64_t key, int depth, TTEntry &out_entry) {
	const size_t index = key & TT_MASK;
	const TTEntry &entry = G_PERSISTENT_TT[index]; // intentionally lockless
	if (entry.key == key && entry.depth >= depth) {
		out_entry = entry;
		return true;
	}
	return false;
}

static void store_tt_entry(uint64_t key, TTEntry entry) {
	entry.key = key;
	const size_t index = key & TT_MASK;
	TTEntry &slot = G_PERSISTENT_TT[index]; // intentionally lockless
	if (entry.depth >= slot.depth || slot.key != key) {
		slot = entry;
	}
}

static uint64_t now_ms() {
	return Time::get_singleton()->get_ticks_msec();
}

// Move ordering: captures (MVV-LVA) > killer > history heuristic > quiet

static void order_moves_with_context(const SearchState &state, MoveList &moves, const SearchContext &ctx, int depth, int prev_from = -1, int prev_to = -1) {
	int killer_from = -1, killer_to = -1;
	int killer2_from = -1, killer2_to = -1;
	if (depth >= 0 && depth < 64) {
		killer_from  = ctx.killer_moves[depth].from;
		killer_to    = ctx.killer_moves[depth].to;
		killer2_from = ctx.killer_moves_2[depth].from;
		killer2_to   = ctx.killer_moves_2[depth].to;
	}
	Move counter;
	if (prev_from >= 0 && prev_from < 64 && prev_to >= 0 && prev_to < 64) {
		counter = ctx.counter_moves[prev_from][prev_to];
	}

	// Pass 1: score every move — pure MVV-LVA for captures.
	int move_scores[256];
	for (int i = 0; i < moves.count; ++i) {
		const Move &mv = moves.moves[i];
		if (mv.is_capture()) {
			move_scores[i] = 20000 + PIECE_VALUES[mv.captured_type] * 100 - PIECE_VALUES[mv.piece_type];
		} else if (mv.from == killer_from && mv.to == killer_to) {
			move_scores[i] = 9000;
		} else if (mv.from == killer2_from && mv.to == killer2_to) {
			move_scores[i] = 8700;
		} else if (counter.from >= 0 && mv.from == counter.from && mv.to == counter.to) {
			move_scores[i] = 8500;
		} else {
			move_scores[i] = ctx.history[mv.from][mv.to];
		}
	}

	// Pass 2: insertion sort descending by pre-calculated score.
	for (int i = 1; i < moves.count; ++i) {
		Move  key_move  = moves.moves[i];
		int   key_score = move_scores[i];
		int j = i - 1;
		while (j >= 0 && move_scores[j] < key_score) {
			moves.moves[j + 1]  = moves.moves[j];
			move_scores[j + 1] = move_scores[j];
			--j;
		}
		moves.moves[j + 1]  = key_move;
		move_scores[j + 1] = key_score;
	}
}

static int minimax(SearchState &state, int depth, int alpha, int beta, SearchContext &ctx) {
	if (godot::Time::get_singleton()->get_ticks_msec() >= ctx.deadline_ms) {
		ctx.timed_out = true;
		return quiescence(state, alpha, beta, ctx, 0);
	}

	if (depth == 0) {
		return quiescence(state, alpha, beta, ctx, 0);
	}

	const int alpha_orig = alpha;
	const uint64_t key = state.hash_key();
	TTEntry e;
	if (load_tt_entry(key, depth, e)) {
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

	const bool in_check = state.is_in_check(state.active_color);
	const bool can_futility = !in_check && depth <= 2;
	int static_eval = -100000;
	if (can_futility) {
		static_eval = evaluate_position(state);
		const int reverse_margin = (depth == 1) ? 100 : 220;
		if (static_eval - reverse_margin >= beta) {
			return static_eval - reverse_margin;
		}
	}

	// Null move pruning: skip a turn and search at reduced depth.
	// If the opponent can't improve even with a free move, we have a beta cutoff.
	if (depth >= 3 && !in_check) {
		const int base = state.active_color * 6;
		bool has_pieces = false;
		for (int pt : {PIECE_ROOK, PIECE_KNIGHT, PIECE_BISHOP, PIECE_QUEEN}) {
			if (state.piece_bb[pt + base] != 0) { has_pieces = true; break; }
		}
		if (has_pieces) {
			const int R = (depth >= 6) ? 3 : 2;
			const uint64_t saved_hash = state.zobrist_hash;
			const int saved_ep = state.en_passant_index;
			if (state.en_passant_index >= 0) {
				state.zobrist_hash ^= ZOBRIST_EN_PASSANT[SearchState::idx_col(state.en_passant_index)];
				state.en_passant_index = -1;
			}
			state.active_color = 1 - state.active_color;
			state.zobrist_hash ^= ZOBRIST_ACTIVE_COLOR;
			const int null_score = -minimax(state, depth - 1 - R, -beta, -(beta - 1), ctx);
			state.active_color = 1 - state.active_color;
			state.en_passant_index = saved_ep;
			state.zobrist_hash = saved_hash;
			if (!ctx.timed_out && null_score >= beta) {
				return beta;
			}
		}
	}

	MoveList legal;
	state.generate_pseudo_legal_moves_for_color(state.active_color, legal);
	const int moving_color = state.active_color;
	if (legal.count == 0) {
		return in_check ? -MATE_SCORE : 0;
	}

	int prev_from = -1;
	int prev_to = -1;
	if (state.history_count > 0) {
		const UndoState &last = state.history_stack[state.history_count - 1];
		prev_from = last.from_idx;
		prev_to = last.to_idx;
	}

	order_moves_with_context(state, legal, ctx, depth, prev_from, prev_to);

	int best_score = -100000;
	int legal_move_count = 0;
	for (int i = 0; i < legal.count; ++i) {
		if (godot::Time::get_singleton()->get_ticks_msec() >= ctx.deadline_ms) {
			ctx.timed_out = true;
			break;
		}
		const Move &mv = legal.moves[i];
		if (can_futility && legal_move_count >= 4 && !mv.is_capture()) {
			const int move_margin = (depth == 1) ? 120 : 260;
			if (static_eval + move_margin <= alpha) {
				continue;
			}
		}
		state.make_move(mv);
		if (state.is_in_check(moving_color)) { state.unmake_move(); continue; }
		const int this_legal_idx = legal_move_count++;
		int score;
		if (this_legal_idx == 0) {
			// First legal move: full window search
			score = -minimax(state, depth - 1, -beta, -alpha, ctx);
		} else {
			// Late move reduction: reduce depth for quiet non-critical moves
			int new_depth = depth - 1;
			if (!mv.is_capture() && !in_check && depth >= 3 && this_legal_idx >= 4) {
				new_depth = depth - 2;
			}
			// PVS: null window search, then re-search if promising
			score = -minimax(state, new_depth, -alpha - 1, -alpha, ctx);
			if (!ctx.timed_out && score > alpha && score < beta) {
				score = -minimax(state, depth - 1, -beta, -alpha, ctx);
			}
		}
		state.unmake_move();
		if (ctx.timed_out) break;

		if (score > best_score) best_score = score;
		if (best_score > alpha) alpha = best_score;
		if (alpha >= beta) {
			// Beta cutoff: update killers and history for quiet moves
			if (!mv.is_capture()) {
				if (depth >= 0 && depth < 64) {
					// Rotate: shift primary to secondary if different, then set new primary
					if (mv.from != ctx.killer_moves[depth].from || mv.to != ctx.killer_moves[depth].to) {
						ctx.killer_moves_2[depth] = ctx.killer_moves[depth];
						ctx.killer_moves[depth] = mv;
					}
				}
				ctx.history[mv.from][mv.to] += depth * depth;
				if (prev_from >= 0 && prev_from < 64 && prev_to >= 0 && prev_to < 64) {
					ctx.counter_moves[prev_from][prev_to] = mv;
				}
			}
			break;
		}
	}

	if (legal_move_count == 0) {
		return in_check ? -MATE_SCORE : 0;
	}

	if (!ctx.timed_out && best_score > -100000) {
		TTEntry store;
		store.depth = depth;
		store.score = best_score;
		store.flag = TT_EXACT;
		store.generation = G_TT_GENERATION.load(std::memory_order_relaxed);
		if (best_score <= alpha_orig) store.flag = TT_UPPER;
		else if (best_score >= beta) store.flag = TT_LOWER;
		store_tt_entry(key, store);
	}

	return best_score > -100000 ? best_score : alpha_orig;
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
	// Initialize Zobrist tables once (thread-safe via static flag)
	static bool zobrist_initialized = false;
	if (!zobrist_initialized) {
		init_zobrist();
		zobrist_initialized = true;
	}
	
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
		state.zobrist_hash ^= ZOBRIST_EN_PASSANT[SearchState::idx_col(state.en_passant_index)];
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

	G_TT_GENERATION.fetch_add(1, std::memory_order_relaxed);

	SearchContext ctx;
	ctx.deadline_ms = now_ms() + uint64_t(time_limit_ms);
	const uint64_t search_start_ms = now_ms();
	uint64_t last_iteration_ms = 0;

	MoveList root_moves;
	state.generate_legal_moves(root_moves);
	if (root_moves.count == 0) {
		Dictionary none;
		none["ok"] = false;
		none["error"] = String("No legal moves");
		return none;
	}

	Move best_move = root_moves.moves[0];
	int best_score = -100000;
	int reached_depth = 0;

	for (int current_depth = 1; current_depth <= depth; ++current_depth) {
		if (now_ms() >= ctx.deadline_ms) break;
		if (current_depth > 1 && last_iteration_ms > 0) {
			const uint64_t elapsed_ms = now_ms() - search_start_ms;
			// Predict next depth cost from last completed iteration and stop early
			// when it is unlikely we can finish another full iteration in budget.
			const uint64_t predicted_total_ms = elapsed_ms + (last_iteration_ms * 20) / 10;
			if (predicted_total_ms >= uint64_t(time_limit_ms)) {
				break;
			}
		}
		ctx.timed_out = false;
		const uint64_t iteration_start_ms = now_ms();

		// Best move from previous iteration goes first
		order_moves_with_context(state, root_moves, ctx, 0);

		auto search_root_with_window = [&](int alpha, int beta, int &out_score, Move &out_move) {
			int local_alpha = alpha;
			int local_best_score = -100000;
			Move local_best_move = root_moves.moves[0];

			// Keep principal variation move on the main thread.
			if (now_ms() >= ctx.deadline_ms) {
				ctx.timed_out = true;
				out_score = local_best_score;
				out_move = local_best_move;
				return;
			}
			{
				const Move &mv = root_moves.moves[0];
				state.make_move(mv);
				int mv_score = -minimax(state, current_depth - 1, -beta, -local_alpha, ctx);
				state.unmake_move();
				if (ctx.timed_out) {
					out_score = local_best_score;
					out_move = local_best_move;
					return;
				}

				local_best_score = mv_score;
				local_best_move = mv;
				if (mv_score > local_alpha) {
					local_alpha = mv_score;
				}
			}

			for (int i = 1; i < root_moves.count; ++i) {
				if (now_ms() >= ctx.deadline_ms) {
					ctx.timed_out = true;
					break;
				}
				const Move &mv = root_moves.moves[i];
				state.make_move(mv);
				int mv_score = -minimax(state, current_depth - 1, -local_alpha - 1, -local_alpha, ctx);
				if (!ctx.timed_out && mv_score > local_alpha && mv_score < beta) {
					mv_score = -minimax(state, current_depth - 1, -beta, -local_alpha, ctx);
				}
				state.unmake_move();
				if (ctx.timed_out) {
					break;
				}

				if (mv_score > local_best_score) {
					local_best_score = mv_score;
					local_best_move = mv;
				}
				if (mv_score > local_alpha) {
					local_alpha = mv_score;
				}
			}

			out_score = local_best_score;
			out_move = local_best_move;
		};

		int depth_best_score = -100000;
		Move depth_best_move = best_move;

		if (current_depth == 1) {
			search_root_with_window(-100000, 100000, depth_best_score, depth_best_move);
		} else {
			int guess = best_score;
			int alpha = guess - 40;
			int beta = guess + 40;
			int delta = 40;
			while (true) {
				search_root_with_window(alpha, beta, depth_best_score, depth_best_move);
				if (ctx.timed_out) {
					break;
				}
				if (depth_best_score <= alpha) {
					delta = std::min(delta * 2, 50000);
					alpha = std::max(-100000, alpha - delta);
					continue;
				}
				if (depth_best_score >= beta) {
					delta = std::min(delta * 2, 50000);
					beta = std::min(100000, beta + delta);
					continue;
				}
				break;
			}
		}

		if (ctx.timed_out || depth_best_score <= -100000) break;

		best_move = depth_best_move;
		best_score = depth_best_score;
		reached_depth = current_depth;
		last_iteration_ms = now_ms() - iteration_start_ms;

		// Move best move to front for better ordering in next iteration
		for (int i = 1; i < root_moves.count; ++i) {
			if (root_moves.moves[i].from == best_move.from && root_moves.moves[i].to == best_move.to) {
				std::swap(root_moves.moves[0], root_moves.moves[i]);
				break;
			}
		}
	}

	return move_to_dict(best_move, best_score, reached_depth);
}

} // namespace dukes_ai
} // namespace godot
