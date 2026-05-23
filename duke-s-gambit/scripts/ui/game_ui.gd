## game_ui.gd
## Handles in-game UI events: game-over back button, pawn promotion selection,
## and the surrender button.

extends Control

@onready var _game: GameController = get_parent()
@onready var _promo_panel: Control = $PromotionPanel
@onready var _surrender_panel: PanelContainer = $SurrenderConfirmPanel
@onready var _surrender_btn: Button = $SurrenderButton
@onready var _ai_thinking_box: Control = $AIThinkingBox
@onready var _ai_status_bar: ProgressBar = $AIThinkingBox/AIThinkingVBox/AIThinkingProgress
@onready var _net_turn_box: Control = $NETPlayerTurnBox
@onready var _net_turn_bar: ProgressBar = $NETPlayerTurnBox/NETPlayerTurnVBox/NETPlayerTurnProgress
@onready var _net_join_box: Control = $NETPlayerJoinBox
@onready var _net_join_bar: ProgressBar = $NETPlayerJoinBox/NETPlayerJoinVBox/NETPlayerJoinProgress
@onready var _disconnect_btn: Button = $NETPlayerJoinBox/NETPlayerJoinVBox/DisconnectButton
@onready var _export_btn: Button = $GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/ExportButton
@onready var _kicked_panel: Control = $KickedBannedPanel
@onready var _kicked_title: Label = $KickedBannedPanel/VBox/TitleLabel
@onready var _kicked_reason: Label = $KickedBannedPanel/VBox/ReasonLabel
@onready var _replay_box: CenterContainer = $ReplayBox
@onready var _replay_progress_label: Label = $ReplayBox/ReplayVBox/ReplayTopRow/ReplayProgressLabel
@onready var _replay_progress_bar: ProgressBar = $ReplayBox/ReplayVBox/ReplayProgressBar

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0
var _status_tween: Tween = null
var _is_replay_mode: bool = false

# Full-screen overlay that absorbs mouse/touch input while a modal dialog is
# open. Game board picking and camera orbit both use _unhandled_input, so a
# Control with MOUSE_FILTER_STOP layered above them blocks all interaction.
var _modal_blocker: Control = null
var _modal_panels: Array[Control] = []

func _ready() -> void:
	$GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/BackButton.pressed.connect(_on_back_pressed)
	$GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/ExportButton.pressed.connect(_on_export_pressed)
	$PromotionPanel/VBox/ContentCenter/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/VBox/ContentCenter/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/VBox/ContentCenter/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/VBox/ContentCenter/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))
	$SurrenderButton.pressed.connect(_on_surrender_pressed)
	$ReplayBox/ReplayVBox/ReplayTopRow/ReplayBackButton.pressed.connect(_on_back_pressed)

	$SurrenderConfirmPanel/VBox/ButtonHBox/YesButton.pressed.connect(_on_surrender_confirmed)
	$SurrenderConfirmPanel/VBox/ButtonHBox/NoButton.pressed.connect(func(): _surrender_panel.visible = false)
	$KickedBannedPanel/VBox/BackButton.pressed.connect(_on_back_pressed)
	if _disconnect_btn != null:
		_disconnect_btn.pressed.connect(_on_disconnect_pressed)

	_setup_modal_blocker()

	_game.promotion_needed.connect(_on_promotion_needed)
	_game.game_over.connect(func(_w: int, _r: int) -> void:
		if _surrender_btn != null:
			_surrender_btn.visible = false
		_surrender_panel.visible = false
		hide_status()
		if _export_btn != null:
			_export_btn.visible = _game._chess != null \
					and not _game._chess.move_history.is_empty()
	)

	var _oc := get_node_or_null("/root/OnlineClient")
	if _oc != null and _oc.has_signal("player_kicked"):
		_oc.player_kicked.connect(_on_player_kicked)

# ── Modal input blocker ────────────────────────────────────────────────────
func _setup_modal_blocker() -> void:
	var blocker := Control.new()
	blocker.name = "ModalBlocker"
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.visible = false
	add_child(blocker)
	_modal_blocker = blocker

	var game_over_panel := get_node_or_null("GameOverPanel") as Control
	_modal_panels = [_promo_panel, _surrender_panel, _kicked_panel]
	if game_over_panel != null:
		_modal_panels.append(game_over_panel)
	for p in _modal_panels:
		if p == null:
			continue
		p.visibility_changed.connect(_on_modal_visibility_changed.bind(p))

