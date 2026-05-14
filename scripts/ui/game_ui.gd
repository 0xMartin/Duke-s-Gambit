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
