## base_piece.gd
## Base class for all chess pieces.
## Handles: colour assignment (fig_color material), animation playback,
## movement (walk → idle), attack sequence, death sequence, opacity fade.
## The 3D model + AnimationPlayer live as children (set up in derived scenes).

class_name BasePiece
extends Node3D

# ── Piece identity ─────────────────────────────────────────────────────────
@export var piece_type:  int = ChessEnums.PieceType.PAWN   # ChessEnums.PieceType
@export var piece_color: int = ChessEnums.PieceColor.WHITE  # ChessEnums.PieceColor

# ── Piece colours (tweak here) ─────────────────────────────────────────────
const COLOR_WHITE := Color(0.92, 0.88, 0.80)
const COLOR_BLACK := Color(0.12, 0.10, 0.08)

# ── Animation names (override in subclass if different) ─────────────────────
@export var anim_idle:   String = "idle"
@export var anim_walk:   String = "walk"
@export var anim_attack: String = "attack"
@export var anim_death:  String = "death"

## Y-axis rotation offset (degrees) to align model's front with Godot's -Z axis.
## Blender exports typically have front = +Z in Godot, so 180 is the default.
@export var model_forward_deg: float = 180.0

## Whether this piece draws a weapon during attack (disable for Knight).
@export var use_weapon: bool = true
## Local transform of the weapon relative to the hand bone (tweak in inspector).
@export var weapon_transform: Transform3D = Transform3D(Basis().scaled(Vector3(0.05, 0.05, 0.05)), Vector3.ZERO)
## Seconds after attack animation begins: trail starts, hit lands, trail ends.
@export var attack_trail_start: float = 0.5
@export var attack_trail_hit:   float = 0.9
@export var attack_trail_end:   float = 1.3

# ── Movement config ────────────────────────────────────────────────────────
const MOVE_SPEED          := 1.0   # units/sec while walking
const ATTACK_STOP_DIST    := 1.1   # stop this many units before target square centre
const DEATH_FADE_DURATION := 0.5   # seconds for opacity to drop to 0
# ── Weapon config ──────────────────────────────────────────────────────────
const WEAPON_BONE         := "mixamorig_RightHand"
const WEAPON_SCENE_PATH   := "res://assets/models/weapons/sword.glb"
const WEAPON_FADE_IN_DUR  := 0.2   # seconds: scale 0 → 1 on appear
const WEAPON_FADE_OUT_DUR := 0.4   # seconds: scale 1 → 0 on disappear
# ── Trail config ────────────────────────────────────────────────────────────
const TRAIL_COLOR         := Color(0.55, 0.88, 1.0, 1.0)  # light blue
const TRAIL_LIFETIME      := 0.4   # seconds each trail point lives before fading out
# ── Node refs (assigned in _ready by searching children) ───────────────────
var _anim: AnimationPlayer = null
var _model: Node3D = null          # first Node3D child (the actual mesh root)

# ── Runtime state ──────────────────────────────────────────────────────────
enum _State { IDLE, WALKING, ATTACKING, DYING }
var _state: _State = _State.IDLE

var _target_pos:     Vector3 = Vector3.ZERO
var _attack_target:  BasePiece = null   # piece being attacked
var _after_attack_pos: Vector3 = Vector3.ZERO  # where to walk after attack

var _dying:       bool  = false
var _fade_timer:  float = 0.0
var _base_alpha:  float = 1.0

# Weapon runtime state
var _sword_skel:       Skeleton3D         = null
var _sword_bone_idx:   int                = -1
var _weapon_instance:  Node3D             = null
var _weapon_scale_t:   float              = 1.0   # 0=hidden 1=full, animated on appear/disappear
# Trail runtime state
var _trail_active:     bool               = false
var _trail_mesh_inst:  MeshInstance3D     = null
var _trail_sword_mesh: MeshInstance3D     = null
var _trail_points:     Array              = []    # [{tip:Vector3, base:Vector3, age:float}]
var _trail_mat:        StandardMaterial3D = null

