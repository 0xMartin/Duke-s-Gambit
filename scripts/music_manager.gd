## music_manager.gd  — Autoload
## Background music with smooth crossfade between menu and game.
##
## API:
##   MusicManager.play_menu_music()   — call from main menu _ready()
##   MusicManager.play_game_music()   — call from game controller _ready()

extends Node

signal dynamic_preset_changed(preset: String)

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

# Dynamic music (tone shaping based on gameplay tension)
var _attack_tension_active: bool = false
var _check_tension_active: bool = false
var _checkmate_tension_active: bool = false
var _music_lpf: AudioEffectLowPassFilter = null
var _music_lpf_bus_idx: int = -1
var _dyn_tween: Tween = null
var _current_dynamic_preset: String = "normal"
var _attack_release_token: int = 0

const DYN_PRESET_NORMAL := "normal"
const DYN_PRESET_ATTACK := "attack"
const DYN_PRESET_CHECK := "check"
const DYN_PRESET_MATE := "mat"

const ATTACK_RELEASE_HOLD_SEC: float = 0.28

const LPF_CUTOFF_NORMAL: float = 20500.0
const LPF_CUTOFF_ATTACK: float = 6500.0
const LPF_CUTOFF_CHECK: float = 3200.0
const LPF_CUTOFF_MATE: float = 2600.0

const LPF_RESO_NORMAL: float = 0.78
const LPF_RESO_ATTACK: float = 0.90
const LPF_RESO_CHECK: float = 1.08
const LPF_RESO_MATE: float = 1.12

const PITCH_NORMAL: float = 1.00
const PITCH_ATTACK: float = 1.00
const PITCH_CHECK: float = 0.978
const PITCH_MATE: float = 0.970

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
	_ensure_music_lowpass()
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
	reset_dynamic_music()
	if not _menu_player.playing:
		_menu_player.play()
	_crossfade(_game_player, _menu_player)

## Call from game_controller._ready() — fades in game music, fades out menu music.
func play_game_music() -> void:
	if _game_streams.is_empty():
		return
	_game_active = true
	reset_dynamic_music()
	if not _game_player.playing:
		_play_next_game_track()
	_crossfade(_menu_player, _game_player)

## Called while an attack animation is actively playing.
func set_attack_tension(active: bool) -> void:
	if active:
		_attack_release_token += 1
		_attack_tension_active = true
		_apply_dynamic_music_tone()
		return

	# Keep attack preset alive for a brief moment so the listener can perceive it.
	_attack_release_token += 1
	var token := _attack_release_token
	get_tree().create_timer(ATTACK_RELEASE_HOLD_SEC).timeout.connect(func() -> void:
		if token != _attack_release_token:
			return
		_attack_tension_active = false
		_apply_dynamic_music_tone()
	)

## Called when side-to-move is in check (active for as long as check lasts).
func set_check_tension(active: bool) -> void:
	_check_tension_active = active
	if not active:
		_checkmate_tension_active = false
	_apply_dynamic_music_tone()

## Called when game enters checkmate.
func set_checkmate_tension(active: bool) -> void:
	_checkmate_tension_active = active
	if active:
		_check_tension_active = true
	_apply_dynamic_music_tone()

## Clear all dynamic modifiers and return to normal music tone.
func reset_dynamic_music() -> void:
	_attack_tension_active = false
	_check_tension_active = false
	_checkmate_tension_active = false
	_apply_dynamic_music_tone(true)

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

func _ensure_music_lowpass() -> void:
	_music_lpf_bus_idx = AudioServer.get_bus_index("Music")
	if _music_lpf_bus_idx < 0:
		return

	# Reuse first low-pass filter already present on the Music bus, if any.
	for i in range(AudioServer.get_bus_effect_count(_music_lpf_bus_idx)):
		var fx := AudioServer.get_bus_effect(_music_lpf_bus_idx, i)
		if fx is AudioEffectLowPassFilter:
			_music_lpf = fx as AudioEffectLowPassFilter
			break

	# Otherwise add one dedicated low-pass filter for dynamic tone changes.
	if _music_lpf == null:
		_music_lpf = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(_music_lpf_bus_idx, _music_lpf, 0)

	_music_lpf.cutoff_hz = LPF_CUTOFF_NORMAL
	_music_lpf.resonance = LPF_RESO_NORMAL

func _apply_dynamic_music_tone(force_fast: bool = false) -> void:
	if _music_lpf == null:
		_ensure_music_lowpass()
	if _music_lpf == null:
		return

	var preset := _resolve_dynamic_preset()
	var target_cutoff: float = LPF_CUTOFF_NORMAL
	var target_reso: float = LPF_RESO_NORMAL
	var target_pitch: float = PITCH_NORMAL
	if preset == DYN_PRESET_MATE:
		target_cutoff = LPF_CUTOFF_MATE
		target_reso = LPF_RESO_MATE
		target_pitch = PITCH_MATE
	elif preset == DYN_PRESET_CHECK:
		target_cutoff = LPF_CUTOFF_CHECK
		target_reso = LPF_RESO_CHECK
		target_pitch = PITCH_CHECK
	elif preset == DYN_PRESET_ATTACK:
		target_cutoff = LPF_CUTOFF_ATTACK
		target_reso = LPF_RESO_ATTACK
		target_pitch = PITCH_ATTACK

	if preset != _current_dynamic_preset:
		_current_dynamic_preset = preset
		emit_signal("dynamic_preset_changed", preset)

	if _dyn_tween:
		_dyn_tween.kill()
	_dyn_tween = create_tween().set_parallel(true)
	var dur: float = 0.20 if force_fast else 0.55
	_dyn_tween.tween_property(_music_lpf, "cutoff_hz", target_cutoff, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_music_lpf, "resonance", target_reso, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_menu_player, "pitch_scale", target_pitch, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_game_player, "pitch_scale", target_pitch, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _resolve_dynamic_preset() -> String:
	if _checkmate_tension_active:
		return DYN_PRESET_MATE
	if _check_tension_active:
		return DYN_PRESET_CHECK
	if _attack_tension_active:
		return DYN_PRESET_ATTACK
	return DYN_PRESET_NORMAL

func _pct_to_db(pct: int) -> float:
	# Keep 0% fully muted; 100% is unity gain (0 dB).
	if pct <= 0:
		return -80.0

	# Perceptual curve: spreads useful changes across the full slider range,
	# so 20-100% is not "all the same" and low values are less jumpy.
	var t: float = clamp(float(pct) / 100.0, 0.0, 1.0)
	var perceptual: float = pow(t, 2.2)
	return linear_to_db(perceptual)
