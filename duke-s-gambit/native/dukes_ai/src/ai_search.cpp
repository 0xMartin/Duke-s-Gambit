// ai_search.cpp
// Duke's Gambit AI — Fail-Soft Negamax with PVS, NMP, Quiescence (+ delta),
// a lockless transposition table, and the Godot Dictionary bridge.

#include "ai_search.h"

#include "ai_constants.h"
#include "ai_eval.h"
#include "ai_state.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cstring>
#include <vector>

namespace dukes_ai {

// ===========================================================================
// Search constants
// ===========================================================================
static constexpr int MAX_PLY      = 64;
static constexpr int INF_SCORE    = 30000;
static constexpr int MATE_SCORE   = 29000;
static constexpr int MATE_IN_MAX  = MATE_SCORE - MAX_PLY;
static constexpr int DRAW_SCORE   = 0;

// Move ordering bonuses.
static constexpr int ORDER_TT       = 1'000'000;
static constexpr int ORDER_PROMO    =   900'000;
static constexpr int ORDER_CAPTURE  =   500'000;
static constexpr int ORDER_KILLER0  =   400'000;
static constexpr int ORDER_KILLER1  =   350'000;

// ===========================================================================
// Transposition table (flat vector, lockless writes/reads).
// ===========================================================================
enum TTFlag : uint8_t {
	TT_EMPTY = 0,
	TT_EXACT = 1,
	TT_LOWER = 2,
	TT_UPPER = 3,
};

struct TTEntry {
	uint64_t key;
	int16_t  score;
	uint16_t move;
	uint8_t  depth;
	uint8_t  flag;
	uint16_t _pad;
};
static_assert(sizeof(TTEntry) == 16, "TTEntry must be 16 bytes");

static constexpr size_t TT_SIZE = 1u << 20; // ~1M entries == 16 MiB.
static std::vector<TTEntry> g_tt;
static std::atomic<bool>    g_tt_ready{ false };

static void ensure_tt() {
	if (g_tt_ready.load(std::memory_order_acquire)) {
		return;
	}
	static std::atomic<bool> init_in_progress{ false };
	bool expected = false;
	if (!init_in_progress.compare_exchange_strong(expected, true)) {
		while (!g_tt_ready.load(std::memory_order_acquire)) { /* spin briefly */ }
		return;
	}
	g_tt.assign(TT_SIZE, TTEntry{});
	g_tt_ready.store(true, std::memory_order_release);
}

static inline size_t tt_index(uint64_t key) {
	return size_t(key) & (TT_SIZE - 1);
}

// Mate scores are stored relative to the matching-ply distance.
static inline int16_t score_to_tt(int s, int ply) {
	if (s >=  MATE_IN_MAX) return int16_t(s + ply);
	if (s <= -MATE_IN_MAX) return int16_t(s - ply);
	return int16_t(s);
}
static inline int score_from_tt(int16_t s, int ply) {
	if (s >=  MATE_IN_MAX) return int(s) - ply;
	if (s <= -MATE_IN_MAX) return int(s) + ply;
	return int(s);
}

// ===========================================================================
// SearchContext — per-search state. Never shared across threads.
// ===========================================================================
struct SearchContext {
	uint64_t nodes = 0;
	uint64_t qnodes = 0;

	// Time control.
	std::chrono::steady_clock::time_point start_time;
	int32_t time_limit_ms = 0;
	bool    stop = false;

	// Heuristics.
	Move killers[MAX_PLY][2] = {};
	int  history[NUM_COLORS][64][64] = {};

