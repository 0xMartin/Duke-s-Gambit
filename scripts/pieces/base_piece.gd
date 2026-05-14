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
## Local transform of the weapon relative to the hand bone (tweak position/rotation in inspector).
@export var weapon_transform: Transform3D = Transform3D()

# ── Movement config ────────────────────────────────────────────────────────
const MOVE_SPEED          := 1.0   # units/sec while walking
const ATTACK_STOP_DIST    := 1.1   # stop this many units before target square centre
const DEATH_FADE_DURATION := 0.5   # seconds for opacity to drop to 0
# ── Weapon config ──────────────────────────────────────────────────────────
const WEAPON_BONE         := "mixamorig:RightHand"
const WEAPON_SCENE_PATH   := "res://assets/models/weapons/sword.blend"
const WEAPON_FADE_IN_DUR  := 0.2
const WEAPON_FADE_OUT_DUR := 0.5
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
var _weapon_attach:   BoneAttachment3D = null
var _weapon_instance: Node3D           = null

signal move_finished          # emitted when piece arrives at destination
signal attack_sequence_done   # emitted when full attack+death sequence is done

# ── Selection outline ──────────────────────────────────────────────────────
static var _outline_mat: ShaderMaterial = null

func set_selected(v: bool) -> void:
	_apply_outline_recursive(self, v)

func _apply_outline_recursive(node: Node, active: bool) -> void:
	if node is MeshInstance3D:
		if _outline_mat == null:
			_outline_mat = ShaderMaterial.new()
			_outline_mat.shader = load("res://shaders/outline.gdshader") as Shader
		(node as MeshInstance3D).material_overlay = _outline_mat if active else null
	for child in node.get_children():
		_apply_outline_recursive(child, active)

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
	# Clean up any leftover weapon from a previous (edge-case) attack.
	_destroy_weapon()

	var skel := _find_skeleton_recursive(self)
	if skel == null:
		push_warning("BasePiece._show_weapon: no Skeleton3D found in piece '%s'" % name)
		return
	if skel.find_bone(WEAPON_BONE) < 0:
		push_warning("BasePiece._show_weapon: bone '%s' not found in skeleton of '%s'" % [WEAPON_BONE, name])
		return

	var sword_scene := load(WEAPON_SCENE_PATH) as PackedScene
	if sword_scene == null:
		push_warning("BasePiece._show_weapon: cannot load '%s'" % WEAPON_SCENE_PATH)
		return

	# In Godot 4, bone_name must be set AFTER add_child so _ready() has run
	# and the BoneAttachment3D can resolve the bone index against the live skeleton.
	_weapon_attach = BoneAttachment3D.new()
	skel.add_child(_weapon_attach)           # enter tree first
	_weapon_attach.bone_name = WEAPON_BONE   # then assign bone (triggers internal _skeleton_changed)

	_weapon_instance = sword_scene.instantiate() as Node3D
	_weapon_instance.transform = weapon_transform
	_weapon_attach.add_child(_weapon_instance)

	_set_weapon_alpha(0.0)
	var tw := create_tween()
	tw.tween_method(_set_weapon_alpha, 0.0, 1.0, WEAPON_FADE_IN_DUR)

func _hide_weapon() -> void:
	if _weapon_instance == null or not is_instance_valid(_weapon_instance):
		return
	var tw := create_tween()
	tw.tween_method(_set_weapon_alpha, 1.0, 0.0, WEAPON_FADE_OUT_DUR)
	tw.tween_callback(_destroy_weapon)

func _destroy_weapon() -> void:
	if _weapon_attach != null and is_instance_valid(_weapon_attach):
		_weapon_attach.queue_free()
	_weapon_attach   = null
	_weapon_instance = null

func _set_weapon_alpha(alpha: float) -> void:
	if _weapon_instance == null or not is_instance_valid(_weapon_instance):
		return
	_set_alpha_recursive(_weapon_instance, alpha)

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
	# Always face the target explicitly — handles cases where the piece didn't walk
	# (adjacent squares) or approached from an odd angle.
	if _attack_target != null and is_instance_valid(_attack_target):
		_face_direction(_attack_target.global_position - global_position)
	_show_weapon()
	_play(anim_attack)
	# Wait for attack animation to finish one cycle
	if _anim and _anim.has_animation(anim_attack):
		var dur := _anim.get_animation(anim_attack).length
		await get_tree().create_timer(max(dur * 0.85 - 0.3, 0.0)).timeout
	# Trigger enemy death, then wait for full death+fade to complete
	if _attack_target != null and is_instance_valid(_attack_target):
		_attack_target.die()
		await _attack_target.tree_exited          # wait until enemy removed from scene
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
