#ifndef DUKES_AI_NATIVE_H
#define DUKES_AI_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class DukesAINative : public RefCounted {
	GDCLASS(DukesAINative, RefCounted)

protected:
	static void _bind_methods();

public:
	DukesAINative() = default;
	~DukesAINative() = default;

	String get_version() const;
	Dictionary find_best_move(Dictionary position, int32_t depth, int32_t time_limit_ms) const;
};

} // namespace godot

#endif // DUKES_AI_NATIVE_H
