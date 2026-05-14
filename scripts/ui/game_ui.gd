## game_ui.gd
## Handles in-game UI events: game-over back button, pawn promotion selection,
## and the surrender button.

extends Control

@onready var _game: GameController = get_parent()
@onready var _promo_panel: Control = $PromotionPanel
@onready var _over_panel:  Control = $GameOverPanel

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0
var _surrender_btn: Button = null

func _ready() -> void:
	$GameOverPanel/VBox/BackButton.pressed.connect(_on_back_pressed)
	$PromotionPanel/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))

	_game.promotion_needed.connect(_on_promotion_needed)
	_setup_surrender_btn()
	_game.game_over.connect(func(_w: int, _r: int) -> void: _surrender_btn.visible = false)
	_apply_roblox_theme()

func _setup_surrender_btn() -> void:
	_surrender_btn = Button.new()
	_surrender_btn.text = "Surrender"
	_surrender_btn.anchor_left    = 0.5
	_surrender_btn.anchor_right   = 0.5
	_surrender_btn.anchor_top     = 1.0
	_surrender_btn.anchor_bottom  = 1.0
	_surrender_btn.grow_horizontal = 2  # GROW_DIRECTION_BOTH
	_surrender_btn.offset_left    = -180.0
	_surrender_btn.offset_right   =  180.0
	_surrender_btn.offset_top     = -80.0
	_surrender_btn.offset_bottom  = -12.0
	_surrender_btn.add_theme_font_size_override("font_size", 32)
	add_child(_surrender_btn)
	_surrender_btn.pressed.connect(_game.surrender)

func _on_promotion_needed(sq: Vector2i, color: int) -> void:
	_pending_promo_sq    = sq
	_pending_promo_color = color
	_promo_panel.visible = true

func _choose(piece_type: int) -> void:
	_promo_panel.visible = false
	_game.choose_promotion(_pending_promo_sq, piece_type)

func _on_back_pressed() -> void:
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

	var over_lbl := _over_panel.get_node_or_null("VBox/Label") as Label
	if over_lbl:
		over_lbl.add_theme_color_override("font_color",         Color(1.0, 0.88, 0.25, 1.0))
		over_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
		over_lbl.add_theme_constant_override("outline_size", 4)

	_style_btn(_over_panel.get_node_or_null("VBox/BackButton") as Button)
	_style_btn(_surrender_btn)
	for btn_name: String in ["QueenBtn", "RookBtn", "BishopBtn", "KnightBtn"]:
		_style_btn(_promo_panel.get_node_or_null("HBox/%s" % btn_name) as Button)
