## Reusable nickname input with autocomplete suggestions.
## Accepts free text and suggests known player profiles with ELO.

class_name NicknameInput
extends Control

signal value_changed(value: String)

@onready var _line_edit: LineEdit = $LineEdit
@onready var _suggest_panel: PanelContainer = $SuggestPanel
@onready var _suggest_box: VBoxContainer = $SuggestPanel/Scroll/VBox

var _profiles_sorted: Array[Dictionary] = []

func _ready() -> void:
	_suggest_panel.top_level = true
	_suggest_panel.z_as_relative = false
	_suggest_panel.z_index = 5000
	_suggest_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_suggest_panel.size = Vector2.ZERO
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.focus_entered.connect(_on_focus_entered)
	_line_edit.focus_exited.connect(_on_focus_exited)
	_update_suggest_panel_position()
	set_process_unhandled_input(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_suggest_panel_position()

func set_profiles(profiles_sorted: Array[Dictionary]) -> void:
	_profiles_sorted = profiles_sorted
	_refresh_suggestions()

func set_value(value: String) -> void:
	_line_edit.text = value
	_line_edit.caret_column = _line_edit.text.length()
	_refresh_suggestions()

func get_value() -> String:
	return _line_edit.text.strip_edges()

func set_enabled(enabled: bool) -> void:
	_line_edit.editable = enabled
	if not enabled:
		_hide_suggestions()

func set_placeholder(text: String) -> void:
	_line_edit.placeholder_text = text

func grab_input_focus() -> void:
	_line_edit.grab_focus()

func _on_text_changed(new_text: String) -> void:
	_refresh_suggestions()
	emit_signal("value_changed", new_text)

func _on_focus_entered() -> void:
	# Do not auto-open suggestions just because the input gained focus.
	_hide_suggestions()

func _on_focus_exited() -> void:
	# Keep list open when focus moves to suggestion buttons.
	call_deferred("_hide_if_no_child_has_focus")

func _hide_if_no_child_has_focus() -> void:
	if _line_edit.has_focus():
		return
	for child in _suggest_box.get_children():
		if child is Control and (child as Control).has_focus():
			return
	_hide_suggestions()

func _refresh_suggestions() -> void:
	if not _line_edit.has_focus() or _profiles_sorted.is_empty():
		_hide_suggestions()
		return
	if _line_edit.text.strip_edges().is_empty():
		_hide_suggestions()
		return

	for child in _suggest_box.get_children():
		child.queue_free()

	var matches := _matching_profiles(_line_edit.text)
	if matches.is_empty():
		_hide_suggestions()
		return

	var max_items := mini(matches.size(), 8)
	for i in range(max_items):
		var profile: Dictionary = matches[i]
		var player_name: String = str(profile.get("name", ""))
		var elo: int = int(profile.get("elo", 1000))
		var btn := Button.new()
		btn.text = "%s (ELO %d)" % [player_name, elo]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.flat = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Copy font and color from LineEdit
		var font = _line_edit.get_theme_font("font")
		if font != null:
			btn.add_theme_font_override("font", font)
		var font_color = _line_edit.get_theme_color("font_color")
		if font_color != null:
			btn.add_theme_color_override("font_color", font_color)
		btn.pressed.connect(func() -> void: _choose_suggestion(player_name))
		_suggest_box.add_child(btn)

	# Dynamically set suggestion panel height to fit current content (up to 8 items).
	await get_tree().process_frame
	var item_count := _suggest_box.get_child_count()
	var item_height := 32.0
	if item_count > 0:
		item_height = maxf(item_height, (_suggest_box.get_child(0) as Control).get_combined_minimum_size().y)
	var max_visible := 8
	var max_height := item_height * float(max_visible)
	var content_height := (_suggest_box as Control).get_combined_minimum_size().y
	var target_height := minf(content_height, max_height)
	var scroll := _suggest_panel.get_node_or_null("Scroll") as ScrollContainer
	if scroll:
		scroll.custom_minimum_size = Vector2(0.0, target_height)
	_suggest_panel.custom_minimum_size = Vector2(_line_edit.get_global_rect().size.x, target_height)
	_suggest_panel.size = Vector2(_line_edit.get_global_rect().size.x, target_height)

	_update_suggest_panel_position()
	_suggest_panel.visible = true

func _choose_suggestion(player_name: String) -> void:
	_line_edit.text = player_name
	_line_edit.caret_column = _line_edit.text.length()
	_hide_suggestions()
	emit_signal("value_changed", _line_edit.text)
	_line_edit.grab_focus.call_deferred()

func _matching_profiles(query: String) -> Array[Dictionary]:
	if query.strip_edges().is_empty():
		return []
	var q := query.to_lower()
	var prefix: Array[Dictionary] = []
	var contains: Array[Dictionary] = []
	for profile in _profiles_sorted:
		var player_name: String = str(profile.get("name", ""))
		var n := player_name.to_lower()
		if n.begins_with(q):
			prefix.append(profile)
		elif n.contains(q):
			contains.append(profile)
	prefix.append_array(contains)
	return prefix

func _update_suggest_panel_position() -> void:
	if _line_edit == null or _suggest_panel == null:
		return
	var r := _line_edit.get_global_rect()
	_suggest_panel.global_position = Vector2(r.position.x, r.position.y + r.size.y + 2.0)
	var current_height := maxf(_suggest_panel.size.y, _suggest_panel.custom_minimum_size.y)
	_suggest_panel.custom_minimum_size = Vector2(r.size.x, current_height)
	_suggest_panel.size = Vector2(r.size.x, current_height)

func _unhandled_input(event: InputEvent) -> void:
	if not _suggest_panel.visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
			return
		var mouse_pos := get_viewport().get_mouse_position()
		var in_input := _line_edit.get_global_rect().has_point(mouse_pos)
		var in_suggest := _suggest_panel.get_global_rect().has_point(mouse_pos)
		if not in_input and not in_suggest:
			_hide_suggestions()
			_line_edit.release_focus()

func _hide_suggestions() -> void:
	_suggest_panel.visible = false
	_suggest_panel.custom_minimum_size = Vector2(_suggest_panel.custom_minimum_size.x, 0.0)
	_suggest_panel.size = Vector2(_suggest_panel.size.x, 0.0)
