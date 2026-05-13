## hud.gd
## Top-bar HUD: both player panels with name, ELO, turn timer and captured pieces.
## Builds all child nodes at runtime — just attach this script to a full-rect Control
## inside the UI node.

extends Control

# ── Constants ──────────────────────────────────────────────────────────────
const ICON_SIZE  := 22
const HUD_HEIGHT := 88

## Maps PieceType int → piece name used in the SVG filename.
const PIECE_NAMES: Dictionary = {
	1: "pawn", 2: "rook", 3: "knight", 4: "bishop", 5: "queen", 6: "king"
}

# ── Internal node refs (built in _build_ui) ────────────────────────────────
var _name_lbl:    Array = [null, null]   # [white, black] Label
var _elo_lbl:     Array = [null, null]
var _timer_lbl:   Array = [null, null]
var _captured_hf: Array = [null, null]  # HFlowContainer
var _turn_ind:    Array = [null, null]  # ColorRect active stripe

var _active_color: int = ChessEnums.PieceColor.WHITE

# ── Setup ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	# Anchor to full width, fixed height at top
	set_anchor_and_offset(SIDE_LEFT,   0, 0)
	set_anchor_and_offset(SIDE_RIGHT,  1, 0)
	set_anchor_and_offset(SIDE_TOP,    0, 0)
	set_anchor_and_offset(SIDE_BOTTOM, 0, HUD_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Dark semi-transparent background
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.04, 0.06, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 0)
	add_child(hbox)

	_build_player_panel(hbox, ChessEnums.PieceColor.WHITE)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(gap)

	_build_player_panel(hbox, ChessEnums.PieceColor.BLACK)

func _build_player_panel(parent: HBoxContainer, color: int) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	# ── Row 1: active-indicator | name | elo | timer ──────────────────────
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	vbox.add_child(row1)

	var ind := ColorRect.new()
	ind.custom_minimum_size = Vector2(4, 20)
	ind.color = Color.TRANSPARENT
	_turn_ind[color] = ind
	row1.add_child(ind)

	var name_lbl := Label.new()
	name_lbl.text = "Player"
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 16)
	_name_lbl[color] = name_lbl
	row1.add_child(name_lbl)

	var elo_lbl := Label.new()
	elo_lbl.text = "ELO –"
	elo_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_elo_lbl[color] = elo_lbl
	row1.add_child(elo_lbl)

	var timer_lbl := Label.new()
	timer_lbl.text = ""
	timer_lbl.custom_minimum_size = Vector2(72, 0)
	timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	timer_lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	_timer_lbl[color] = timer_lbl
	row1.add_child(timer_lbl)

	# ── Row 2: captured piece icons ───────────────────────────────────────
	var hflow := HFlowContainer.new()
	hflow.add_theme_constant_override("h_separation", 1)
	hflow.add_theme_constant_override("v_separation", 1)
	hflow.custom_minimum_size = Vector2(0, ICON_SIZE + 2)
	_captured_hf[color] = hflow
	vbox.add_child(hflow)

# ── Public API ─────────────────────────────────────────────────────────────

## Call after setup() has player names and ELOs.
func setup(white_name: String, white_elo: int,
		   black_name: String, black_elo: int) -> void:
	(_name_lbl[ChessEnums.PieceColor.WHITE] as Label).text = white_name
	(_elo_lbl [ChessEnums.PieceColor.WHITE] as Label).text = "ELO %d" % white_elo
	(_name_lbl[ChessEnums.PieceColor.BLACK] as Label).text = black_name
	(_elo_lbl [ChessEnums.PieceColor.BLACK] as Label).text = "ELO %d" % black_elo

	# Clear captured icons from any previous game
	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		for child in (_captured_hf[c] as HFlowContainer).get_children():
			child.queue_free()

	set_active_player(ChessEnums.PieceColor.WHITE)

## Highlight the active player's panel with a gold stripe + bright name.
func set_active_player(color: int) -> void:
	_active_color = color
	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var active: bool = (c == color)
		(_turn_ind[c] as ColorRect).color = \
			Color(1.0, 0.85, 0.1, 1.0) if active else Color.TRANSPARENT
		(_name_lbl[c] as Label).add_theme_color_override("font_color",
			Color(1.0, 0.92, 0.4) if active else Color(0.88, 0.88, 0.88))
		(_timer_lbl[c] as Label).text = ""  # clear timer on turn switch

## Update the turn-elapsed timer display (call from _process in GameController).
func update_timer(elapsed_ms: int) -> void:
	var secs: int = elapsed_ms / 1000
	var frac: int = (elapsed_ms % 1000) / 100
	(_timer_lbl[_active_color] as Label).text = "⏱ %d.%ds" % [secs, frac]

## Rebuild captured-piece icons for one player (capturing_color = the player who captured).
## captured_types is an Array of PieceType ints (can contain duplicates).
func refresh_captured(capturing_color: int, captured_types: Array) -> void:
	var container := _captured_hf[capturing_color] as HFlowContainer
	for child in container.get_children():
		child.queue_free()

	# Show the OPPONENT's pieces (the ones that were captured)
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
