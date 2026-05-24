## music_manager.gd — Autoload
##
## Background music with smooth crossfade between menu and game modes.
## Supports two sources for game music:
##   • Offline  — local MP3 assets bundled with the game (always available).
##   • Online   — tracks streamed from the game server over HTTPS and cached
##                locally so repeated listens cost no extra bandwidth.
##
## Public API:
##   MusicManager.play_menu_music()       — call from main_menu._ready()
##   MusicManager.play_game_music()       — call from game controller _ready()
##   MusicManager.set_attack_tension()    — call during attack animations
##   MusicManager.set_check_tension()     — call when king is in check
##   MusicManager.set_checkmate_tension() — call on checkmate
##   MusicManager.reset_dynamic_music()   — call at game start / game over
##   MusicManager.set_music_volume(pct)   — 0-100, called from settings UI
##   MusicManager.set_sfx_volume(pct)     — 0-100, called from settings UI

extends Node

signal dynamic_preset_changed(preset: String)


# ────────────────────────────────────────────────────────────────────────────
#   CONSTANTS                                                               
# ────────────────────────────────────────────────────────────────────────────

# ── Shared ──────────────────────────────────────────────────────────────────
const FADE_DURATION: float = 2.0        # crossfade duration in seconds

# ── Offline (local bundled assets) ──────────────────────────────────────────
const MENU_MUSIC: String = "res://assets/sounds/menu_music.mp3"
const MUSIC_DIR:  String = "res://assets/sounds/music/"

# ── Online (streaming from game server) ─────────────────────────────────────
## Tracks downloaded from the server are cached here so subsequent
## plays require no network round-trip.
const MUSIC_CACHE_DIR := "user://music_cache/"

# ── Dynamic music — preset names ────────────────────────────────────────────
const DYN_PRESET_NORMAL := "normal"
const DYN_PRESET_ATTACK := "attack"
const DYN_PRESET_CHECK  := "check"
const DYN_PRESET_MATE   := "mat"

const ATTACK_RELEASE_HOLD_SEC: float = 0.28   # attack tone lingers briefly after anim ends

# ── Dynamic music — low-pass filter presets (removes highs during tension) ──
const LPF_CUTOFF_NORMAL: float = 20500.0
const LPF_CUTOFF_ATTACK: float = 8000.0
const LPF_CUTOFF_CHECK:  float = 4200.0
const LPF_CUTOFF_MATE:   float = 2800.0

const LPF_RESO_NORMAL: float = 0.78
const LPF_RESO_ATTACK: float = 0.88
const LPF_RESO_CHECK:  float = 1.05
const LPF_RESO_MATE:   float = 1.10

# ── Dynamic music — high-pass filter presets (removes lows) ─────────────────
const HPF_CUTOFF_NORMAL: float = 20.0
const HPF_CUTOFF_ATTACK: float = 50.0
const HPF_CUTOFF_CHECK:  float = 80.0
const HPF_CUTOFF_MATE:   float = 100.0

# ── Dynamic music — compressor presets (dynamic-range control) ───────────────
const COMP_THRESHOLD_NORMAL: float =  0.0
const COMP_THRESHOLD_ATTACK: float = -15.0
const COMP_THRESHOLD_CHECK:  float = -20.0
const COMP_THRESHOLD_MATE:   float = -25.0

const COMP_RATIO_NORMAL: float = 1.0
const COMP_RATIO_ATTACK: float = 4.0
const COMP_RATIO_CHECK:  float = 6.0
const COMP_RATIO_MATE:   float = 8.0

const COMP_MAKEUP_GAIN_NORMAL: float = 0.0
const COMP_MAKEUP_GAIN_ATTACK: float = 2.0
const COMP_MAKEUP_GAIN_CHECK:  float = 3.0
const COMP_MAKEUP_GAIN_MATE:   float = 4.0

# ── Dynamic music — distortion presets (subtle overdrive at high tension) ────
const DIST_LEVEL_NORMAL: float = 0.0
const DIST_LEVEL_ATTACK: float = 0.15
const DIST_LEVEL_CHECK:  float = 0.25
const DIST_LEVEL_MATE:   float = 0.35