signal move_finished          # emitted when piece arrives at destination
signal attack_sequence_done   # emitted when full attack+death sequence is done

# ── Weapon ──────────────────────────────────────────────────────────────────────
func _find_skeleton_recursive(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton_recursive(child)
		if found != null:
			return found
	return null

func _show_weapon() -> void:
	if not use_weapon:
		return
	_destroy_weapon()

	var skel := _find_skeleton_recursive(self)
	if skel == null:
		push_warning("[BasePiece] _show_weapon: no Skeleton3D found in '%s'" % name)
		return
	var bone_idx := skel.find_bone(WEAPON_BONE)
	if bone_idx < 0:
		var bone_names: Array[String] = []
		for i in skel.get_bone_count():
			bone_names.append(skel.get_bone_name(i))
		push_warning("[BasePiece] _show_weapon: bone '%s' not found in '%s'.\n  Available: [%s]" \
			% [WEAPON_BONE, name, ", ".join(bone_names)])
		return

	var sword_scene := load(WEAPON_SCENE_PATH) as PackedScene
	if sword_scene == null:
		push_warning("[BasePiece] _show_weapon: cannot load '%s'" % WEAPON_SCENE_PATH)
		return

	_sword_skel     = skel
	_sword_bone_idx = bone_idx

	_weapon_instance           = sword_scene.instantiate() as Node3D
	_weapon_instance.top_level = true
	add_child(_weapon_instance)

	_weapon_scale_t = 0.0
	_update_weapon_transform()   # position at scale=0 immediately (invisible)
	_setup_trail()

	# Scale-in: 0 → 1 over WEAPON_FADE_IN_DUR seconds
	var tw := create_tween()
	tw.tween_property(self, "_weapon_scale_t", 1.0, WEAPON_FADE_IN_DUR).set_ease(Tween.EASE_OUT)

func _hide_weapon() -> void:
	if _weapon_instance == null or not is_instance_valid(_weapon_instance):
		_destroy_weapon()
		return
	# Scale-out: 1 → 0, then destroy
	var tw := create_tween()
	tw.tween_property(self, "_weapon_scale_t", 0.0, WEAPON_FADE_OUT_DUR).set_ease(Tween.EASE_IN)
	tw.tween_callback(_destroy_weapon)

func _destroy_weapon() -> void:
	_cleanup_trail()
	if _weapon_instance != null and is_instance_valid(_weapon_instance):
		_weapon_instance.queue_free()
	_weapon_instance = null
	_sword_skel      = null
	_sword_bone_idx  = -1

# ── Trail ──────────────────────────────────────────────────────────────────

func _find_mesh_recursive(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh_recursive(child)
		if found != null:
			return found
	return null

func _setup_trail() -> void:
	_trail_sword_mesh = _find_mesh_recursive(_weapon_instance)
	_trail_points.clear()
	_trail_active = false

	_trail_mat = StandardMaterial3D.new()
	_trail_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	_trail_mat.albedo_color               = TRAIL_COLOR

	_trail_mesh_inst                      = MeshInstance3D.new()
	_trail_mesh_inst.top_level            = true
	_trail_mesh_inst.global_transform     = Transform3D.IDENTITY
	_trail_mesh_inst.material_override    = _trail_mat
	_trail_mesh_inst.mesh                 = ImmediateMesh.new()
	add_child(_trail_mesh_inst)

func _cleanup_trail() -> void:
	_trail_active = false
	_trail_points.clear()
	_trail_sword_mesh = null
	if _trail_mesh_inst != null and is_instance_valid(_trail_mesh_inst):
		_trail_mesh_inst.queue_free()
	_trail_mesh_inst = null
	_trail_mat       = null

func _on_attack_start() -> void:
	_trail_active = true

func _on_attack_hit() -> void:
	if _attack_target != null and is_instance_valid(_attack_target):
		_attack_target.die()

func _on_attack_end() -> void:
	_trail_active = false   # stop sampling; existing points age out naturally

func _get_blade_world_points() -> Array[Vector3]:
	if _trail_sword_mesh == null or not is_instance_valid(_trail_sword_mesh):
		return [Vector3.ZERO, Vector3.ZERO]
	var aabb: AABB = _trail_sword_mesh.get_aabb()
	var cx := aabb.position.x + aabb.size.x * 0.5
	var cz := aabb.position.z + aabb.size.z * 0.5
	var tip_local  := Vector3(cx, aabb.position.y + aabb.size.y * 0.95, cz)
	var base_local := Vector3(cx, aabb.position.y + aabb.size.y * 0.15, cz)
	return [
		_trail_sword_mesh.global_transform * tip_local,
		_trail_sword_mesh.global_transform * base_local,
	]

func _update_trail(delta: float) -> void:
	if _trail_mesh_inst == null or not is_instance_valid(_trail_mesh_inst):
		return
	# Age all points; remove expired ones (oldest are at index 0)
	for pt in _trail_points:
		pt.age += delta
	while _trail_points.size() > 0 and _trail_points[0].age >= TRAIL_LIFETIME:
		_trail_points.remove_at(0)
	# Sample a new point when trail is active
	if _trail_active and _trail_sword_mesh != null and is_instance_valid(_trail_sword_mesh):
		var pts := _get_blade_world_points()
		_trail_points.append({tip = pts[0], base = pts[1], age = 0.0})
	_rebuild_trail_mesh()

func _rebuild_trail_mesh() -> void:
	var im := _trail_mesh_inst.mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	var count := _trail_points.size()
	if count < 2:
		return
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(count - 1):
		var p0: Dictionary = _trail_points[i]      # older → more transparent
		var p1: Dictionary = _trail_points[i + 1]  # newer → more opaque
		# Alpha = position-fraction × remaining-lifetime-fraction
		var a0: float = (1.0 - float(p0.age) / TRAIL_LIFETIME) * (float(i)     / float(count - 1))
		var a1: float = (1.0 - float(p1.age) / TRAIL_LIFETIME) * (float(i + 1) / float(count - 1))
		# Quad as two CCW triangles; vertices in world space (mesh is at identity transform)
		im.surface_set_color(Color(1, 1, 1, a0)); im.surface_add_vertex(p0.base)
		im.surface_set_color(Color(1, 1, 1, a0)); im.surface_add_vertex(p0.tip)
		im.surface_set_color(Color(1, 1, 1, a1)); im.surface_add_vertex(p1.tip)
		im.surface_set_color(Color(1, 1, 1, a0)); im.surface_add_vertex(p0.base)
		im.surface_set_color(Color(1, 1, 1, a1)); im.surface_add_vertex(p1.tip)
		im.surface_set_color(Color(1, 1, 1, a1)); im.surface_add_vertex(p1.base)
	im.surface_end()

## Called every frame to keep the sword aligned with the hand bone in world space.
func _update_weapon_transform() -> void:
	if _weapon_instance == null or not is_instance_valid(_weapon_instance):
		return
	if _sword_skel == null or not is_instance_valid(_sword_skel) or _sword_bone_idx < 0:
		return
	var bone_world   := _sword_skel.global_transform * _sword_skel.get_bone_global_pose(_sword_bone_idx)
	var bone_rot_pos := Transform3D(bone_world.basis.orthonormalized(), bone_world.origin)
	# Scale the weapon by _weapon_scale_t (0=hidden, 1=full) for smooth appear/disappear
	var wt_sc          := weapon_transform.basis.get_scale() * _weapon_scale_t
	var animated_basis := weapon_transform.basis.orthonormalized().scaled(wt_sc)
	_weapon_instance.global_transform = bone_rot_pos * Transform3D(animated_basis, weapon_transform.origin)

# ──────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_find_children()
	_setup_animation_loops()
	_apply_color()
	_set_initial_facing()
	_play(anim_idle)

func _find_children() -> void:
	# Recursive search so AnimationPlayer inside armature hierarchy is found.
	_anim = _find_anim_recursive(self)
	for child in get_children():
		if child is Node3D:
			_model = child
			break

func _find_anim_recursive(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child as AnimationPlayer
		var found: AnimationPlayer = _find_anim_recursive(child)
		if found != null:
			return found
	return null

## Idle loops with pingpong (smooth, no visible jump at loop point).
## Walk loops linearly. Both are set on the shared animation resource — that is fine
## because all instances of the same piece type share the same desired loop behaviour.
func _setup_animation_loops() -> void:
	if _anim == null:
		return
	if _anim.has_animation(anim_idle):
		_anim.get_animation(anim_idle).loop_mode = Animation.LOOP_PINGPONG
	if _anim.has_animation(anim_walk):
		_anim.get_animation(anim_walk).loop_mode = Animation.LOOP_LINEAR

## Set starting orientation so piece faces the opponent's half of the board.
func _set_initial_facing() -> void:
	# Board: row 0 = white back rank, row 7 = black back rank.
	# White faces +Z (toward higher rows), black faces -Z (toward lower rows).
	var fwd := Vector3(0, 0, 1) if piece_color == ChessEnums.PieceColor.WHITE \
							   else Vector3(0, 0, -1)
	_face_direction(fwd)

## Rotate piece to face a horizontal world direction.
func _face_direction(dir: Vector3) -> void:
	if dir.length_squared() < 0.001:
		return
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	look_at(global_position + flat, Vector3.UP)
	if model_forward_deg != 0.0:
		rotation_degrees.y += model_forward_deg

func _apply_color() -> void:
	var col := COLOR_WHITE if piece_color == ChessEnums.PieceColor.WHITE else COLOR_BLACK
	_set_material_color(self, col)

func _set_material_color(node: Node, col: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		for i in range(mi.get_surface_override_material_count()):
			var mat := mi.get_surface_override_material(i)
			if mat == null:
				mat = mi.mesh.surface_get_material(i)
			if mat and mat.resource_name == "fig_color":
				var new_mat := mat.duplicate() as StandardMaterial3D
				new_mat.albedo_color = col
				mi.set_surface_override_material(i, new_mat)
	for child in node.get_children():
		_set_material_color(child, col)

# ── Public movement API ────────────────────────────────────────────────────

## Simple move to world position (no combat)
func move_to(world_pos: Vector3) -> void:
	_target_pos = world_pos
	_state = _State.WALKING
	_play(anim_walk)

## Full attack sequence: walk toward target, play attack, wait for death, walk to final pos
func attack_and_move_to(target: BasePiece, final_pos: Vector3) -> void:
	_attack_target = target
	_after_attack_pos = final_pos
	_state = _State.WALKING
	_target_pos = _calc_attack_stop_pos(target.global_position)
	_play(anim_walk)

func _calc_attack_stop_pos(target_world: Vector3) -> Vector3:
	var diff := target_world - global_position
	diff.y = 0.0
	var len := diff.length()
	if len <= ATTACK_STOP_DIST:
		return global_position   # already within range — stay put, we'll turn in _start_attack
	return target_world - diff.normalized() * ATTACK_STOP_DIST

# ── Process ────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	match _state:
		_State.WALKING:
			_process_walk(delta)
		_State.DYING:
			_process_death_fade(delta)
	_update_weapon_transform()
	_update_trail(delta)

func _process_walk(delta: float) -> void:
	var diff := _target_pos - global_position
	diff.y = 0.0
	var dist := diff.length()
	if dist < 0.02:
		global_position = _target_pos
		if _attack_target != null:
			_start_attack()
		else:
			_state = _State.IDLE
			_play(anim_idle)
			emit_signal("move_finished")
	else:
		var step := MOVE_SPEED * delta
		global_position += diff.normalized() * min(step, dist)
		# Face movement direction
		if diff.length_squared() > 0.001:
			_face_direction(diff.normalized())

func _start_attack() -> void:
	_state = _State.ATTACKING
	if _attack_target != null and is_instance_valid(_attack_target):
		_face_direction(_attack_target.global_position - global_position)
	_show_weapon()
	_play(anim_attack)
	# Trail start
	await get_tree().create_timer(attack_trail_start).timeout
	_on_attack_start()
	# Hit — trigger target death
	await get_tree().create_timer(attack_trail_hit - attack_trail_start).timeout
	_on_attack_hit()
	# Trail end — stop sampling, points fade on their own
	await get_tree().create_timer(attack_trail_end - attack_trail_hit).timeout
	_on_attack_end()
	# Wait for target to fully leave the scene tree
	if _attack_target != null and is_instance_valid(_attack_target):
		await _attack_target.tree_exited
	_hide_weapon()
	_attack_target = null
	# Walk to final square
	_state = _State.WALKING
	_target_pos = _after_attack_pos
	_play(anim_walk)

## Trigger death sequence on this piece
func die() -> void:
	if _dying:
		return
	_dying = true
	_play(anim_death)
	if _anim and _anim.has_animation(anim_death):
		var dur := _anim.get_animation(anim_death).length
		await get_tree().create_timer(dur).timeout
	_start_fade()

func _start_fade() -> void:
	_state = _State.DYING   # Begin fade processing only after death animation finishes
	_fade_timer = 0.0
	_spawn_death_particles()

func _process_death_fade(delta: float) -> void:
	if not _dying:
		return
	_fade_timer += delta
	var t: float = clamp(_fade_timer / DEATH_FADE_DURATION, 0.0, 1.0)
	_set_alpha_recursive(self, 1.0 - t)
	if t >= 1.0:
		queue_free()

func _set_alpha_recursive(node: Node, alpha: float) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var surface_count: int = mi.mesh.get_surface_count() if mi.mesh != null else 0
		for i in range(surface_count):
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D:
				# Duplicate per-instance so fading one piece doesn't affect others sharing the mesh
				var override := mi.get_surface_override_material(i)
				if override == null:
					override = mat.duplicate() as StandardMaterial3D
					mi.set_surface_override_material(i, override)
				var m := override as StandardMaterial3D
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var c := m.albedo_color
				c.a = alpha
				m.albedo_color = c
	for child in node.get_children():
		_set_alpha_recursive(child, alpha)

func _spawn_death_particles() -> void:
	# Load and instance the shared death particle scene
	var ps_scene := load("res://scenes/effects/death_particles.tscn") as PackedScene
	if ps_scene == null:
		return
	var ps := ps_scene.instantiate() as GPUParticles3D
	get_parent().add_child(ps)
	ps.global_position = global_position + Vector3(0, 0.5, 0)
	ps.emitting = true
	# Auto-free after particles finish
	var lifetime: float = ps.lifetime * (ps.amount + 1)
	get_tree().create_timer(lifetime + 1.0).timeout.connect(ps.queue_free)

# ── Animation helper ───────────────────────────────────────────────────────
func _play(anim_name: String) -> void:
	if _anim == null:
		return
	if _anim.has_animation(anim_name):
		if _anim.current_animation != anim_name:
			_anim.play(anim_name)
			# Randomise start position for idle so pieces don't animate in sync
			if anim_name == anim_idle:
				var anim_len: float = _anim.get_animation(anim_name).length
				_anim.seek(randf_range(0.0, anim_len), true)
	else:
		push_warning("BasePiece: animation '%s' not found on %s" % [anim_name, name])

func current_anim() -> String:
	return _anim.current_animation if _anim else ""

func board_square() -> Vector2i:
	return Vector2i.ZERO  # set by GameController after instantiation
