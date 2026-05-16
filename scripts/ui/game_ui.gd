## game_ui.gd
## Handles in-game UI events: game-over back button, pawn promotion selection,
## and the surrender button.

extends Control

@onready var _game: GameController = get_parent()
@onready var _promo_panel: Control = $PromotionPanel
@onready var _promo_title: Label = $PromotionPanel/VBox/TitleLabel
@onready var _over_panel:  Control = $GameOverPanel
@onready var _surrender_panel: PanelContainer = $SurrenderConfirmPanel

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0
var _surrender_btn: Button = null
var _ai_status_container: Control = null
var _ai_status_bar: ProgressBar = null

func _ready() -> void:
	$GameOverPanel/VBox/BackButton.pressed.connect(_on_back_pressed)
	$PromotionPanel/VBox/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/VBox/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/VBox/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/VBox/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))

	$SurrenderConfirmPanel/VBox/ButtonHBox/YesButton.pressed.connect(_on_surrender_confirmed)
	$SurrenderConfirmPanel/VBox/ButtonHBox/NoButton.pressed.connect(func(): _surrender_panel.visible = false)

	_game.promotion_needed.connect(_on_promotion_needed)
	_setup_surrender_btn()
	_setup_ai_status()
	_game.game_over.connect(func(_w: int, _r: int) -> void:
		_surrender_btn.visible = false
		_surrender_panel.visible = false
		_ai_status_container.visible = false
	)
	_apply_roblox_theme()

func _setup_surrender_btn() -> void:
	_surrender_btn = Button.new()
	_surrender_btn.text = "Surrender"
	# Umístění: nahoře uprostřed
	_surrender_btn.anchor_left    = 0.5
	_surrender_btn.anchor_right   = 0.5
	_surrender_btn.anchor_top     = 0.0
	_surrender_btn.anchor_bottom  = 0.0
	_surrender_btn.grow_horizontal = 2  # GROW_DIRECTION_BOTH
	_surrender_btn.offset_left    = -100.0
	_surrender_btn.offset_right   =  100.0
	_surrender_btn.offset_top     = 16.0
	_surrender_btn.offset_bottom  = 56.0
	_surrender_btn.add_theme_font_size_override("font_size", 24)
	add_child(_surrender_btn)
	_surrender_btn.pressed.connect(_on_surrender_pressed)

func _setup_ai_status() -> void:
	"""Vytvoří AI status indikátor - defaultně skrytý"""
	_ai_status_container = Control.new()
	_ai_status_container.anchor_left    = 0.5
	_ai_status_container.anchor_right   = 0.5
	_ai_status_container.anchor_top     = 0.0
	_ai_status_container.anchor_bottom  = 0.0
	_ai_status_container.grow_horizontal = 2
	_ai_status_container.offset_left    = -150.0
	_ai_status_container.offset_right   =  150.0
	_ai_status_container.offset_top     = 64.0
	_ai_status_container.offset_bottom  = 120.0
	_ai_status_container.visible = false
	add_child(_ai_status_container)

	# Label "AI thinking..."
	var label = Label.new()
	label.text = "AI is thinking..."
	label.add_theme_font_size_override("font_size", 16)
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.anchor_bottom = 0.4
	_ai_status_container.add_child(label)

	# Loading bar
	_ai_status_bar = ProgressBar.new()
	_ai_status_bar.show_percentage = false
	_ai_status_bar.anchor_left = 0.0
	_ai_status_bar.anchor_right = 1.0
	_ai_status_bar.anchor_top = 0.4
	_ai_status_bar.anchor_bottom = 1.0
	_ai_status_bar.offset_top = 4.0
	_ai_status_container.add_child(_ai_status_bar)

	# Animace loading baru
	_animate_ai_loading_bar()

func _animate_ai_loading_bar() -> void:
	"""Nekonečná animace loading baru"""
	if _ai_status_container == null or not _ai_status_container.visible:
		return
	var tween = create_tween().set_loops()
	_ai_status_bar.value = 0
	tween.tween_property(_ai_status_bar, "value", 100, 1.5) \
		.set_trans(Tween.TRANS_LINEAR)
	tween.tween_property(_ai_status_bar, "value", 0, 0.2)

func show_ai_thinking() -> void:
	"""Zobrazí AI status indikátor"""
	if _ai_status_container != null:
		_ai_status_container.visible = true
		_animate_ai_loading_bar()

func hide_ai_thinking() -> void:
	"""Skryje AI status indikátor"""
	if _ai_status_container != null:
		_ai_status_container.visible = false

func _on_surrender_pressed() -> void:
	_surrender_panel.visible = true

func _on_surrender_confirmed() -> void:
	_surrender_panel.visible = false
	_game.surrender()

func _on_promotion_needed(sq: Vector2i, color: int) -> void:
	_pending_promo_sq    = sq
	_pending_promo_color = color
	_configure_promotion_dialog(color)
	_promo_panel.visible = true

func _choose(piece_type: int) -> void:
	_promo_panel.visible = false
	_game.choose_promotion(_pending_promo_sq, piece_type)

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

