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

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0
var _ai_loading_tween: Tween = null

func _ready() -> void:
	$GameOverPanel/VBox/BackButton.pressed.connect(_on_back_pressed)
	$PromotionPanel/VBox/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/VBox/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/VBox/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/VBox/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))
	$SurrenderButton.pressed.connect(_on_surrender_pressed)

	$SurrenderConfirmPanel/VBox/ButtonHBox/YesButton.pressed.connect(_on_surrender_confirmed)
	$SurrenderConfirmPanel/VBox/ButtonHBox/NoButton.pressed.connect(func(): _surrender_panel.visible = false)

	_game.promotion_needed.connect(_on_promotion_needed)
	_game.game_over.connect(func(_w: int, _r: int) -> void:
		if _surrender_btn != null:
			_surrender_btn.visible = false
		_surrender_panel.visible = false
		hide_ai_thinking()
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
	var queen_btn := $PromotionPanel/VBox/HBox/QueenBtn as Button
	var rook_btn := $PromotionPanel/VBox/HBox/RookBtn as Button
	var bishop_btn := $PromotionPanel/VBox/HBox/BishopBtn as Button
	var knight_btn := $PromotionPanel/VBox/HBox/KnightBtn as Button
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
