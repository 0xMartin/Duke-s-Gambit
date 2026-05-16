#ifndef DUKES_AI_EVAL_H
#define DUKES_AI_EVAL_H

#include "ai_state.h"

#include <vector>

namespace godot {
namespace dukes_ai {

int evaluate_position(SearchState &state);
void order_moves(std::vector<Move> &moves);

} // namespace dukes_ai
} // namespace godot

#endif // DUKES_AI_EVAL_H
