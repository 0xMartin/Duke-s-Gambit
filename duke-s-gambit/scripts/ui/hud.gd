## hud.gd
## Top-bar HUD: both player panels with name, ELO, chess-clock timer, captured pieces.
## UI nodes are defined in the scene; this script only updates values/highlights.

extends Control

# ── Constants ──────────────────────────────────────────────────────────────
const ICON_SIZE  := 36
const HISTORY_ICON_SIZE := 38
const CAPTURED_BADGE_FONT := preload("res://assets/fonts/Montserrat-Regular.ttf")
const HISTORY_LABEL_THEME := preload("res://themes/history_label.tres")
const PLAYER_CARD_THEME := preload("res://themes/player_card.tres")
const PLAYER_CARD_ACTIVE_THEME := preload("res://themes/player_card_active.tres")
const PLAYER_CARD_BLACK_THEME := preload("res://themes/player_card_black.tres")
const PLAYER_CARD_BLACK_ACTIVE_THEME := preload("res://themes/player_card_black_active.tres")
const CAPTURED_PAGE_DURATION := 5.0
const MAX_HUD_NAME_LENGTH := 15

## Maps PieceType int → piece name used in the SVG filename.
const PIECE_NAMES: Dictionary = {
	1: "pawn", 2: "rook", 3: "knight", 4: "bishop", 5: "queen", 6: "king"
}

const PIECE_LETTERS: Dictionary = {
	ChessEnums.PieceType.PAWN: "",
	ChessEnums.PieceType.ROOK: "R",
	ChessEnums.PieceType.KNIGHT: "N",
	ChessEnums.PieceType.BISHOP: "B",
	ChessEnums.PieceType.QUEEN: "Q",
	ChessEnums.PieceType.KING: "K",
}

const CAPTURED_BADGE_ORDER: Array[int] = [
	ChessEnums.PieceType.PAWN,
	ChessEnums.PieceType.KNIGHT,
	ChessEnums.PieceType.BISHOP,
	ChessEnums.PieceType.ROOK,
	ChessEnums.PieceType.QUEEN,
	ChessEnums.PieceType.KING,
]

# ── Internal node refs (wired from scene) ──────────────────────────────────
var _panel:       Array = [null, null]   # [white, black] PanelContainer
var _name_lbl:    Array = [null, null]   # [white, black] Label
var _elo_lbl:     Array = [null, null]
var _timer_lbl:   Array = [null, null]
var _captured_scroll: Array = [null, null]  # ScrollContainer
var _captured_padding: Array = [null, null]  # MarginContainer
var _captured_list: Array = [null, null]  # HBoxContainer
var _captured_timer: Array = [null, null]  # Timer
var _captured_pages: Array = [[], []]
var _captured_page_index: Array = [0, 0]
var _captured_badge_specs: Array = [[], []]
var _captured_refresh_queued: Array = [false, false]
var _captured_refresh_in_progress: Array = [false, false]
var _history_panel: PanelContainer = null
var _history_list: VBoxContainer = null
var _history_scroll: ScrollContainer = null
var _history_collapse_btn: Button = null
var _history_expand_btn: Button = null
var _history_collapsed: bool = false
var _history_tween: Tween = null
var _history_ply_count: int = 0
var _history_panel_left_expanded: float = 8.0
var _history_panel_width: float = 300.0
var _history_scroll_retry_count: int = 0

var _has_time_limit: bool = false  # true = countdown mode

