## hud.gd
## Top-bar HUD: both player panels with name, ELO, chess-clock timer, captured pieces.
## Builds all child nodes at runtime.

extends Control

# ── Constants ──────────────────────────────────────────────────────────────
const ICON_SIZE  := 22
const HUD_HEIGHT := 96
const AVATAR_SIZE := 48

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
var _has_time_limit: bool = false  # true = countdown mode

# ── Setup ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	set_anchor_and_offset(SIDE_LEFT,   0, 0)
	set_anchor_and_offset(SIDE_RIGHT,  1, 0)
	set_anchor_and_offset(SIDE_TOP,    0, 0)
	set_anchor_and_offset(SIDE_BOTTOM, 0, HUD_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Left panel | transparent centre | right panel
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 0)
	add_child(hbox)

	_build_player_panel(hbox, ChessEnums.PieceColor.WHITE)   # left edge

	var spacer := Control.new()   # transparent centre
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(spacer)

	_build_player_panel(hbox, ChessEnums.PieceColor.BLACK)   # right edge

func _build_player_panel(parent: HBoxContainer, color: int) -> void:
	var is_right := (color == ChessEnums.PieceColor.BLACK)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END if is_right \
								  else Control.SIZE_SHRINK_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(hbox)

	# ── Circular pawn avatar ──────────────────────────────────────────────
	var circle := PanelContainer.new()
	circle.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	var radius: int = AVATAR_SIZE / 2
	style.corner_radius_top_left     = radius
	style.corner_radius_top_right    = radius
	style.corner_radius_bottom_left  = radius
	style.corner_radius_bottom_right = radius
	style.bg_color = Color(0.85, 0.85, 0.85) if color == ChessEnums.PieceColor.WHITE \
					else Color(0.18, 0.18, 0.22)
	circle.add_theme_stylebox_override("panel", style)
	var color_str: String = "white" if color == ChessEnums.PieceColor.WHITE else "black"
	var pawn_path := "res://assets/textures/pieces/%s_pawn.svg" % color_str
	if ResourceLoader.exists(pawn_path):
		var pawn_tex := TextureRect.new()
		pawn_tex.texture = load(pawn_path) as Texture2D
		pawn_tex.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
		pawn_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pawn_tex.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		pawn_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		circle.add_child(pawn_tex)

	# ── Text info column ──────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Row 1: active-indicator | name | elo | timer
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
	timer_lbl.custom_minimum_size = Vector2(76, 0)
	timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	timer_lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	_timer_lbl[color] = timer_lbl
	row1.add_child(timer_lbl)

	# Row 2: captured piece icons
	var hflow := HFlowContainer.new()
	hflow.add_theme_constant_override("h_separation", 1)
	hflow.add_theme_constant_override("v_separation", 1)
	hflow.custom_minimum_size = Vector2(0, ICON_SIZE + 2)
	_captured_hf[color] = hflow
	vbox.add_child(hflow)

	# Compose hbox: white = [circle | vbox], black = [vbox | circle]
	if is_right:
		hbox.add_child(vbox)
		hbox.add_child(circle)
	else:
		hbox.add_child(circle)
		hbox.add_child(vbox)

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
		(_turn_ind[c] as ColorRect).color = \
			Color(1.0, 0.85, 0.1, 1.0) if active else Color.TRANSPARENT
		(_name_lbl[c] as Label).add_theme_color_override("font_color",
			Color(1.0, 0.92, 0.4) if active else Color(0.88, 0.88, 0.88))
		(_timer_lbl[c] as Label).text = ""

## ms = remaining time (countdown) or elapsed (count-up), depending on _has_time_limit.
func update_timer(ms: int) -> void:
	var lbl := _timer_lbl[_active_color] as Label
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