func _promo_piece_name(piece_type: int) -> String:
	match piece_type:
		ChessEnums.PieceType.QUEEN:
			return "Queen"
		ChessEnums.PieceType.ROOK:
			return "Rook"
		ChessEnums.PieceType.BISHOP:
			return "Bishop"
		ChessEnums.PieceType.KNIGHT:
			return "Knight"
		_:
			return "Piece"

func _promo_button(btn: Button, piece_type: int, color: int) -> void:
	if btn == null:
		return
	btn.text = _promo_piece_name(piece_type)
	var icon_path := _promo_icon_path(color, piece_type)
	if icon_path != "":
		btn.icon = load(icon_path)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0, 92)

func _configure_promotion_dialog(color: int) -> void:
	if _promo_title:
		_promo_title.text = "White pawn promotion" if color == ChessEnums.PieceColor.WHITE else "Black pawn promotion"
		_promo_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_promo_title.add_theme_font_size_override("font_size", 30)
		_promo_title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3, 1.0) if color == ChessEnums.PieceColor.WHITE else Color(0.9, 0.9, 0.95, 1.0))
	_promo_button($PromotionPanel/VBox/HBox/QueenBtn, ChessEnums.PieceType.QUEEN, color)
	_promo_button($PromotionPanel/VBox/HBox/RookBtn, ChessEnums.PieceType.ROOK, color)
	_promo_button($PromotionPanel/VBox/HBox/BishopBtn, ChessEnums.PieceType.BISHOP, color)
	_promo_button($PromotionPanel/VBox/HBox/KnightBtn, ChessEnums.PieceType.KNIGHT, color)

func _on_back_pressed() -> void:
	MusicManager.play_menu_music()
	# Add menu first, then free game scene so root is never empty for a frame
	var menu: Node = load("res://scenes/main_menu.tscn").instantiate()
	get_tree().root.add_child(menu)
	_game.queue_free()

func _style_btn(btn: Button) -> void:
	if btn == null:
		return
	var s_n := StyleBoxFlat.new()
	s_n.bg_color    = Color(0.13, 0.15, 0.25, 1.0)
	s_n.border_color = Color(0.68, 0.50, 0.10, 1.0)
	s_n.set_border_width_all(3)
	s_n.set_corner_radius_all(10)
	s_n.content_margin_left   = 20
	s_n.content_margin_right  = 20
	s_n.content_margin_top    = 10
	s_n.content_margin_bottom = 10
	var s_h := s_n.duplicate() as StyleBoxFlat
	s_h.bg_color    = Color(0.22, 0.26, 0.42, 1.0)
	s_h.border_color = Color(1.00, 0.82, 0.20, 1.0)
	var s_p := s_n.duplicate() as StyleBoxFlat
	s_p.bg_color = Color(0.07, 0.08, 0.15, 1.0)
	btn.add_theme_stylebox_override("normal",  s_n)
	btn.add_theme_stylebox_override("hover",   s_h)
	btn.add_theme_stylebox_override("pressed", s_p)
	btn.add_theme_stylebox_override("focus",   s_h)
	btn.add_theme_color_override("font_color",         Color(1.0,  0.95, 0.80, 1.0))
	btn.add_theme_color_override("font_hover_color",   Color(1.0,  0.85, 0.20, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.85, 0.72, 0.30, 1.0))
	btn.add_theme_constant_override("outline_size", 2)
	btn.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.expand_icon = true

func _apply_roblox_theme() -> void:
	var panel_s := StyleBoxFlat.new()
	panel_s.bg_color    = Color(0.05, 0.06, 0.12, 0.95)
	panel_s.border_color = Color(0.82, 0.62, 0.10, 1.0)
	panel_s.set_border_width_all(5)
	panel_s.set_corner_radius_all(16)
	_over_panel.add_theme_stylebox_override("panel", panel_s)

	var promo_s := panel_s.duplicate() as StyleBoxFlat
	promo_s.set_border_width_all(4)
	promo_s.set_corner_radius_all(12)
	_promo_panel.add_theme_stylebox_override("panel", promo_s)
	_promo_panel.add_theme_constant_override("margin_left", 20)
	_promo_panel.add_theme_constant_override("margin_right", 20)
	_promo_panel.add_theme_constant_override("margin_top", 16)
	_promo_panel.add_theme_constant_override("margin_bottom", 16)

	var promo_box := _promo_panel.get_node_or_null("VBox") as VBoxContainer
	if promo_box:
		promo_box.add_theme_constant_override("separation", 14)

	var over_lbl := _over_panel.get_node_or_null("VBox/Label") as Label
	if over_lbl:
		over_lbl.add_theme_color_override("font_color",         Color(1.0, 0.88, 0.25, 1.0))
		over_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
		over_lbl.add_theme_constant_override("outline_size", 4)

	_style_btn(_over_panel.get_node_or_null("VBox/BackButton") as Button)
	_style_btn(_surrender_btn)
	for btn_name: String in ["QueenBtn", "RookBtn", "BishopBtn", "KnightBtn"]:
		_style_btn(_promo_panel.get_node_or_null("VBox/HBox/%s" % btn_name) as Button)