# ── Setup ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel[ChessEnums.PieceColor.WHITE]     = get_node("WhitePanel") as PanelContainer
	_panel[ChessEnums.PieceColor.BLACK]     = get_node("BlackPanel") as PanelContainer
	_name_lbl[ChessEnums.PieceColor.WHITE]  = get_node("WhitePanel/MainHBox/InfoVBox/Row/Name") as Label
	_name_lbl[ChessEnums.PieceColor.BLACK]  = get_node("BlackPanel/MainHBox/InfoVBox/Row/Name") as Label
	_elo_lbl[ChessEnums.PieceColor.WHITE]   = get_node("WhitePanel/MainHBox/InfoVBox/Row/Elo") as Label
	_elo_lbl[ChessEnums.PieceColor.BLACK]   = get_node("BlackPanel/MainHBox/InfoVBox/Row/Elo") as Label
	_timer_lbl[ChessEnums.PieceColor.WHITE] = get_node("WhitePanel/MainHBox/InfoVBox/Row/Timer") as Label
	_timer_lbl[ChessEnums.PieceColor.BLACK] = get_node("BlackPanel/MainHBox/InfoVBox/Row/Timer") as Label
	_captured_scroll[ChessEnums.PieceColor.WHITE] = get_node("WhitePanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow") as ScrollContainer
	_captured_scroll[ChessEnums.PieceColor.BLACK] = get_node("BlackPanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow") as ScrollContainer
	_captured_padding[ChessEnums.PieceColor.WHITE] = get_node("WhitePanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow/CapturedPadding") as MarginContainer
	_captured_padding[ChessEnums.PieceColor.BLACK] = get_node("BlackPanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow/CapturedPadding") as MarginContainer
	_captured_list[ChessEnums.PieceColor.WHITE] = get_node("WhitePanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow/CapturedPadding/CapturedList") as HBoxContainer
	_captured_list[ChessEnums.PieceColor.BLACK] = get_node("BlackPanel/MainHBox/InfoVBox/CapturedPanel/CapturedFlow/CapturedPadding/CapturedList") as HBoxContainer
	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var captured_scroll := _captured_scroll[c] as ScrollContainer
		captured_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		captured_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		captured_scroll.clip_contents = true
		var page_timer := Timer.new()
		page_timer.one_shot = false
		page_timer.wait_time = CAPTURED_PAGE_DURATION
		page_timer.timeout.connect(_on_captured_page_timeout.bind(c))
		add_child(page_timer)
		_captured_timer[c] = page_timer

	_history_panel = get_node_or_null("../MoveHistoryPanel") as PanelContainer
	_history_scroll = get_node_or_null("../MoveHistoryPanel/Margin/VBox/HistoryScroll") as ScrollContainer
	_history_list = get_node_or_null("../MoveHistoryPanel/Margin/VBox/HistoryScroll/HistoryList") as VBoxContainer
	_history_collapse_btn = get_node_or_null("../MoveHistoryPanel/Margin/VBox/Header/CollapseButton") as Button
	_history_expand_btn = get_node_or_null("../MoveHistoryExpandButton") as Button
	if _history_collapse_btn != null:
		_history_collapse_btn.pressed.connect(_collapse_history)
	if _history_expand_btn != null:
		_history_expand_btn.pressed.connect(_expand_history)
	_apply_history_theme()
	reset_move_history()
	_set_history_minimized(true, true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_queue_captured_page_refresh(ChessEnums.PieceColor.WHITE)
		_queue_captured_page_refresh(ChessEnums.PieceColor.BLACK)

# ── Public API ─────────────────────────────────────────────────────────────

func setup(white_name: String, white_elo: int,
		   black_name: String, black_elo: int,
		   has_time_limit: bool = false,
		   show_elo: bool = true,
		   white_elo_override: String = "",
		   black_elo_override: String = "") -> void:
	_has_time_limit = has_time_limit
	_apply_player_name(ChessEnums.PieceColor.WHITE, white_name)
	(_elo_lbl [ChessEnums.PieceColor.WHITE] as Label).text = \
		white_elo_override if white_elo_override != "" else "ELO %d" % white_elo
	_apply_player_name(ChessEnums.PieceColor.BLACK, black_name)
	(_elo_lbl [ChessEnums.PieceColor.BLACK] as Label).text = \
		black_elo_override if black_elo_override != "" else "ELO %d" % black_elo
	(_elo_lbl[ChessEnums.PieceColor.WHITE] as Label).visible = show_elo
	(_elo_lbl[ChessEnums.PieceColor.BLACK] as Label).visible = show_elo

	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		for child in (_captured_list[c] as HBoxContainer).get_children():
			child.queue_free()
		(_captured_timer[c] as Timer).stop()
		_captured_pages[c] = []
		_captured_page_index[c] = 0
		_captured_badge_specs[c] = []
		_captured_refresh_queued[c] = false
		_captured_refresh_in_progress[c] = false

	reset_move_history()

	# Count-up mode: prime both timer labels so the inactive player doesn't
	# linger on whatever default text the scene had (e.g. "10:00").
	if not _has_time_limit:
		update_timer(ChessEnums.PieceColor.WHITE, 0)
		update_timer(ChessEnums.PieceColor.BLACK, 0)

func _apply_player_name(color: int, player_name: String) -> void:
	var label := _name_lbl[color] as Label
	if label == null:
		return
	label.text = _format_player_name(player_name)
	label.tooltip_text = player_name

func _format_player_name(player_name: String) -> String:
	if player_name.length() <= MAX_HUD_NAME_LENGTH:
		return player_name
	return player_name.left(MAX_HUD_NAME_LENGTH - 3) + "..."

func reset_move_history() -> void:
	_history_ply_count = 0
	if _history_list == null:
		return
	for child in _history_list.get_children():
		child.queue_free()
	if _history_scroll != null:
		_history_scroll.scroll_vertical = 0

func append_move_to_history(mv: ChessMove) -> void:
	if _history_list == null:
		return

	_history_ply_count += 1
	var move_no := int((_history_ply_count + 1) / 2.0)
	var is_white_move := mv.piece_color == ChessEnums.PieceColor.WHITE
	var turn_prefix := "%d." % move_no if is_white_move else "%d..." % move_no

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)

	var turn_lbl := Label.new()
	turn_lbl.custom_minimum_size = Vector2(72, 0)
	turn_lbl.theme = HISTORY_LABEL_THEME
	turn_lbl.text = turn_prefix
	row.add_child(turn_lbl)

	var piece_icon := _build_piece_icon(mv.piece_color, mv.piece_type, HISTORY_ICON_SIZE)
	if piece_icon != null:
		row.add_child(piece_icon)

	if mv.is_capture():
		var x_lbl := Label.new()
		x_lbl.theme = HISTORY_LABEL_THEME
		x_lbl.text = "x"
		row.add_child(x_lbl)

		var cap_icon := _build_piece_icon(1 - mv.piece_color, mv.captured_type, HISTORY_ICON_SIZE)
		if cap_icon != null:
			row.add_child(cap_icon)

	var move_lbl := Label.new()
	move_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_lbl.theme = HISTORY_LABEL_THEME
	move_lbl.text = _move_notation(mv)
	row.add_child(move_lbl)

	_history_list.add_child(row)
	_scroll_history_to_bottom()

