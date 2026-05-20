// ai_search.h
// Duke's Gambit AI — Search entry point bridged to Godot.

#ifndef DUKES_AI_SEARCH_H
#define DUKES_AI_SEARCH_H

#include <godot_cpp/variant/dictionary.hpp>

namespace dukes_ai {

// Godot bridge entry point. Parses the position dictionary, runs an iterative
// deepening alpha-beta search, and returns the chosen move serialised in the
// format expected by `AIController._move_matches_payload()` (see
// scripts/controllers/ai_controller.gd):
//   { ok, from_col, from_row, to_col, to_row,
//     move_type, piece_type, piece_color, captured_type, promotion_type,
//     score, depth, nodes, time_ms }
//
//   depth         > 0 — hard depth limit (in plies)
//   time_limit_ms > 0 — soft wall-clock limit in milliseconds
// If both are positive, whichever fires first stops the search.
::godot::Dictionary find_best_move_internal(::godot::Dictionary position,
		int32_t depth, int32_t time_limit_ms);

} // namespace dukes_ai

#endif // DUKES_AI_SEARCH_H
