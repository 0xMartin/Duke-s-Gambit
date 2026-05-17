## game_controller.gd
## Central game controller. Owns: chess logic, piece scenes, board highlights,
## camera transitions, input routing, pawn promotion, check/checkmate UI.

class_name GameController
extends Node3D

# ── Exports / node refs ────────────────────────────────────────────────────
@export var board_node:  NodePath = ^"Board"
@export var camera_node: NodePath = ^"OrbitCamera"
@export var pieces_root: NodePath = ^"Pieces"
@export var ui_root:     NodePath = ^"UI"

## Scale applied to every piece on spawn. Adjust until pieces fit the board.
@export var piece_scale: float = 0.05

@onready var _board:   Board       = get_node(board_node)
@onready var _camera:  OrbitCamera = get_node(camera_node)
@onready var _pieces:  Node3D      = get_node(pieces_root)
@onready var _ui:      Control     = get_node(ui_root)
@onready var _terrain: Node3D      = get_node_or_null("Terrain")
@onready var _world_env: WorldEnvironment = get_node_or_null("WorldEnvironment")
@onready var _material_pressure_fx: Node = get_node_or_null("MaterialPressureFX")

var _hud: Node = null

# ── Piece scenes (populated in _setup_piece_scenes) ────────────────────────
var _piece_scenes: Dictionary = {}   # PieceType -> PackedScene

# ── Runtime state ──────────────────────────────────────────────────────────
var _chess:       ChessBoardState = null
var _controllers: Array           = []  # [white_ctrl, black_ctrl]

var _sq_pieces:   Dictionary = {}   # Vector2i -> BasePiece (live scene nodes)
var _selected_sq: Vector2i   = Vector2i(-1, -1)
var _selected_piece: BasePiece = null
var _legal_from_selected: Array = []
var _pending_promotion_moves: Array = []
var _attack_outlined_pieces: Array[BasePiece] = []
var _check_outlined_king: BasePiece = null

var _busy:        bool = false   # true while piece animation is running
var _move_start_time_ms: int = 0  # timestamp for avg-move-time tracking

# Move counters per player for current game
var _move_counts:       Array = [0, 0]
var _move_times_ms:     Array = [0, 0]

# Captured pieces: [white_captures[], black_captures[]]  (lists of PieceType ints)
var _captured_by: Array = [[], []]

var _player_names: Array = ["Player1", "Player2"]
var _player_elos:  Array = [1200, 1200]
var _is_player_vs_ai: bool = false

# Chess clock (ms). 0 = no limit.
var _time_control_ms:   int = 0
var _time_remaining_ms: Array = [0, 0]  # [white, black]
var _game_over_shown:   bool = false
var _sfx_select: AudioStreamPlayer = null
var _base_saturation: float = 0.9
var _sat_tween: Tween = null

const OUTLINE_SELECTED := Color(0.00, 1.00, 0.15, 1.0)
const OUTLINE_ATTACK   := Color(1.00, 0.05, 0.00, 1.0)
const OUTLINE_CHECK    := Color(1.00, 0.05, 0.00, 1.0)
const OUTLINE_WIDTH    := 0.5

# Promotion impact (same assets as BasePiece death effect)
const _PROMO_VFX_IMPACT_SCENE: PackedScene = preload("res://assets/BinbunVFX_Vol2/StylizedHitFX/effects/big_impact/vfx_big_impact_02.tscn")
const _PROMO_SFX_SPELL: AudioStream = preload("res://assets/sounds/spell.mp3")

# Signals
signal game_over(winner_color: int, reason: int)   # reason = ChessEnums.GameState
signal promotion_needed(sq: Vector2i, color: int)

# ──────────────────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	if _chess == null or _busy or _move_start_time_ms == 0 or _game_over_shown:
		return
	var elapsed: int = Time.get_ticks_msec() - _move_start_time_ms
	if _hud == null:
		return
	if _time_control_ms > 0:
		var color := _chess.active_color
		var inactive := 1 - color
		var remaining: int = _time_remaining_ms[color] - elapsed
		if remaining <= 0:
			_on_time_out(color)
			return
		# Update both timers: active player counts down, inactive shows their frozen remaining
		_hud.update_timer(color, remaining)
		_hud.update_timer(inactive, _time_remaining_ms[inactive])
	else:
		# No time limit: active player shows elapsed time for current move
		_hud.update_timer(_chess.active_color, elapsed)

