## orbit_camera.gd
## Orbit camera with a pivot at the board centre.
## RMB drag = rotate azimuth + change elevation; MMB drag = pan pivot left/right; scroll = zoom.
## After each move the camera smoothly faces the active player's side,
## resets the pivot to board centre, and ensures a comfortable zoom level.

class_name OrbitCamera
extends Node3D

# ── Config ─────────────────────────────────────────────────────────────────
@export var distance_min:   float = 3.0
@export var distance_max:   float = 14.0
@export var distance:       float = 11.2
@export var distance_after_move: float = 11.2  # max distance snapped to after each move

@export var elevation_min:  float = 10.0  # degrees
@export var elevation_max:  float = 80.0  # degrees
@export var elevation:      float = 40.0  # current, degrees

@export var rotate_speed:   float = 0.4   # deg per pixel (overridden by CameraConfig)
@export var zoom_speed:     float = 1.2
@export var smooth_speed:   float = 4.0   # for auto-rotate after move

@export var pan_speed:      float = 0.0015  # world-units per pixel per distance-unit (overridden by CameraConfig)

# Side azimuths: WHITE looks from -Z side (azimuth=180), BLACK from +Z (azimuth=0)
const AZIMUTH_WHITE := 180.0
const AZIMUTH_BLACK := 0.0

var _azimuth: float = AZIMUTH_WHITE
var _target_azimuth:   float = AZIMUTH_WHITE
var _target_elevation: float = 40.0
var _target_distance:  float = 11.2

# Unified drag state (RMB or MMB)
var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_azimuth_start:   float = 0.0
var _drag_elevation_start: float = 0.0

# MMB pan state
var _panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _pan_pivot_start: Vector3 = Vector3.ZERO

# Kill cam state
const KILL_CAM_ORBIT_SPEED      := 18.0   # deg/s cinematic orbit during regular kill cam
const CHECKMATE_CAM_ORBIT_SPEED :=  6.0   # deg/s slow mournful orbit around dying king
var _kill_cam_active:      bool    = false
var _checkmate_cam_active: bool    = false  # set together with _kill_cam_active for checkmate
var _kill_cam_track:       Node3D  = null    # moving attacker piece
var _kill_cam_target_pos:  Vector3 = Vector3.ZERO  # capture destination (XZ)
var _pre_kill_cam_distance: float  = 11.2  # zoom saved before kill cam, restored after

@onready var _cam: Camera3D = $Camera3D

# Shake state
var _shake_strength: float = 0.0
var _shake_timer:    float = 0.0
var _shake_dur:      float = 0.0

# ── Ready ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		pan_speed    = cam_cfg.pan_speed()
		rotate_speed = cam_cfg.tilt_speed()
	_apply_transform()

# ── Input ──────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if _kill_cam_active:
		return   # block all camera controls during kill cam
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			# RMB: orbit (azimuth) + elevation
			_dragging = mb.pressed
			if _dragging:
				_drag_start           = mb.position
				_drag_azimuth_start   = _azimuth
				_drag_elevation_start = elevation
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			# MMB: pan pivot left/right
			_panning = mb.pressed
			if _panning:
				_pan_start       = mb.position
				_pan_pivot_start = position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_target_distance = clamp(_target_distance - zoom_speed, distance_min, distance_max)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_target_distance = clamp(_target_distance + zoom_speed, distance_min, distance_max)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			var delta := mm.position - _drag_start
			# Horizontal → azimuth (orbit), vertical → elevation
			_azimuth = _drag_azimuth_start - delta.x * rotate_speed
			_target_azimuth = _azimuth
			elevation = clamp(_drag_elevation_start + delta.y * rotate_speed,
							elevation_min, elevation_max)
			_target_elevation = elevation
		elif _panning:
			var d := mm.position - _pan_start
			var az_rad := deg_to_rad(_azimuth)
			var right   := Vector3(cos(az_rad),  0.0, -sin(az_rad))
			var forward := Vector3(sin(az_rad),  0.0,  cos(az_rad))
			var scale := distance * pan_speed
			var new_pos := _pan_pivot_start \
				+ right   * (-d.x * scale) \
				+ forward * (-d.y * scale)
			new_pos.x = clamp(new_pos.x, -4.0, 4.0)
			new_pos.z = clamp(new_pos.z, -4.0, 4.0)
			position = new_pos

# ── Process ────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _kill_cam_active:
		# Orbit speed: slow mournful for checkmate, faster for regular capture.
		var orb_speed := CHECKMATE_CAM_ORBIT_SPEED if _checkmate_cam_active else KILL_CAM_ORBIT_SPEED
		_target_azimuth += orb_speed * delta
		# Track attacker OR converge on a fixed target (checkmate cam).
		if _kill_cam_track != null and is_instance_valid(_kill_cam_track):
			var piece_xz := Vector3(_kill_cam_track.global_position.x, 0.0,
								_kill_cam_track.global_position.z)
			var mid := (piece_xz + _kill_cam_target_pos) * 0.5
			position = position.lerp(mid, smooth_speed * delta)
		else:
			# Checkmate cam: pivot glides smoothly toward the king.
			position = position.lerp(_kill_cam_target_pos, smooth_speed * 0.5 * delta)
	_azimuth  = _lerp_angle(_azimuth, _target_azimuth, smooth_speed * delta)
	elevation = lerp(elevation, _target_elevation, smooth_speed * delta)
	distance  = lerp(distance, _target_distance, smooth_speed * delta)
	if _shake_dur > 0.0:
		_shake_timer = minf(_shake_timer + delta, _shake_dur)
	_apply_transform()

