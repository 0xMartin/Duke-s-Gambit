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
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.focus_entered.connect(_on_focus_entered)
	_line_edit.focus_exited.connect(_on_focus_exited)
	_update_suggest_panel_position()

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
	_refresh_suggestions()

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
		btn.pressed.connect(func() -> void: _choose_suggestion(player_name))
		_suggest_box.add_child(btn)

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
		return _profiles_sorted
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
	_suggest_panel.custom_minimum_size = Vector2(r.size.x, 0.0)

func _hide_suggestions() -> void:
	_suggest_panel.visible = false