# ──────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if _terrain != null and _board != null:
		# Keep authored Y/Z so terrain can be fine-tuned manually in game.tscn.
		var bc := _board.board_center()
		var p := _terrain.global_position
		_terrain.global_position = Vector3(bc.x, p.y, p.z)
	_setup_piece_scenes()
	_hud = _ui.get_node_or_null("HUD")
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

## Called from MainMenu before adding this node to the scene tree.
func setup(p1_name: String, p2_name: String,
		   white_is_ai: bool, black_is_ai: bool, ai_strength: int,
		   time_control_ms: int = 0) -> void:
	_player_names[ChessEnums.PieceColor.WHITE] = p1_name
	_player_names[ChessEnums.PieceColor.BLACK] = p2_name
	_time_control_ms = time_control_ms
	_is_player_vs_ai = white_is_ai != black_is_ai

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
			ai.player_name = _player_names[color]
			# Set AI difficulty (map 1-3 to difficulty levels)
			var difficulty := maxi(1, mini(3, ai_strength))
			ai.difficulty = difficulty
			ctrl = ai
		else:
			var human := HumanController.new()
			human.color = color
			human.player_name = _player_names[color]
			ctrl = human
		ctrl.move_chosen.connect(_on_move_chosen)
		_controllers.append(ctrl)

func start_game() -> void:
	_chess = ChessBoardState.new()
	_chess.pawn_promotion_required.connect(_on_promotion_required)
	_busy = false
	_game_over_shown = false
	_selected_sq = Vector2i(-1, -1)
	_move_counts = [0, 0]
	_move_times_ms = [0, 0]
	_captured_by = [[], []]
	_time_remaining_ms = [_time_control_ms, _time_control_ms]
	if _material_pressure_fx != null and _material_pressure_fx.has_method("reset_effects"):
		_material_pressure_fx.call("reset_effects")
	_clear_pieces()
	_board.clear_last_move()
	_spawn_all_pieces()
	var initial_camera_color: int = ChessEnums.PieceColor.WHITE
	if _is_player_vs_ai:
		initial_camera_color = _human_player_color()
	_camera.snap_to_player(initial_camera_color)
	if _hud != null:
		_hud.setup(
			_player_names[ChessEnums.PieceColor.WHITE], _player_elos[ChessEnums.PieceColor.WHITE],
			_player_names[ChessEnums.PieceColor.BLACK], _player_elos[ChessEnums.PieceColor.BLACK],
			_time_control_ms > 0
		)
		if _hud.has_method("reset_move_history"):
			_hud.call("reset_move_history")
	_start_turn()

func _human_player_color() -> int:
	for color in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var ctrl: PlayerController = _controllers[color] as PlayerController
		if ctrl != null and not ctrl.is_ai:
			return color
	return ChessEnums.PieceColor.WHITE

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
	_clear_check_outline()
	_deselect_piece()
	_board.clear_highlights()
	_selected_sq = Vector2i(-1, -1)
	_legal_from_selected.clear()

	var color  := _chess.active_color
	var state  := _chess.get_game_state()
	var legal  := _chess.get_legal_moves(color)
	_update_surrender_ui()

	if _hud != null:
		_hud.set_active_player(color)

	# Check / checkmate / stalemate
	if state == ChessEnums.GameState.CHECKMATE:
		MusicManager.set_checkmate_tension(true)
		emit_signal("game_over", 1 - color, ChessEnums.GameState.CHECKMATE)
		_animate_checkmate_end(color)                        # async: king dies → 2s → panel
		return
	if state == ChessEnums.GameState.STALEMATE:
		MusicManager.reset_dynamic_music()
		emit_signal("game_over", -1, ChessEnums.GameState.STALEMATE)
		_show_game_over(-1, "Pat (remíza)")
		return
	if state == ChessEnums.GameState.DRAW:
		MusicManager.reset_dynamic_music()
		emit_signal("game_over", -1, ChessEnums.GameState.DRAW)
		_show_game_over(-1, "Remíza")
		return
	if state == ChessEnums.GameState.CHECK:
		MusicManager.set_check_tension(true)
		var king_sq := _chess._find_king(color)
		_board.highlight_check(king_sq)
		_apply_check_outline(color)
	else:
		MusicManager.set_check_tension(false)

	_move_start_time_ms = Time.get_ticks_msec()
	var ctrl: PlayerController = _controllers[color] as PlayerController
	_update_ai_ui(ctrl.is_ai)
	# Show AI thinking indicator
	if ctrl.is_ai and _ui != null:
		var game_ui = _ui as Control
		if game_ui.has_method("show_ai_thinking"):
			game_ui.show_ai_thinking()
	ctrl.request_move(_chess, legal)

