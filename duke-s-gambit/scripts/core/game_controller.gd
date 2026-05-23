## game_controller.gd
## Central game controller. Owns: chess logic, piece scenes, board highlights,
## camera transitions, input routing, pawn promotion, check/checkmate UI.

class_name GameController
extends Node3D

# ── Exports / node refs ────────────────────────────────────────────────────
@export var board_node:  NodePath = ^"Board"
@export var camera_node: NodePath = ^"OrbitCamera"
@export var pieces_root: NodePath = ^"Pieces"
@export var ui_root:     NodePath = ^"HUD"

## Scale applied to every piece on spawn. Adjust until pieces fit the board.
@export var piece_scale: float = 0.05

@onready var _board:   Board       = get_node(board_node)
@onready var _camera:  OrbitCamera = get_node(camera_node)
@onready var _pieces:  Node3D      = get_node(pieces_root)
@onready var _ui:      Control     = get_node(ui_root)
@onready var _terrain: Node3D      = get_node_or_null("Terrain")
@onready var _board_notation: Node3D = get_node_or_null("BoardNotation")
@onready var _world_env: WorldEnvironment = get_node_or_null("WorldEnvironment")
@onready var _material_pressure_fx: Node = get_node_or_null("MaterialPressureFX")
@onready var _white_base: Node3D   = get_node_or_null("WhiteBase")
@onready var _black_base: Node3D   = get_node_or_null("BlackBase")

var _hud: Node = null

# ── Piece scenes (populated in _setup_piece_scenes) ────────────────────────
var _piece_scenes: Dictionary = {}   # PieceType -> PackedScene

# ── Constants ──────────────────────────────────────────────────────────────
# Promotion VFX and game-over panel icons.
const _PROMO_VFX_IMPACT_SCENE: PackedScene = preload("res://scenes/effects/spell.tscn")

# ── Signals ────────────────────────────────────────────────────────────────
signal game_over(winner_color: int, reason: int)   # reason = ChessEnums.GameState
signal promotion_needed(sq: Vector2i, color: int)

# ── Runtime state ──────────────────────────────────────────────────────────
# Chess core.
var _chess:       ChessBoardState = null
var _controllers: Array           = []  # [white_ctrl, black_ctrl]
var _sq_pieces:   Dictionary      = {}  # Vector2i -> BasePiece (live scene nodes)

# Animation / move timing.
var _busy: bool = false                  # true while piece animation is running
var _move_start_time_ms: int = 0         # timestamp for avg-move-time tracking
var _move_counts:   Array = [0, 0]       # per-player move counter
var _move_times_ms: Array = [0, 0]       # cumulative thinking time per player

# Captured pieces: [white_captures[], black_captures[]] (lists of PieceType ints).
var _captured_by: Array = [[], []]

# Players.
var _player_names: Array = ["Player1", "Player2"]
var _player_elos:  Array = [1200, 1200]
var _is_player_vs_ai: bool = false
var _ai_color: int = -1          # color of the AI controller in PvAI (-1 if none)
var _ai_difficulty_label: String = ""  # e.g. "Casual", "Challenger", "Master"

# Online mode (server is the authority for move legality and game-over).
var _online_mode: bool = false
var _my_online_color: int = -1   # local player's color when online; -1 = none

# Replay mode.
var _replay_mode: bool = false
var _replay_moves: Array = []   # Array[Dictionary] loaded from CSV
var _game_start_time_ms: int = 0   # ticks_msec() at the moment the first turn begins
var _current_legal_moves: Array = []   # legal moves at the start of the current turn
# Queue of pending server-applied moves; processed strictly sequentially so a
# rapidly-arriving opponent move cannot re-enter `_on_move_chosen` while the
# previous animation is still awaiting (would desync the local board).
var _server_move_queue: Array = []
var _processing_server_move: bool = false
const _RemoteControllerScript := preload("res://scripts/controllers/remote_controller.gd")

# Chess clock (ms). 0 = no limit.
var _time_control_ms:   int = 0
var _time_remaining_ms: Array = [0, 0]  # [white, black]
var _game_over_shown:   bool  = false

# Audio / world FX.
var _sfx_select: AudioStreamPlayer = null
var _base_saturation: float = 0.9
var _sat_tween: Tween = null

# Sub-controllers (created in _ready).
var _intro_animator: GameIntroAnimator = null
var _input: GameBoardInput = null

# ── Lifecycle ──────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	if _chess == null or _busy or _move_start_time_ms == 0 or _game_over_shown:
		return
	if _hud == null:
		return
	if _online_mode:
		# In online mode the clock is driven entirely by the server
		# (see `_on_server_clock_update`).  The local _process loop is a
		# passive display only — it must not run any countdown of its own,
		# otherwise the HUD will drift away from the authoritative values.
		return
	var elapsed: int = Time.get_ticks_msec() - _move_start_time_ms
	if _time_control_ms > 0:
		var color := _chess.active_color
		var inactive := 1 - color
		var remaining: int = _time_remaining_ms[color] - elapsed
		if remaining <= 0:
			if not _online_mode:
				_on_time_out(color)
			return
		# Update both timers: active player counts down, inactive shows their frozen remaining
		_hud.update_timer(color, remaining)
		_hud.update_timer(inactive, _time_remaining_ms[inactive])
	else:
		# No time limit: show running total per player. Active player accumulates
		# this move's elapsed time on top of their previous total; inactive stays
		# frozen on their stored total. This is what the game-over panel reports.
		var active := _chess.active_color
		var inactive := 1 - active
		_hud.update_timer(active, _move_times_ms[active] + elapsed)
		_hud.update_timer(inactive, _move_times_ms[inactive])

