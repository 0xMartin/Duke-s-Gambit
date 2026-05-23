## game_over_panel.gd
## Fills in the end-of-game dialog (player icons, winner colours, reason,
## stats grid).  Pure presentation — game logic stays in GameController.
## Attach to HUD/GameOverPanel and call `show_result(...)`.

class_name GameOverPanel
extends PanelContainer

const _GAMEOVER_KING_ICON: Texture2D = preload("res://assets/textures/pieces/white_king.svg")
const _GAMEOVER_PAWN_ICON: Texture2D = preload("res://assets/textures/pieces/white_pawn.svg")

const _COLOR_NEUTRAL := Color(0.92, 0.92, 0.92, 1.0)
const _COLOR_WINNER  := Color(0.20, 0.85, 0.30, 1.0)
const _COLOR_LOSER   := Color(0.90, 0.25, 0.25, 1.0)

@onready var _white_icon: TextureRect = $VBox/ContentCenter/ContentVBox/PlayersRow/WhitePlayerBox/WhitePlayerIcon
@onready var _white_lbl:  Label       = $VBox/ContentCenter/ContentVBox/PlayersRow/WhitePlayerBox/WhitePlayerLabel
@onready var _black_icon: TextureRect = $VBox/ContentCenter/ContentVBox/PlayersRow/BlackPlayerBox/BlackPlayerIcon
@onready var _black_lbl:  Label       = $VBox/ContentCenter/ContentVBox/PlayersRow/BlackPlayerBox/BlackPlayerLabel
@onready var _reason_lbl: Label       = $VBox/ContentCenter/ContentVBox/ReasonLabel
@onready var _white_name_value: Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/WhiteNameValue
@onready var _white_time_value: Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/WhiteTimeValue
@onready var _white_avg_value:  Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/WhiteAvgValue
@onready var _black_name_value: Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/BlackNameValue
@onready var _black_time_value: Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/BlackTimeValue
@onready var _black_avg_value:  Label = $VBox/ContentCenter/ContentVBox/StatsCenter/StatsGrid/BlackAvgValue

## Populates the dialog and makes it visible.
##   winner_color   ChessEnums.PieceColor or -1 for draw
##   reason         Free-text reason ("Checkmate", "Surrender", …)
##   player_names   [white_name, black_name]
##   white_time_str / black_time_str  Already-formatted time strings
##   white_avg_str  / black_avg_str   Already-formatted average move times
func show_result(
		winner_color: int,
		reason: String,
		player_names: Array,
		white_time_str: String,
		black_time_str: String,
		white_avg_str: String,
		black_avg_str: String) -> void:
	visible = true

	_white_lbl.text = player_names[ChessEnums.PieceColor.WHITE]
	_black_lbl.text = player_names[ChessEnums.PieceColor.BLACK]

	if winner_color == -1:
		_apply_player_visual(_white_icon, _white_lbl, _GAMEOVER_KING_ICON, _COLOR_NEUTRAL)
		_apply_player_visual(_black_icon, _black_lbl, _GAMEOVER_KING_ICON, _COLOR_NEUTRAL)
	else:
		var white_wins := winner_color == ChessEnums.PieceColor.WHITE
		_apply_player_visual(
			_white_icon, _white_lbl,
			_GAMEOVER_KING_ICON if white_wins else _GAMEOVER_PAWN_ICON,
			_COLOR_WINNER if white_wins else _COLOR_LOSER,
		)
		_apply_player_visual(
			_black_icon, _black_lbl,
			_GAMEOVER_KING_ICON if not white_wins else _GAMEOVER_PAWN_ICON,
			_COLOR_WINNER if not white_wins else _COLOR_LOSER,
		)

	_reason_lbl.text = reason

	_white_name_value.text = player_names[ChessEnums.PieceColor.WHITE]
	_black_name_value.text = player_names[ChessEnums.PieceColor.BLACK]
	_white_time_value.text = white_time_str
	_black_time_value.text = black_time_str
	_white_avg_value.text  = white_avg_str
	_black_avg_value.text  = black_avg_str

func _apply_player_visual(icon: TextureRect, lbl: Label, tex: Texture2D, color: Color) -> void:
	icon.texture  = tex
	icon.modulate = color
	lbl.add_theme_color_override("font_color", color)
