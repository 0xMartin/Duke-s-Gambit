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
var _shuffle_bag:  Array[int]        = []
var _rng:          RandomNumberGenerator = RandomNumberGenerator.new()
var _game_active:  bool              = false
var _tween:        Tween             = null

# Dynamic music (tone shaping based on gameplay tension)
var _attack_tension_active: bool = false
var _check_tension_active: bool = false
var _checkmate_tension_active: bool = false
var _music_lpf: AudioEffectLowPassFilter = null
var _music_hpf: AudioEffectHighPassFilter = null
var _music_compressor: AudioEffectCompressor = null
var _music_distortion: AudioEffectDistortion = null

var _music_stereo: AudioEffectStereoEnhance = null
var _music_bus_idx: int = -1
var _dyn_tween: Tween = null
var _current_dynamic_preset: String = "normal"
var _attack_release_token: int = 0

const DYN_PRESET_NORMAL := "normal"
const DYN_PRESET_ATTACK := "attack"
const DYN_PRESET_CHECK := "check"
const DYN_PRESET_MATE := "mat"

const ATTACK_RELEASE_HOLD_SEC: float = 0.28

# Low-pass filter presets (removes high frequencies during tension)
const LPF_CUTOFF_NORMAL: float = 20500.0
const LPF_CUTOFF_ATTACK: float = 8000.0
const LPF_CUTOFF_CHECK: float = 4200.0
const LPF_CUTOFF_MATE: float = 2800.0

const LPF_RESO_NORMAL: float = 0.78
const LPF_RESO_ATTACK: float = 0.88
const LPF_RESO_CHECK: float = 1.05
const LPF_RESO_MATE: float = 1.10

# High-pass filter presets (removes low frequencies)
const HPF_CUTOFF_NORMAL: float = 20.0
const HPF_CUTOFF_ATTACK: float = 50.0
const HPF_CUTOFF_CHECK: float = 80.0
const HPF_CUTOFF_MATE: float = 100.0

# Compressor presets (dynamic range control)
const COMP_THRESHOLD_NORMAL: float = 0.0
const COMP_THRESHOLD_ATTACK: float = -15.0
const COMP_THRESHOLD_CHECK: float = -20.0
const COMP_THRESHOLD_MATE: float = -25.0

const COMP_RATIO_NORMAL: float = 1.0
const COMP_RATIO_ATTACK: float = 4.0
const COMP_RATIO_CHECK: float = 6.0
const COMP_RATIO_MATE: float = 8.0

const COMP_MAKEUP_GAIN_NORMAL: float = 0.0
const COMP_MAKEUP_GAIN_ATTACK: float = 2.0
const COMP_MAKEUP_GAIN_CHECK: float = 3.0
const COMP_MAKEUP_GAIN_MATE: float = 4.0

# Distortion presets (subtle overdrive during intensity)
const DIST_LEVEL_NORMAL: float = 0.0
const DIST_LEVEL_ATTACK: float = 0.15
const DIST_LEVEL_CHECK: float = 0.25
const DIST_LEVEL_MATE: float = 0.35


# Stereo enhancement (narrower during tension)
const STEREO_ENHANCE_NORMAL: float = 1.0
const STEREO_ENHANCE_ATTACK: float = 0.75
const STEREO_ENHANCE_CHECK: float = 0.5
const STEREO_ENHANCE_MATE: float = 0.3

# Pitch adjustments for tension
const PITCH_NORMAL: float = 1.00
const PITCH_ATTACK: float = 1.00
const PITCH_CHECK: float = 0.978
const PITCH_MATE: float = 0.970

# Tween transition duration
const TRANSITION_NORMAL: float = 0.55
const TRANSITION_ATTACK: float = 0.35

func _ready() -> void:
	_rng.randomize()
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
	_rebuild_shuffle_bag()
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
	# Always start a fresh random track when entering gameplay.
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
	var idx := _pick_random()
	_game_player.stream = _game_streams[idx]
	_game_player.play()

func _pick_random() -> int:
	if _game_streams.is_empty():
		return -1
	if _game_streams.size() == 1:
		_last_idx = 0
		return 0
	if _shuffle_bag.is_empty():
		_rebuild_shuffle_bag(_last_idx)
		if _shuffle_bag.is_empty():
			_rebuild_shuffle_bag()
	var idx: int = _shuffle_bag.pop_back()
	_last_idx = idx
	return idx