func is_human_turn() -> bool:
	if _chess == null or _controllers.size() < 2:
		return false
	var color: int = _chess.active_color
	var ctrl: PlayerController = _controllers[color] as PlayerController
	return ctrl != null and not ctrl.is_ai

func can_surrender() -> bool:
	if _game_over_shown or _chess == null:
		return false
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

# ── Time-out ───────────────────────────────────────────────────────────────
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
	_game_over_shown = true
	_busy = true
	MusicManager.reset_dynamic_music()
	var surrendering := _chess.active_color
	var winner := 1 - surrendering
	emit_signal("game_over", winner, ChessEnums.GameState.CHECKMATE)
	_show_game_over(winner, "Surrender")

func _format_time(ms: int) -> String:
	var secs: int = int(ms / 1000.0)
	var mins: int = int(secs / 60.0)
	var sec_rem: int = secs % 60
	if mins > 0:
		return "%d:%02d" % [mins, sec_rem]
	return "%d s" % secs

func _update_ai_ui(is_ai: bool) -> void:
	var lbl := _ui.get_node_or_null("AIThinkingLabel") as Label
	if lbl:
		lbl.visible = is_ai

# ── Input (human clicks) ───────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if _busy:
		return
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return

	var color: int = _chess.active_color
	var ctrl: PlayerController = _controllers[color] as PlayerController
	if ctrl.is_ai:
		return   # ignore clicks during AI turn

	# Raycast to board plane
	var clicked_sq := _raycast_board(mb.position)
	if clicked_sq.x < 0:
		return
	var human_ctrl := ctrl as HumanController
	if human_ctrl == null:
		return

	_handle_human_click(clicked_sq, human_ctrl)

func _handle_human_click(sq: Vector2i, ctrl: HumanController) -> void:
	var color := _chess.active_color

	# Clicking a valid move square?
	for mv in _legal_from_selected:
		if mv.to_sq == sq:
			if mv.move_type == ChessEnums.MoveType.PROMOTION \
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
				_request_promotion(sq, color)
				return
			_board.clear_highlights()
			_deselect_piece()
			ctrl.try_move(mv)
			return

	# Clicking own piece?
	var piece := _chess.get_piece(sq)
	if not piece.is_empty() and piece["color"] == color:
		_deselect_piece()
		_selected_sq = sq
		_select_piece(sq)
		_legal_from_selected = ctrl.get_legal_moves_from(sq)
		_highlight_attack_targets(_legal_from_selected)
		_board.clear_highlights()
		_board.highlight_selected(sq)
		_board.highlight_moves(_legal_from_selected)
		if _sfx_select != null:
			_sfx_select.play()
		# Re-draw check highlight if still in check
		if _chess.get_game_state() == ChessEnums.GameState.CHECK:
			_board.highlight_check(_chess._find_king(color))
			_apply_check_outline(color)
		return

	# Click on empty or enemy without selection → deselect
	_deselect_piece()
	_selected_sq = Vector2i(-1, -1)
	_legal_from_selected.clear()
	_board.clear_highlights()

func _request_promotion(sq: Vector2i, color: int) -> void:
	_pending_promotion_moves.clear()
	for mv in _legal_from_selected:
		if mv.to_sq == sq and (
			mv.move_type == ChessEnums.MoveType.PROMOTION
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE
		):
			_pending_promotion_moves.append(mv)
	if _pending_promotion_moves.is_empty():
		return
	_busy = true
	_board.clear_highlights()
	_deselect_piece()
	emit_signal("promotion_needed", sq, color)

