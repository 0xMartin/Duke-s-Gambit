## knight_piece.gd
## Knight overrides movement: physically arcs through the air (jump animation).
## The jump animation timing is matched to the physical arc so take-off and
## landing align perfectly with the animation keyframes.

class_name KnightPiece
extends BasePiece

@export var anim_jump: String = "jump"

# Arc parameters
const ARC_HEIGHT       := 1.8   # peak height above board (world units)
const JUMP_DURATION    := 1.53   # seconds for the full arc (matched to anim)
const JUMP_TIME_SCALE  := 0.6  
# When attacking: trigger enemy death this fraction before landing
const DEATH_TRIGGER_T  := 0.85

const _SFX_LAND: AudioStream = preload("res://assets/sounds/jumpland.mp3")

var _jumping:          bool    = false
var _jump_start:       Vector3 = Vector3.ZERO
var _jump_end:         Vector3 = Vector3.ZERO
var _jump_elapsed:     float   = 0.0
var _jump_duration:    float   = JUMP_DURATION
var _jump_is_attack:   bool    = false
var _jump_attack_done: bool    = false
var _land_sound_played: bool   = false
var _land_player:      AudioStreamPlayer = null

# ── Ready ─────────────────────────────────────────────────────────────────
func _ready() -> void:
	super._ready()
	_trail_lifetime = TRAIL_LIFETIME * 2.5  # longer, more visible trail
	# Pre-allocate land sound player so there's no delay on first landing
	_land_player = AudioStreamPlayer.new()
	_land_player.bus = "SFX"
	_land_player.stream = _SFX_LAND
	_land_player.volume_db = 6.0
	add_child(_land_player)

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
	_land_sound_played = false
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
	var right := global_transform.basis.x.normalized() * 0.1
	var center := global_position + Vector3(0.0, 0.5, 0.0)
	return [center - right, center + right]

# ── Process override ───────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _jumping:
		_process_jump(delta)
		_update_weapon_transform()
		_update_trail(delta)
		return
	super._process(delta)

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

	# Trigger enemy death 0.05 s before the natural trigger point so death anim isn't late
	if _jump_is_attack and not _jump_attack_done \
			and _jump_elapsed + 0.05 >= _jump_duration * DEATH_TRIGGER_T:
		_jump_attack_done = true
		if _attack_target != null and is_instance_valid(_attack_target):
			# Push attacked piece away before it dies
			var from := global_position
			var to := _attack_target.global_position
			var dir := Vector3(to.x - from.x, 0.0, to.z - from.z)
			if dir.length_squared() > 0.0001:
				dir = dir.normalized() * 0.5
				var target_pos := to + dir
				target_pos.y = to.y  # zachovat výšku
				var tw := _attack_target.create_tween()
				tw.tween_property(_attack_target, "global_position", target_pos, 0.13).set_ease(Tween.EASE_OUT)
			_attack_target.die()

	# Play landing sound 0.2 s before actual landing
	if not _land_sound_played and _jump_elapsed >= _jump_duration - 0.2:
		_land_sound_played = true
		if _land_player != null:
			_land_player.play()
		# Play knight attack sound if this is an attack jump
		if _jump_is_attack:
			var atk := AudioStreamPlayer.new()
			atk.bus = "SFX"
			atk.stream = preload("res://assets/sounds/knight_attack.mp3")
			atk.volume_db = 2.0
			get_tree().root.add_child(atk)
			atk.finished.connect(atk.queue_free)
			atk.play()

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