# ── Dynamic music — stereo width presets (narrows under tension) ─────────────
const STEREO_ENHANCE_NORMAL: float = 1.0
const STEREO_ENHANCE_ATTACK: float = 0.75
const STEREO_ENHANCE_CHECK:  float = 0.5
const STEREO_ENHANCE_MATE:   float = 0.3

# ── Dynamic music — pitch presets ───────────────────────────────────────────
const PITCH_NORMAL: float = 1.00
const PITCH_ATTACK: float = 1.00
const PITCH_CHECK:  float = 0.978
const PITCH_MATE:   float = 0.970

# ── Dynamic music — tween durations ─────────────────────────────────────────
const TRANSITION_NORMAL: float = 0.55
const TRANSITION_ATTACK: float = 0.35


# ────────────────────────────────────────────────────────────────────────────
#   RUNTIME STATE                                                           
# ────────────────────────────────────────────────────────────────────────────

# ── Audio players & crossfade ────────────────────────────────────────────────
## Two players allow seamless crossfade between menu and game music.
var _menu_player: AudioStreamPlayer = null   # loops a single menu track
var _game_player: AudioStreamPlayer = null   # game playlist (offline or streaming)
var _tween:       Tween             = null   # crossfade tween handle

# ── Offline playlist state ───────────────────────────────────────────────────
var _game_streams: Array[AudioStream]    = []
var _last_idx:     int                   = -1
var _shuffle_bag:  Array[int]            = []
var _rng:          RandomNumberGenerator = RandomNumberGenerator.new()
var _game_active:  bool                  = false

# ── Online streaming state ───────────────────────────────────────────────────
## _track_info_mode routes the server's track_info response to either the
## "main" handler (download-then-play) or the "prefetch" handler (background
## download for the *next* song). Only one mode is active at a time — this
## prevents two callbacks from being connected to the same signal simultaneously.
enum _TrackMode { NONE, MAIN, PREFETCH }
var _track_info_mode:   int         = _TrackMode.NONE

var _http_request:      HTTPRequest = null   # primary download node (current track)
var _prefetch_request:  HTTPRequest = null   # secondary download node (next track)
var _pending_track:     String      = ""     # track being fetched by _http_request
var _prefetched_track:  String      = ""     # track fetched (or being fetched) by _prefetch_request
var _prefetch_done:     bool        = false  # true when prefetch download succeeded
var _play_after_prefetch: bool      = false  # set when song ends while prefetch is still downloading

# ── Dynamic music effect state ───────────────────────────────────────────────
var _attack_tension_active:    bool = false
var _check_tension_active:     bool = false
var _checkmate_tension_active: bool = false
var _music_lpf:        AudioEffectLowPassFilter  = null
var _music_hpf:        AudioEffectHighPassFilter = null
var _music_compressor: AudioEffectCompressor     = null
var _music_distortion: AudioEffectDistortion     = null
var _music_stereo:     AudioEffectStereoEnhance  = null
var _music_bus_idx:    int                       = -1
var _dyn_tween:        Tween                     = null
var _current_dynamic_preset: String              = "normal"
var _attack_release_token:   int                 = 0


# ────────────────────────────────────────────────────────────────────────────
#   INITIALIZATION                                                          
# ────────────────────────────────────────────────────────────────────────────

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
	# Ensure named audio buses exist before assigning players to them.
	_ensure_bus("Music")
	_ensure_bus("SFX")
	_menu_player.bus = "Music"
	_game_player.bus = "Music"
	_ensure_music_lowpass()
	_load_tracks()
	_rebuild_shuffle_bag()
	# Apply persisted volume levels (CameraConfig autoloads before MusicManager).
	var cam_cfg := get_node_or_null("/root/CameraConfig")
	if cam_cfg != null:
		set_music_volume(int(cam_cfg.get("music_volume")))
		set_sfx_volume(int(cam_cfg.get("sfx_volume")))
	# Online streaming: create two HTTPRequest nodes — one for the current track,
	# one dedicated to prefetching the next track while the current plays.
	_http_request = HTTPRequest.new()
	_http_request.use_threads = true
	add_child(_http_request)
	_http_request.request_completed.connect(_on_download_complete)
	_prefetch_request = HTTPRequest.new()
	_prefetch_request.use_threads = true
	add_child(_prefetch_request)
	_prefetch_request.request_completed.connect(_on_prefetch_complete)
	DirAccess.make_dir_recursive_absolute(MUSIC_CACHE_DIR)

