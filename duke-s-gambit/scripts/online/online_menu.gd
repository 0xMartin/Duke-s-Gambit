## online_menu.gd
## Builds and drives the Online section of the main menu programmatically.
## Mounted onto the existing MainPanel by main_menu.gd at runtime; uses the
## same themes as the other panels so it visually matches.

extends RefCounted

const _MENU_BTN_THEME    := preload("res://themes/menu_button.tres")
const _SECTION_THEME     := preload("res://themes/menu_section_title.tres")
const _LABEL_THEME       := preload("res://themes/menu_label.tres")
const _OPTION_THEME      := preload("res://themes/option_button.tres")
const _BTN_THEME         := preload("res://themes/button.tres")
const _ONLINE_ICON       := preload("res://assets/textures/pieces/black_queen.svg")
const _ONLINE_BTN_ICON   := preload("res://assets/textures/pieces/black_pawn.svg")

const NICKNAME_RE := "^[A-Za-z0-9_.\\- ]{1,15}$"

# Panels (built lazily).
var connect_panel:  VBoxContainer = null
var lobby_panel:    VBoxContainer = null
var create_panel:   VBoxContainer = null
var join_panel:     VBoxContainer = null
var wait_panel:     VBoxContainer = null

# Connect panel widgets
var _url_input: LineEdit
var _nick_input: LineEdit
var _cert_input: LineEdit
var _insecure_check: CheckButton
var _connect_btn: Button
var _connect_status: Label

# Lobby
var _lobby_status: Label
var _lobby_count_label: Label
var _lobby_list: VBoxContainer
var _refresh_btn: Button
var _create_btn: Button

# Create
var _room_name_input: LineEdit
var _room_color_opt: OptionButton
var _room_time_opt: OptionButton
var _room_password_input: LineEdit
var _create_confirm_btn: Button
var _create_status: Label

# Join (password)
var _join_room_id: String = ""
var _join_name_label: Label
var _join_password_input: LineEdit
var _join_confirm_btn: Button
var _join_status: Label

# Wait (room ready)
var _wait_title: Label
var _wait_white_label: Label
var _wait_black_label: Label
var _wait_info_label: Label
var _wait_status: Label
var _wait_cancel_btn: Button

# External hooks
var _menu: Node = null               # MainMenu
var _online_btn: Button = null
var _current_lobby_rooms: Array = []

func setup(menu: Node) -> void:
	_menu = menu
	_inject_online_button()
	_build_connect_panel()
	_build_lobby_panel()
	_build_create_panel()
	_build_join_panel()
	_build_wait_panel()
	_connect_signals()

func panels() -> Array:
	return [connect_panel, lobby_panel, create_panel, join_panel, wait_panel]

# ── Panel build helpers ────────────────────────────────────────────────────
func _inject_online_button() -> void:
	var main_vbox := _menu.get_node("MainPanel/MainVBox") as VBoxContainer
	if main_vbox == null:
		return
	_online_btn = Button.new()
	_online_btn.name = "OnlineBtn"
	_online_btn.theme = _MENU_BTN_THEME
	_online_btn.text = " Online"
	_online_btn.icon = _ONLINE_BTN_ICON
	_online_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	main_vbox.add_child(_online_btn)
	# Place directly after PvAIBtn
	var pvai := main_vbox.get_node_or_null("PvAIBtn")
	if pvai != null:
		main_vbox.move_child(_online_btn, pvai.get_index() + 1)

func _new_panel(panel_name: String, title: String) -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = panel_name
	panel.visible = false
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 18)
	var title_lbl := Label.new()
	title_lbl.theme = _SECTION_THEME
	title_lbl.text = title
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title_lbl)
	_menu.get_node("MainPanel").add_child(panel)
	return panel

func _add_row(parent: VBoxContainer, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	var lbl := Label.new()
	lbl.theme = _LABEL_THEME
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(320, 0)
	row.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)

