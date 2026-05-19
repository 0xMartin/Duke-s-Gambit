#ifndef DUKES_AI_EVAL_H
#define DUKES_AI_EVAL_H

#include "ai_state.h"

namespace godot {
namespace dukes_ai {

int evaluate_position(SearchState &state);
void order_moves(MoveList &moves);
int quiescence(SearchState &state, int alpha, int beta, SearchContext &ctx, int depth);

} // namespace dukes_ai
} // namespace godot

#endif // DUKES_AI_EVAL_H