func _scroll_history_to_bottom() -> void:
	# Deferred with a short retry so we still reach the true bottom after late layout updates.
	_history_scroll_retry_count = 3
	_apply_history_scroll_bottom.call_deferred()

func _apply_history_scroll_bottom() -> void:
	if _history_scroll == null:
		return
	var bar := _history_scroll.get_v_scroll_bar()
	if bar == null:
		return
	_history_scroll.scroll_vertical = 1000000
	if _history_scroll_retry_count > 0:
		_history_scroll_retry_count -= 1
		if bar.value < bar.max_value - 1.0:
			_apply_history_scroll_bottom.call_deferred()

func _piece_icon_path(color: int, piece_type: int) -> String:
	if not PIECE_NAMES.has(piece_type):
		return ""
	var side := "white" if color == ChessEnums.PieceColor.WHITE else "black"
	return "res://assets/textures/pieces/%s_%s.svg" % [side, PIECE_NAMES[piece_type]]

func _build_piece_icon(color: int, piece_type: int, icon_size: int) -> Control:
	var path := _piece_icon_path(color, piece_type)
	if path == "" or not ResourceLoader.exists(path):
		return null

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(icon_size + 8, icon_size + 8)
	var frame_style := StyleBoxFlat.new()
	frame_style.set_corner_radius_all(6)
	frame_style.set_border_width_all(1)
	if color == ChessEnums.PieceColor.BLACK:
		frame_style.bg_color = Color(0.92, 0.92, 0.96, 0.92)
		frame_style.border_color = Color(0.20, 0.20, 0.24, 0.65)
	else:
		frame_style.bg_color = Color(0.14, 0.16, 0.24, 0.92)
		frame_style.border_color = Color(0.90, 0.90, 0.95, 0.45)
	frame.add_theme_stylebox_override("panel", frame_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 3)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_right", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	frame.add_child(margin)

	var icon := TextureRect.new()
	icon.texture = load(path) as Texture2D
	icon.custom_minimum_size = Vector2(icon_size, icon_size)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	margin.add_child(icon)
	return frame

