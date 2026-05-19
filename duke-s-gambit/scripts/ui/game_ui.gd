## game_ui.gd
## Handles in-game UI events: game-over back button, pawn promotion selection,
## and the surrender button.

extends Control

@onready var _game: GameController = get_parent()
@onready var _promo_panel: Control = $PromotionPanel
@onready var _surrender_panel: PanelContainer = $SurrenderConfirmPanel
@onready var _surrender_btn: Button = $SurrenderButton
@onready var _ai_thinking_box: Control = $AIThinkingBox
@onready var _ai_thinking_label: Label = $AIThinkingBox/AIThinkingVBox/AIThinkingLabel
@onready var _ai_status_bar: ProgressBar = $AIThinkingBox/AIThinkingVBox/AIThinkingProgress
@onready var _export_btn: Button = $GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/ExportButton

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0
var _ai_loading_tween: Tween = null

func _ready() -> void:
	$GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/BackButton.pressed.connect(_on_back_pressed)
	$GameOverPanel/VBox/ContentCenter/ContentVBox/ButtonsRow/ExportButton.pressed.connect(_on_export_pressed)
	$PromotionPanel/VBox/ContentCenter/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/VBox/ContentCenter/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/VBox/ContentCenter/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/VBox/ContentCenter/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))
	$SurrenderButton.pressed.connect(_on_surrender_pressed)

	$SurrenderConfirmPanel/VBox/ButtonHBox/YesButton.pressed.connect(_on_surrender_confirmed)
	$SurrenderConfirmPanel/VBox/ButtonHBox/NoButton.pressed.connect(func(): _surrender_panel.visible = false)

	_game.promotion_needed.connect(_on_promotion_needed)
	_game.game_over.connect(func(_w: int, _r: int) -> void:
		if _surrender_btn != null:
			_surrender_btn.visible = false
		_surrender_panel.visible = false
		hide_ai_thinking()
		if _export_btn != null:
			_export_btn.visible = _game._chess != null \
					and not _game._chess.move_history.is_empty()
	)

func _animate_ai_loading_bar() -> void:
	if _ai_status_bar == null:
		return
	if _ai_loading_tween != null:
		_ai_loading_tween.kill()
	_ai_loading_tween = create_tween().set_loops()
	_ai_status_bar.value = 0
	_ai_loading_tween.tween_property(_ai_status_bar, "value", 100, 1.5) \
		.set_trans(Tween.TRANS_LINEAR)
	_ai_loading_tween.tween_property(_ai_status_bar, "value", 0, 0.2)

func show_ai_thinking() -> void:
	if _ai_thinking_box != null:
		_ai_thinking_box.visible = true
	if _ai_thinking_label != null:
		_ai_thinking_label.visible = true
	if _ai_status_bar != null:
		_ai_status_bar.visible = true
		_animate_ai_loading_bar()

func hide_ai_thinking() -> void:
	if _ai_loading_tween != null:
		_ai_loading_tween.kill()
		_ai_loading_tween = null
	if _ai_thinking_box != null:
		_ai_thinking_box.visible = false
	if _ai_thinking_label != null:
		_ai_thinking_label.visible = false
	if _ai_status_bar != null:
		_ai_status_bar.visible = false

func _on_surrender_pressed() -> void:
	if _game == null or not _game.can_surrender():
		return
	_surrender_panel.visible = true

func _on_surrender_confirmed() -> void:
	if _game == null or not _game.can_surrender():
		_surrender_panel.visible = false
		return
	_surrender_panel.visible = false
	_game.surrender()

func set_surrender_available(available: bool) -> void:
	if _surrender_btn == null:
		return
	_surrender_btn.visible = available
	_surrender_btn.disabled = not available
	if not available and _surrender_panel != null:
		_surrender_panel.visible = false

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
	var filename: String = "%s_%s_%s.csv" % [white_name, black_name, dt]

	var base_dir: String
	if OS.has_feature("editor"):
		base_dir = ProjectSettings.globalize_path("res://")
	else:
		base_dir = OS.get_executable_path().get_base_dir()
	var path: String = base_dir.path_join(filename)

	var lines: PackedStringArray = PackedStringArray()
	lines.append("Move,Color,Piece,From,To,Type,Captured,Promotion,Notation")
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
		lines.append("%d,%s,%s,%s,%s,%s,%s,%s,%s" % [
			move_no, color_str, piece_str, from_str, to_str,
			type_str, cap_str, prom_str, notation
		])

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("ExportButton: cannot write to %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	for line in lines:
		file.store_line(line)
	file.close()
	_export_btn.disabled = true
	_export_btn.text = "Exported!"

func _sanitize_filename(s: String) -> String:
	var out := ""
	for ch in s:
		if ch in '/\\:*?"<>| ':
			out += "_"
		else:
			out += ch
	return out if out != "" else "Player"

func _export_sq(sq: Vector2i) -> String:
	return "%s%d" % [String.chr(97 + sq.x), sq.y + 1]

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
		ChessEnums.MoveType.CASTLING_KINGSIDE:  return "O-O"
		ChessEnums.MoveType.CASTLING_QUEENSIDE: return "O-O-O"

	const LETTERS := {
		ChessEnums.PieceType.PAWN: "", ChessEnums.PieceType.ROOK: "R",
		ChessEnums.PieceType.KNIGHT: "N", ChessEnums.PieceType.BISHOP: "B",
		ChessEnums.PieceType.QUEEN: "Q", ChessEnums.PieceType.KING: "K",
	}
	var piece_letter: String = String(LETTERS.get(mv.piece_type, ""))
	if mv.piece_type == ChessEnums.PieceType.PAWN and mv.is_capture():
		piece_letter = String.chr(97 + mv.from_sq.x)
	var cap := "x" if mv.is_capture() else ""
	var to := _export_sq(mv.to_sq)
	var notation := "%s%s%s" % [piece_letter, cap, to]
	if mv.move_type == ChessEnums.MoveType.PROMOTION \
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		notation += "=" + String(LETTERS.get(mv.promotion_type, "Q"))
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		notation += " e.p."
	return notation