func _apply_transform() -> void:
	# Pivot is this node's position (should be at board centre).
	# Camera sits at (azimuth, elevation) spherical coords from pivot.
	var az_rad := deg_to_rad(_azimuth)
	var el_rad := deg_to_rad(elevation)
	var offset := Vector3(
		sin(az_rad) * cos(el_rad),
		sin(el_rad),
		cos(az_rad) * cos(el_rad)
	) * distance
	if _cam:
		_cam.position = offset
		_cam.look_at(global_position, Vector3.UP)
		# Apply camera shake as a small post-look rotation
		if _shake_dur > 0.0:
			var t: float = clamp(_shake_timer / _shake_dur, 0.0, 1.0)
			var str: float = _shake_strength * (1.0 - t)
			_cam.rotate_object_local(Vector3.RIGHT, randf_range(-str, str))
			_cam.rotate_object_local(Vector3.UP,   randf_range(-str, str))

# ── Public API ─────────────────────────────────────────────────────────────
## Called by GameController after a move. Smoothly rotates to face active player,
## resets pivot to board centre, and ensures a comfortable viewing distance.
func face_player(color: int) -> void:
	# Cancel any active drag or kill cam so the camera returns cleanly.
	_dragging             = false
	_panning              = false
	# Restore zoom to what it was before the kill cam (capped to distance_after_move).
	if _kill_cam_active:
		_target_distance = minf(_pre_kill_cam_distance, distance_after_move)
	else:
		_target_distance = minf(_target_distance, distance_after_move)
	_kill_cam_active      = false
	_checkmate_cam_active = false
	_kill_cam_track       = null

	_target_azimuth   = AZIMUTH_WHITE if color == ChessEnums.PieceColor.WHITE else AZIMUTH_BLACK
	_target_elevation = 40.0
	position          = Vector3.ZERO                              # reset pivot to board centre

## Teleport instantly (used on game start)
func snap_to_player(color: int) -> void:
	_azimuth          = AZIMUTH_WHITE if color == ChessEnums.PieceColor.WHITE else AZIMUTH_BLACK
	_target_azimuth   = _azimuth
	elevation         = 40.0
	_target_elevation = elevation
	_apply_transform()

## Dramatic close-up of a capture. Called by GameController before the capture animation.
## Tracks the attacker piece, slowly orbits the action point, blocks user input.
## face_player() restores the view after the animation finishes.
func kill_cam(from_world: Vector3, to_world: Vector3, attacker: Node3D = null) -> void:
	_dragging = false
	_panning  = false
	_kill_cam_active     = true
	_kill_cam_track      = attacker
	_kill_cam_target_pos = Vector3(to_world.x, 0.0, to_world.z)

	# Pivot at midpoint between attacker origin and capture square.
	var mid := (from_world + to_world) * 0.5
	mid.y    = 0.0
	position = mid

	# Attack direction in XZ plane.
	var dir: Vector3 = (to_world - from_world)
	dir.y = 0.0
	var len: float = dir.length()

	# Perpendicular to attack (90° CCW in XZ) → side-on cinematic angle.
	var perp: Vector3
	if len > 0.01:
		dir  = dir.normalized()
		perp = Vector3(-dir.z, 0.0, dir.x)
	else:
		perp = Vector3(1.0, 0.0, 0.0)

	# Azimuth: camera sits in the direction of `perp` from the pivot.
	# Convention: camera offset = (sin(az)*cos(el), sin(el), cos(az)*cos(el)) * dist
	_target_azimuth = rad_to_deg(atan2(perp.x, perp.z))
	_azimuth        = _target_azimuth   # snap azimuth immediately, no spin

	# Low cinematic elevation.
	_target_elevation = 20.0

	# Distance: show both pieces clearly, scaled by their separation.
	var separation: float = maxf(len, 1.0)
	_pre_kill_cam_distance = _target_distance  # save zoom before overwriting
	_target_distance = clamp(separation * 2.0 + 1.5, 3.5, 7.0)

## Cinematic close-up of the losing king after checkmate.
## Smoothly moves the pivot toward the king, zooms in and orbits slowly.
## kill_cam_enabled setting controls whether this fires (caller checks it).
func checkmate_cam(king_world: Vector3) -> void:
	_dragging             = false
	_panning              = false
	_kill_cam_active      = true
	_checkmate_cam_active = true
	_kill_cam_track       = null   # nothing moving; pivot drifts on its own in _process()
	_kill_cam_target_pos  = Vector3(king_world.x, 0.0, king_world.z)

	# Dramatically lower elevation and zoom-in — camera peers at the fallen king.
	_target_elevation      = 22.0
	_pre_kill_cam_distance = _target_distance
	_target_distance       = 5.0
	# Keep current azimuth so there's no jarring flip; orbit handles rotation slowly.

## Called when the king hits the ground — emphasises the impact before the game-over panel.
## Adds a camera shake and a final dramatic close push.
func king_impact() -> void:
	shake(0.06, 0.9)
	_target_elevation = 12.0
	_target_distance  = 3.0

## Lerp shortest path between two angles
func _lerp_angle(from: float, to: float, weight: float) -> float:
	var diff := fmod(to - from + 540.0, 360.0) - 180.0
	return from + diff * weight

## Brief screen-space shake. strength is in radians (e.g. 0.04 ≈ light hit).
func shake(strength: float, duration: float) -> void:
	_shake_strength = strength
	_shake_dur      = duration
	_shake_timer    = 0.0
