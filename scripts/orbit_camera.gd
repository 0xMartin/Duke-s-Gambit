## orbit_camera.gd
## Orbit camera with a pivot at the board centre.
## RMB or MMB drag = rotate azimuth + change elevation; scroll = zoom.
## After each move the camera smoothly faces the active player's side,
## resets the pivot to board centre, and ensures a comfortable zoom level.

class_name OrbitCamera
extends Node3D

# ── Config ─────────────────────────────────────────────────────────────────
@export var distance_min:   float = 3.0
@export var distance_max:   float = 25.0
@export var distance:       float = 11.2
@export var distance_after_move: float = 11.2  # max distance snapped to after each move

@export var elevation_min:  float = 10.0  # degrees
@export var elevation_max:  float = 80.0  # degrees
@export var elevation:      float = 40.0  # current, degrees

@export var rotate_speed:   float = 0.4   # deg per pixel
@export var zoom_speed:     float = 1.2
@export var smooth_speed:   float = 4.0   # for auto-rotate after move

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

@onready var _cam: Camera3D = $Camera3D

# ── Ready ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	_apply_transform()

# ── Input ──────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# Both RMB and MMB activate the same orbit+elevation drag
		if mb.button_index == MOUSE_BUTTON_RIGHT \
		or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
			if _dragging:
				_drag_start           = mb.position
				_drag_azimuth_start   = _azimuth
				_drag_elevation_start = elevation
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

# ── Process ────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_azimuth  = _lerp_angle(_azimuth, _target_azimuth, smooth_speed * delta)
	elevation = lerp(elevation, _target_elevation, smooth_speed * delta)
	distance  = lerp(distance, _target_distance, smooth_speed * delta)
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

# ── Public API ─────────────────────────────────────────────────────────────
## Called by GameController after a move. Smoothly rotates to face active player,
## resets pivot to board centre, and ensures a comfortable viewing distance.
func face_player(color: int) -> void:
	_target_azimuth   = AZIMUTH_WHITE if color == ChessEnums.PieceColor.WHITE else AZIMUTH_BLACK
	_target_elevation = 40.0
	position          = Vector3.ZERO                              # reset pivot to board centre
	_target_distance  = minf(_target_distance, distance_after_move)  # pull in if too far out

## Teleport instantly (used on game start)
func snap_to_player(color: int) -> void:
	_azimuth          = AZIMUTH_WHITE if color == ChessEnums.PieceColor.WHITE else AZIMUTH_BLACK
	_target_azimuth   = _azimuth
	elevation         = 40.0
	_target_elevation = elevation
	_apply_transform()

## Lerp shortest path between two angles
func _lerp_angle(from: float, to: float, weight: float) -> float:
	var diff := fmod(to - from + 540.0, 360.0) - 180.0
	return from + diff * weight