func _select_piece(sq: Vector2i) -> void:
	var bp: BasePiece = _sq_pieces.get(sq) as BasePiece
	if bp:
		_selected_piece = bp
		_selected_piece.set_outline(OUTLINE_SELECTED, OUTLINE_WIDTH)

func _deselect_piece() -> void:
	if _selected_piece != null and is_instance_valid(_selected_piece):
		_selected_piece.clear_outline()
	for bp in _attack_outlined_pieces:
		if bp != null and is_instance_valid(bp):
			bp.clear_outline()
	_attack_outlined_pieces.clear()
	_selected_piece = null

func _highlight_attack_targets(moves: Array) -> void:
	_attack_outlined_pieces.clear()
	var seen := {}
	for mv in moves:
		if not mv.is_capture():
			continue
		var target_sq: Vector2i = mv.to_sq
		if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
			target_sq = Vector2i(mv.to_sq.x, mv.from_sq.y)
		var key := "%d,%d" % [target_sq.x, target_sq.y]
		if seen.has(key):
			continue
		seen[key] = true
		var target: BasePiece = _sq_pieces.get(target_sq) as BasePiece
		if target != null and is_instance_valid(target):
			target.set_outline(OUTLINE_ATTACK, OUTLINE_WIDTH)
			_attack_outlined_pieces.append(target)

func _apply_check_outline(color: int) -> void:
	_clear_check_outline()
	var king_sq := _chess._find_king(color)
	var king_piece: BasePiece = _sq_pieces.get(king_sq) as BasePiece
	if king_piece != null and is_instance_valid(king_piece):
		king_piece.set_outline(OUTLINE_CHECK, OUTLINE_WIDTH)
		_check_outlined_king = king_piece

func _clear_check_outline() -> void:
	if _check_outlined_king != null and is_instance_valid(_check_outlined_king):
		_check_outlined_king.clear_outline()
	_check_outlined_king = null

func _raycast_board(screen_pos: Vector2) -> Vector2i:
	var camera := _camera.get_node("Camera3D") as Camera3D
	if camera == null:
		return Vector2i(-1, -1)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir    := camera.project_ray_normal(screen_pos)
	# Intersect with Y=0 plane
	if abs(ray_dir.y) < 0.001:
		return Vector2i(-1, -1)
	var t := -ray_origin.y / ray_dir.y
	if t < 0:
		return Vector2i(-1, -1)
	var hit := ray_origin + ray_dir * t
	return _board.world_to_sq(hit)