func _ready() -> void:
	if _terrain != null and _board != null:
		# Keep authored Y/Z so terrain can be fine-tuned manually in game.tscn.
		var bc := _board.board_center()
		var p := _terrain.global_position
		_terrain.global_position = Vector3(bc.x, p.y, p.z)
	_setup_piece_scenes()
	_hud = _ui.get_node_or_null("TopBar")
	_sfx_select = AudioStreamPlayer.new()
	_sfx_select.bus = "SFX"
	_sfx_select.stream = preload("res://assets/sounds/piece_select.mp3")
	_sfx_select.volume_db = -10.0
	add_child(_sfx_select)
	if _world_env != null and _world_env.environment != null:
		_base_saturation = _world_env.environment.adjustment_saturation
	if not MusicManager.dynamic_preset_changed.is_connected(_on_dynamic_music_preset_changed):
		MusicManager.dynamic_preset_changed.connect(_on_dynamic_music_preset_changed)
	MusicManager.play_game_music()
	_on_dynamic_music_preset_changed("normal")
	# Apply notation visibility setting.
	if _board_notation != null:
		var cam_cfg := get_node_or_null("/root/CameraConfig")
		_board_notation.visible = cam_cfg == null or cam_cfg.get("notation_visible") != false
	_intro_animator = GameIntroAnimator.new()
	add_child(_intro_animator)
	_input = GameBoardInput.new()
	add_child(_input)
	_input.setup(self)
	_input.promotion_requested.connect(_on_promotion_required)

