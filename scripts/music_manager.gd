## music_manager.gd  — Autoload
## Background music with smooth crossfade between menu and game.
##
## API:
##   MusicManager.play_menu_music()   — call from main menu _ready()
##   MusicManager.play_game_music()   — call from game controller _ready()

extends Node

const MENU_MUSIC:    String = "res://assets/sounds/menu_music.mp3"
const MUSIC_DIR:     String = "res://assets/sounds/music/"
const FADE_DURATION: float  = 2.0   # seconds for crossfade

# Two players allow smooth crossfade between menu and game music.
var _menu_player: AudioStreamPlayer = null   # loops a single menu track
var _game_player: AudioStreamPlayer = null   # random game playlist

var _game_streams: Array[AudioStream] = []
var _last_idx:     int               = -1
var _game_active:  bool              = false
var _tween:        Tween             = null

func _ready() -> void:
	_menu_player = AudioStreamPlayer.new()
	_game_player = AudioStreamPlayer.new()
	_menu_player.volume_db = -80.0
	_game_player.volume_db = -80.0
	add_child(_menu_player)
	add_child(_game_player)
	_menu_player.finished.connect(_on_menu_finished)
	_game_player.finished.connect(_on_game_finished)
	# Ensure named buses exist before assigning them
	_ensure_bus("Music")
	_ensure_bus("SFX")
	_menu_player.bus = "Music"
	_game_player.bus = "Music"
	_load_tracks()
	# Apply persisted volumes (CameraConfig loads before MusicManager)
	var cam_cfg := get_node_or_null("/root/CameraConfig")
	if cam_cfg != null:
		set_music_volume(int(cam_cfg.get("music_volume")))
		set_sfx_volume(int(cam_cfg.get("sfx_volume")))

# ── Track loading ───────────────────────────────────────────────────────────

func _load_tracks() -> void:
	# Menu music (single looping track)
	var ms := load(MENU_MUSIC) as AudioStream
	if ms != null:
		_menu_player.stream = ms

	# Game music (random playlist)
	var dir := DirAccess.open(MUSIC_DIR)
	if dir == null:
		push_warning("[MusicManager] Cannot open: " + MUSIC_DIR)
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir():
			var ext := file.get_extension().to_lower()
			if ext == "mp3" or ext == "ogg" or ext == "wav":
				var s := load(MUSIC_DIR + file) as AudioStream
				if s != null:
					_game_streams.append(s)
		file = dir.get_next()
	dir.list_dir_end()

# ── Public API ──────────────────────────────────────────────────────────────

## Call from main_menu._ready() — fades in menu music, fades out game music.
func play_menu_music() -> void:
	_game_active = false
	if not _menu_player.playing:
		_menu_player.play()
	_crossfade(_game_player, _menu_player)

## Call from game_controller._ready() — fades in game music, fades out menu music.
func play_game_music() -> void:
	if _game_streams.is_empty():
		return
	_game_active = true
	if not _game_player.playing:
		_play_next_game_track()
	_crossfade(_menu_player, _game_player)

# ── Internal ────────────────────────────────────────────────────────────────

func _on_menu_finished() -> void:
	# Loop menu track forever
	_menu_player.play()

func _on_game_finished() -> void:
	if _game_active:
		_play_next_game_track()

func _play_next_game_track() -> void:
	if _game_streams.is_empty():
		return
	_game_player.stream = _game_streams[_pick_random()]
	_game_player.play()

func _pick_random() -> int:
	if _game_streams.size() == 1:
		return 0
	var idx := randi() % _game_streams.size()
	while idx == _last_idx:
		idx = randi() % _game_streams.size()
	_last_idx = idx
	return idx

## Parallel crossfade: fade out one player, fade in the other simultaneously.
func _crossfade(fade_out: AudioStreamPlayer, fade_in: AudioStreamPlayer) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(fade_out, "volume_db", -80.0, FADE_DURATION)
	_tween.tween_property(fade_in,  "volume_db",   0.0, FADE_DURATION)

# ── Volume control (called from settings UI) ────────────────────────────────

## Set music bus volume. pct = 0..100 (percentage).
func set_music_volume(pct: int) -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _pct_to_db(pct))

## Set SFX bus volume. pct = 0..100 (percentage).
func set_sfx_volume(pct: int) -> void:
	var idx := AudioServer.get_bus_index("SFX")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _pct_to_db(pct))

func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		var idx: int = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)

func _pct_to_db(pct: int) -> float:
	# Keep 0% fully muted; 100% is unity gain (0 dB).
	if pct <= 0:
		return -80.0

	# Perceptual curve: spreads useful changes across the full slider range,
	# so 20-100% is not "all the same" and low values are less jumpy.
	var t: float = clamp(float(pct) / 100.0, 0.0, 1.0)
	var perceptual: float = pow(t, 2.2)
	return linear_to_db(perceptual)