# ── Move execution ─────────────────────────────────────────────────────────
func _on_move_chosen(mv: ChessMove) -> void:
	if _game_over_shown:
		return   # game ended (e.g. surrender while AI was thinking)
	# Hide AI thinking indicator
	if _ui != null:
		var game_ui = _ui as Control
		if game_ui.has_method("hide_ai_thinking"):
			game_ui.hide_ai_thinking()
	_busy = true
	_deselect_piece()   # clear outline before move animation
	# Track timing + deduct from clock
	var elapsed: int = Time.get_ticks_msec() - _move_start_time_ms
	_move_times_ms[mv.piece_color] += elapsed
	_move_counts[mv.piece_color]   += 1
	if _time_control_ms > 0:
		_time_remaining_ms[mv.piece_color] = maxi(
			_time_remaining_ms[mv.piece_color] - elapsed, 0)

	# Track captured pieces for HUD
	if mv.captured_type != ChessEnums.PieceType.NONE:
		_captured_by[mv.piece_color].append(mv.captured_type)
		if _hud != null:
			_hud.refresh_captured(mv.piece_color, _captured_by[mv.piece_color])
		if _material_pressure_fx != null and _material_pressure_fx.has_method("update_from_captured"):
			_material_pressure_fx.call("update_from_captured", _captured_by)

	# Apply to logic board BEFORE animation so board state is updated
	_chess.make_move(mv)

	# Kill cam: dramatic close-up for captures (if enabled in settings).
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var _is_capture := mv.move_type == ChessEnums.MoveType.CAPTURE \
		or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE \
		or mv.move_type == ChessEnums.MoveType.EN_PASSANT
	if _is_capture and cam_cfg != null and cam_cfg.kill_cam_enabled:
		var from_world      := _board.sq_to_world(mv.from_sq)
		var to_world        := _board.sq_to_world(mv.to_sq)
		var attacker_piece  := _sq_pieces.get(mv.from_sq) as Node3D
		_camera.kill_cam(from_world, to_world, attacker_piece)

	await _animate_move(mv)
	_board.highlight_last_move(mv.from_sq, mv.to_sq)
	if _hud != null and _hud.has_method("append_move_to_history"):
		_hud.call("append_move_to_history", mv)
	_busy = false

	# After a kill-cam capture, hold the view for 2 s so the player can appreciate the moment.
	if _is_capture and cam_cfg != null and cam_cfg.kill_cam_enabled:
		await get_tree().create_timer(2.0).timeout

	# Rotate camera to active player — skip if disabled OR if checkmate is coming
	# (checkmate_cam will take over instead of face_player in _animate_checkmate_end).
	var _next_state := _chess.get_game_state()
	var _is_checkmate := _next_state == ChessEnums.GameState.CHECKMATE
	if not _is_checkmate:
		if _is_player_vs_ai and _is_capture and cam_cfg != null and cam_cfg.kill_cam_enabled:
			_camera.restore_pre_kill_cam_view()
		elif not _is_player_vs_ai and (cam_cfg == null or cam_cfg.get("face_player_after_move") != false):
			_camera.face_player(_chess.active_color)
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
	var vfx: Node3D = _PROMO_VFX_IMPACT_SCENE.instantiate() as Node3D
	get_tree().root.add_child(vfx)
	vfx.global_position = world_pos + Vector3(0, 0.5, 0)
	vfx.scale = vfx.scale * 1.2
	vfx.set("one_shot", true)
	if vfx.has_method("play"):
		vfx.call("play")
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if is_instance_valid(vfx):
			vfx.queue_free())

	# Same spell SFX as death impact; root-level so it survives piece swap.
	var tmp := AudioStreamPlayer.new()
	tmp.bus = "SFX"
	get_tree().root.add_child(tmp)
	tmp.stream = _PROMO_SFX_SPELL
	tmp.volume_db = -6.0
	tmp.finished.connect(tmp.queue_free)
	tmp.play()

# ── Pawn promotion UI ──────────────────────────────────────────────────────
func _on_promotion_required(sq: Vector2i, color: int) -> void:
	emit_signal("promotion_needed", sq, color)
	# UI handled by PromotionPanel node; it calls choose_promotion()

func choose_promotion(sq: Vector2i, piece_type: int) -> void:
	# Called by UI after player picks promoted piece.
	var chosen: ChessMove = null
	for mv in _pending_promotion_moves:
		if mv.to_sq == sq and mv.promotion_type == piece_type:
			chosen = mv
			break
	_pending_promotion_moves.clear()
	if chosen == null:
		return
	_on_move_chosen(chosen)