func _on_modal_visibility_changed(panel: Control) -> void:
	if _modal_blocker == null:
		return
	if panel.visible:
		# Keep blocker just under the panel so input and rendering stay layered:
		# blocker absorbs everything below, panel still receives clicks.
		move_child(_modal_blocker, -1)
		panel.move_to_front()
	_modal_blocker.visible = _any_modal_visible()

func _any_modal_visible() -> bool:
	for p in _modal_panels:
		if p != null and p.visible:
			return true
	return false

# ── Status stack (mutually exclusive boxes at top-centre of HUD) ───────────
# Only one of {SurrenderButton, AIThinkingBox, NETPlayerTurnBox, NETPlayerJoinBox}
# is visible at a time. Each box has fixed text — swap by toggling visibility,
# never by rewriting labels.

func _animate_progress_bar(bar: ProgressBar) -> void:
	if bar == null:
		return
	if _status_tween != null:
		_status_tween.kill()
	bar.value = 0
	_status_tween = create_tween().set_loops()
	_status_tween.tween_property(bar, "value", 100, 1.5).set_trans(Tween.TRANS_LINEAR)
	_status_tween.tween_property(bar, "value", 0, 0.2)

func _hide_status_boxes() -> void:
	if _ai_thinking_box != null:
		_ai_thinking_box.visible = false
	if _net_turn_box != null:
		_net_turn_box.visible = false
	if _net_join_box != null:
		_net_join_box.visible = false

func show_ai_thinking() -> void:
	_hide_status_boxes()
	if _surrender_btn != null:
		_surrender_btn.visible = false
	if _ai_thinking_box != null:
		_ai_thinking_box.visible = true
	_animate_progress_bar(_ai_status_bar)

func show_opponent_turn() -> void:
	_hide_status_boxes()
	if _surrender_btn != null:
		_surrender_btn.visible = false
	if _net_turn_box != null:
		_net_turn_box.visible = true
	_animate_progress_bar(_net_turn_bar)

func show_waiting_for_opponent() -> void:
	_hide_status_boxes()
	if _surrender_btn != null:
		_surrender_btn.visible = false
	if _net_join_box != null:
		_net_join_box.visible = true
	_animate_progress_bar(_net_join_bar)

func hide_status() -> void:
	if _status_tween != null:
		_status_tween.kill()
		_status_tween = null
	_hide_status_boxes()

func _on_surrender_pressed() -> void:
	if _is_replay_mode:
		# In replay mode the button acts as "Stop Replay" — go directly to menu.
		_on_back_pressed()
		return
	if _game == null or not _game.can_surrender():
		return
	_surrender_panel.visible = true

func _on_disconnect_pressed() -> void:
	# Used while waiting for the opponent to finish loading: leave the room
	# (server treats mid-game leave as resignation) and return to main menu.
	var oc := get_node_or_null("/root/OnlineClient")
	if oc != null:
		oc.send_leave_room()
	hide_status()
	_on_back_pressed()

func _on_player_kicked(reason: String, is_ban: bool) -> void:
	if _kicked_panel == null:
		return
	_kicked_title.text = "You are banned" if is_ban else "You were kicked"
	_kicked_reason.text = reason
	_kicked_panel.visible = true
	if _surrender_btn != null:
		_surrender_btn.visible = false
	_surrender_panel.visible = false
	hide_status()

func _on_surrender_confirmed() -> void:
	if _game == null or not _game.can_surrender():
		_surrender_panel.visible = false
		return
	_surrender_panel.visible = false
	_game.surrender()

func set_surrender_available(available: bool) -> void:
	if _surrender_btn == null:
		return
	# In replay mode the surrender button is hidden; ReplayBox has the back button.
	if _is_replay_mode:
		_surrender_btn.visible = false
		_surrender_btn.disabled = true
		return
	if available:
		# Player's local turn — ensure no status box steals the spot.
		hide_status()
	_surrender_btn.visible = available
	_surrender_btn.disabled = not available
	if not available and _surrender_panel != null:
		_surrender_panel.visible = false

## Called from GameController.setup_replay() to switch to replay-mode UI.
func set_replay_mode(enabled: bool) -> void:
	_is_replay_mode = enabled
	if _replay_box != null:
		_replay_box.visible = enabled
	# Keep SurrenderButton hidden in replay mode (ReplayBox has the back button).
	if _surrender_btn != null:
		_surrender_btn.visible = not enabled