func _make_button(text: String) -> Button:
	var b := Button.new()
	b.theme = _BTN_THEME
	b.text = text
	return b

func _make_back_button(target_callable: Callable) -> Button:
	var b := _make_button("Back")
	b.pressed.connect(target_callable)
	return b

func _make_status_label(error: bool = true) -> Label:
	var lbl := Label.new()
	lbl.theme = _LABEL_THEME
	if error:
		lbl.add_theme_color_override("font_color", Color(0.87, 0.0, 0.45, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.text = ""
	return lbl

func _build_connect_panel() -> void:
	connect_panel = _new_panel("OnlineConnectVBox", "Online — Connect")
	_url_input = LineEdit.new()
	_url_input.text = "wss://127.0.0.1:8765"
	_url_input.placeholder_text = "wss://server.example:8765"
	_add_row(connect_panel, "Server URL", _url_input)

	_nick_input = LineEdit.new()
	_nick_input.placeholder_text = "Your nickname (1–15 chars)"
	_nick_input.max_length = 15
	_add_row(connect_panel, "Nickname", _nick_input)

	_cert_input = LineEdit.new()
	_cert_input.placeholder_text = "Optional: absolute path to server cert (.crt)"
	_add_row(connect_panel, "Trusted cert (path)", _cert_input)

	_insecure_check = CheckButton.new()
	_insecure_check.text = "Skip cert verification (LAN only, INSECURE)"
	_add_row(connect_panel, "TLS", _insecure_check)

	_connect_status = _make_status_label()
	connect_panel.add_child(_connect_status)

	_connect_btn = _make_button("Connect")
	connect_panel.add_child(_connect_btn)
	connect_panel.add_child(_make_back_button(func(): _back_to_main()))

func _build_lobby_panel() -> void:
	lobby_panel = _new_panel("OnlineLobbyVBox", "Online — Lobby")
	_lobby_count_label = Label.new()
	_lobby_count_label.theme = _LABEL_THEME
	_lobby_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_count_label.text = "0 players online · 0 rooms"
	lobby_panel.add_child(_lobby_count_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lobby_list = VBoxContainer.new()
	_lobby_list.add_theme_constant_override("separation", 8)
	_lobby_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_lobby_list)
	lobby_panel.add_child(scroll)

	_lobby_status = _make_status_label(false)
	lobby_panel.add_child(_lobby_status)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 16)
	_refresh_btn = _make_button("Refresh")
	_create_btn  = _make_button("Create Room")
	actions.add_child(_refresh_btn)
	actions.add_child(_create_btn)
	lobby_panel.add_child(actions)
	lobby_panel.add_child(_make_back_button(func(): _disconnect_and_back()))

func _build_create_panel() -> void:
	create_panel = _new_panel("OnlineCreateRoomVBox", "Online — Create Room")
	_room_name_input = LineEdit.new()
	_room_name_input.max_length = 24
	_room_name_input.placeholder_text = "Room name"
	_add_row(create_panel, "Room name", _room_name_input)

	_room_color_opt = OptionButton.new()
	_room_color_opt.theme = _OPTION_THEME
	_room_color_opt.add_item("White", 0)
	_room_color_opt.add_item("Black", 1)
	_room_color_opt.add_item("Random", 2)
	_room_color_opt.select(0)
	_add_row(create_panel, "Your color", _room_color_opt)

	_room_time_opt = OptionButton.new()
	_room_time_opt.theme = _OPTION_THEME
	_room_time_opt.add_item("No limit", 0)
	_room_time_opt.add_item("3 min", 3 * 60 * 1000)
	_room_time_opt.add_item("5 min", 5 * 60 * 1000)
	_room_time_opt.add_item("10 min", 10 * 60 * 1000)
	_room_time_opt.add_item("15 min", 15 * 60 * 1000)
	_room_time_opt.select(3)
	_add_row(create_panel, "Time control", _room_time_opt)

	_room_password_input = LineEdit.new()
	_room_password_input.placeholder_text = "Optional"
	_room_password_input.secret = true
	_room_password_input.max_length = 64
	_add_row(create_panel, "Password", _room_password_input)

	_create_status = _make_status_label()
	create_panel.add_child(_create_status)

	_create_confirm_btn = _make_button("Create")
	create_panel.add_child(_create_confirm_btn)
	create_panel.add_child(_make_back_button(func(): _show_panel(lobby_panel)))

func _build_join_panel() -> void:
	join_panel = _new_panel("OnlineJoinVBox", "Join Room")
	_join_name_label = Label.new()
	_join_name_label.theme = _LABEL_THEME
	_join_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	join_panel.add_child(_join_name_label)

	_join_password_input = LineEdit.new()
	_join_password_input.placeholder_text = "Room password"
	_join_password_input.secret = true
	_join_password_input.max_length = 64
	_add_row(join_panel, "Password", _join_password_input)

	_join_status = _make_status_label()
	join_panel.add_child(_join_status)

	_join_confirm_btn = _make_button("Join")
	join_panel.add_child(_join_confirm_btn)
	join_panel.add_child(_make_back_button(func(): _show_panel(lobby_panel)))

func _build_wait_panel() -> void:
	wait_panel = _new_panel("OnlineRoomWaitVBox", "Online — Room")
	_wait_title = Label.new()
	_wait_title.theme = _SECTION_THEME
	_wait_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wait_panel.add_child(_wait_title)

	_wait_white_label = Label.new()
	_wait_white_label.theme = _LABEL_THEME
	_wait_white_label.text = "White: (waiting...)"
	wait_panel.add_child(_wait_white_label)

	_wait_black_label = Label.new()
	_wait_black_label.theme = _LABEL_THEME
	_wait_black_label.text = "Black: (waiting...)"
	wait_panel.add_child(_wait_black_label)

	_wait_info_label = Label.new()
	_wait_info_label.theme = _LABEL_THEME
	_wait_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wait_panel.add_child(_wait_info_label)

	_wait_status = _make_status_label(false)
	wait_panel.add_child(_wait_status)

	_wait_cancel_btn = _make_button("Leave room")
	wait_panel.add_child(_wait_cancel_btn)

# ── Wiring ─────────────────────────────────────────────────────────────────
func _connect_signals() -> void:
	_online_btn.pressed.connect(_on_online_pressed)
	_connect_btn.pressed.connect(_on_connect_pressed)
	_refresh_btn.pressed.connect(func():
		var c := _online_client()
		if c != null:
			c.send_list_rooms()
	)
	_create_btn.pressed.connect(func(): _show_panel(create_panel))
	_create_confirm_btn.pressed.connect(_on_create_confirm)
	_join_confirm_btn.pressed.connect(_on_join_confirm)
	_wait_cancel_btn.pressed.connect(_on_leave_room)

	var oc := _online_client()
	if oc == null:
		return
	oc.connection_state_changed.connect(_on_state_changed)
	oc.connection_error.connect(_on_connection_error)
	oc.welcomed.connect(_on_welcomed)
	oc.online_count_updated.connect(_on_online_count)
	oc.room_list_updated.connect(_on_room_list)
	oc.room_created.connect(_on_room_created)
	oc.room_joined.connect(_on_room_joined)
	oc.room_updated.connect(_on_room_updated)
	oc.room_deleted.connect(_on_room_deleted)
	oc.game_starting.connect(_on_game_starting)
	oc.server_error.connect(_on_server_error)

# ── Button handlers ────────────────────────────────────────────────────────
func _on_online_pressed() -> void:
	var oc := _online_client()
	if oc != null and oc.get_state() == oc.State.READY:
		# Already connected, jump to lobby and refresh.
		_show_panel(lobby_panel)
		oc.send_list_rooms()
	else:
		_connect_status.text = ""
		_show_panel(connect_panel)

func _on_connect_pressed() -> void:
	var nick: String = _nick_input.text.strip_edges()
	var url: String  = _url_input.text.strip_edges()
	if not _validate_nickname(nick):
		_connect_status.text = "Nickname must be 1–15 chars (letters, digits, _ . - space)."
		return
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		_connect_status.text = "URL must start with ws:// or wss://."
		return
	_connect_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	_connect_status.text = "Connecting..."
	_connect_btn.disabled = true
	var oc := _online_client()
	if oc == null:
		_connect_status.text = "OnlineClient autoload missing."
		_connect_btn.disabled = false
		return
	oc.connect_to_server(url, nick, _cert_input.text.strip_edges(),
		"", _insecure_check.button_pressed)

func _on_create_confirm() -> void:
	var nm: String = _room_name_input.text.strip_edges()
	if nm.length() < 1:
		_create_status.text = "Room name is required."
		return
	var sel := _room_color_opt.get_selected_id()
	var color := "random"
	if sel == 0:
		color = "white"
	elif sel == 1:
		color = "black"
	var time_ms := _room_time_opt.get_item_id(_room_time_opt.selected)
	var oc := _online_client()
	if oc == null:
		return
	_create_status.text = "Creating..."
	oc.send_create_room(nm, color, time_ms, _room_password_input.text)

func _on_join_confirm() -> void:
	var oc := _online_client()
	if oc == null or _join_room_id == "":
		return
	_join_status.text = "Joining..."
	oc.send_join_room(_join_room_id, _join_password_input.text)

func _on_leave_room() -> void:
	var oc := _online_client()
	if oc == null:
		return
	oc.send_leave_room()
	_show_panel(lobby_panel)
	oc.send_list_rooms()

func _disconnect_and_back() -> void:
	var oc := _online_client()
	if oc != null:
		oc.disconnect_from_server()
	_back_to_main()

func _back_to_main() -> void:
	if _menu.has_method("show_main_panel"):
		_menu.call("show_main_panel")

# ── Signal callbacks ───────────────────────────────────────────────────────
func _on_state_changed(_new_state: int) -> void:
	pass

func _on_connection_error(msg: String) -> void:
	_connect_status.add_theme_color_override("font_color", Color(0.87, 0.0, 0.45, 1.0))
	_connect_status.text = msg
	_connect_btn.disabled = false
	if _menu != null and _menu.has_method("is_online_panel_active"):
		if _menu.call("is_online_panel_active"):
			_show_panel(connect_panel)

func _on_welcomed(online_count: int) -> void:
	_connect_btn.disabled = false
	_show_panel(lobby_panel)
	_lobby_count_label.text = "%d players online" % online_count
	var oc := _online_client()
	if oc != null:
		oc.send_list_rooms()

func _on_online_count(n: int) -> void:
	_lobby_count_label.text = "%d players online · %d rooms" % [n, _current_lobby_rooms.size()]

func _on_room_list(rooms: Array, online_count: int) -> void:
	_current_lobby_rooms = rooms
	_lobby_count_label.text = "%d players online · %d rooms" % [online_count, rooms.size()]
	for child in _lobby_list.get_children():
		child.queue_free()
	if rooms.is_empty():
		var empty := Label.new()
		empty.theme = _LABEL_THEME
		empty.text = "No rooms — be the first to create one!"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_lobby_list.add_child(empty)
		return
	for r in rooms:
		_lobby_list.add_child(_make_room_row(r))

func _make_room_row(room: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var info := Label.new()
	info.theme = _LABEL_THEME
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var has_pw := bool(room.get("has_password", false))
	var status := str(room.get("state", "waiting"))
	var players := int(room.get("player_count", 0))
	var time_ms := int(room.get("time_ms", 0))
	var time_str := "no limit"
	if time_ms > 0:
		@warning_ignore("integer_division")
		var mins := time_ms / 60000
		time_str = "%d min" % mins
	info.text = "%s%s — %s · %d/2 · %s" % [
		"🔒 " if has_pw else "",
		str(room.get("name", "?")),
		status, players, time_str
	]
	row.add_child(info)
	var join := _make_button("Join")
	join.custom_minimum_size = Vector2(140, 0)
	join.disabled = (status != "waiting" or players >= 2)
	var rid := str(room.get("room_id", ""))
	join.pressed.connect(func(): _try_join_room(rid, str(room.get("name", "")), has_pw))
	row.add_child(join)
	return row

func _try_join_room(rid: String, name_str: String, has_pw: bool) -> void:
	if has_pw:
		_join_room_id = rid
		_join_name_label.text = "Joining room: %s" % name_str
		_join_password_input.text = ""
		_join_status.text = ""
		_show_panel(join_panel)
	else:
		var oc := _online_client()
		if oc != null:
			oc.send_join_room(rid, "")

func _on_room_created(room: Dictionary) -> void:
	_create_status.text = ""
	_show_wait_for(room)

func _on_room_joined(room: Dictionary, _role: String) -> void:
	_join_status.text = ""
	_show_wait_for(room)

func _on_room_updated(room: Dictionary) -> void:
	if wait_panel.visible:
		_show_wait_for(room)

func _show_wait_for(room: Dictionary) -> void:
	_wait_title.text = "Room: %s" % str(room.get("name", "?"))
	var members: Array = room.get("members", [])
	var white_n := ""
	var black_n := ""
	for m in members:
		var md: Dictionary = m
		if str(md.get("color", "")) == "white":
			white_n = str(md.get("nickname", ""))
		elif str(md.get("color", "")) == "black":
			black_n = str(md.get("nickname", ""))
	_wait_white_label.text = "White: %s" % (white_n if white_n != "" else "(waiting...)")
	_wait_black_label.text = "Black: %s" % (black_n if black_n != "" else "(waiting...)")
	var time_ms := int(room.get("time_ms", 0))
	var time_str := "no limit"
	if time_ms > 0:
		@warning_ignore("integer_division")
		var mins := time_ms / 60000
		time_str = "%d min" % mins
	_wait_info_label.text = "Time: %s · Players: %d/2" % [time_str, members.size()]
	_wait_status.text = "Waiting for opponent..." if members.size() < 2 else "Ready — game starting..."
	_show_panel(wait_panel)

func _on_room_deleted(_rid: String, reason: String) -> void:
	if wait_panel.visible or create_panel.visible or join_panel.visible:
		_show_panel(lobby_panel)
	if _menu != null and _menu.has_method("show_online_toast"):
		_menu.call("show_online_toast", "Room closed: %s" % reason)
	var oc := _online_client()
	if oc != null:
		oc.send_list_rooms()

func _on_game_starting(payload: Dictionary) -> void:
	# Hand control back to MainMenu which loads game.tscn and invokes setup_online.
	if _menu != null and _menu.has_method("start_online_game"):
		_menu.call("start_online_game", payload)

func _on_server_error(code: String, msg: String) -> void:
	var text := "[%s] %s" % [code, msg]
	if create_panel.visible:
		_create_status.text = text
	elif join_panel.visible:
		_join_status.text = text
	elif connect_panel.visible:
		_connect_status.text = text
	elif wait_panel.visible:
		_wait_status.add_theme_color_override("font_color", Color(0.87, 0.0, 0.45, 1.0))
		_wait_status.text = text
	else:
		if _menu != null and _menu.has_method("show_online_toast"):
			_menu.call("show_online_toast", text)

# ── Helpers ────────────────────────────────────────────────────────────────
func _show_panel(panel: Control) -> void:
	if _menu != null and _menu.has_method("show_online_panel"):
		_menu.call("show_online_panel", panel)

func _online_client() -> Node:
	if _menu == null:
		return null
	return _menu.get_node_or_null("/root/OnlineClient")

func _validate_nickname(s: String) -> bool:
	if s.length() < 1 or s.length() > 15:
		return false
	var re := RegEx.new()
	if re.compile(NICKNAME_RE) != OK:
		return false
	return re.search(s) != null