# ── Game over UI ───────────────────────────────────────────────────────────
func _show_game_over(winner_color: int, reason: String) -> void:
	var panel := _ui.get_node_or_null("GameOverPanel") as Control
	if panel == null:
		return
	panel.visible = true

	var title_lbl := panel.get_node_or_null("VBox/TitleLabel") as Label
	var winner_lbl := panel.get_node_or_null("VBox/WinnerLabel") as Label
	var loser_lbl := panel.get_node_or_null("VBox/LoserLabel") as Label
	var reason_lbl := panel.get_node_or_null("VBox/ReasonLabel") as Label
	var stats_lbl := panel.get_node_or_null("VBox/StatsLabel") as Label
	var stats_time_title := panel.get_node_or_null("VBox/StatsTimeTitle") as Label
	var stats_time_value := panel.get_node_or_null("VBox/StatsTimeValue") as Label
	var stats_avg_title := panel.get_node_or_null("VBox/StatsAvgTitle") as Label
	var stats_avg_value := panel.get_node_or_null("VBox/StatsAvgValue") as Label

	if winner_color == -1:
		if title_lbl:
			title_lbl.text = "DRAW"
		if winner_lbl:
			winner_lbl.text = "%s vs %s" % [_player_names[0], _player_names[1]]
		if loser_lbl:
			loser_lbl.text = ""
	else:
		var winner_name: String = _player_names[winner_color]
		var loser_name: String  = _player_names[1 - winner_color]
		if title_lbl:
			title_lbl.text = "VICTORY"
		if winner_lbl:
			winner_lbl.text = winner_name + " WON"
		if loser_lbl:
			loser_lbl.text = loser_name + " LOST"

	if reason_lbl:
		reason_lbl.text = reason

	if stats_time_title == null or stats_time_value == null \
	or stats_avg_title == null or stats_avg_value == null:
		var vbox := panel.get_node_or_null("VBox") as VBoxContainer
		if vbox != null:
			if stats_time_title == null:
				stats_time_title = Label.new()
				stats_time_title.name = "StatsTimeTitle"
				stats_time_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				stats_time_title.add_theme_font_size_override("font_size", 20)
				stats_time_title.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4, 1.0))
				vbox.add_child(stats_time_title)
			if stats_time_value == null:
				stats_time_value = Label.new()
				stats_time_value.name = "StatsTimeValue"
				stats_time_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				stats_time_value.add_theme_font_size_override("font_size", 18)
				stats_time_value.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88, 1.0))
				vbox.add_child(stats_time_value)
			if stats_avg_title == null:
				stats_avg_title = Label.new()
				stats_avg_title.name = "StatsAvgTitle"
				stats_avg_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				stats_avg_title.add_theme_font_size_override("font_size", 20)
				stats_avg_title.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4, 1.0))
				vbox.add_child(stats_avg_title)
			if stats_avg_value == null:
				stats_avg_value = Label.new()
				stats_avg_value.name = "StatsAvgValue"
				stats_avg_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				stats_avg_value.add_theme_font_size_override("font_size", 18)
				stats_avg_value.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88, 1.0))
				vbox.add_child(stats_avg_value)

	# Compute time remaining/elapsed for both players
	var white_time: String = ""
	var black_time: String = ""
	if _time_control_ms > 0:
		white_time = _format_time(_time_remaining_ms[ChessEnums.PieceColor.WHITE])
		black_time = _format_time(_time_remaining_ms[ChessEnums.PieceColor.BLACK])
	else:
		white_time = _format_time(_move_times_ms[ChessEnums.PieceColor.WHITE])
		black_time = _format_time(_move_times_ms[ChessEnums.PieceColor.BLACK])

	var white_avg_ms: float = 0.0
	var black_avg_ms: float = 0.0
	if _move_counts[ChessEnums.PieceColor.WHITE] > 0:
		white_avg_ms = float(_move_times_ms[ChessEnums.PieceColor.WHITE]) / float(_move_counts[ChessEnums.PieceColor.WHITE])
	if _move_counts[ChessEnums.PieceColor.BLACK] > 0:
		black_avg_ms = float(_move_times_ms[ChessEnums.PieceColor.BLACK]) / float(_move_counts[ChessEnums.PieceColor.BLACK])

	var white_avg_s: String = "%.1f s" % (white_avg_ms / 1000.0)
	var black_avg_s: String = "%.1f s" % (black_avg_ms / 1000.0)

	if stats_time_title:
		stats_time_title.text = "Time"
	if stats_time_value:
		stats_time_value.text = "%s: %s\n%s: %s" % [
			_player_names[ChessEnums.PieceColor.WHITE], white_time,
			_player_names[ChessEnums.PieceColor.BLACK], black_time
		]
	if stats_avg_title:
		stats_avg_title.text = "Average Turn"
	if stats_avg_value:
		stats_avg_value.text = "%s: %s\n%s: %s" % [
			_player_names[ChessEnums.PieceColor.WHITE], white_avg_s,
			_player_names[ChessEnums.PieceColor.BLACK], black_avg_s
		]
	if stats_lbl:
		stats_lbl.visible = false


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
