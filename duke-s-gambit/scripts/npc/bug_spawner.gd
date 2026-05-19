## BugSpawner – NavMesh edition
## Spawnuje brouky na náhodných pozicích navmesh při startu hry.
## Připoj k node "Bugs" (type="Node") v game.tscn.
extends Node

@export var bug_scene: PackedScene
@export var bug_count: int = 7
@export var wander_radius: float = 16.0


func _ready() -> void:
	if bug_scene == null:
		push_warning("BugSpawner: bug_scene not set!")
		return
	await _wait_for_navmesh()
	_spawn_bugs()



func _wait_for_navmesh() -> void:
	var nav_map: RID = get_viewport().get_world_3d().navigation_map
	for _i in 120:  # timeout ~2s
		if NavigationServer3D.map_get_random_point(nav_map, 1, false) != Vector3.ZERO:
			return
		await get_tree().process_frame
	push_warning("BugSpawner: navmesh not ready after waiting, bugs may not spawn correctly.")


func _spawn_bugs() -> void:
	var nav_map: RID = get_viewport().get_world_3d().navigation_map
	for _i in bug_count:
		var bug: BugNPC = bug_scene.instantiate()
		add_child(bug)
		bug.wander_radius = wander_radius
		bug.global_position = _random_nav_point(nav_map)


func _random_nav_point(nav_map: RID) -> Vector3:
	for _i in 40:
		var point := NavigationServer3D.map_get_random_point(nav_map, 1, false)
		if point != Vector3.ZERO and Vector2(point.x, point.z).length() <= wander_radius:
			return point
	# Fallback: nejbližší bod navmesh k počátku scény
	return NavigationServer3D.map_get_closest_point(nav_map, Vector3.ZERO)
