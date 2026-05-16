#ifndef DUKES_AI_SEARCH_H
#define DUKES_AI_SEARCH_H

#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>

namespace godot {
namespace dukes_ai {

Dictionary find_best_move_internal(Dictionary position, int32_t depth, int32_t time_limit_ms);

} // namespace dukes_ai
} // namespace godot

#endif // DUKES_AI_SEARCH_H
