## game_ui.gd
## Handles in-game UI events: game-over back button, pawn promotion selection.

extends Control

@onready var _game: GameController = get_parent()
@onready var _promo_panel: Control = $PromotionPanel
@onready var _over_panel:  Control = $GameOverPanel

var _pending_promo_sq: Vector2i = Vector2i(-1, -1)
var _pending_promo_color: int = 0

func _ready() -> void:
	$GameOverPanel/VBox/BackButton.pressed.connect(_on_back_pressed)
	$PromotionPanel/HBox/QueenBtn.pressed.connect( func(): _choose(ChessEnums.PieceType.QUEEN))
	$PromotionPanel/HBox/RookBtn.pressed.connect(  func(): _choose(ChessEnums.PieceType.ROOK))
	$PromotionPanel/HBox/BishopBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.BISHOP))
	$PromotionPanel/HBox/KnightBtn.pressed.connect(func(): _choose(ChessEnums.PieceType.KNIGHT))

	_game.promotion_needed.connect(_on_promotion_needed)

func _on_promotion_needed(sq: Vector2i, color: int) -> void:
	_pending_promo_sq    = sq
	_pending_promo_color = color
	_promo_panel.visible = true

func _choose(piece_type: int) -> void:
	_promo_panel.visible = false
	_game.choose_promotion(_pending_promo_sq, piece_type)

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