func _build_captured_badge(color: int, piece_type: int, count: int) -> Control:
	var path := _piece_icon_path(color, piece_type)
	if path == "" or not ResourceLoader.exists(path):
		return null

	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(0, 36)
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = Color8(64, 215, 245, 230)
	badge_style.border_color = Color8(17, 79, 94, 96)
	badge_style.set_border_width_all(1)
	badge_style.set_corner_radius_all(999)
	badge.add_theme_stylebox_override("panel", badge_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 4)
	badge.add_child(margin)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(center)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	center.add_child(row)

	var icon := TextureRect.new()
	icon.texture = load(path) as Texture2D
	icon.custom_minimum_size = Vector2(22, 22)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	row.add_child(icon)

	var count_lbl := Label.new()
	count_lbl.text = "%dx" % count
	count_lbl.add_theme_font_override("font", CAPTURED_BADGE_FONT)
	count_lbl.add_theme_font_size_override("font_size", 18)
	count_lbl.add_theme_color_override("font_color", Color8(7, 41, 51, 255))
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count_lbl)
	return badge

func _build_captured_badge_spec(color: int, piece_type: int, count: int) -> Dictionary:
	var badge := _build_captured_badge(color, piece_type, count)
	if badge == null:
		return {}
	var separation := (_captured_list[ChessEnums.PieceColor.WHITE] as HBoxContainer).get_theme_constant("separation")
	var badge_size := badge.get_combined_minimum_size()
	return {
		"color": color,
		"piece_type": piece_type,
		"count": count,
		"width": badge_size.x + separation,
	}

func _get_captured_viewport_width(color: int) -> float:
	var scroll := _captured_scroll[color] as ScrollContainer
	var padding := _captured_padding[color] as MarginContainer
	var style := scroll.get_theme_stylebox("panel")
	var viewport_width := scroll.size.x
	if style != null:
		viewport_width -= style.content_margin_left + style.content_margin_right
	viewport_width -= padding.get_theme_constant("margin_left") + padding.get_theme_constant("margin_right")
	return max(viewport_width, 1.0)

