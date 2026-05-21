## camera_config.gd
## Autoload singleton: stores camera sensitivity settings, persisted to disk.
## Pan and tilt use a 1–10 integer scale; helpers return actual float values.

extends Node

const CONFIG_PATH := "user://saves/camera_config.cfg"

# 1–10 scale; 5 = default
var pan_sensitivity:  int  = 5
var tilt_sensitivity: int  = 5
var kill_cam_enabled:       bool = true
var face_player_after_move: bool = true
# 0–100 %; default: music lower than SFX
var music_volume: int = 50
var sfx_volume:   int = 100

func _ready() -> void:
	_load()

# ── Value helpers ──────────────────────────────────────────────────────────
func pan_speed() -> float:
	return pan_sensitivity * 0.0003        # 5 → 0.0015 (half of original 0.003)

# Horizontal rotation speed for touch (deg/pixel), uses pan_sensitivity scale.
func pan_rot_speed() -> float:
	return pan_sensitivity * 0.08          # 5 → 0.40

func tilt_speed() -> float:
	return tilt_sensitivity * 0.08         # 5 → 0.40

# ── Persistence ────────────────────────────────────────────────────────────
func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		pan_sensitivity  = cfg.get_value("camera", "pan_sensitivity",  5)
		tilt_sensitivity = cfg.get_value("camera", "tilt_sensitivity", 5)
		kill_cam_enabled       = cfg.get_value("camera", "kill_cam_enabled",       true)
		face_player_after_move = cfg.get_value("camera", "face_player_after_move", true)
		music_volume = cfg.get_value("audio",  "music_volume", 50)
		sfx_volume   = cfg.get_value("audio",  "sfx_volume",   100)

func save_config() -> void:
	DirAccess.make_dir_recursive_absolute("user://saves")
	var cfg := ConfigFile.new()
	cfg.set_value("camera", "pan_sensitivity",  pan_sensitivity)
	cfg.set_value("camera", "tilt_sensitivity", tilt_sensitivity)
	cfg.set_value("camera", "kill_cam_enabled",       kill_cam_enabled)
	cfg.set_value("camera", "face_player_after_move", face_player_after_move)
	cfg.set_value("audio",  "music_volume", music_volume)
	cfg.set_value("audio",  "sfx_volume",   sfx_volume)
	cfg.save(CONFIG_PATH)
