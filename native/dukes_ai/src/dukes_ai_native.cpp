#include "dukes_ai_native.h"

#include "ai_constants.h"
#include "ai_search.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void DukesAINative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_version"), &DukesAINative::get_version);
	ClassDB::bind_method(D_METHOD("find_best_move", "position", "depth", "time_limit_ms"), &DukesAINative::find_best_move);
}

String DukesAINative::get_version() const {
	return String(dukes_ai::AI_VERSION);
}

Dictionary DukesAINative::find_best_move(Dictionary position, int32_t depth, int32_t time_limit_ms) const {
	return dukes_ai::find_best_move_internal(position, depth, time_limit_ms);
}

} // namespace godot