func _refresh_captured_pages(color: int) -> void:
	if _captured_refresh_in_progress[color]:
		return
	_captured_refresh_in_progress[color] = true
	var specs: Array = _captured_badge_specs[color]
	var pages: Array = []
	var max_width := _get_captured_viewport_width(color)
	var current_page: Array = []
	var current_width := 0.0
	for spec_variant in specs:
		var spec: Dictionary = spec_variant as Dictionary
		var badge_width := float(spec.get("width", 0.0))
		if current_page.is_empty() or current_width + badge_width <= max_width:
			current_page.append(spec)
			current_width += badge_width
		else:
			pages.append(current_page)
			current_page = [spec]
			current_width = badge_width
	if not current_page.is_empty():
		pages.append(current_page)
	_captured_pages[color] = pages
	var page_count := pages.size()
	if page_count == 0:
		_captured_page_index[color] = 0
		(_captured_timer[color] as Timer).stop()
		_clear_captured_page(color)
		_captured_refresh_in_progress[color] = false
		return
	_captured_page_index[color] = mini(_captured_page_index[color], page_count - 1)
	_show_captured_page(color, _captured_page_index[color])
	var timer := _captured_timer[color] as Timer
	if page_count > 1:
		if timer.is_stopped():
			timer.start()
	else:
		timer.stop()
	_captured_refresh_in_progress[color] = false

func _queue_captured_page_refresh(color: int) -> void:
	if _captured_refresh_queued[color]:
		return
	_captured_refresh_queued[color] = true
	call_deferred("_run_queued_captured_page_refresh", color)

func _run_queued_captured_page_refresh(color: int) -> void:
	_captured_refresh_queued[color] = false
	_refresh_captured_pages(color)

func _clear_captured_page(color: int) -> void:
	var container := _captured_list[color] as HBoxContainer
	for child in container.get_children():
		child.queue_free()

func _show_captured_page(color: int, page_index: int) -> void:
	_clear_captured_page(color)
	var pages: Array = _captured_pages[color]
	if page_index < 0 or page_index >= pages.size():
		return
	var container := _captured_list[color] as HBoxContainer
	for spec_variant in (pages[page_index] as Array):
		var spec: Dictionary = spec_variant as Dictionary
		var badge := _build_captured_badge(
			int(spec.get("color", ChessEnums.PieceColor.WHITE)),
			int(spec.get("piece_type", ChessEnums.PieceType.PAWN)),
			int(spec.get("count", 0))
		)
		if badge != null:
			container.add_child(badge)

func _on_captured_page_timeout(color: int) -> void:
	var pages: Array = _captured_pages[color]
	if pages.size() <= 1:
		(_captured_timer[color] as Timer).stop()
		return
	_captured_page_index[color] = (_captured_page_index[color] + 1) % pages.size()
	_show_captured_page(color, _captured_page_index[color])

func _move_notation(mv: ChessMove) -> String:
	match mv.move_type:
		ChessEnums.MoveType.CASTLING_KINGSIDE:
			return "O-O"
		ChessEnums.MoveType.CASTLING_QUEENSIDE:
			return "O-O-O"
		_:
			pass

	var piece_letter: String = String(PIECE_LETTERS.get(mv.piece_type, ""))
	var from_file := String.chr(97 + (7 - mv.from_sq.x))
	var capture_mark := "x" if mv.is_capture() else ""
	var to_sq := _sq_to_notation(mv.to_sq)

	if mv.piece_type == ChessEnums.PieceType.PAWN and mv.is_capture():
		piece_letter = from_file

	var notation := "%s%s%s" % [piece_letter, capture_mark, to_sq]
	if mv.move_type == ChessEnums.MoveType.PROMOTION or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
		notation += "=" + String(PIECE_LETTERS.get(mv.promotion_type, "Q"))
	if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
		notation += " e.p."
	return notation

func _sq_to_notation(sq: Vector2i) -> String:
	return "%s%d" % [String.chr(97 + (7 - sq.x)), sq.y + 1]

func _apply_history_theme() -> void:
	if _history_panel != null:
		_history_panel_left_expanded = _history_panel.offset_left
		_history_panel_width = _history_panel.offset_right - _history_panel.offset_left
		if _history_panel_width <= 0.0:
			_history_panel_width = maxf(_history_panel.custom_minimum_size.x, 300.0)

func _collapse_history() -> void:
	_set_history_minimized(true)

func _expand_history() -> void:
	_set_history_minimized(false)