func _rebuild_shuffle_bag(exclude_idx: int = -1) -> void:
	_shuffle_bag.clear()
	for i in range(_game_streams.size()):
		if i == exclude_idx:
			continue
		_shuffle_bag.append(i)
	# Fisher-Yates shuffle for unbiased order.
	for i in range(_shuffle_bag.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := _shuffle_bag[i]
		_shuffle_bag[i] = _shuffle_bag[j]
		_shuffle_bag[j] = tmp

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
	_music_bus_idx = AudioServer.get_bus_index("Music")
	if _music_bus_idx < 0:
		return

	# Setup LPF at slot 0
	if _music_lpf == null:
		_music_lpf = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_lpf, 0)
	_music_lpf.cutoff_hz = LPF_CUTOFF_NORMAL
	_music_lpf.resonance = LPF_RESO_NORMAL

	# Setup HPF at slot 1
	if _music_hpf == null:
		_music_hpf = AudioEffectHighPassFilter.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_hpf, 1)
	_music_hpf.cutoff_hz = HPF_CUTOFF_NORMAL

	# Setup Compressor at slot 2
	if _music_compressor == null:
		_music_compressor = AudioEffectCompressor.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_compressor, 2)
	_music_compressor.threshold = COMP_THRESHOLD_NORMAL
	_music_compressor.ratio = COMP_RATIO_NORMAL
	_music_compressor.gain = COMP_MAKEUP_GAIN_NORMAL
	_music_compressor.attack_us = 10000  # 10ms
	_music_compressor.release_ms = 100

	# Setup Distortion at slot 3
	if _music_distortion == null:
		_music_distortion = AudioEffectDistortion.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_distortion, 3)
	_music_distortion.pre_gain = 0.0
	_music_distortion.post_gain = 0.0
	_music_distortion.mode = AudioEffectDistortion.MODE_OVERDRIVE

	# Setup Stereo Enhancement at slot 4 (was slot 5)
	if _music_stereo == null:
		_music_stereo = AudioEffectStereoEnhance.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_stereo, 4)
	_music_stereo.pan_pullout = STEREO_ENHANCE_NORMAL

func _apply_dynamic_music_tone(force_fast: bool = false) -> void:
	if _music_lpf == null:
		_ensure_music_lowpass()
	if _music_lpf == null:
		return

	var preset := _resolve_dynamic_preset()
	var target_cutoff: float = LPF_CUTOFF_NORMAL
	var target_reso: float = LPF_RESO_NORMAL
	var target_hpf_cutoff: float = HPF_CUTOFF_NORMAL
	var target_comp_threshold: float = COMP_THRESHOLD_NORMAL
	var target_comp_ratio: float = COMP_RATIO_NORMAL
	var target_comp_makeup: float = COMP_MAKEUP_GAIN_NORMAL
	var target_dist_level: float = DIST_LEVEL_NORMAL
	var target_stereo: float = STEREO_ENHANCE_NORMAL
	var target_pitch: float = PITCH_NORMAL

	match preset:
		DYN_PRESET_MATE:
			target_cutoff = LPF_CUTOFF_MATE
			target_reso = LPF_RESO_MATE
			target_hpf_cutoff = HPF_CUTOFF_MATE
			target_comp_threshold = COMP_THRESHOLD_MATE
			target_comp_ratio = COMP_RATIO_MATE
			target_comp_makeup = COMP_MAKEUP_GAIN_MATE
			target_dist_level = DIST_LEVEL_MATE
			target_stereo = STEREO_ENHANCE_MATE
			target_pitch = PITCH_MATE
		DYN_PRESET_CHECK:
			target_cutoff = LPF_CUTOFF_CHECK
			target_reso = LPF_RESO_CHECK
			target_hpf_cutoff = HPF_CUTOFF_CHECK
			target_comp_threshold = COMP_THRESHOLD_CHECK
			target_comp_ratio = COMP_RATIO_CHECK
			target_comp_makeup = COMP_MAKEUP_GAIN_CHECK
			target_dist_level = DIST_LEVEL_CHECK
			target_stereo = STEREO_ENHANCE_CHECK
			target_pitch = PITCH_CHECK
		DYN_PRESET_ATTACK:
			target_cutoff = LPF_CUTOFF_ATTACK
			target_reso = LPF_RESO_ATTACK
			target_hpf_cutoff = HPF_CUTOFF_ATTACK
			target_comp_threshold = COMP_THRESHOLD_ATTACK
			target_comp_ratio = COMP_RATIO_ATTACK
			target_comp_makeup = COMP_MAKEUP_GAIN_ATTACK
			target_dist_level = DIST_LEVEL_ATTACK
			target_stereo = STEREO_ENHANCE_ATTACK
			target_pitch = PITCH_ATTACK

	if preset != _current_dynamic_preset:
		_current_dynamic_preset = preset
		emit_signal("dynamic_preset_changed", preset)

	if _dyn_tween:
		_dyn_tween.kill()
	_dyn_tween = create_tween().set_parallel(true)
	var dur: float = TRANSITION_ATTACK if force_fast else TRANSITION_NORMAL

	# Animate LPF
	_dyn_tween.tween_property(_music_lpf, "cutoff_hz", target_cutoff, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_music_lpf, "resonance", target_reso, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Animate HPF
	if _music_hpf != null:
		_dyn_tween.tween_property(_music_hpf, "cutoff_hz", target_hpf_cutoff, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Animate Compressor
	if _music_compressor != null:
		_dyn_tween.tween_property(_music_compressor, "threshold", target_comp_threshold, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_dyn_tween.tween_property(_music_compressor, "ratio", target_comp_ratio, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_dyn_tween.tween_property(_music_compressor, "gain", target_comp_makeup, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Animate Distortion (pre_gain controls overdrive amount)
	if _music_distortion != null:
		_dyn_tween.tween_property(_music_distortion, "pre_gain", target_dist_level, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Animate Stereo Enhancement (narrower during tension)
	if _music_stereo != null:
		_dyn_tween.tween_property(_music_stereo, "pan_pullout", target_stereo, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Animate Pitch
	_dyn_tween.tween_property(_menu_player, "pitch_scale", target_pitch, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_game_player, "pitch_scale", target_pitch, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

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
