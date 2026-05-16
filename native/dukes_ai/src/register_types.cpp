#include "register_types.h"

#include "dukes_ai_native.h"

#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_dukes_ai_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<DukesAINative>();
}

void uninitialize_dukes_ai_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT dukes_ai_native_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_dukes_ai_module);
	init_obj.register_terminator(uninitialize_dukes_ai_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}

}
