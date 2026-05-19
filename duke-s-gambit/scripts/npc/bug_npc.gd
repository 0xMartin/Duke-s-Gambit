## BugNPC – NavMesh edition
## Brouček co se potuluje po NavigationMesh.
## Y pozice pochází přímo z navmesh cesty – žádná fyzika ani collision shape potřeba.
class_name BugNPC
extends Node3D

const MOVE_SPEED    := 2.2
const BOB_AMPLITUDE := 0.10   ## výška poskoku (m)
const BOB_SPEED     := 12.0
const TURN_SPEED    := 7.0
const MIN_WAIT     := 1.5    ## sekund
const MAX_WAIT     := 6.0
const MAX_ATTEMPTS := 20     ## pokusy o nalezení validního navmesh bodu

@export var wander_radius: float = 200.0  ## max vzdálenost od počátku světa (XZ)

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _model: Node3D = $Model

var _moving: bool = false
var _wait_timer: float = 0.0
var _bob_phase: float = 0.0
var _nav_map: RID


func _ready() -> void:
	# Náhodný rozestup startu, aby brouci nechůdili synchronně
	_wait_timer = randf_range(0.0, MAX_WAIT)
	# Zakáž stíny na všech MeshInstance3D uvnitř FBX (cast_shadow na instanci root se nepropaguje)
	for mesh in find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# NavigationAgent3D potřebuje jeden frame na inicializaci
	call_deferred("_init_nav")


func _init_nav() -> void:
	_nav_map = get_world_3d().navigation_map


func _process(delta: float) -> void:
	if not _nav_map.is_valid():
		return
	if _moving:
		_update_movement(delta)
	else:
		_wait_timer -= delta
		if _wait_timer <= 0.0:
			_pick_random_target()


func _update_movement(delta: float) -> void:
	if _agent.is_navigation_finished():
		_arrive()
		return

	var next := _agent.get_next_path_position()
	var diff := next - global_position
	var diff_xz := Vector2(diff.x, diff.z)

	if diff_xz.length() > 0.05:
		var dir := diff_xz.normalized()

		# Horizontální pohyb
		global_position.x += dir.x * MOVE_SPEED * delta
		global_position.z += dir.y * MOVE_SPEED * delta   # Vector2.y = world Z

		# Otočení směrem pohybu (Godot Y-up, forward = -Z)
		var target_angle := atan2(-dir.x, -dir.y)
		rotation.y = lerp_angle(rotation.y, target_angle, TURN_SPEED * delta)

	# Plynule sledujeme Y povrchu navmesh (= terén)
	global_position.y = lerpf(global_position.y, next.y, delta * 8.0)

	# Poskakování – jen na child Model nodu, ne na physics body
	_bob_phase += BOB_SPEED * delta
	if _model:
		_model.position.y = abs(sin(_bob_phase)) * BOB_AMPLITUDE


func _arrive() -> void:
	_moving     = false
	_bob_phase  = 0.0
	_wait_timer = randf_range(MIN_WAIT, MAX_WAIT)
	if _model:
		_model.position.y = 0.0


func _pick_random_target() -> void:
	for _i in MAX_ATTEMPTS:
		var point := NavigationServer3D.map_get_random_point(_nav_map, 1, false)
		if point == Vector3.ZERO:
			continue
		# Zkontroluj radius (XZ vzdálenost od počátku)
		if Vector2(point.x, point.z).length() <= wander_radius:
			_agent.target_position = point
			_moving = true
			return
	# Žádný validní bod – zkus znovu za chvíli
	_wait_timer = randf_range(1.0, 3.0)