func _load_tracks() -> void:
	# Menu music — single looping track.
	var ms := load(MENU_MUSIC) as AudioStream
	if ms != null:
		_menu_player.stream = ms

	# Game music — hardcoded list so it works reliably in exported builds.
	const GAME_TRACKS: Array[String] = [
		"res://assets/sounds/music/music1.mp3",
		"res://assets/sounds/music/music2.mp3",
		"res://assets/sounds/music/music3.mp3",
		"res://assets/sounds/music/music4.mp3",
		"res://assets/sounds/music/music5.mp3",
		"res://assets/sounds/music/music6.mp3",
		"res://assets/sounds/music/music7.mp3",
		"res://assets/sounds/music/music8.mp3",
		"res://assets/sounds/music/music9.mp3",
		"res://assets/sounds/music/music10.mp3",
		"res://assets/sounds/music/music11.mp3",
	]
	for path in GAME_TRACKS:
		var s := load(path) as AudioStream
		if s != null:
			_game_streams.append(s)


# ────────────────────────────────────────────────────────────────────────────
#   PUBLIC API                                                              
# ────────────────────────────────────────────────────────────────────────────

## Fade in menu music, fade out game music. Call from main_menu._ready().
func play_menu_music() -> void:
	_game_active = false
	reset_dynamic_music()
	# Discard any in-flight online-streaming state from the previous game so it
	# cannot interfere with the next game (stale _track_info_mode would block
	# _request_online_track; a late _on_download_complete would send an extra
	# prefetch request and shift the server-side track index out of sync).
	_track_info_mode    = _TrackMode.NONE
	_pending_track      = ""
	_prefetched_track   = ""
	_prefetch_done      = false
	_play_after_prefetch = false
	_disconnect_online_track_signals()
	if not _menu_player.playing:
		_menu_player.play()
	_crossfade(_game_player, _menu_player)

## Fade in game music, fade out menu music. Call from game controller _ready().
func play_game_music() -> void:
	if _game_streams.is_empty() and not _is_online_mode():
		return
	_game_active = true
	reset_dynamic_music()
	if _is_online_mode():
		_request_online_track()
	else:
		_play_next_game_track()
	_crossfade(_menu_player, _game_player)

## Enable/disable attack tension. Call while an attack animation plays.
func set_attack_tension(active: bool) -> void:
	if active:
		_attack_release_token += 1
		_attack_tension_active = true
		_apply_dynamic_music_tone()
		return
	# Hold the attack preset briefly so the listener can perceive the hit.
	_attack_release_token += 1
	var token := _attack_release_token
	get_tree().create_timer(ATTACK_RELEASE_HOLD_SEC).timeout.connect(func() -> void:
		if token != _attack_release_token:
			return
		_attack_tension_active = false
		_apply_dynamic_music_tone()
	)

## Enable/disable check tension. Keep active for as long as check lasts.
func set_check_tension(active: bool) -> void:
	_check_tension_active = active
	if not active:
		_checkmate_tension_active = false
	_apply_dynamic_music_tone()

## Enable/disable checkmate tension.
func set_checkmate_tension(active: bool) -> void:
	_checkmate_tension_active = active
	if active:
		_check_tension_active = true
	_apply_dynamic_music_tone()

## Clear all dynamic modifiers and return to the normal music tone.
## Call at game start and game over.
func reset_dynamic_music() -> void:
	_attack_tension_active    = false
	_check_tension_active     = false
	_checkmate_tension_active = false
	_apply_dynamic_music_tone(true)

## Set Music bus volume. pct = 0..100 (percentage). Call from settings UI.
func set_music_volume(pct: int) -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _pct_to_db(pct))