func _on_dynamic_music_preset_changed(preset: String) -> void:
	if _world_env == null or _world_env.environment == null:
		return

	var target_sat: float = _base_saturation
	match preset:
		"check":
			target_sat = _base_saturation * 0.72
		"mat":
			target_sat = _base_saturation * 0.54
		_:
			target_sat = _base_saturation

	if _sat_tween:
		_sat_tween.kill()
	_sat_tween = create_tween()
	_sat_tween.tween_property(_world_env.environment, "adjustment_saturation", target_sat, 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## Online mode setup. Builds a local human controller for ``your_color`` and a
## passive RemoteController for the opponent — moves arrive via OnlineClient.
func setup_online(white_name: String, black_name: String,
			your_color: int, time_control_ms: int,
			white_elo: int = 1200, black_elo: int = 1200) -> void:
	_online_mode = true
	_my_online_color = your_color
	_player_names[ChessEnums.PieceColor.WHITE] = white_name
	_player_names[ChessEnums.PieceColor.BLACK] = black_name
	_player_elos[ChessEnums.PieceColor.WHITE]  = white_elo
	_player_elos[ChessEnums.PieceColor.BLACK]  = black_elo
	_time_control_ms = time_control_ms
	_is_player_vs_ai = false
	_ai_color = -1
	_ai_difficulty_label = ""

	_controllers.clear()
	for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var ctrl: PlayerController
		if color == your_color:
			var human := HumanController.new()
			human.color = color
			human.player_name = _player_names[color]
			ctrl = human
		else:
			var remote: PlayerController = _RemoteControllerScript.new()
			remote.color = color
			remote.player_name = _player_names[color]
			ctrl = remote
		ctrl.move_chosen.connect(_on_local_move_chosen)
		_controllers.append(ctrl)

	var oc := get_node_or_null("/root/OnlineClient")
	if oc != null:
		if not oc.move_applied.is_connected(_on_server_move_applied):
			oc.move_applied.connect(_on_server_move_applied)
		if not oc.clock_update_received.is_connected(_on_server_clock_update):
			oc.clock_update_received.connect(_on_server_clock_update)
		if not oc.game_over_received.is_connected(_on_server_game_over):
			oc.game_over_received.connect(_on_server_game_over)
		if not oc.server_error.is_connected(_on_server_error_online):
			oc.server_error.connect(_on_server_error_online)

## Called from MainMenu before adding this node to the scene tree.
func setup(p1_name: String, p2_name: String,
		   white_is_ai: bool, black_is_ai: bool, ai_strength: int,
		   time_control_ms: int = 0) -> void:
	_player_names[ChessEnums.PieceColor.WHITE] = p1_name
	_player_names[ChessEnums.PieceColor.BLACK] = p2_name
	_time_control_ms = time_control_ms
	_is_player_vs_ai = white_is_ai != black_is_ai
	_ai_color = -1
	_ai_difficulty_label = ""
	if _is_player_vs_ai:
		_ai_color = ChessEnums.PieceColor.WHITE if white_is_ai else ChessEnums.PieceColor.BLACK
		var diff := maxi(1, mini(3, ai_strength))
		_ai_difficulty_label = _difficulty_label(diff)

	# Read ELOs from SaveManager
	var save_node := get_node_or_null("/root/SaveManager")
	if save_node:
		for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
			var pname: String = _player_names[color]
			if save_node.player_exists(pname):
				var pdata: Dictionary = save_node.get_player(pname)
				_player_elos[color] = pdata.get("elo", 1000)

	# Build controllers
	_controllers.clear()
	for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var is_ai := white_is_ai if color == ChessEnums.PieceColor.WHITE else black_is_ai
		var ctrl: PlayerController
		if is_ai:
			var ai := AIController.new()
			ai.color = color
			# Set AI difficulty (map 1-3 to difficulty levels)
			var difficulty := maxi(1, mini(3, ai_strength))
			ai.difficulty = difficulty
			ctrl = ai
			if not ai._native_available:
				_player_names[color] = "Simple AI"
			ai.player_name = _player_names[color]
		else:
			var human := HumanController.new()
			human.color = color
			human.player_name = _player_names[color]
			ctrl = human
		ctrl.move_chosen.connect(_on_local_move_chosen)
		_controllers.append(ctrl)

## Sets up a replay game from CSV-parsed move data.
## ``moves_data`` is an Array[Dictionary] with keys: from_sq, to_sq, promotion_type, game_time_ms.
func setup_replay(white_name: String, black_name: String, moves_data: Array) -> void:
	_replay_mode = true
	_replay_moves = moves_data
	_player_names[ChessEnums.PieceColor.WHITE] = white_name
	_player_names[ChessEnums.PieceColor.BLACK] = black_name
	_time_control_ms = 0
	_is_player_vs_ai = false
	_ai_color = -1
	_ai_difficulty_label = ""
	# Both sides use a passive controller (is_ai = true so mouse input is ignored).
	_controllers.clear()
	for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var ctrl := PlayerController.new()
		ctrl.color = color
		ctrl.player_name = _player_names[color]
		ctrl.is_ai = true
		ctrl.move_chosen.connect(_on_local_move_chosen)
		_controllers.append(ctrl)
	# Notify the game UI so it can show the "Stop Replay" button.
	if _ui != null and _ui.has_method("set_replay_mode"):
		_ui.call("set_replay_mode", true)

## Coroutine that drives the replay: waits the correct inter-move delays and
## feeds each move to the normal animation pipeline.
func _run_replay() -> void:
	var replay_ref_ms := Time.get_ticks_msec()   # wall-clock anchor for replay timing
	var total := _replay_moves.size()
	var current_move := 0
	if _ui != null and _ui.has_method("update_replay_progress"):
		_ui.call("update_replay_progress", 0, total)
	for move_data in _replay_moves:
		if _game_over_shown or not is_inside_tree():
			return
		# Compute how many ms should have elapsed since replay started for this move.
		var target_ms: int = int(move_data.get("game_time_ms", 0))
		var elapsed_ms := Time.get_ticks_msec() - replay_ref_ms
		var wait_ms := target_ms - elapsed_ms
		if wait_ms > 50:
			await get_tree().create_timer(wait_ms / 1000.0).timeout
		if _game_over_shown or not is_inside_tree():
			return
		var from_sq: Vector2i = move_data.get("from_sq", Vector2i(-1, -1))
		var to_sq: Vector2i   = move_data.get("to_sq",   Vector2i(-1, -1))
		if from_sq.x < 0 or to_sq.x < 0:
			continue
		var promo_type: int = int(move_data.get("promotion_type", ChessEnums.PieceType.NONE))
		var mv := _resolve_legal_move(from_sq, to_sq, promo_type)
		if mv == null:
			push_warning("Replay: move not legal in current position: %s → %s" % [from_sq, to_sq])
			continue
		await _on_move_chosen(mv)
		current_move += 1
		if _ui != null and _ui.has_method("update_replay_progress"):
			_ui.call("update_replay_progress", current_move, total)
	# All moves played — return to menu after a short pause.
	if not is_inside_tree():
		return
	await get_tree().create_timer(2.5).timeout
	if is_inside_tree():
		MusicManager.play_menu_music()
		var menu: Node = load("res://scenes/main_menu.tscn").instantiate()
		get_tree().root.add_child(menu)
		queue_free()

func start_game() -> void:
	_chess = ChessBoardState.new()
	_chess.pawn_promotion_required.connect(_on_promotion_required)
	_busy = true   # blocked until intro finishes
	_game_over_shown = false
	_move_counts = [0, 0]
	_move_times_ms = [0, 0]
	_captured_by = [[], []]
	_time_remaining_ms = [_time_control_ms, _time_control_ms]
	_server_move_queue.clear()
	_processing_server_move = false
	if _material_pressure_fx != null and _material_pressure_fx.has_method("reset_effects"):
		_material_pressure_fx.call("reset_effects")
	_clear_pieces()
	_board.clear_last_move()
	if _board_notation != null:
		_board_notation.call("reset_highlight")
	# Setup HUD data now (it will be hidden during the intro).
	if _hud != null:
		var white_elo_override := _ai_difficulty_label if _ai_color == ChessEnums.PieceColor.WHITE else ""
		var black_elo_override := _ai_difficulty_label if _ai_color == ChessEnums.PieceColor.BLACK else ""
		_hud.setup(
			_player_names[ChessEnums.PieceColor.WHITE], _player_elos[ChessEnums.PieceColor.WHITE],
			_player_names[ChessEnums.PieceColor.BLACK], _player_elos[ChessEnums.PieceColor.BLACK],
			_time_control_ms > 0,
			not _online_mode and not _replay_mode,   # hide ELO in replay
			white_elo_override,
			black_elo_override
		)
		if _hud.has_method("reset_move_history"):
			_hud.call("reset_move_history")
	await _intro_animator.play(self)
	# In online mode, hold the clock until both clients have finished loading.
	# Server only arms the chess clock once it receives C_CLIENT_READY from both
	# sides; while we wait for the opponent, reuse the "thinking" progress bar.
	if _online_mode:
		await _await_online_ready()
	_busy = false
	_game_start_time_ms = Time.get_ticks_msec()
	var initial_camera_color: int = ChessEnums.PieceColor.WHITE
	if _online_mode and _my_online_color != -1:
		initial_camera_color = _my_online_color
	elif _is_player_vs_ai:
		initial_camera_color = _human_player_color()
	_camera.snap_to_player(initial_camera_color)
	_start_turn()
	if _replay_mode:
		_run_replay()   # fire-and-forget coroutine

func _await_online_ready() -> void:
	var oc := get_node_or_null("/root/OnlineClient")
	if oc == null:
		return
	oc.send_client_ready()
	var game_ui = _ui as Control
	var bar_shown := false
	if game_ui != null and game_ui.has_method("show_waiting_for_opponent"):
		game_ui.show_waiting_for_opponent()
		bar_shown = true
	while true:
		var payload: Variant = await oc.ready_state_updated
		if typeof(payload) == TYPE_DICTIONARY and bool((payload as Dictionary).get("all_ready", false)):
			break
	if bar_shown and game_ui != null and game_ui.has_method("hide_status"):
		game_ui.hide_status()




# ── Piece scene setup ──────────────────────────────────────────────────────
func _setup_piece_scenes() -> void:
	var types := {
		ChessEnums.PieceType.PAWN:   "res://scenes/pieces/pawn.tscn",
		ChessEnums.PieceType.ROOK:   "res://scenes/pieces/rook.tscn",
		ChessEnums.PieceType.KNIGHT: "res://scenes/pieces/knight.tscn",
		ChessEnums.PieceType.BISHOP: "res://scenes/pieces/bishop.tscn",
		ChessEnums.PieceType.QUEEN:  "res://scenes/pieces/queen.tscn",
		ChessEnums.PieceType.KING:   "res://scenes/pieces/king.tscn",
	}
	for t in types:
		var path: String = types[t]
		if ResourceLoader.exists(path):
			_piece_scenes[t] = load(path)
		else:
			push_error("GameController: scene not found: %s" % path)

# ── Spawn / clear ──────────────────────────────────────────────────────────
func _spawn_all_pieces() -> void:
	_sq_pieces.clear()
	for c in range(8):
		for r in range(8):
			var p: Variant = _chess.board[c][r]
			if p == null:
				continue
			var pd: Dictionary = p
			_spawn_piece(Vector2i(c, r), pd["type"], pd["color"])

func _spawn_piece(sq: Vector2i, type: int, color: int) -> BasePiece:
	if not _piece_scenes.has(type):
		push_error("GameController: no scene for piece type %d" % type)
		return null
	var piece: BasePiece = _piece_scenes[type].instantiate()
	piece.piece_type  = type
	piece.piece_color = color
	piece.scale = Vector3.ONE * piece_scale
	_pieces.add_child(piece)
	piece.global_position = _board.sq_to_world(sq)
	_sq_pieces[sq] = piece
	return piece

func _clear_pieces() -> void:
	for child in _pieces.get_children():
		child.queue_free()
	_sq_pieces.clear()

# ── Turn loop ──────────────────────────────────────────────────────────────
func _start_turn() -> void:
	_input.clear_check_outline()
	_input.clear_selection()

	var color  := _chess.active_color
	var state  := _chess.get_game_state()
	var legal  := _chess.get_legal_moves(color)
	_current_legal_moves = legal
	_update_surrender_ui()
	if _hud != null and _hud.has_method("set_active_color"):
		_hud.set_active_color(color)

	# Check / checkmate / stalemate
	if state == ChessEnums.GameState.CHECKMATE:
		MusicManager.set_checkmate_tension(true)
		if not _online_mode:
			emit_signal("game_over", 1 - color, ChessEnums.GameState.CHECKMATE)
			_animate_checkmate_end(color)                        # async: king dies → 2s → panel
			return
	if state == ChessEnums.GameState.STALEMATE:
		MusicManager.reset_dynamic_music()
		if not _online_mode:
			emit_signal("game_over", -1, ChessEnums.GameState.STALEMATE)
			_show_game_over(-1, "Pat (remíza)")
			return
	if state == ChessEnums.GameState.DRAW:
		MusicManager.reset_dynamic_music()
		if not _online_mode:
			emit_signal("game_over", -1, ChessEnums.GameState.DRAW)
			_show_game_over(-1, "Remíza")
			return
	if state == ChessEnums.GameState.CHECK:
		MusicManager.set_check_tension(true)
		var king_sq := _chess._find_king(color)
		_board.highlight_check(king_sq)
		_input.apply_check_outline(color)
	else:
		MusicManager.set_check_tension(false)

	_move_start_time_ms = Time.get_ticks_msec()
	var ctrl: PlayerController = _controllers[color] as PlayerController
	# Push current clock snapshot into the AI so it can do real time management.
	# 0 ms == "no clock info" (count-up game) — AIController treats this as such.
	if ctrl is AIController:
		var ai_ctrl := ctrl as AIController
		ai_ctrl.time_left_ms = _time_remaining_ms[color] if _time_control_ms > 0 else 0
		ai_ctrl.increment_ms = 0  # no increment system yet; wire when added.
	# Show thinking indicator for AI or remote (online) opponent.
	# Never show these boxes during replay — the ReplayBox already fills that slot.
	if ctrl.is_ai and not _replay_mode and _ui != null:
		var game_ui = _ui as Control
		if _online_mode:
			if game_ui.has_method("show_opponent_turn"):
				game_ui.show_opponent_turn()
		else:
			if game_ui.has_method("show_ai_thinking"):
				game_ui.show_ai_thinking()
	ctrl.request_move(_chess, legal)

func is_human_turn() -> bool:
	if _chess == null or _controllers.size() < 2:
		return false
	var color: int = _chess.active_color
	var ctrl: PlayerController = _controllers[color] as PlayerController
	return ctrl != null and not ctrl.is_ai

func _human_player_color() -> int:
	for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var ctrl: PlayerController = _controllers[color] as PlayerController
		if ctrl != null and not ctrl.is_ai:
			return color
	return ChessEnums.PieceColor.WHITE

func _difficulty_label(diff: int) -> String:
	match diff:
		1: return "Casual"
		2: return "Challenger"
		3: return "Master"
		_: return ""

func can_surrender() -> bool:
	if _replay_mode:
		return false
	if _game_over_shown or _chess == null:
		return false
	if _online_mode:
		return true  # can resign at any point in an online game
	if _is_player_vs_ai:
		return is_human_turn()
	return true

func _update_surrender_ui() -> void:
	if _ui != null and _ui.has_method("set_surrender_available"):
		_ui.call("set_surrender_available", can_surrender())

# ── Checkmate animation ────────────────────────────────────────────────────
func _animate_checkmate_end(loser_color: int) -> void:
	_busy = true   # block further input
	var king_sq := _chess._find_king(loser_color)
	var king_piece: BasePiece = _sq_pieces.get(king_sq)
	var winner_color := 1 - loser_color
	if king_piece:
		_captured_by[winner_color].append(ChessEnums.PieceType.KING)
		if _hud != null:
			_hud.refresh_captured(winner_color, _captured_by[winner_color])

	# Checkmate cam: start zooming toward the king BEFORE die() so the camera
	# is already moving when the death animation plays.
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var use_cinematic: bool = cam_cfg == null or cam_cfg.kill_cam_enabled
	var king_world := _board.sq_to_world(king_sq)
	if use_cinematic:
		_camera.checkmate_cam(king_world)

	if king_piece:
		# Start death animation without awaiting — we wait on the signal instead.
		king_piece.die()
		# Wait until the animation fully plays out (king hits the ground).
		await king_piece.death_finished
	else:
		# No king piece on board (shouldn't happen, but be safe).
		await get_tree().create_timer(1.5).timeout

	# King has fallen — emphasise the impact with shake and a final close push.
	if use_cinematic:
		_camera.king_impact()

	await get_tree().create_timer(2.0).timeout
	_show_game_over(winner_color, "Checkmate")
	_start_defeat_sequence(loser_color)

# ── Surrender / time-out ───────────────────────────────────────────────────
func _on_time_out(loser_color: int) -> void:
	if _game_over_shown:
		return
	_game_over_shown = true
	_busy = true
	MusicManager.reset_dynamic_music()
	var winner := 1 - loser_color
	emit_signal("game_over", winner, ChessEnums.GameState.DRAW)  # reuse signal
	_show_game_over(winner, "Time Expired")

## Forfeit: the current active player loses.
func surrender() -> void:
	if not can_surrender():
		return
	if _online_mode:
		var oc := get_node_or_null("/root/OnlineClient")
		if oc != null:
			oc.send_surrender()
		return
	_game_over_shown = true
	_busy = true
	MusicManager.reset_dynamic_music()
	var surrendering := _chess.active_color
	var winner := 1 - surrendering
	emit_signal("game_over", winner, ChessEnums.GameState.CHECKMATE)
	_show_game_over(winner, "Surrender")
	_start_defeat_sequence(surrendering)

# ── Move execution ─────────────────────────────────────────────────────────
## Slot fed by controllers (HumanController.try_move → move_chosen).
## In offline play it applies directly; in online play it routes the move to
## the server and waits for the authoritative `move_applied` event.
func _on_local_move_chosen(mv: ChessMove) -> void:
	if _online_mode:
		var oc := get_node_or_null("/root/OnlineClient")
		if oc == null:
			return
		oc.send_move(GameUtils.move_to_uci(mv))
		# Lock input until the server's authoritative echo arrives and the
		# local animation finishes. Without this, the player can click other
		# pieces during the roundtrip and hit a stale empty `_pending_legal`
		# (HumanController.try_move clears it on send), or accidentally
		# re-trigger a move via the still-populated `_legal_from_selected`.
		_input.clear_selection()
		_busy = true
		return
	_on_move_chosen(mv)

## Release the input lock if the server rejects a move we just sent. Without
## this, an illegal/not-your-turn rejection would leave the client stuck
## with `_busy = true` and no way to retry.
func _on_server_error_online(code: String, _message: String) -> void:
	if not _online_mode or _game_over_shown:
		return
	match code:
		"illegal_move", "not_your_turn", "bad_state", "bad_request":
			_busy = false
			_start_turn()

func _on_move_chosen(mv: ChessMove) -> void:
	if _game_over_shown:
		return   # game ended (e.g. surrender while AI was thinking)
	# Hide AI thinking indicator
	if _ui != null:
		var game_ui = _ui as Control
		if game_ui.has_method("hide_status"):
			game_ui.hide_status()
	_busy = true
	_input.deselect()   # clear outline before move animation
	# Track timing + deduct from clock.  In online mode the server is the
	# authoritative source for the clock (see `_on_server_clock_update`)
	# so we skip the local deduction — doing it here would subtract the
	# think-time a second time on top of what the server already deducted.
	var elapsed: int = Time.get_ticks_msec() - _move_start_time_ms
	_move_times_ms[mv.piece_color] += elapsed
	_move_counts[mv.piece_color]   += 1
	if _time_control_ms > 0 and not _online_mode:
		_time_remaining_ms[mv.piece_color] = maxi(
			_time_remaining_ms[mv.piece_color] - elapsed, 0)
	# Freeze clock updates until the next turn is officially started.
	_move_start_time_ms = 0

	# Record move metadata before applying to board.
	mv.game_time_ms = Time.get_ticks_msec() - _game_start_time_ms
	GameUtils.compute_disambiguation(mv, _current_legal_moves)

	# Track captured pieces for HUD
	if mv.captured_type != ChessEnums.PieceType.NONE:
		_captured_by[mv.piece_color].append(mv.captured_type)
		if _hud != null:
			_hud.refresh_captured(mv.piece_color, _captured_by[mv.piece_color])
		if _material_pressure_fx != null and _material_pressure_fx.has_method("update_from_captured"):
			_material_pressure_fx.call("update_from_captured", _captured_by)

	# Apply to logic board BEFORE animation so board state is updated
	_chess.make_move(mv)

	# Record check/checkmate annotation now that the board is in the new state.
	var _post_state := _chess.get_game_state()
	if _post_state == ChessEnums.GameState.CHECKMATE:
		mv.check_annotation = "#"
	elif _post_state == ChessEnums.GameState.CHECK:
		mv.check_annotation = "+"
	else:
		mv.check_annotation = ""

	# Kill cam: dramatic close-up for captures.
	# In online mode kill cam is always on (settings ignored); otherwise honor settings.
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var _is_capture := mv.move_type == ChessEnums.MoveType.CAPTURE \
		or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE \
		or mv.move_type == ChessEnums.MoveType.EN_PASSANT
	var _use_kill_cam: bool = _is_capture and (_online_mode or (cam_cfg != null and cam_cfg.kill_cam_enabled))
	if _use_kill_cam:
		var from_world      := _board.sq_to_world(mv.from_sq)
		var to_world        := _board.sq_to_world(mv.to_sq)
		var attacker_piece  := _sq_pieces.get(mv.from_sq) as Node3D
		_camera.kill_cam(from_world, to_world, attacker_piece)

	await _animate_move(mv)
	_board.highlight_last_move(mv.from_sq, mv.to_sq)
	if _board_notation != null:
		var _cam_cfg := get_node_or_null("/root/CameraConfig")
		if _cam_cfg == null or _cam_cfg.get("notation_highlight") != false:
			_board_notation.call("highlight", mv.to_sq)
	if _hud != null and _hud.has_method("append_move_to_history"):
		_hud.call("append_move_to_history", mv)

	# After a kill-cam capture, hold the view for 2 s so the player can appreciate the moment.
	if _use_kill_cam:
		await get_tree().create_timer(2.0).timeout

	# Rotate camera to active player — skip if disabled OR if checkmate is coming
	# (checkmate_cam will take over instead of face_player in _animate_checkmate_end).
	var _next_state := _chess.get_game_state()
	var _is_checkmate := _next_state == ChessEnums.GameState.CHECKMATE
	if not _is_checkmate:
		if _online_mode or _is_player_vs_ai:
			# Stay on the local player's perspective; restore after kill cam.
			if _use_kill_cam:
				_camera.restore_pre_kill_cam_view()
		elif _replay_mode:
			# Camera stays free — never auto-rotate to a player's side.
			# But if a kill cam ran, we must restore the view it displaced.
			if _use_kill_cam:
				_camera.restore_pre_kill_cam_view()
		elif cam_cfg == null or cam_cfg.get("face_player_after_move") != false:
			_camera.face_player(_chess.active_color)
		elif _use_kill_cam:
			_camera.restore_pre_kill_cam_view()
	_busy = false
	_start_turn()

func _animate_move(mv: ChessMove) -> void:
	var piece: BasePiece = _sq_pieces.get(mv.from_sq)
	if piece == null:
		return

	# Update sq_pieces mapping immediately
	_sq_pieces.erase(mv.from_sq)

	match mv.move_type:
		ChessEnums.MoveType.NORMAL, ChessEnums.MoveType.PROMOTION:
			_sq_pieces[mv.to_sq] = piece
			var dest := _board.sq_to_world(mv.to_sq)
			piece.move_to(dest)
			await piece.move_finished

		ChessEnums.MoveType.CAPTURE, ChessEnums.MoveType.PROMOTION_CAPTURE:
			var target: BasePiece = _sq_pieces.get(mv.to_sq)
			_sq_pieces.erase(mv.to_sq)
			_sq_pieces[mv.to_sq] = piece
			var dest := _board.sq_to_world(mv.to_sq)
			piece.attack_and_move_to(target, dest)
			await piece.move_finished

		ChessEnums.MoveType.EN_PASSANT:
			var cap_sq := Vector2i(mv.to_sq.x, mv.from_sq.y)
			var target: BasePiece = _sq_pieces.get(cap_sq)
			_sq_pieces.erase(cap_sq)
			_sq_pieces[mv.to_sq] = piece
			var dest := _board.sq_to_world(mv.to_sq)
			if target:
				piece.attack_and_move_to(target, dest)
				await piece.move_finished
			else:
				piece.move_to(dest)
				await piece.move_finished

		ChessEnums.MoveType.CASTLING_KINGSIDE:
			_sq_pieces[mv.to_sq] = piece
			var rook_from := Vector2i(0, mv.from_sq.y)
			var rook_to   := Vector2i(2, mv.from_sq.y)
			var rook: BasePiece = _sq_pieces.get(rook_from)
			_sq_pieces.erase(rook_from)
			if rook:
				_sq_pieces[rook_to] = rook
			piece.move_to(_board.sq_to_world(mv.to_sq))
			if rook:
				rook.move_to(_board.sq_to_world(rook_to))
			await piece.move_finished

		ChessEnums.MoveType.CASTLING_QUEENSIDE:
			_sq_pieces[mv.to_sq] = piece
			var rook_from := Vector2i(7, mv.from_sq.y)
			var rook_to   := Vector2i(4, mv.from_sq.y)
			var rook: BasePiece = _sq_pieces.get(rook_from)
			_sq_pieces.erase(rook_from)
			if rook:
				_sq_pieces[rook_to] = rook
			piece.move_to(_board.sq_to_world(mv.to_sq))
			if rook:
				rook.move_to(_board.sq_to_world(rook_to))
			await piece.move_finished

	# Handle promotion: swap visual piece
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
	or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		_swap_promoted_piece(piece, mv)

func _swap_promoted_piece(old_piece: BasePiece, mv: ChessMove) -> void:
	_spawn_promotion_impact(_board.sq_to_world(mv.to_sq))
	old_piece.queue_free()
	_sq_pieces.erase(mv.to_sq)
	var new_piece := _spawn_piece(mv.to_sq, mv.promotion_type, mv.piece_color)
	if new_piece:
		new_piece.global_position = _board.sq_to_world(mv.to_sq)

func _spawn_promotion_impact(world_pos: Vector3) -> void:
	# Same effect as death impact; scaled up by 20% for promotion emphasis.
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var vfx_on: bool = cam_cfg == null or cam_cfg.get("vfx_enabled") != false
	if vfx_on:
		var vfx: Node3D = _PROMO_VFX_IMPACT_SCENE.instantiate() as Node3D
		vfx.position = world_pos + Vector3(0, 0.5, 0)   # set before add_child so _ready() emits at correct position
		vfx.scale = vfx.scale * 1.2
		get_tree().root.add_child(vfx)

# ── Pawn promotion UI ──────────────────────────────────────────────────────
func _on_promotion_required(sq: Vector2i, color: int) -> void:
	emit_signal("promotion_needed", sq, color)
	# UI handled by PromotionPanel node; it calls choose_promotion()

func get_pending_promotion_types(sq: Vector2i) -> Array[int]:
	var result: Array[int] = []
	for mv in _input.pending_promotion_moves:
		if mv.to_sq != sq:
			continue
		if not result.has(mv.promotion_type):
			result.append(mv.promotion_type)
	return result

func choose_promotion(sq: Vector2i, piece_type: int) -> bool:
	# Called by UI after player picks promoted piece.
	var chosen: ChessMove = null
	for mv in _input.pending_promotion_moves:
		if mv.to_sq == sq and mv.promotion_type == piece_type:
			chosen = mv
			break
	if chosen == null:
		# Invalid option for current position; allow player to choose again.
		_busy = false
		return false
	_input.pending_promotion_moves.clear()
	_on_move_chosen(chosen)
	return true

# ── Game over UI ───────────────────────────────────────────────────────────
## Activates fire effects in the loser's base and flies the camera there.
## Called after _show_game_over for checkmate and surrender (not draws).
func _start_defeat_sequence(loser_color: int) -> void:
	var base: Node3D = _white_base if loser_color == ChessEnums.PieceColor.WHITE \
		else _black_base
	if base == null or _camera == null:
		return
	# Camera glides to base first; fires ignite when it arrives
	await _camera.defeat_cam(base.global_position)
	for child in base.get_children():
		child.visible = true
		var audio := child.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
		if audio and not audio.playing:
			audio.play()


func _show_game_over(winner_color: int, reason: String) -> void:
	# In replay mode we never show the game-over panel or save stats.
	if _replay_mode:
		return
	if _hud != null and _hud.has_method("set_active_color"):
		_hud.set_active_color(-1)
	var panel := _ui.get_node_or_null("GameOverPanel") as GameOverPanel
	if panel == null:
		return

	# Build formatted stat strings (raw numbers stay in GameController).
	var white_time_str: String
	var black_time_str: String
	if _time_control_ms > 0:
		white_time_str = GameUtils.format_time(_time_remaining_ms[ChessEnums.PieceColor.WHITE])
		black_time_str = GameUtils.format_time(_time_remaining_ms[ChessEnums.PieceColor.BLACK])
	else:
		white_time_str = GameUtils.format_time(_move_times_ms[ChessEnums.PieceColor.WHITE])
		black_time_str = GameUtils.format_time(_move_times_ms[ChessEnums.PieceColor.BLACK])

	var white_avg_ms := 0.0
	var black_avg_ms := 0.0
	if _move_counts[ChessEnums.PieceColor.WHITE] > 0:
		white_avg_ms = float(_move_times_ms[ChessEnums.PieceColor.WHITE]) / float(_move_counts[ChessEnums.PieceColor.WHITE])
	if _move_counts[ChessEnums.PieceColor.BLACK] > 0:
		black_avg_ms = float(_move_times_ms[ChessEnums.PieceColor.BLACK]) / float(_move_counts[ChessEnums.PieceColor.BLACK])
	var white_avg_str := "%.1f s" % (white_avg_ms / 1000.0)
	var black_avg_str := "%.1f s" % (black_avg_ms / 1000.0)

	panel.show_result(
		winner_color, reason, _player_names,
		white_time_str, black_time_str,
		white_avg_str, black_avg_str,
	)

	# Save stats
	var w_name: String = _player_names[ChessEnums.PieceColor.WHITE]
	var b_name: String = _player_names[ChessEnums.PieceColor.BLACK]
	var save_node := get_node_or_null("/root/SaveManager")
	if save_node:
		var is_draw: bool = (winner_color == -1)
		var winner_n: String = "" if is_draw else _player_names[winner_color]
		var loser_n: String  = "" if is_draw else _player_names[1 - winner_color]
		save_node.record_game_result(
			w_name if is_draw else winner_n,
			b_name if is_draw else loser_n,
			is_draw,
			_move_counts[0], _move_counts[1],
			_move_times_ms[0], _move_times_ms[1]
		)

# ── Online helpers ─────────────────────────────────────────────────────────
func _resolve_legal_move(from_sq: Vector2i, to_sq: Vector2i, promo_type: int) -> ChessMove:
	if _chess == null:
		return null
	var legal := _chess.get_legal_moves(_chess.active_color)
	for mv in legal:
		if mv.from_sq != from_sq or mv.to_sq != to_sq:
			continue
		var is_promo: bool = mv.move_type == ChessEnums.MoveType.PROMOTION \
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE
		if is_promo:
			if promo_type == ChessEnums.PieceType.NONE:
				continue
			if mv.promotion_type != promo_type:
				continue
		return mv
	return null

func _on_server_move_applied(payload: Dictionary) -> void:
	if not _online_mode or _chess == null:
		return
	_server_move_queue.append(payload)
	if _processing_server_move:
		return
	_processing_server_move = true
	while not _server_move_queue.is_empty():
		var p: Dictionary = _server_move_queue.pop_front()
		await _apply_server_move(p)
	_processing_server_move = false

func _apply_server_move(payload: Dictionary) -> void:
	if not _online_mode or _chess == null or _game_over_shown:
		return
	var uci := str(payload.get("uci", ""))
	var parsed := GameUtils.parse_uci(uci)
	if parsed.is_empty():
		push_warning("GameController: bad UCI from server: %s" % uci)
		return
	var mv := _resolve_legal_move(parsed["from"], parsed["to"], parsed["promotion"])
	if mv == null:
		push_warning("GameController: server move not legal locally: %s" % uci)
		return
	# Sync server clock values BEFORE applying the move so HUD shows authoritative time.
	if payload.has("white_ms"):
		_time_remaining_ms[ChessEnums.PieceColor.WHITE] = int(payload.get("white_ms", 0))
		if _hud != null:
			_hud.update_timer(ChessEnums.PieceColor.WHITE, _time_remaining_ms[ChessEnums.PieceColor.WHITE])
	if payload.has("black_ms"):
		_time_remaining_ms[ChessEnums.PieceColor.BLACK] = int(payload.get("black_ms", 0))
		if _hud != null:
			_hud.update_timer(ChessEnums.PieceColor.BLACK, _time_remaining_ms[ChessEnums.PieceColor.BLACK])
	# Online clock is server-driven; neutralise the local elapsed so
	# `_move_times_ms` accumulation below stays a reasonable estimate.
	_move_start_time_ms = Time.get_ticks_msec()
	await _on_move_chosen(mv)

func _on_server_clock_update(payload: Dictionary) -> void:
	# Authoritative periodic clock from the server. Update both timers in
	# the HUD; we are not running any local countdown in online mode.
	if not _online_mode or _game_over_shown or _hud == null:
		return
	if payload.has("white_ms"):
		_time_remaining_ms[ChessEnums.PieceColor.WHITE] = int(payload.get("white_ms", 0))
		_hud.update_timer(ChessEnums.PieceColor.WHITE, _time_remaining_ms[ChessEnums.PieceColor.WHITE])
	if payload.has("black_ms"):
		_time_remaining_ms[ChessEnums.PieceColor.BLACK] = int(payload.get("black_ms", 0))
		_hud.update_timer(ChessEnums.PieceColor.BLACK, _time_remaining_ms[ChessEnums.PieceColor.BLACK])

func _on_server_game_over(payload: Dictionary) -> void:
	if not _online_mode or _game_over_shown:
		return
	apply_remote_game_over(
		str(payload.get("winner", "")),
		str(payload.get("reason", ""))
	)

## Public entry called by OnlineClient.game_over_received.
## ``winner`` is "white" / "black" / "" (draw). ``reason`` is server-side text.
func apply_remote_game_over(winner: String, reason: String) -> void:
	if _game_over_shown:
		return
	var winner_color := -1
	if winner == "white":
		winner_color = ChessEnums.PieceColor.WHITE
	elif winner == "black":
		winner_color = ChessEnums.PieceColor.BLACK
	_game_over_shown = true
	_busy = true
	MusicManager.reset_dynamic_music()
	var state_reason: int = ChessEnums.GameState.CHECKMATE
	if winner_color == -1:
		state_reason = ChessEnums.GameState.DRAW
	emit_signal("game_over", winner_color, state_reason)
	var pretty_reason := reason.capitalize() if reason != "" else "Game over"
	if winner_color == -1:
		_show_game_over(-1, pretty_reason)
	else:
		_show_game_over(winner_color, pretty_reason)
		_start_defeat_sequence(1 - winner_color)