func update_replay_progress(current: int, total: int) -> void:
	if _replay_progress_label != null:
		_replay_progress_label.text = "%d / %d" % [current, total]
	if _replay_progress_bar != null:
		_replay_progress_bar.max_value = maxf(1, total)
		_replay_progress_bar.value = current

func _on_promotion_needed(sq: Vector2i, color: int) -> void:
	_pending_promo_sq    = sq
	_pending_promo_color = color
	_configure_promotion_dialog(color)
	_promo_panel.visible = true

func _choose(piece_type: int) -> void:
	var accepted := _game.choose_promotion(_pending_promo_sq, piece_type)
	if accepted:
		_promo_panel.visible = false
	else:
		_configure_promotion_dialog(_pending_promo_color)
		_promo_panel.visible = true

func _promo_icon_path(color: int, piece_type: int) -> String:
	var prefix := "white" if color == ChessEnums.PieceColor.WHITE else "black"
	match piece_type:
		ChessEnums.PieceType.QUEEN:
			return "res://assets/textures/pieces/%s_queen.svg" % prefix
		ChessEnums.PieceType.ROOK:
			return "res://assets/textures/pieces/%s_rook.svg" % prefix
		ChessEnums.PieceType.BISHOP:
			return "res://assets/textures/pieces/%s_bishop.svg" % prefix
		ChessEnums.PieceType.KNIGHT:
			return "res://assets/textures/pieces/%s_knight.svg" % prefix
		_:
			return ""

func _promo_button(btn: Button, piece_type: int, color: int) -> void:
	if btn == null:
		return
	var icon_path := _promo_icon_path(color, piece_type)
	if icon_path != "":
		btn.icon = load(icon_path)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT

func _configure_promotion_dialog(color: int) -> void:
	var queen_btn := $PromotionPanel/VBox/ContentCenter/HBox/QueenBtn as Button
	var rook_btn := $PromotionPanel/VBox/ContentCenter/HBox/RookBtn as Button
	var bishop_btn := $PromotionPanel/VBox/ContentCenter/HBox/BishopBtn as Button
	var knight_btn := $PromotionPanel/VBox/ContentCenter/HBox/KnightBtn as Button
	_promo_button(queen_btn, ChessEnums.PieceType.QUEEN, color)
	_promo_button(rook_btn, ChessEnums.PieceType.ROOK, color)
	_promo_button(bishop_btn, ChessEnums.PieceType.BISHOP, color)
	_promo_button(knight_btn, ChessEnums.PieceType.KNIGHT, color)

func _on_back_pressed() -> void:
	MusicManager.play_menu_music()
	# In online mode the server still has ctx.room_id set even after the game
	# finishes. Send leave_room so the server clears it; otherwise the next
	# attempt to create/join a room is rejected with "already in a room".
	if _game != null and _game._online_mode:
		var oc := get_node_or_null("/root/OnlineClient")
		if oc != null:
			oc.send_leave_room()
	# Add menu first, then free game scene so root is never empty for a frame
	var menu: Node = load("res://scenes/main_menu.tscn").instantiate()
	get_tree().root.add_child(menu)
	_game.queue_free()