## Set SFX bus volume. pct = 0..100 (percentage). Call from settings UI.
func set_sfx_volume(pct: int) -> void:
	var idx := AudioServer.get_bus_index("SFX")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, _pct_to_db(pct))


# ────────────────────────────────────────────────────────────────────────────
#   OFFLINE MUSIC (local assets)                                           
# ────────────────────────────────────────────────────────────────────────────

func _on_menu_finished() -> void:
	_menu_player.play()   # loop menu track indefinitely

func _on_game_finished() -> void:
	if not _game_active:
		return
	if _is_online_mode():
		_advance_online_playlist()
	else:
		_play_next_game_track()

## Play a random local game track, avoiding the one that just finished.
func _play_next_game_track() -> void:
	if _game_streams.is_empty():
		return
	var idx := _pick_random()
	_game_player.stream = _game_streams[idx]
	_game_player.play()

## Draw the next index from the shuffle bag; refill when empty.
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

## Fill the shuffle bag with all track indices (except exclude_idx) in random order.
func _rebuild_shuffle_bag(exclude_idx: int = -1) -> void:
	_shuffle_bag.clear()
	for i in range(_game_streams.size()):
		if i == exclude_idx:
			continue
		_shuffle_bag.append(i)
	# Fisher-Yates shuffle for unbiased ordering.
	for i in range(_shuffle_bag.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp         := _shuffle_bag[i]
		_shuffle_bag[i]  = _shuffle_bag[j]
		_shuffle_bag[j]  = tmp

## Parallel crossfade: fade one player out while fading the other in.
func _crossfade(fade_out: AudioStreamPlayer, fade_in: AudioStreamPlayer) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(fade_out, "volume_db", -80.0, FADE_DURATION)
	_tween.tween_property(fade_in,  "volume_db",   0.0, FADE_DURATION)


# ────────────────────────────────────────────────────────────────────────────
#   ONLINE STREAMING (server-provided tracks)                               
# ────────────────────────────────────────────────────────────────────────────
#   Flow overview:                                                          
#   1. play_game_music() → _request_online_track()                          
#      Server replies track_info → _on_any_track_info(MAIN)                 
#      → _download_track → _on_download_complete → _play_cached_track       
#      → _prefetch_next_track (background)                                  
#   2. _prefetch_next_track runs while the current song plays.              
#      Server replies track_info → _on_any_track_info(PREFETCH)             
#      → _handle_prefetch_track_info → background download.                 
#   3. Song ends → _on_game_finished → _advance_online_playlist()           
#      Prefetch done?   → play immediately, zero gap.                        
#      Prefetch active? → set _play_after_prefetch; auto-plays on finish.   
#      No prefetch?     → _request_online_track() (brief download gap).     
# ────────────────────────────────────────────────────────────────────────────

func _is_online_mode() -> bool:
	var oc := get_node_or_null("/root/OnlineClient")
	return oc != null and oc.get_state() == oc.State.READY

## Use the prefetched track if ready; otherwise fall back to a fresh request.
func _advance_online_playlist() -> void:
	if _prefetch_done and not _prefetched_track.is_empty():
		# Prefetch finished — play instantly, zero gap.
		var track := _prefetched_track
		_prefetched_track = ""
		_prefetch_done    = false
		_play_cached_track(track)
		_prefetch_next_track()
	elif not _prefetched_track.is_empty():
		# Prefetch download is still in progress — auto-play when it finishes.
		_play_after_prefetch = true
	else:
		# No prefetch started (e.g. server has no music) — request normally.
		_request_online_track()

## Ask the server for the next track name and download it for immediate play.
func _request_online_track() -> void:
	if _track_info_mode != _TrackMode.NONE:
		return   # already waiting for a server response; avoid duplicates
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		_play_next_game_track()
		return
	_track_info_mode = _TrackMode.MAIN
	if not oc.track_info_received.is_connected(_on_any_track_info):
		oc.track_info_received.connect(_on_any_track_info)
	if not oc.server_error.is_connected(_on_track_request_error):
		oc.server_error.connect(_on_track_request_error)
	oc.send_request_track()

## Ask the server for the NEXT track name and download it in the background
## while the current track is still playing. Eliminates the gap between songs.
func _prefetch_next_track() -> void:
	if not _is_online_mode() or _prefetch_request == null:
		return
	if _track_info_mode != _TrackMode.NONE:
		return   # another request is in flight — don't overlap
	_prefetch_done    = false
	_prefetched_track = ""
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		return
	_track_info_mode = _TrackMode.PREFETCH
	if not oc.track_info_received.is_connected(_on_any_track_info):
		oc.track_info_received.connect(_on_any_track_info)
	oc.send_request_track()

## Single dispatcher for all server track_info responses.
## Routes to the correct handler based on _track_info_mode.
func _on_any_track_info(track_name: String) -> void:
	var mode         := _track_info_mode
	_track_info_mode  = _TrackMode.NONE
	_disconnect_online_track_signals()
	if mode == _TrackMode.MAIN:
		_handle_main_track_info(track_name)
	elif mode == _TrackMode.PREFETCH:
		_handle_prefetch_track_info(track_name)

## Handle a track_info response for the currently-needed (main) track.
func _handle_main_track_info(track_name: String) -> void:
	if track_name.is_empty():
		_play_next_game_track()
		return
	if FileAccess.file_exists(MUSIC_CACHE_DIR + track_name):
		_play_cached_track(track_name)
		_prefetch_next_track()
	else:
		_download_track(track_name)

## Handle a track_info response for the upcoming (prefetch) track.
func _handle_prefetch_track_info(track_name: String) -> void:
	if track_name.is_empty() or not _game_active:
		return
	if FileAccess.file_exists(MUSIC_CACHE_DIR + track_name):
		# Already in cache — mark ready immediately, no download needed.
		_prefetched_track = track_name
		_prefetch_done    = true
		_maybe_play_after_prefetch()
		return
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		return
	var base_url: String = oc.get_http_base_url()
	if base_url.is_empty():
		return
	_prefetched_track = track_name
	_prefetch_request.set_download_file(MUSIC_CACHE_DIR + track_name)
	if base_url.begins_with("https://"):
		_prefetch_request.set_tls_options(TLSOptions.client_unsafe())
	var err := _prefetch_request.request(base_url + "/music/" + track_name)
	if err != OK:
		push_warning("MusicManager: prefetch failed to start (err=%d)" % err)
		_prefetched_track = ""

## If _play_after_prefetch is set and the prefetch is now complete, play the track.
func _maybe_play_after_prefetch() -> void:
	if _play_after_prefetch and _prefetch_done and not _prefetched_track.is_empty():
		_play_after_prefetch = false
		var track            := _prefetched_track
		_prefetched_track    = ""
		_prefetch_done       = false
		_play_cached_track(track)
		_prefetch_next_track()

## Fall back to local tracks on a server error while waiting for track_info.
func _on_track_request_error(code: String, _message: String) -> void:
	if code == "not_found":
		_track_info_mode = _TrackMode.NONE
		_disconnect_online_track_signals()
		_play_next_game_track()

func _disconnect_online_track_signals() -> void:
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		return
	if oc.track_info_received.is_connected(_on_any_track_info):
		oc.track_info_received.disconnect(_on_any_track_info)
	if oc.server_error.is_connected(_on_track_request_error):
		oc.server_error.disconnect(_on_track_request_error)

## Start downloading *track_name* from the server (main node, for immediate play).
func _download_track(track_name: String) -> void:
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		_play_next_game_track()
		return
	var base_url: String = oc.get_http_base_url()
	if base_url.is_empty():
		_play_next_game_track()
		return
	_pending_track = track_name
	_http_request.set_download_file(MUSIC_CACHE_DIR + track_name)
	if base_url.begins_with("https://"):
		_http_request.set_tls_options(TLSOptions.client_unsafe())
	var err := _http_request.request(base_url + "/music/" + track_name)
	if err != OK:
		push_warning("MusicManager: failed to start music download (err=%d)" % err)
		_pending_track = ""
		_play_next_game_track()

## Callback for the main (_http_request) download completing.
func _on_download_complete(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var track  := _pending_track
	_pending_track = ""
	_http_request.set_download_file("")
	# Guard: the game may have ended while the download was in flight (surrender).
	# If so, discard the result silently — play_menu_music() already cleared the
	# streaming state, and sending a prefetch request here would shift the
	# server-side track index out of sync with the other client.
	if not _game_active:
		if not track.is_empty() and result != HTTPRequest.RESULT_SUCCESS:
			DirAccess.remove_absolute(MUSIC_CACHE_DIR + track)
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("MusicManager: music download failed (result=%d, code=%d) — using local fallback" % [result, response_code])
		if not track.is_empty():
			DirAccess.remove_absolute(MUSIC_CACHE_DIR + track)
		_play_next_game_track()
		return
	_play_cached_track(track)
	# Start prefetching the next track while this one plays — eliminates the gap.
	_prefetch_next_track()

## Callback for the prefetch (_prefetch_request) download completing.
func _on_prefetch_complete(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_prefetch_request.set_download_file("")
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("MusicManager: prefetch download failed (result=%d, code=%d)" % [result, response_code])
		if not _prefetched_track.is_empty():
			DirAccess.remove_absolute(MUSIC_CACHE_DIR + _prefetched_track)
		_prefetched_track = ""
		_prefetch_done    = false
		return
	_prefetch_done = true
	_maybe_play_after_prefetch()

## Load a cached track from disk and play it on _game_player.
func _play_cached_track(track_name: String) -> void:
	if not _game_active:
		return
	var cache_path := MUSIC_CACHE_DIR + track_name
	var ext        := track_name.get_extension().to_lower()
	var stream: AudioStream
	match ext:
		"mp3":
			var s := AudioStreamMP3.new()
			s.data = FileAccess.get_file_as_bytes(cache_path)
			stream  = s
		"ogg":
			stream = AudioStreamOggVorbis.load_from_file(cache_path)
		_:
			push_warning("MusicManager: unsupported cached format '%s'" % ext)
			_play_next_game_track()
			return
	if stream == null:
		push_warning("MusicManager: could not load cached track '%s'" % track_name)
		_play_next_game_track()
		return
	_game_player.stream = stream
	_game_player.play()


# ────────────────────────────────────────────────────────────────────────────
#   DYNAMIC MUSIC (tension-based tone shaping)                              
# ────────────────────────────────────────────────────────────────────────────
#   Applies real-time audio effects (LPF, HPF, compressor, distortion,      
#   stereo width, pitch) on the Music bus to reflect gameplay tension.      
# ────────────────────────────────────────────────────────────────────────────

func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		var idx: int = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)

func _ensure_music_lowpass() -> void:
	_music_bus_idx = AudioServer.get_bus_index("Music")
	if _music_bus_idx < 0:
		return
	# Slot 0 — Low-pass filter
	if _music_lpf == null:
		_music_lpf = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_lpf, 0)
	_music_lpf.cutoff_hz = LPF_CUTOFF_NORMAL
	_music_lpf.resonance  = LPF_RESO_NORMAL
	# Slot 1 — High-pass filter
	if _music_hpf == null:
		_music_hpf = AudioEffectHighPassFilter.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_hpf, 1)
	_music_hpf.cutoff_hz = HPF_CUTOFF_NORMAL
	# Slot 2 — Compressor
	if _music_compressor == null:
		_music_compressor = AudioEffectCompressor.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_compressor, 2)
	_music_compressor.threshold  = COMP_THRESHOLD_NORMAL
	_music_compressor.ratio      = COMP_RATIO_NORMAL
	_music_compressor.gain       = COMP_MAKEUP_GAIN_NORMAL
	_music_compressor.attack_us  = 10000  # 10 ms
	_music_compressor.release_ms = 100
	# Slot 3 — Distortion
	if _music_distortion == null:
		_music_distortion = AudioEffectDistortion.new()
		AudioServer.add_bus_effect(_music_bus_idx, _music_distortion, 3)
	_music_distortion.pre_gain  = 0.0
	_music_distortion.post_gain = 0.0
	_music_distortion.mode      = AudioEffectDistortion.MODE_OVERDRIVE
	# Slot 4 — Stereo enhancement
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
	var target_cutoff:         float = LPF_CUTOFF_NORMAL
	var target_reso:           float = LPF_RESO_NORMAL
	var target_hpf_cutoff:    float = HPF_CUTOFF_NORMAL
	var target_comp_threshold: float = COMP_THRESHOLD_NORMAL
	var target_comp_ratio:     float = COMP_RATIO_NORMAL
	var target_comp_makeup:    float = COMP_MAKEUP_GAIN_NORMAL
	var target_dist_level:     float = DIST_LEVEL_NORMAL
	var target_stereo:         float = STEREO_ENHANCE_NORMAL
	var target_pitch:          float = PITCH_NORMAL

	match preset:
		DYN_PRESET_MATE:
			target_cutoff         = LPF_CUTOFF_MATE
			target_reso           = LPF_RESO_MATE
			target_hpf_cutoff     = HPF_CUTOFF_MATE
			target_comp_threshold = COMP_THRESHOLD_MATE
			target_comp_ratio     = COMP_RATIO_MATE
			target_comp_makeup    = COMP_MAKEUP_GAIN_MATE
			target_dist_level     = DIST_LEVEL_MATE
			target_stereo         = STEREO_ENHANCE_MATE
			target_pitch          = PITCH_MATE
		DYN_PRESET_CHECK:
			target_cutoff         = LPF_CUTOFF_CHECK
			target_reso           = LPF_RESO_CHECK
			target_hpf_cutoff     = HPF_CUTOFF_CHECK
			target_comp_threshold = COMP_THRESHOLD_CHECK
			target_comp_ratio     = COMP_RATIO_CHECK
			target_comp_makeup    = COMP_MAKEUP_GAIN_CHECK
			target_dist_level     = DIST_LEVEL_CHECK
			target_stereo         = STEREO_ENHANCE_CHECK
			target_pitch          = PITCH_CHECK
		DYN_PRESET_ATTACK:
			target_cutoff         = LPF_CUTOFF_ATTACK
			target_reso           = LPF_RESO_ATTACK
			target_hpf_cutoff     = HPF_CUTOFF_ATTACK
			target_comp_threshold = COMP_THRESHOLD_ATTACK
			target_comp_ratio     = COMP_RATIO_ATTACK
			target_comp_makeup    = COMP_MAKEUP_GAIN_ATTACK
			target_dist_level     = DIST_LEVEL_ATTACK
			target_stereo         = STEREO_ENHANCE_ATTACK
			target_pitch          = PITCH_ATTACK

	if preset != _current_dynamic_preset:
		_current_dynamic_preset = preset
		emit_signal("dynamic_preset_changed", preset)

	if _dyn_tween:
		_dyn_tween.kill()
	_dyn_tween = create_tween().set_parallel(true)
	var dur: float = TRANSITION_ATTACK if force_fast else TRANSITION_NORMAL

	_dyn_tween.tween_property(_music_lpf, "cutoff_hz", target_cutoff, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_dyn_tween.tween_property(_music_lpf, "resonance", target_reso, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _music_hpf != null:
		_dyn_tween.tween_property(_music_hpf, "cutoff_hz", target_hpf_cutoff, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _music_compressor != null:
		_dyn_tween.tween_property(_music_compressor, "threshold", target_comp_threshold, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_dyn_tween.tween_property(_music_compressor, "ratio", target_comp_ratio, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_dyn_tween.tween_property(_music_compressor, "gain", target_comp_makeup, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _music_distortion != null:
		_dyn_tween.tween_property(_music_distortion, "pre_gain", target_dist_level, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _music_stereo != null:
		_dyn_tween.tween_property(_music_stereo, "pan_pullout", target_stereo, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
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

## Convert a 0-100 percentage to dB. 0 % → fully muted, 100 % → 0 dB (unity).
func _pct_to_db(pct: int) -> float:
	if pct <= 0:
		return -80.0
	# Perceptual curve: spreads useful changes across the full slider range so
	# low values are not all "equally quiet" and 20-100 % is not all "equal".
	var t: float = clamp(float(pct) / 100.0, 0.0, 1.0)
	return linear_to_db(pow(t, 2.2))
