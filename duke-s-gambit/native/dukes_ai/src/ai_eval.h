// ai_eval.h
// Duke's Gambit AI — Tapered PeSTO evaluation.

#ifndef DUKES_AI_EVAL_H
#define DUKES_AI_EVAL_H

#include "ai_state.h"

namespace dukes_ai {

// Initialised once. Populates the combined PSQT[color][piece][sq] tables for
// both middle-game and end-game phases. Safe to call multiple times.
void init_eval();

// Evaluate the position from the side-to-move's perspective (centipawns).
int evaluate(const SearchState &s);

// Game-phase value in [0, 24]. 24 = full opening material, 0 = bare kings.
int game_phase(const SearchState &s);

} // namespace dukes_ai

#endif // DUKES_AI_EVAL_H
