## knight_piece.gd
## Knight overrides movement: physically arcs through the air (jump animation).
## The jump animation timing is matched to the physical arc so take-off and
## landing align perfectly with the animation keyframes.

class_name KnightPiece
extends BasePiece

@export var anim_jump: String = "jump"

# Arc parameters
const ARC_HEIGHT       := 2.0   # peak height above board (world units)
const JUMP_DURATION    := 1.0   # seconds for the full arc (matched to anim)
const JUMP_TIME_SCALE  := 0.75  # 25% shorter jump duration
# When attacking: trigger enemy death this fraction before landing
const DEATH_TRIGGER_T  := 0.85

var _jumping:          bool    = false
var _jump_start:       Vector3 = Vector3.ZERO
var _jump_end:         Vector3 = Vector3.ZERO
var _jump_elapsed:     float   = 0.0
var _jump_duration:    float   = JUMP_DURATION
var _jump_is_attack:   bool    = false
var _jump_attack_done: bool    = false

# ── Override: move_to ──────────────────────────────────────────────────────
func move_to(world_pos: Vector3) -> void:
	_begin_jump(world_pos, false, null)

func attack_and_move_to(target: BasePiece, final_pos: Vector3) -> void:
	_attack_target = target
	_after_attack_pos = final_pos
	_begin_jump(final_pos, true, target)

func _begin_jump(dest: Vector3, is_attack: bool, target: BasePiece) -> void:
	_jumping         = true
	_jump_start      = global_position
	_jump_end        = dest
	_jump_elapsed    = 0.0
	_jump_is_attack  = is_attack
	_jump_attack_done = false
	_attack_target   = target

	_trail_active = true

	# Match animation duration to jump duration (speed_scale=2 → 50 % faster)
	if _anim and _anim.has_animation(anim_jump):
		var anim_res := _anim.get_animation(anim_jump)
		_anim.speed_scale = 2.0
		_jump_duration = (anim_res.length / 2.0) * JUMP_TIME_SCALE
		_anim.play(anim_jump)
	else:
		_jump_duration = JUMP_DURATION * JUMP_TIME_SCALE
		push_warning("KnightPiece: jump animation '%s' not found" % anim_jump)

	_state = _State.WALKING  # prevent base _process_walk from running

# ── Trail: override to use knight body position directly ──────────────────
func _get_blade_world_points() -> Array[Vector3]:
	var top := global_position + Vector3(0.0, 0.6, 0.0)
	var bot := global_position + Vector3(0.0, 0.05, 0.0)
	return [top, bot]

# ── Process override ───────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _jumping:
		_process_jump(delta)
		return
	if _state == _State.DYING:
		_process_death_fade(delta)

func _process_jump(delta: float) -> void:
	_jump_elapsed += delta
	var t: float = clamp(_jump_elapsed / _jump_duration, 0.0, 1.0)

	# Horizontal lerp
	var horiz: Vector3 = _jump_start.lerp(_jump_end, t)
	# Vertical parabola: h * 4 * t * (1 - t)
	var vert: float = ARC_HEIGHT * 4.0 * t * (1.0 - t)
	global_position = Vector3(horiz.x, _jump_start.y + vert, horiz.z)
	# Disable shadow while jumping, so it only appears on the board
	_disable_jump_shadow(true)

	# Face direction of travel
	var diff := (_jump_end - _jump_start)
	diff.y = 0.0
	if diff.length_squared() > 0.001:
		_face_direction(diff.normalized())

	# Trigger enemy death 0.3 s before the natural trigger point so death anim isn't late
	if _jump_is_attack and not _jump_attack_done \
			and _jump_elapsed + 0.3 >= _jump_duration * DEATH_TRIGGER_T:
		_jump_attack_done = true
		if _attack_target != null and is_instance_valid(_attack_target):
			_attack_target.die()

	if t >= 1.0:
		_finish_jump()

func _finish_jump() -> void:
	if _anim:
		_anim.speed_scale = 1.0   # reset after jump
	_jumping = false
	global_position = _jump_end
	_attack_target  = null
	_trail_active = false
	_disable_jump_shadow(false)  # Re-enable shadow on landing
	_state = _State.IDLE
	_play(anim_idle)
	emit_signal("move_finished")

func _disable_jump_shadow(disable: bool) -> void:
	var blob := get_node_or_null("BlobShadow")
	if blob != null:
		blob.visible = not disable
