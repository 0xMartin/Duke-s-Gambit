#include "ai_search.h"

#include "ai_constants.h"
#include "ai_eval.h"
#include "ai_state.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <atomic>
#include <future>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace godot {
namespace dukes_ai {

static std::unordered_map<uint64_t, TTEntry> G_PERSISTENT_TT;
static std::mutex G_PERSISTENT_TT_MUTEX;
static std::atomic<uint32_t> G_TT_GENERATION{0};
static std::atomic<uint32_t> G_TT_STORE_COUNTER{0};
static constexpr size_t PERSISTENT_TT_MAX_ENTRIES = 350000;
static constexpr uint32_t PERSISTENT_TT_KEEP_GENERATIONS = 6;
static constexpr int PERSISTENT_TT_MIN_PROBE_DEPTH = 4;
static constexpr uint32_t PERSISTENT_TT_PRUNE_PERIOD = 4096;

static void prune_persistent_tt_if_needed(uint32_t current_generation) {
	if (G_PERSISTENT_TT.size() <= PERSISTENT_TT_MAX_ENTRIES) {
		return;
	}

	for (auto it = G_PERSISTENT_TT.begin(); it != G_PERSISTENT_TT.end();) {
		const uint32_t entry_gen = it->second.generation;
		const uint32_t age = current_generation >= entry_gen ? (current_generation - entry_gen) : 0;
		if (age > PERSISTENT_TT_KEEP_GENERATIONS) {
			it = G_PERSISTENT_TT.erase(it);
		} else {
			++it;
		}
	}

	if (G_PERSISTENT_TT.size() <= PERSISTENT_TT_MAX_ENTRIES) {
		return;
	}

	// Safety cap: drop oldest arbitrary tail if aging alone wasn't enough.
	while (G_PERSISTENT_TT.size() > PERSISTENT_TT_MAX_ENTRIES) {
		G_PERSISTENT_TT.erase(G_PERSISTENT_TT.begin());
	}
}

static bool load_tt_entry(uint64_t key, int depth, SearchContext &ctx, TTEntry &out_entry) {
	auto it_local = ctx.tt.find(key);
	if (it_local != ctx.tt.end() && it_local->second.depth >= depth) {
		out_entry = it_local->second;
		return true;
	}

	if (depth < PERSISTENT_TT_MIN_PROBE_DEPTH) {
		return false;
	}

	std::lock_guard<std::mutex> lock(G_PERSISTENT_TT_MUTEX);
	auto it_global = G_PERSISTENT_TT.find(key);
	if (it_global == G_PERSISTENT_TT.end() || it_global->second.depth < depth) {
		return false;
	}
	out_entry = it_global->second;
	ctx.tt[key] = out_entry;
	return true;
}

static void store_tt_entry(uint64_t key, const TTEntry &entry, SearchContext &ctx) {
	ctx.tt[key] = entry;
	if (entry.depth < PERSISTENT_TT_MIN_PROBE_DEPTH) {
		return;
	}

	std::lock_guard<std::mutex> lock(G_PERSISTENT_TT_MUTEX);
	auto it = G_PERSISTENT_TT.find(key);
	if (it == G_PERSISTENT_TT.end() || entry.depth >= it->second.depth) {
		G_PERSISTENT_TT[key] = entry;
	}

	const uint32_t stores = G_TT_STORE_COUNTER.fetch_add(1, std::memory_order_relaxed) + 1;
	if (G_PERSISTENT_TT.size() > PERSISTENT_TT_MAX_ENTRIES && (stores % PERSISTENT_TT_PRUNE_PERIOD) == 0) {
		prune_persistent_tt_if_needed(entry.generation);
	}
}

static uint64_t now_ms() {
	return Time::get_singleton()->get_ticks_msec();
}

// Move ordering: captures (MVV-LVA) > killer > history heuristic > quiet

// Static Exchange Evaluation - returns true if SEE(move) >= threshold
// Simulates piece trades on capture square by finding all attackers/defenders
static bool see_ge(SearchState &state, const Move &mv, int threshold) {
	if (!mv.is_capture()) {
		return true;
	}
	
	int to_sq = mv.to;
	int captured_value = PIECE_VALUES[mv.captured_type];
	int attacking_value = PIECE_VALUES[mv.piece_type];
	
	// Simple exchange: if we capture and can't be recaptured
	if (captured_value - threshold >= 0) {
		// Try to find the weakest defending piece
		// Check for pawn defenders first (cheapest)
		int to_col = SearchState::idx_col(to_sq);
		int to_row = SearchState::idx_row(to_sq);
		int enemy_color = 1 - state.active_color;
		int enemy_pawn_code = (enemy_color == WHITE) ? 1 : 7;
		
		// Pawn can defend from diagonals
		for (int dc = -1; dc <= 1; dc += 2) {
			int c = to_col + dc;
			if (c >= 0 && c <= 7) {
				int pawn_row = to_row + (enemy_color == WHITE ? -1 : 1);
				if (pawn_row >= 0 && pawn_row <= 7) {
					int idx = SearchState::sq_to_index(c, pawn_row);
					if (state.board[idx] == enemy_pawn_code) {
						// Pawn can recapture
						int pawn_value = PIECE_VALUES[PIECE_PAWN];
						if (attacking_value - pawn_value <= threshold) {
							return false;  // We lose the exchange
						}
						// Continue searching for other defenders
					}
				}
			}
		}
		
		// Check for knight defenders (can attack from L-shape)
		int knight_code = (enemy_color == WHITE) ? PIECE_KNIGHT : PIECE_KNIGHT + 6;
		static const int knight_offsets[8][2] = {{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2}};
		for (const auto &off : knight_offsets) {
			int c = to_col + off[0];
			int r = to_row + off[1];
			if (c >= 0 && c <= 7 && r >= 0 && r <= 7) {
				if (state.board[SearchState::sq_to_index(c, r)] == knight_code) {
					int knight_value = PIECE_VALUES[PIECE_KNIGHT];
					if (attacking_value - knight_value <= threshold) {
						return false;
					}
				}
			}
		}
		
		// Check for bishop/queen diagonal defenders
		int bishop_code = (enemy_color == WHITE) ? PIECE_BISHOP : PIECE_BISHOP + 6;
		int queen_code = (enemy_color == WHITE) ? PIECE_QUEEN : PIECE_QUEEN + 6;
		static const int bishop_dirs[4][2] = {{1,1},{1,-1},{-1,1},{-1,-1}};
		for (const auto &dir : bishop_dirs) {
			for (int dist = 1; dist < 8; ++dist) {
				int c = to_col + dir[0] * dist;
				int r = to_row + dir[1] * dist;
				if (c < 0 || c > 7 || r < 0 || r > 7) break;
				int code = state.board[SearchState::sq_to_index(c, r)];
				if (code != 0) {
					if (code == bishop_code || code == queen_code) {
						int piece_val = (code == bishop_code) ? PIECE_VALUES[PIECE_BISHOP] : PIECE_VALUES[PIECE_QUEEN];
						if (attacking_value - piece_val <= threshold) {
							return false;
						}
					}
					break;  // Blocked by a piece
				}
			}
		}
		
		// Check for rook/queen straight defenders
		int rook_code = (enemy_color == WHITE) ? PIECE_ROOK : PIECE_ROOK + 6;
		static const int rook_dirs[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
		for (const auto &dir : rook_dirs) {
			for (int dist = 1; dist < 8; ++dist) {
				int c = to_col + dir[0] * dist;
				int r = to_row + dir[1] * dist;
				if (c < 0 || c > 7 || r < 0 || r > 7) break;
				int code = state.board[SearchState::sq_to_index(c, r)];
				if (code != 0) {
					if (code == rook_code || code == queen_code) {
						int piece_val = (code == rook_code) ? PIECE_VALUES[PIECE_ROOK] : PIECE_VALUES[PIECE_QUEEN];
						if (attacking_value - piece_val <= threshold) {
							return false;
						}
					}
					break;
				}
			}
		}
		
		// If no strong defenders found, capture is safe
		return true;
	}
	
	return false;
}

static void order_moves_with_context(const SearchState &state, std::vector<Move> &moves, const SearchContext &ctx, int depth, int prev_from = -1, int prev_to = -1) {
	int killer_from = -1, killer_to = -1;
	auto kit = ctx.killer_moves.find(depth);
	if (kit != ctx.killer_moves.end()) {
		killer_from = kit->second.from;
		killer_to = kit->second.to;
	}
	Move counter;
	if (prev_from >= 0 && prev_from < 64 && prev_to >= 0 && prev_to < 64) {
		counter = ctx.counter_moves[prev_from][prev_to];
	}
	std::sort(moves.begin(), moves.end(), [&](const Move &a, const Move &b) {
		auto score = [&](const Move &mv) -> int {
			if (mv.is_capture()) {
				// Check if it's a safe capture (using SEE)
				bool safe = see_ge(const_cast<SearchState &>(state), mv, 0);
				
				if (safe) {
					// Safe captures: prioritize HEAVILY by material gain
					// MVV-LVA: Most Valuable Victim, Least Valuable Attacker
					int victim_value = PIECE_VALUES[mv.captured_type];
					int attacker_value = PIECE_VALUES[mv.piece_type];
					// Higher score = better move
					// Big bonus for capturing queen/rook, small penalty for sacrificing them
					int score_val = 20000 + victim_value * 100 - attacker_value;
					return score_val;
				} else {
					// Unsafe captures: check if it's a sacrifice that's still worth it
					// (e.g., sacrificing queen for mate threat would show in search depth)
					int victim_value = PIECE_VALUES[mv.captured_type];
					int attacker_value = PIECE_VALUES[mv.piece_type];
					// Much lower score for bad trades
					int loss = attacker_value - victim_value;
					if (loss > 300) {
						// Big material loss - put it at the end
						return 1000 + victim_value;
					} else if (loss > 100) {
						// Moderate loss - low priority
						return 2000 + victim_value;
					} else {
						// Small loss or queen sacrifice - might be intentional
						return 3000 + victim_value;
					}
				}
			}
			if (mv.from == killer_from && mv.to == killer_to) {
				return 9000;
			}
			if (counter.from >= 0 && mv.from == counter.from && mv.to == counter.to) {
				return 8500;
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
	TTEntry e;
	if (load_tt_entry(key, depth, ctx, e)) {
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

	int prev_from = -1;
	int prev_to = -1;
	if (!state.history.empty()) {
		const UndoState &last = state.history.back();
		prev_from = last.from_idx;
		prev_to = last.to_idx;
	}

	order_moves_with_context(state, legal, ctx, depth, prev_from, prev_to);

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
				if (prev_from >= 0 && prev_from < 64 && prev_to >= 0 && prev_to < 64) {
					ctx.counter_moves[prev_from][prev_to] = mv;
				}
			}
			break;
		}
	}

	if (!ctx.timed_out && best_score > -100000) {
		TTEntry store;
		store.depth = depth;
		store.score = best_score;
		store.flag = TT_EXACT;
		store.generation = G_TT_GENERATION.load(std::memory_order_relaxed);
		if (best_score <= alpha_orig) store.flag = TT_UPPER;
		else if (best_score >= beta) store.flag = TT_LOWER;
		store_tt_entry(key, store, ctx);
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
		last_iteration_ms = now_ms() - iteration_start_ms;

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
