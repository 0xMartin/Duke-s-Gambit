#include "ai_search.h"

#include "ai_constants.h"
#include "ai_eval.h"
#include "ai_state.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <future>
#include <thread>

namespace godot {
namespace dukes_ai {

static uint64_t now_ms() {
	return Time::get_singleton()->get_ticks_msec();
}

// Move ordering: captures (MVV-LVA) > killer > history heuristic > quiet
static void order_moves_with_context(std::vector<Move> &moves, const SearchContext &ctx, int depth) {
	int killer_from = -1, killer_to = -1;
	auto kit = ctx.killer_moves.find(depth);
	if (kit != ctx.killer_moves.end()) {
		killer_from = kit->second.from;
		killer_to = kit->second.to;
	}
	std::sort(moves.begin(), moves.end(), [&](const Move &a, const Move &b) {
		auto score = [&](const Move &mv) -> int {
			if (mv.is_capture()) {
				return 10000 + PIECE_VALUES[mv.captured_type] * 10 - PIECE_VALUES[mv.piece_type];
			}
			if (mv.from == killer_from && mv.to == killer_to) {
				return 9000;
			}
			return ctx.history[mv.from][mv.to];
		};
		return score(a) > score(b);
	});
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

	std::vector<Move> legal = state.generate_legal_moves();
	if (legal.empty()) {
		return in_check ? -MATE_SCORE : 0;
	}

	order_moves_with_context(legal, ctx, depth);

	int best_score = -100000;
	for (int i = 0; i < (int)legal.size(); ++i) {
		if (godot::Time::get_singleton()->get_ticks_msec() >= ctx.deadline_ms) {
			ctx.timed_out = true;
			break;
		}
		const Move &mv = legal[i];
		if (can_futility && i >= 4 && !mv.is_capture()) {
			const int move_margin = (depth == 1) ? 120 : 260;
			if (static_eval + move_margin <= alpha) {
				continue;
			}
		}
		state.make_move(mv);
		int score;
		if (i == 0) {
			// First move: full window search
			score = -minimax(state, depth - 1, -beta, -alpha, ctx);
		} else {
			// Late move reduction: reduce depth for quiet non-critical moves
			int new_depth = depth - 1;
			if (!mv.is_capture() && !in_check && depth >= 3 && i >= 4) {
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
			// Beta cutoff: update killer and history for quiet moves
			if (!mv.is_capture()) {
				ctx.killer_moves[depth] = mv;
				ctx.history[mv.from][mv.to] += depth * depth;
			}
			break;
		}
	}

	if (!ctx.timed_out && best_score > -100000) {
		TTEntry store;
		store.depth = depth;
		store.score = best_score;
		store.flag = TT_EXACT;
		if (best_score <= alpha_orig) store.flag = TT_UPPER;
		else if (best_score >= beta) store.flag = TT_LOWER;
		ctx.tt[key] = store;
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
		if (now_ms() >= ctx.deadline_ms) break;
		ctx.timed_out = false;

		// Best move from previous iteration goes first
		order_moves_with_context(root_moves, ctx, 0);

		auto search_root_with_window = [&](int alpha, int beta, int &out_score, Move &out_move) {
			int local_alpha = alpha;
			int local_best_score = -100000;
			Move local_best_move = root_moves[0];

			// Keep principal variation move on the main thread.
			if (now_ms() >= ctx.deadline_ms) {
				ctx.timed_out = true;
				out_score = local_best_score;
				out_move = local_best_move;
				return;
			}
			{
				const Move &mv = root_moves[0];
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

			const uint64_t now = now_ms();
			const uint64_t time_left_ms = (ctx.deadline_ms > now) ? (ctx.deadline_ms - now) : 0;
			const bool enable_parallel = (current_depth >= 4 && root_moves.size() >= 6 && time_left_ms >= 25);
			const unsigned hw = std::thread::hardware_concurrency();
			const unsigned physical_like = (hw == 0) ? 2u : hw;
			const unsigned max_workers = std::max(1u, physical_like - 1u);

			if (enable_parallel && max_workers > 1) {
				struct RootTaskResult {
					int score;
					Move move;
					bool timed_out;
				};

				SearchState root_state = state;
				const int alpha_snapshot = local_alpha;
				std::vector<std::future<RootTaskResult>> futures;
				futures.reserve(root_moves.size() - 1);
				std::vector<RootTaskResult> probe_results;
				probe_results.reserve(root_moves.size() - 1);
				std::vector<RootTaskResult> promising;
				promising.reserve(root_moves.size() - 1);

				auto consume_probe_result = [&](RootTaskResult result) {
					if (result.timed_out) {
						ctx.timed_out = true;
						return;
					}
					probe_results.push_back(result);
				};

				for (int i = 1; i < (int)root_moves.size(); ++i) {
					if (now_ms() >= ctx.deadline_ms) {
						ctx.timed_out = true;
						break;
					}

					const Move mv = root_moves[i];
					futures.push_back(std::async(std::launch::async, [&root_state, mv, current_depth, alpha_snapshot, deadline_ms = ctx.deadline_ms]() -> RootTaskResult {
						SearchState local_state = root_state;
						SearchContext local_ctx;
						local_ctx.deadline_ms = deadline_ms;
						local_state.make_move(mv);
						// Null-window probe first. Full re-search is only done for promising moves.
						const int score = -minimax(local_state, current_depth - 1, -alpha_snapshot - 1, -alpha_snapshot, local_ctx);
						return {score, mv, local_ctx.timed_out};
					}));

					if (futures.size() >= max_workers) {
						RootTaskResult result = futures.front().get();
						futures.erase(futures.begin());
						consume_probe_result(result);
						if (ctx.timed_out) {
							break;
						}
					}
				}

				for (auto &fut : futures) {
					RootTaskResult result = fut.get();
					consume_probe_result(result);
					if (ctx.timed_out) {
						break;
					}
				}

				if (!ctx.timed_out) {
					for (const RootTaskResult &r : probe_results) {
						if (r.score > local_best_score) {
							local_best_score = r.score;
							local_best_move = r.move;
						}
						if (r.score > local_alpha) {
							promising.push_back(r);
						}
					}

					std::sort(promising.begin(), promising.end(), [](const RootTaskResult &a, const RootTaskResult &b) {
						return a.score > b.score;
					});

					for (const RootTaskResult &r : promising) {
						if (now_ms() >= ctx.deadline_ms) {
							ctx.timed_out = true;
							break;
						}
						SearchState verify_state = state;
						verify_state.make_move(r.move);
						int full_score = -minimax(verify_state, current_depth - 1, -beta, -local_alpha, ctx);
						if (ctx.timed_out) {
							break;
						}
						if (full_score > local_best_score) {
							local_best_score = full_score;
							local_best_move = r.move;
						}
						if (full_score > local_alpha) {
							local_alpha = full_score;
						}
					}
				}
			} else {
				for (int i = 1; i < (int)root_moves.size(); ++i) {
					if (now_ms() >= ctx.deadline_ms) {
						ctx.timed_out = true;
						break;
					}
					const Move &mv = root_moves[i];
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

		// Move best move to front for better ordering in next iteration
		for (int i = 1; i < (int)root_moves.size(); ++i) {
			if (root_moves[i].from == best_move.from && root_moves[i].to == best_move.to) {
				std::swap(root_moves[0], root_moves[i]);
				break;
			}
		}
	}

	return move_to_dict(best_move, best_score, reached_depth);
}

} // namespace dukes_ai
} // namespace godot
