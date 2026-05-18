## Drives fire VFX, dust density and lighting based on each side's lost material.
## FireWhite tracks WHITE losses, FireBlack tracks BLACK losses.

class_name MaterialPressureFX
extends Node

const MATERIAL_TOTAL: int = 39
const THRESHOLD_FIRE1: float = 0.20
const THRESHOLD_FIRE2: float = 0.50
const THRESHOLD_FIRE3: float = 0.70
const LIGHT_TWEEN_SEC: float = 10.0
const FIRE_AUDIO_FADE_IN_SEC: float = 1.0
const FIRE_AUDIO_SILENT_DB: float = -40.0

const PIECE_MATERIAL := {
	ChessEnums.PieceType.PAWN: 1,
	ChessEnums.PieceType.KNIGHT: 3,
	ChessEnums.PieceType.BISHOP: 3,
	ChessEnums.PieceType.ROOK: 5,
	ChessEnums.PieceType.QUEEN: 9,
}

const DUST_BY_LEVEL := {
	0: 160,
	1: 220,
	2: 320,
	3: 460,
}

const AMBIENT_BY_LEVEL := {
	0: 0.55,
	1: 0.47,
	2: 0.40,
	3: 0.25,
}

const DIRECTIONAL_BY_LEVEL := {
	0: 0.65,
	1: 0.56,
	2: 0.50,
	3: 0.45,
}

@onready var _fire_white: Node = get_parent().get_node_or_null("FireWhite")
@onready var _fire_black: Node = get_parent().get_node_or_null("FireBlack")
@onready var _dust: GPUParticles3D = get_parent().get_node_or_null("Particles/DustParticles") as GPUParticles3D
@onready var _world_env: WorldEnvironment = get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
@onready var _dir_light: DirectionalLight3D = get_parent().get_node_or_null("DirectionalLight3D") as DirectionalLight3D

var _light_tween: Tween = null
var _fire_audio_default_db: Dictionary = {}
var _fire_audio_tweens: Dictionary = {}

func _ready() -> void:
	_cache_fire_audio_defaults(_fire_white)
	_cache_fire_audio_defaults(_fire_black)
	reset_effects()

func reset_effects() -> void:
	_set_fire_level(_fire_white, 0, true)
	_set_fire_level(_fire_black, 0, true)
	_set_dust_level(0)
	_apply_lighting_level_immediate(0)

## captured_by uses GameController format:
## captured_by[WHITE] = pieces captured by white (so BLACK losses)
## captured_by[BLACK] = pieces captured by black (so WHITE losses)
func update_from_captured(captured_by: Array) -> void:
	if captured_by.size() < 2:
		return

	var black_losses: int = _material_loss(captured_by[ChessEnums.PieceColor.WHITE])
	var white_losses: int = _material_loss(captured_by[ChessEnums.PieceColor.BLACK])

	var white_level: int = _level_from_ratio(float(white_losses) / float(MATERIAL_TOTAL))
	var black_level: int = _level_from_ratio(float(black_losses) / float(MATERIAL_TOTAL))

	_set_fire_level(_fire_white, white_level)
	_set_fire_level(_fire_black, black_level)

	var global_level: int = maxi(white_level, black_level)
	_set_dust_level(global_level)
	_tween_lighting_level(global_level)

func _material_loss(captured_types: Array) -> int:
	var total: int = 0
	for piece_type: int in captured_types:
		if piece_type == ChessEnums.PieceType.KING:
			continue
		if PIECE_MATERIAL.has(piece_type):
			total += int(PIECE_MATERIAL[piece_type])
	return total

func _level_from_ratio(ratio: float) -> int:
	if ratio >= THRESHOLD_FIRE3:
		return 3
	if ratio >= THRESHOLD_FIRE2:
		return 2
	if ratio >= THRESHOLD_FIRE1:
		return 1
	return 0

func _set_fire_level(root: Node, level: int, force_audio_sync: bool = false) -> void:
	if root == null:
		return
	for idx in range(1, 4):
		var fire_node := root.get_node_or_null("Fire%d" % idx) as Node3D
		if fire_node != null:
			var should_be_visible: bool = idx <= level
			var changed: bool = fire_node.visible != should_be_visible
			fire_node.visible = should_be_visible
			if changed or force_audio_sync:
				_set_fire_audio_state(fire_node, should_be_visible)

func _cache_fire_audio_defaults(root: Node) -> void:
	if root == null:
		return
	for idx in range(1, 4):
		var fire_node := root.get_node_or_null("Fire%d" % idx) as Node3D
		if fire_node == null:
			continue
		var audio := fire_node.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
		if audio == null:
			continue
		var key := str(fire_node.get_path())
		_fire_audio_default_db[key] = audio.volume_db

func _set_fire_audio_state(fire_node: Node3D, active: bool) -> void:
	var audio := fire_node.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	if audio == null:
		return
	var key := str(fire_node.get_path())
	var target_db: float = float(_fire_audio_default_db.get(key, audio.volume_db))

	if _fire_audio_tweens.has(key):
		var prev_tween := _fire_audio_tweens[key] as Tween
		if prev_tween != null:
			prev_tween.kill()
		_fire_audio_tweens.erase(key)

	if active:
		audio.volume_db = FIRE_AUDIO_SILENT_DB
		if not audio.playing:
			audio.play()
		var tw := create_tween()
		_fire_audio_tweens[key] = tw
		tw.tween_property(audio, "volume_db", target_db, FIRE_AUDIO_FADE_IN_SEC) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.finished.connect(func() -> void:
			if _fire_audio_tweens.get(key) == tw:
				_fire_audio_tweens.erase(key)
		)
	else:
		audio.stop()
		audio.volume_db = target_db

func _set_dust_level(level: int) -> void:
	if _dust == null:
		return
	var amount: int = int(DUST_BY_LEVEL.get(level, DUST_BY_LEVEL[0]))
	_dust.amount = amount

func _apply_lighting_level_immediate(level: int) -> void:
	if _light_tween != null:
		_light_tween.kill()
	_set_lighting_values(level)

func _tween_lighting_level(level: int) -> void:
	if _light_tween != null:
		_light_tween.kill()
	_light_tween = create_tween().set_parallel(true)
	if _world_env != null and _world_env.environment != null:
		var ambient: float = float(AMBIENT_BY_LEVEL.get(level, AMBIENT_BY_LEVEL[0]))
		_light_tween.tween_property(_world_env.environment, "ambient_light_energy", ambient, LIGHT_TWEEN_SEC) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _dir_light != null:
		var energy: float = float(DIRECTIONAL_BY_LEVEL.get(level, DIRECTIONAL_BY_LEVEL[0]))
		_light_tween.tween_property(_dir_light, "light_energy", energy, LIGHT_TWEEN_SEC) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _set_lighting_values(level: int) -> void:
	if _world_env != null and _world_env.environment != null:
		_world_env.environment.ambient_light_energy = float(AMBIENT_BY_LEVEL.get(level, AMBIENT_BY_LEVEL[0]))
	if _dir_light != null:
		_dir_light.light_energy = float(DIRECTIONAL_BY_LEVEL.get(level, DIRECTIONAL_BY_LEVEL[0]))
