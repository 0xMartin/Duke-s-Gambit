## hud.gd
## Top-bar HUD: both player panels with name, ELO, chess-clock timer, captured pieces.
## UI nodes are defined in the scene; this script only updates values/highlights.

extends Control

# ── Constants ──────────────────────────────────────────────────────────────
const ICON_SIZE  := 36

## Maps PieceType int → piece name used in the SVG filename.
const PIECE_NAMES: Dictionary = {
	1: "pawn", 2: "rook", 3: "knight", 4: "bishop", 5: "queen", 6: "king"
}

# ── Internal node refs (wired from scene) ──────────────────────────────────
var _name_lbl:    Array = [null, null]   # [white, black] Label
var _elo_lbl:     Array = [null, null]
var _timer_lbl:   Array = [null, null]
var _captured_hf: Array = [null, null]  # HFlowContainer
var _turn_ind:    Array = [null, null]  # ColorRect active stripe
var _panel_style: Array = [null, null]  # StyleBoxFlat per player panel

var _active_color: int = ChessEnums.PieceColor.WHITE
var _has_time_limit: bool = false  # true = countdown mode

# ── Setup ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_lbl[ChessEnums.PieceColor.WHITE]  = get_node("TopBar/WhitePanel/Margin/MainHBox/InfoVBox/Row/Name") as Label
	_name_lbl[ChessEnums.PieceColor.BLACK]  = get_node("TopBar/BlackPanel/Margin/MainHBox/InfoVBox/Row/Name") as Label
	_elo_lbl[ChessEnums.PieceColor.WHITE]   = get_node("TopBar/WhitePanel/Margin/MainHBox/InfoVBox/Row/Elo") as Label
	_elo_lbl[ChessEnums.PieceColor.BLACK]   = get_node("TopBar/BlackPanel/Margin/MainHBox/InfoVBox/Row/Elo") as Label
	_timer_lbl[ChessEnums.PieceColor.WHITE] = get_node("TopBar/WhitePanel/Margin/MainHBox/InfoVBox/Row/Timer") as Label
	_timer_lbl[ChessEnums.PieceColor.BLACK] = get_node("TopBar/BlackPanel/Margin/MainHBox/InfoVBox/Row/Timer") as Label
	_captured_hf[ChessEnums.PieceColor.WHITE] = get_node("TopBar/WhitePanel/Margin/MainHBox/InfoVBox/CapturedPanel/CapturedFlow") as HFlowContainer
	_captured_hf[ChessEnums.PieceColor.BLACK] = get_node("TopBar/BlackPanel/Margin/MainHBox/InfoVBox/CapturedPanel/CapturedFlow") as HFlowContainer
	_turn_ind[ChessEnums.PieceColor.WHITE] = get_node("TopBar/WhitePanel/Margin/MainHBox/InfoVBox/Row/TurnIndicator") as ColorRect
	_turn_ind[ChessEnums.PieceColor.BLACK] = get_node("TopBar/BlackPanel/Margin/MainHBox/InfoVBox/Row/TurnIndicator") as ColorRect

	var white_panel := get_node("TopBar/WhitePanel") as PanelContainer
	var black_panel := get_node("TopBar/BlackPanel") as PanelContainer
	_panel_style[ChessEnums.PieceColor.WHITE] = white_panel.get_theme_stylebox("panel") as StyleBoxFlat
	_panel_style[ChessEnums.PieceColor.BLACK] = black_panel.get_theme_stylebox("panel") as StyleBoxFlat

# ── Public API ─────────────────────────────────────────────────────────────

func setup(white_name: String, white_elo: int,
		   black_name: String, black_elo: int,
		   has_time_limit: bool = false) -> void:
	_has_time_limit = has_time_limit
	(_name_lbl[ChessEnums.PieceColor.WHITE] as Label).text = white_name
	(_elo_lbl [ChessEnums.PieceColor.WHITE] as Label).text = "ELO %d" % white_elo
	(_name_lbl[ChessEnums.PieceColor.BLACK] as Label).text = black_name
	(_elo_lbl [ChessEnums.PieceColor.BLACK] as Label).text = "ELO %d" % black_elo

	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		for child in (_captured_hf[c] as HFlowContainer).get_children():
			child.queue_free()

	set_active_player(ChessEnums.PieceColor.WHITE)

func set_active_player(color: int) -> void:
	_active_color = color
	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var active: bool = (c == color)
		# Side stripe indicator
		(_turn_ind[c] as ColorRect).color = \
			Color(1.0, 0.85, 0.1, 1.0) if active else Color.TRANSPARENT
		# Name colour
		(_name_lbl[c] as Label).add_theme_color_override("font_color",
			Color(1.0, 0.92, 0.4) if active else Color(0.88, 0.88, 0.88))
		# Panel border: thick bright gold when active, thin dim when inactive
		var ps := _panel_style[c] as StyleBoxFlat
		if ps != null:
			if active:
				ps.border_color = Color(1.0, 0.85, 0.1, 1.0)
				ps.set_border_width_all(5)
				ps.bg_color = Color(0.10, 0.12, 0.24, 0.97)
			else:
				ps.border_color = Color(0.38, 0.30, 0.06, 0.55)
				ps.set_border_width_all(2)
				ps.bg_color = Color(0.04, 0.05, 0.10, 0.82)

## color = which player's label to update.
## ms  = remaining time (countdown) or elapsed (count-up), depending on _has_time_limit.
func update_timer(color: int, ms: int) -> void:
	var lbl := _timer_lbl[color] as Label
	if _has_time_limit:
		# Countdown: show MM:SS, red when < 30 s
		var total_secs: int = ms / 1000
		var mins: int = total_secs / 60
		var secs: int = total_secs % 60
		lbl.text = "%d:%02d" % [mins, secs]
		if ms < 30000:
			lbl.add_theme_color_override("font_color", Color(1, 0.25, 0.2))
		else:
			lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	else:
		var secs: int = ms / 1000
		var frac: int = (ms % 1000) / 100
		lbl.text = "⏱ %d.%ds" % [secs, frac]

func refresh_captured(capturing_color: int, captured_types: Array) -> void:
	var container := _captured_hf[capturing_color] as HFlowContainer
	for child in container.get_children():
		child.queue_free()

	var opponent_str: String = "black" if capturing_color == ChessEnums.PieceColor.WHITE \
							   else "white"
	for piece_type: int in captured_types:
		if not PIECE_NAMES.has(piece_type):
			continue
		var path: String = "res://assets/textures/pieces/%s_%s.svg" \
						   % [opponent_str, PIECE_NAMES[piece_type]]
		if not ResourceLoader.exists(path):
			continue
		var icon := TextureRect.new()
		icon.texture = load(path) as Texture2D
		icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		container.add_child(icon)