func _set_history_minimized(minimized: bool, instant: bool = false) -> void:
	if _history_panel == null:
		return
	if _history_collapsed == minimized and not instant:
		return

	_history_collapsed = minimized
	if _history_tween:
		_history_tween.kill()
		_history_tween = null

	if minimized:
		if _history_expand_btn != null:
			_history_expand_btn.visible = true
		if instant:
			_history_panel.offset_left = -_history_panel_width - 12.0
			_history_panel.offset_right = -12.0
			_history_panel.visible = false
			return
		_history_panel.visible = true
		_history_tween = create_tween()
		_history_tween.tween_property(_history_panel, "offset_left", -_history_panel_width - 12.0, 0.20)
		_history_tween.parallel().tween_property(_history_panel, "offset_right", -12.0, 0.20)
		_history_tween.finished.connect(func() -> void:
			if _history_collapsed and _history_panel != null:
				_history_panel.visible = false
		)
		return

	# Expanded state
	_history_panel.visible = true
	if _history_expand_btn != null:
		_history_expand_btn.visible = false
	if instant:
		_history_panel.offset_left = _history_panel_left_expanded
		_history_panel.offset_right = _history_panel_left_expanded + _history_panel_width
		return
	_history_tween = create_tween()
	_history_tween.tween_property(_history_panel, "offset_left", _history_panel_left_expanded, 0.20)
	_history_tween.parallel().tween_property(_history_panel, "offset_right", _history_panel_left_expanded + _history_panel_width, 0.20)
	_history_tween.finished.connect(_scroll_history_to_bottom)

## color = which player's label to update.
## ms  = remaining time (countdown) or elapsed (count-up), depending on _has_time_limit.
func update_timer(color: int, ms: int) -> void:
	var lbl := _timer_lbl[color] as Label
	if _has_time_limit:
		# Countdown: show MM:SS
		var total_secs: int = int(ms / 1000.0)
		var mins: int = int(total_secs / 60.0)
		var secs: int = total_secs % 60
		lbl.text = "%d:%02d" % [mins, secs]
	else:
		var secs: int = int(ms / 1000.0)
		var frac: int = int((ms % 1000) / 100.0)
		lbl.text = "%d.%ds ⏱" % [secs, frac]

## Swap player-card themes so the side on turn pops visually.
## Pass WHITE/BLACK to highlight that side; any other value clears both.
func set_active_color(color: int) -> void:
	for c in [ChessEnums.PieceColor.WHITE, ChessEnums.PieceColor.BLACK]:
		var panel := _panel[c] as PanelContainer
		if panel == null:
			continue
		var is_active: bool = c == color
		if c == ChessEnums.PieceColor.WHITE:
			panel.theme = PLAYER_CARD_ACTIVE_THEME if is_active else PLAYER_CARD_THEME
		else:
			panel.theme = PLAYER_CARD_BLACK_ACTIVE_THEME if is_active else PLAYER_CARD_BLACK_THEME

func refresh_captured(capturing_color: int, captured_types: Array) -> void:
	_clear_captured_page(capturing_color)

	var counts: Dictionary = {}
	for piece_type: int in captured_types:
		counts[piece_type] = int(counts.get(piece_type, 0)) + 1

	var captured_color := ChessEnums.PieceColor.BLACK if capturing_color == ChessEnums.PieceColor.WHITE \
		else ChessEnums.PieceColor.WHITE
	var badge_specs: Array = []
	for piece_type in CAPTURED_BADGE_ORDER:
		var count := int(counts.get(piece_type, 0))
		if count <= 0:
			continue
		var badge_spec := _build_captured_badge_spec(captured_color, piece_type, count)
		if not badge_spec.is_empty():
			badge_specs.append(badge_spec)
	_captured_badge_specs[capturing_color] = badge_specs
	_captured_page_index[capturing_color] = 0
	_queue_captured_page_refresh(capturing_color)