	// Root info captured across iterative-deepening iterations.
	Move best_move_root = MOVE_NONE;
	int  best_score_root = -INF_SCORE;
	int  completed_depth = 0;
};

static inline bool time_up(SearchContext &ctx) {
	if (ctx.stop) return true;
	if (ctx.time_limit_ms <= 0) return false;
	if ((ctx.nodes & 2047) != 0) return false;
	auto now = std::chrono::steady_clock::now();
	auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(
			now - ctx.start_time).count();
	if (ms >= ctx.time_limit_ms) {
		ctx.stop = true;
		return true;
	}
	return false;
}

// ===========================================================================
// Helpers — captured-piece detection, move scoring, board insights
// ===========================================================================
static inline uint8_t captured_piece_type(const SearchState &s, Move m) {
	MoveFlag fl = m.flag();
	if (fl == MF_EN_PASSANT) return PAWN;
	if (fl == MF_CASTLING)   return PT_NONE;
	Bitboard to_bb = square_bb(m.to());
	int them = 1 - s.side_to_move;
	if (!(s.occupancy[them] & to_bb)) return PT_NONE;
	for (int pt = 0; pt < NUM_PIECE_TYPES; ++pt) {
		if (s.pieces[them][pt] & to_bb) return uint8_t(pt);
	}
	return PT_NONE;
}

static inline bool is_capture_move(const SearchState &s, Move m) {
	return captured_piece_type(s, m) != PT_NONE;
}

// Returns true if side has at least one non-pawn, non-king piece (NMP guard).
static inline bool has_non_pawn_material(const SearchState &s, int color) {
	return s.pieces[color][KNIGHT] | s.pieces[color][BISHOP]
			| s.pieces[color][ROOK] | s.pieces[color][QUEEN];
}

// Light insufficient-material detector (KK, KBK, KNK, KBKB-same-color).
static bool insufficient_material(const SearchState &s) {
	if (s.pieces[WHITE][PAWN] | s.pieces[BLACK][PAWN]
			| s.pieces[WHITE][ROOK]  | s.pieces[BLACK][ROOK]
			| s.pieces[WHITE][QUEEN] | s.pieces[BLACK][QUEEN]) {
		return false;
	}
	int wN = std::popcount(s.pieces[WHITE][KNIGHT]);
	int bN = std::popcount(s.pieces[BLACK][KNIGHT]);
	int wB = std::popcount(s.pieces[WHITE][BISHOP]);
	int bB = std::popcount(s.pieces[BLACK][BISHOP]);
	int w_minors = wN + wB;
	int b_minors = bN + bB;
	if (w_minors == 0 && b_minors == 0) return true;       // K vs K
	if (w_minors + b_minors == 1) return true;             // K + minor vs K
	if (w_minors == 1 && b_minors == 1 && wN == 0 && bN == 0) {
		return true;                                       // KB vs KB (any colours)
	}
	return false;
}

static int score_move(const SearchState &s, Move m, Move tt_move,
		const SearchContext &ctx, int ply) {
	if (!tt_move.is_null() && m == tt_move) return ORDER_TT;
	MoveFlag fl = m.flag();
	if (fl == MF_PROMOTION) {
		return ORDER_PROMO + PIECE_VALUE_MG[m.promotion_type()];
	}
	uint8_t victim = captured_piece_type(s, m);
	if (victim != PT_NONE) {
		uint8_t attacker = s.piece_type_on(m.from());
		return ORDER_CAPTURE + MVV_LVA_VICTIM[victim] * 16 - int(attacker);
	}
	if (ply < MAX_PLY) {
		if (m == ctx.killers[ply][0]) return ORDER_KILLER0;
		if (m == ctx.killers[ply][1]) return ORDER_KILLER1;
	}
	return ctx.history[s.side_to_move][m.from()][m.to()];
}

static void score_all_moves(const SearchState &s, MoveList &list,
		Move tt_move, const SearchContext &ctx, int ply) {
	for (int i = 0; i < list.count; ++i) {
		list.scores[i] = score_move(s, list.moves[i], tt_move, ctx, ply);
	}
}

// Picks the next-best (by score) move from index `start_idx` onward via a
// partial selection sort — keeps the hot loop branch-light without sorting
// everything upfront (cutoffs often happen on the very first move).
static void pick_next_move(MoveList &list, int start_idx) {
	int best = start_idx;
	for (int i = start_idx + 1; i < list.count; ++i) {
		if (list.scores[i] > list.scores[best]) best = i;
	}
	if (best != start_idx) {
		std::swap(list.moves[start_idx],  list.moves[best]);
		std::swap(list.scores[start_idx], list.scores[best]);
	}
}

// ===========================================================================
// Quiescence search (captures + queen promotions only, with delta pruning).
// ===========================================================================
static int qsearch(SearchState &s, SearchContext &ctx, int alpha, int beta, int ply) {
	++ctx.nodes;
	++ctx.qnodes;
	if (time_up(ctx)) return 0;

	if (ply >= MAX_PLY) {
		return evaluate(s);
	}

	const int stand_pat = evaluate(s);
	if (stand_pat >= beta) {
		return stand_pat; // Fail-soft.
	}
	int best = stand_pat;
	if (stand_pat > alpha) alpha = stand_pat;

	// Delta-pruning safety margin: even capturing a queen + promotion + buffer.
	const int delta_buffer = 200;

	MoveList list;
	s.generate_tactical_moves(list);
	score_all_moves(s, list, MOVE_NONE, ctx, ply);

	for (int i = 0; i < list.count; ++i) {
		pick_next_move(list, i);
		Move m = list.moves[i];

		// Delta pruning per move: prune obvious failures.
		uint8_t victim = captured_piece_type(s, m);
		int gain = (victim != PT_NONE) ? PIECE_VALUE_MG[victim] : 0;
		if (m.flag() == MF_PROMOTION) {
			gain += PIECE_VALUE_MG[m.promotion_type()] - PIECE_VALUE_MG[PAWN];
		}
		if (stand_pat + gain + delta_buffer < alpha && !s.in_check()) {
			continue;
		}

		s.make_move(m);
		if (s.in_check(1 - s.side_to_move)) { // Left own king in check.
			s.unmake_move(m);
			continue;
		}
		int score = -qsearch(s, ctx, -beta, -alpha, ply + 1);
		s.unmake_move(m);

		if (ctx.stop) return 0;

		if (score > best) {
			best = score;
			if (score > alpha) alpha = score;
			if (alpha >= beta) break; // Fail-soft beta cutoff.
		}
	}
	return best;
}

// ===========================================================================
// Main fail-soft negamax with PVS, TT, NMP.
// ===========================================================================
static int negamax(SearchState &s, SearchContext &ctx,
		int alpha, int beta, int depth, int ply, bool allow_null) {

	if (time_up(ctx)) return 0;

	const bool is_root = (ply == 0);
	const bool is_pv   = (beta - alpha) > 1;

	// Draw detection (skip at root).
	if (!is_root) {
		if (s.halfmove_clock >= 100 || s.is_repetition() || insufficient_material(s)) {
			return DRAW_SCORE;
		}
	}

	if (ply >= MAX_PLY) {
		return evaluate(s);
	}

	const bool in_check = s.in_check();
	// Check extension: stay one ply deeper when in check.
	if (in_check) ++depth;

	if (depth <= 0) {
		return qsearch(s, ctx, alpha, beta, ply);
	}

	++ctx.nodes;

	// ---- Transposition table probe ----
	const uint64_t key = s.zobrist;
	TTEntry &slot = g_tt[tt_index(key)];
	TTEntry probe = slot; // Single 16-byte copy; tolerate torn reads.
	Move tt_move = MOVE_NONE;
	if (probe.flag != TT_EMPTY && probe.key == key) {
		tt_move = Move(probe.move);
		if (!is_root && !is_pv && probe.depth >= depth) {
			int tt_score = score_from_tt(probe.score, ply);
			if (probe.flag == TT_EXACT) return tt_score;
			if (probe.flag == TT_LOWER && tt_score >= beta)  return tt_score;
			if (probe.flag == TT_UPPER && tt_score <= alpha) return tt_score;
		}
	}

	// ---- Reverse futility pruning (static null-move pruning) ----
	// Only at shallow non-PV, non-check nodes far from mate scores.
	if (!is_pv && !in_check && depth <= 3
			&& beta < MATE_IN_MAX && beta > -MATE_IN_MAX) {
		int static_eval = evaluate(s);
		if (static_eval - 100 * depth >= beta) {
			return static_eval;
		}
	}

	// ---- Null move pruning ----
	if (!is_pv && !in_check && allow_null && depth >= 3
			&& has_non_pawn_material(s, s.side_to_move)
			&& evaluate(s) >= beta) {
		int R = 2 + (depth >= 6 ? 1 : 0);
		s.make_null_move();
		int null_score = -negamax(s, ctx, -beta, -beta + 1,
				depth - 1 - R, ply + 1, false);
		s.unmake_null_move();
		if (ctx.stop) return 0;
		if (null_score >= beta) {
			// Avoid returning unproven mate scores from a null search.
			if (null_score >  MATE_IN_MAX) null_score = beta;
			return null_score;
		}
	}

	// ---- Generate and order moves ----
	MoveList list;
	s.generate_pseudo_moves(list);
	score_all_moves(s, list, tt_move, ctx, ply);

	int best = -INF_SCORE;
	Move best_move = MOVE_NONE;
	int legal_count = 0;
	uint8_t flag = TT_UPPER;
	const int orig_alpha = alpha;

	// Track quiet moves that failed to cut so we can apply a history malus on a
	// later cutoff. Bounded; extras are not penalised (rare and harmless).
	Move quiets_tried[64];
	int  quiets_tried_count = 0;

	for (int i = 0; i < list.count; ++i) {
		pick_next_move(list, i);
		Move m = list.moves[i];

		const bool is_quiet =
				!is_capture_move(s, m) && m.flag() != MF_PROMOTION;

		s.make_move(m);
		if (s.in_check(1 - s.side_to_move)) {
			s.unmake_move(m);
			continue;
		}
		++legal_count;
		const bool gives_check = s.in_check();

		int score;
		if (legal_count == 1) {
			// PV move: full window.
			score = -negamax(s, ctx, -beta, -alpha, depth - 1, ply + 1, true);
		} else {
			// Late Move Reductions for late quiet moves at non-shallow depths.
			int reduction = 0;
			if (depth >= 3 && legal_count >= 4 && is_quiet
					&& !in_check && !gives_check) {
				reduction = 1 + (depth >= 6 ? 1 : 0);
				if (reduction >= depth - 1) reduction = depth - 2;
			}

			// Zero-window scout, possibly reduced.
			score = -negamax(s, ctx, -alpha - 1, -alpha,
					depth - 1 - reduction, ply + 1, true);

			// If the reduced search beat alpha, re-search at full depth.
			if (!ctx.stop && reduction > 0 && score > alpha) {
				score = -negamax(s, ctx, -alpha - 1, -alpha,
						depth - 1, ply + 1, true);
			}
			// PVS: open window if we landed inside (alpha, beta).
			if (!ctx.stop && score > alpha && score < beta) {
				score = -negamax(s, ctx, -beta, -alpha, depth - 1, ply + 1, true);
			}
		}
		s.unmake_move(m);

		if (ctx.stop) return 0;

		if (score > best) {
			best = score;
			best_move = m;
			if (score > alpha) {
				alpha = score;
				flag = TT_EXACT;
			}
			if (alpha >= beta) {
				// Beta cutoff. Update killers and history for quiet moves.
				if (is_quiet) {
					if (ply < MAX_PLY) {
						if (ctx.killers[ply][0] != m) {
							ctx.killers[ply][1] = ctx.killers[ply][0];
							ctx.killers[ply][0] = m;
						}
					}
					const int bonus = depth * depth;
					int &h = ctx.history[s.side_to_move][m.from()][m.to()];
					h += bonus;
					// History malus for earlier quiet moves that didn't cut.
					for (int q = 0; q < quiets_tried_count; ++q) {
						Move qm = quiets_tried[q];
						ctx.history[s.side_to_move][qm.from()][qm.to()] -= bonus;
					}
					if (h > 200000) {
						// Periodic decay to keep magnitudes manageable.
						for (int c = 0; c < NUM_COLORS; ++c) {
							for (int f = 0; f < 64; ++f) {
								for (int t = 0; t < 64; ++t) {
									ctx.history[c][f][t] /= 2;
								}
							}
						}
					}
				}
				flag = TT_LOWER;
				break;
			}
		}

		if (is_quiet && quiets_tried_count < 64) {
			quiets_tried[quiets_tried_count++] = m;
		}
	}

	if (legal_count == 0) {
		// Mate or stalemate.
		return in_check ? (-MATE_SCORE + ply) : DRAW_SCORE;
	}

	// ---- TT store ----
	TTEntry store;
	store.key   = key;
	store.score = score_to_tt(best, ply);
	store.move  = best_move.data;
	store.depth = uint8_t(depth < 0 ? 0 : (depth > 255 ? 255 : depth));
	store.flag  = (flag == TT_UPPER && best > orig_alpha) ? TT_EXACT : flag;
	store._pad  = 0;
	slot = store;

	if (is_root) {
		ctx.best_move_root  = best_move;
		ctx.best_score_root = best;
	}

	return best;
}

// ===========================================================================
// Iterative deepening at the root
// ===========================================================================
static void search_root(SearchState &state, SearchContext &ctx,
		int max_depth, Move &out_best, int &out_score) {
	// Find a guaranteed-legal fallback first.
	MoveList root_moves;
	state.generate_pseudo_moves(root_moves);
	Move first_legal = MOVE_NONE;
	for (int i = 0; i < root_moves.count; ++i) {
		Move m = root_moves.moves[i];
		state.make_move(m);
		bool legal = !state.in_check(1 - state.side_to_move);
		state.unmake_move(m);
		if (legal) { first_legal = m; break; }
	}
	out_best  = first_legal;
	out_score = 0;
	if (first_legal.is_null()) return; // No legal moves: leave caller to handle.

	if (max_depth <= 0) max_depth = MAX_PLY - 1;

	int prev_score = 0;

	for (int depth = 1; depth <= max_depth; ++depth) {
		int alpha = -INF_SCORE;
		int beta  =  INF_SCORE;
		int delta = 25;

		// Aspiration window once we have a stable prior score.
		if (depth >= 4) {
			alpha = prev_score - delta;
			beta  = prev_score + delta;
		}

		int score = 0;
		Move iter_best = MOVE_NONE;

		while (true) {
			ctx.best_move_root  = MOVE_NONE;
			ctx.best_score_root = -INF_SCORE;

			score = negamax(state, ctx, alpha, beta, depth, 0, true);

			if (ctx.stop) break;

			if (score <= alpha) {
				// Fail low: widen alpha, keep beta.
				beta  = (alpha + beta) / 2;
				alpha = score - delta;
				delta += delta / 2;
				if (delta > 600 || alpha <= -MATE_IN_MAX) {
					alpha = -INF_SCORE;
					beta  =  INF_SCORE;
				}
				continue;
			}
			if (score >= beta) {
				// Fail high: widen beta. Capture the move; it's safe.
				if (!ctx.best_move_root.is_null()) iter_best = ctx.best_move_root;
				beta += delta;
				delta += delta / 2;
				if (delta > 600 || beta >= MATE_IN_MAX) {
					alpha = -INF_SCORE;
					beta  =  INF_SCORE;
				}
				continue;
			}

			// Score is within the window.
			if (!ctx.best_move_root.is_null()) iter_best = ctx.best_move_root;
			break;
		}

		if (ctx.stop) break;

		if (!iter_best.is_null()) {
			out_best  = iter_best;
			out_score = score;
			prev_score = score;
			ctx.completed_depth = depth;
		}

		// Early exit on confirmed mate.
		if (score >  MATE_IN_MAX) break;
		if (score < -MATE_IN_MAX) break;
	}
}

// ===========================================================================
// Move serialisation back to Godot's expected dictionary fields.
// ===========================================================================
static int classify_move_type(const SearchState &before, Move m, uint8_t captured) {
	MoveFlag fl = m.flag();
	if (fl == MF_CASTLING) {
		int to_file = file_of(m.to());
		return (to_file == 6) ? 3 /* CASTLING_KINGSIDE */ : 4 /* CASTLING_QUEENSIDE */;
	}
	if (fl == MF_EN_PASSANT) return 2; // EN_PASSANT
	if (fl == MF_PROMOTION) {
		return (captured < PT_NONE) ? 6 /* PROMOTION_CAPTURE */ : 5 /* PROMOTION */;
	}
	if (captured < PT_NONE) return 1; // CAPTURE
	return 0; // NORMAL
	(void)before;
}

static ::godot::Dictionary serialize_move(const SearchState &before, Move m,
		int score, int depth, uint64_t nodes, int64_t time_ms) {
	::godot::Dictionary d;
	if (m.is_null()) {
		d["ok"] = false;
		return d;
	}

	int from = m.from();
	int to   = m.to();
	uint8_t moved   = before.piece_type_on(from);
	uint8_t captured = captured_piece_type(before, m);
	int piece_color = before.side_to_move;

	d["ok"]            = true;
	d["from_col"]      = file_of(from);
	d["from_row"]      = rank_of(from);
	d["to_col"]        = file_of(to);
	d["to_row"]        = rank_of(to);
	d["move_type"]     = classify_move_type(before, m, captured);
	d["piece_type"]    = (moved < PT_NONE) ? INTERNAL_TO_GODOT_PT[moved] : 0;
	d["piece_color"]   = piece_color;
	d["captured_type"] = (captured < PT_NONE) ? INTERNAL_TO_GODOT_PT[captured] : 0;
	if (m.flag() == MF_PROMOTION) {
		d["promotion_type"] = INTERNAL_TO_GODOT_PT[m.promotion_type()];
	} else {
		d["promotion_type"] = 0;
	}
	d["score"]         = score;
	d["depth"]         = depth;
	d["reached_depth"] = depth;
	d["nodes"]         = int64_t(nodes);
	d["time_ms"]       = time_ms;
	return d;
}

// ===========================================================================
// Position parsing
// ===========================================================================
static bool load_state_from_dict(const ::godot::Dictionary &position,
		SearchState &out) {
	using namespace ::godot;
	if (!position.has("board")) return false;

	Variant board_var = position["board"];
	int32_t board[64];
	std::memset(board, 0, sizeof(board));

	if (board_var.get_type() == Variant::PACKED_INT32_ARRAY) {
		PackedInt32Array arr = board_var;
		int n = arr.size();
		if (n > 64) n = 64;
		for (int i = 0; i < n; ++i) board[i] = arr[i];
	} else if (board_var.get_type() == Variant::ARRAY) {
		Array arr = board_var;
		int n = arr.size();
		if (n > 64) n = 64;
		for (int i = 0; i < n; ++i) board[i] = int32_t(int(arr[i]));
	} else {
		return false;
	}

	int side     = int(position.get("active_color", 0));
	int castling = int(position.get("castling_rights", 0));
	int ep_idx   = int(position.get("en_passant_index", -1));
	int halfm    = int(position.get("halfmove_clock", 0));
	int fullm    = int(position.get("fullmove_number", 1));

	out.load_position(board, side, castling, ep_idx, halfm, fullm);
	return true;
}

// ===========================================================================
// Public entry point
// ===========================================================================
::godot::Dictionary find_best_move_internal(::godot::Dictionary position,
		int32_t depth, int32_t time_limit_ms) {
	init_tables();
	init_eval();
	ensure_tt();

	::godot::Dictionary result;
	result["ok"] = false;

	SearchState state;
	if (!load_state_from_dict(position, state)) {
		return result;
	}

	// Snapshot the root position for move serialisation.
	SearchState root_snapshot = state;

	SearchContext ctx;
	ctx.start_time    = std::chrono::steady_clock::now();
	ctx.time_limit_ms = time_limit_ms;

	Move best  = MOVE_NONE;
	int  score = 0;
	search_root(state, ctx, depth, best, score);

	int64_t elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - ctx.start_time).count();

	if (best.is_null()) {
		result["ok"]            = false;
		result["nodes"]         = int64_t(ctx.nodes);
		result["time_ms"]       = elapsed;
		result["depth"]         = ctx.completed_depth;
		result["reached_depth"] = ctx.completed_depth;
		return result;
	}

	return serialize_move(root_snapshot, best, score, ctx.completed_depth,
			ctx.nodes, elapsed);
}

} // namespace dukes_ai
