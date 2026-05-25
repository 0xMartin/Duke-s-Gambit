## Attach this script to the root node of a one-shot effect scene (particles + audio).
## Automatically frees the node once the longest particle lifetime has elapsed.
extends Node3D

func _ready() -> void:
	_assign_sfx_bus(self)
	_start_particles(self)
	var max_lifetime := _get_max_particle_lifetime(self)
	# Add 0.5 s buffer so the last particles fully fade before freeing.
	get_tree().create_timer(max(max_lifetime + 0.5, 2.0)).timeout.connect(queue_free)

## Routes all AudioStreamPlayer3D nodes in the subtree to the SFX bus.
## Done in code so the Godot editor cannot reset the property in the .tscn file.
func _assign_sfx_bus(node: Node) -> void:
	if node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).bus = &"SFX"
	for child in node.get_children():
		_assign_sfx_bus(child)

## Kicks off emitting on every GPUParticles3D in the subtree.
func _start_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = true
	for child in node.get_children():
		_start_particles(child)

## Recursively finds the longest GPUParticles3D lifetime in the subtree.
func _get_max_particle_lifetime(node: Node) -> float:
	var result := 0.0
	if node is GPUParticles3D:
		result = max(result, (node as GPUParticles3D).lifetime)
	for child in node.get_children():
		result = max(result, _get_max_particle_lifetime(child))
	return result