func _on_export_pressed() -> void:
	if _game == null or _game._chess == null:
		return
	var history: Array = _game._chess.move_history
	if history.is_empty():
		return

	var white_name: String = _sanitize_filename(_game._player_names[ChessEnums.PieceColor.WHITE])
	var black_name: String = _sanitize_filename(_game._player_names[ChessEnums.PieceColor.BLACK])
	var dt: String = Time.get_datetime_string_from_system(false, true) \
			.replace(":", "-").replace("T", "_")
	var suggested: String = "%s_%s_%s.csv" % [white_name, black_name, dt]

	# Build CSV content up front so the lambda can capture it.
	var lines: PackedStringArray = PackedStringArray()
	lines.append("White,%s" % _game._player_names[ChessEnums.PieceColor.WHITE])
	lines.append("Black,%s" % _game._player_names[ChessEnums.PieceColor.BLACK])
	lines.append("Move,Color,Piece,From,To,Type,Captured,Promotion,Notation,GameTime_ms")
	var ply := 0
	for mv_variant in history:
		var mv: ChessMove = mv_variant as ChessMove
		if mv == null:
			continue
		ply += 1
		var move_no := int((ply + 1) / 2.0)
		var color_str  := "White" if mv.piece_color == ChessEnums.PieceColor.WHITE else "Black"
		var piece_str  := _export_piece_name(mv.piece_type)
		var from_str   := _export_sq(mv.from_sq)
		var to_str     := _export_sq(mv.to_sq)
		var type_str   := _export_move_type(mv.move_type)
		var cap_str    := _export_piece_name(mv.captured_type) if mv.is_capture() else ""
		var prom_str   := _export_piece_name(mv.promotion_type) \
				if mv.move_type == ChessEnums.MoveType.PROMOTION \
				or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE else ""
		var notation   := _export_notation(mv)
		lines.append("%d,%s,%s,%s,%s,%s,%s,%s,%s,%d" % [
			move_no, color_str, piece_str, from_str, to_str,
			type_str, cap_str, prom_str, notation, mv.game_time_ms
		])

	# Open a save-file dialog so the player can choose the destination.
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.csv ; CSV Files"])
	dialog.current_file = suggested
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))

	dialog.file_selected.connect(func(path: String) -> void:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			push_error("ExportButton: cannot write to %s (error %d)" % [path, FileAccess.get_open_error()])
			dialog.queue_free()
			return
		for line in lines:
			file.store_line(line)
		file.close()
		dialog.queue_free()
		_export_btn.disabled = true
		_export_btn.text = "Exported!"
	)
	dialog.canceled.connect(dialog.queue_free)

func _sanitize_filename(s: String) -> String:
	var out := ""
	for ch in s:
		if ch in '/\\:*?"<>| ':
			out += "_"
		else:
			out += ch
	return out if out != "" else "Player"

func _export_sq(sq: Vector2i) -> String:
	return "%s%d" % [String.chr(97 + (7 - sq.x)), sq.y + 1]

func _export_piece_name(pt: int) -> String:
	match pt:
		ChessEnums.PieceType.PAWN:   return "Pawn"
		ChessEnums.PieceType.ROOK:   return "Rook"
		ChessEnums.PieceType.KNIGHT: return "Knight"
		ChessEnums.PieceType.BISHOP: return "Bishop"
		ChessEnums.PieceType.QUEEN:  return "Queen"
		ChessEnums.PieceType.KING:   return "King"
		_:                           return ""

func _export_move_type(mt: int) -> String:
	match mt:
		ChessEnums.MoveType.NORMAL:              return "Normal"
		ChessEnums.MoveType.CAPTURE:             return "Capture"
		ChessEnums.MoveType.CASTLING_KINGSIDE:   return "CastlingKingside"
		ChessEnums.MoveType.CASTLING_QUEENSIDE:  return "CastlingQueenside"
		ChessEnums.MoveType.EN_PASSANT:          return "EnPassant"
		ChessEnums.MoveType.PROMOTION:           return "Promotion"
		ChessEnums.MoveType.PROMOTION_CAPTURE:   return "PromotionCapture"
		_:                                       return "Unknown"

func _export_notation(mv: ChessMove) -> String:
	match mv.move_type:
		ChessEnums.MoveType.CASTLING_KINGSIDE:  return "O-O" + mv.check_annotation
		ChessEnums.MoveType.CASTLING_QUEENSIDE: return "O-O-O" + mv.check_annotation

	const LETTERS := {
		ChessEnums.PieceType.PAWN: "", ChessEnums.PieceType.ROOK: "R",
		ChessEnums.PieceType.KNIGHT: "N", ChessEnums.PieceType.BISHOP: "B",
		ChessEnums.PieceType.QUEEN: "Q", ChessEnums.PieceType.KING: "K",
	}
	var piece_letter: String = String(LETTERS.get(mv.piece_type, ""))
	if mv.piece_type == ChessEnums.PieceType.PAWN and mv.is_capture():
		piece_letter = String.chr(97 + (7 - mv.from_sq.x))
	var cap := "x" if mv.is_capture() else ""
	var to := _export_sq(mv.to_sq)
	var notation := "%s%s%s%s" % [piece_letter, mv.disambiguation, cap, to]
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		notation += "=" + String(LETTERS.get(mv.promotion_type, "Q"))
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		notation += " e.p."
	notation += mv.check_annotation
	return notation
