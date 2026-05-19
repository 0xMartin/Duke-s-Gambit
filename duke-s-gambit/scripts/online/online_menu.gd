## online_menu.gd
## Drives the Online section of the main menu. UI nodes live in main_menu.tscn;
## this script only wires logic, populates dynamic data and binds signals.

extends RefCounted

const _LABEL_THEME := preload("res://themes/menu_label.tres")
const _BTN_THEME   := preload("res://themes/button.tres")

const NICKNAME_RE := "^[A-Za-z0-9_.\\- ]{1,15}$"

# Panels (from scene)
var connect_panel:  VBoxContainer = null
var lobby_panel:    VBoxContainer = null
var create_panel:   VBoxContainer = null
var join_panel:     VBoxContainer = null
var wait_panel:     VBoxContainer = null

# Connect panel widgets
var _url_input:       LineEdit
var _nick_input:      LineEdit
var _cert_input:      LineEdit
var _insecure_check:  CheckButton
var _connect_btn:     Button
var _connect_back_btn: Button
var _connect_status:  Label

# Lobby
var _lobby_count_label: Label
var _lobby_status:      Label
var _lobby_list:        VBoxContainer
var _refresh_btn:       Button
var _create_btn:        Button
var _lobby_back_btn:    Button

# Create
var _room_name_input:     LineEdit
var _room_color_opt:      OptionButton
var _room_time_opt:       OptionButton
var _room_password_input: LineEdit
var _create_confirm_btn:  Button
var _create_back_btn:     Button
var _create_status:       Label

# Join
var _join_room_id: String = ""
var _join_room_name_label: Label
var _join_password_input:  LineEdit
var _join_confirm_btn:     Button
var _join_back_btn:        Button
var _join_status:          Label

# Wait
var _wait_room_title:  Label
var _wait_white_label: Label
var _wait_black_label: Label
var _wait_info_label:  Label
var _wait_status:      Label
var _wait_start_btn:   Button
var _wait_leave_btn:   Button
var _am_host: bool = false

# External
var _menu: Node = null               # MainMenu
var _online_btn: Button = null
var _current_lobby_rooms: Array = []

# ──────────────────────────────────────────────────────────────────────────
func setup(menu: Node) -> void:
	_menu = menu
	_bind_nodes()
	_populate_static_options()
	_connect_signals()

func panels() -> Array:
	return [connect_panel, lobby_panel, create_panel, join_panel, wait_panel]

# ── Bind scene nodes ──────────────────────────────────────────────────────
func _bind_nodes() -> void:
	_online_btn = _menu.get_node("MainPanel/MainVBox/OnlineBtn") as Button

	connect_panel = _menu.get_node("MainPanel/OnlineConnectVBox") as VBoxContainer
	_url_input      = connect_panel.get_node("URLRow/URLInput") as LineEdit
	_nick_input     = connect_panel.get_node("NickRow/NickInput") as LineEdit
	_cert_input     = connect_panel.get_node("CertRow/CertInput") as LineEdit
	_insecure_check = connect_panel.get_node("InsecureRow/InsecureCheck") as CheckButton
	_connect_status = connect_panel.get_node("StatusLabel") as Label
	_connect_btn    = connect_panel.get_node("ConnectBtn") as Button
	_connect_back_btn = connect_panel.get_node("BackBtn") as Button

	lobby_panel = _menu.get_node("MainPanel/OnlineLobbyVBox") as VBoxContainer
	_lobby_count_label = lobby_panel.get_node("CountLabel") as Label
	_lobby_list        = lobby_panel.get_node("ScrollContainer/RoomList") as VBoxContainer
	_lobby_status      = lobby_panel.get_node("StatusLabel") as Label
	_refresh_btn       = lobby_panel.get_node("ActionsRow/RefreshBtn") as Button
	_create_btn        = lobby_panel.get_node("ActionsRow/CreateBtn") as Button
	_lobby_back_btn    = lobby_panel.get_node("BackBtn") as Button

	create_panel = _menu.get_node("MainPanel/OnlineCreateRoomVBox") as VBoxContainer
	_room_name_input     = create_panel.get_node("NameRow/NameInput") as LineEdit
	_room_color_opt      = create_panel.get_node("ColorRow/ColorOption") as OptionButton
	_room_time_opt       = create_panel.get_node("TimeRow/TimeOption") as OptionButton
	_room_password_input = create_panel.get_node("PasswordRow/PasswordInput") as LineEdit
	_create_status       = create_panel.get_node("StatusLabel") as Label
	_create_confirm_btn  = create_panel.get_node("CreateConfirmBtn") as Button
	_create_back_btn     = create_panel.get_node("BackBtn") as Button

	join_panel = _menu.get_node("MainPanel/OnlineJoinVBox") as VBoxContainer
	_join_room_name_label = join_panel.get_node("RoomNameLabel") as Label
	_join_password_input  = join_panel.get_node("PasswordRow/PasswordInput") as LineEdit
	_join_status          = join_panel.get_node("StatusLabel") as Label
	_join_confirm_btn     = join_panel.get_node("JoinConfirmBtn") as Button
	_join_back_btn        = join_panel.get_node("BackBtn") as Button

	wait_panel = _menu.get_node("MainPanel/OnlineRoomWaitVBox") as VBoxContainer
	_wait_room_title  = wait_panel.get_node("RoomTitle") as Label
	_wait_white_label = wait_panel.get_node("WhiteLabel") as Label
	_wait_black_label = wait_panel.get_node("BlackLabel") as Label
	_wait_info_label  = wait_panel.get_node("InfoLabel") as Label
	_wait_status      = wait_panel.get_node("StatusLabel") as Label
	_wait_start_btn   = wait_panel.get_node("StartBtn") as Button
	_wait_leave_btn   = wait_panel.get_node("LeaveBtn") as Button

func _populate_static_options() -> void:
	_room_color_opt.clear()
	_room_color_opt.add_item("White", 0)
	_room_color_opt.add_item("Black", 1)
	_room_color_opt.add_item("Random", 2)
	_room_color_opt.select(0)

	_room_time_opt.clear()
	_room_time_opt.add_item("No limit", 0)
	_room_time_opt.add_item("3 min",    3 * 60 * 1000)
	_room_time_opt.add_item("5 min",    5 * 60 * 1000)
	_room_time_opt.add_item("10 min",  10 * 60 * 1000)
	_room_time_opt.add_item("15 min",  15 * 60 * 1000)
	_room_time_opt.select(3)

# ── Wiring ─────────────────────────────────────────────────────────────────
func _connect_signals() -> void:
	_online_btn.pressed.connect(_on_online_pressed)
	_connect_btn.pressed.connect(_on_connect_pressed)
	_connect_back_btn.pressed.connect(_back_to_main)
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_create_btn.pressed.connect(func(): _show_panel(create_panel))
	_lobby_back_btn.pressed.connect(_disconnect_and_back)
	_create_confirm_btn.pressed.connect(_on_create_confirm)
	_create_back_btn.pressed.connect(func(): _show_panel(lobby_panel))
	_join_confirm_btn.pressed.connect(_on_join_confirm)
	_join_back_btn.pressed.connect(func(): _show_panel(lobby_panel))
	_wait_leave_btn.pressed.connect(_on_leave_room)
	_wait_start_btn.pressed.connect(_on_start_game_pressed)

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
		_show_panel(lobby_panel)
		oc.send_list_rooms()
	else:
		_connect_status.text = ""
		_show_panel(connect_panel)

func _on_refresh_pressed() -> void:
	var oc := _online_client()
	if oc != null:
		oc.send_list_rooms()

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
	_am_host = false
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
	var players := int(room.get("members", 0))
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
	var join := Button.new()
	join.theme = _BTN_THEME
	join.text = "Join"
	join.custom_minimum_size = Vector2(140, 0)
	join.disabled = (status != "waiting" or players >= 2)
	var rid := str(room.get("room_id", ""))
	join.pressed.connect(func(): _try_join_room(rid, str(room.get("name", "")), has_pw))
	row.add_child(join)
	return row

func _try_join_room(rid: String, name_str: String, has_pw: bool) -> void:
	if has_pw:
		_join_room_id = rid
		_join_room_name_label.text = "Joining room: %s" % name_str
		_join_password_input.text = ""
		_join_status.text = ""
		_show_panel(join_panel)
	else:
		var oc := _online_client()
		if oc != null:
			oc.send_join_room(rid, "")

func _on_room_created(room: Dictionary) -> void:
	_create_status.text = ""
	_am_host = true
	_show_wait_for(room)

func _on_room_joined(room: Dictionary, role: String) -> void:
	_join_status.text = ""
	_am_host = (role == "host")
	_show_wait_for(room)

func _on_room_updated(room: Dictionary) -> void:
	if wait_panel.visible:
		_show_wait_for(room)

func _show_wait_for(room: Dictionary) -> void:
	_wait_room_title.text = "Room: %s" % str(room.get("name", "?"))
	var members: Array = room.get("members_detail", [])
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
	var both_in := members.size() >= 2
	if _am_host:
		_wait_start_btn.visible = true
		_wait_start_btn.disabled = not both_in
		_wait_status.text = "Waiting for opponent..." if not both_in else "Both players ready — press Start to begin."
	else:
		_wait_start_btn.visible = false
		_wait_status.text = "Waiting for opponent..." if not both_in else "Waiting for host to start the game..."
	_show_panel(wait_panel)

func _on_start_game_pressed() -> void:
	var oc := _online_client()
	if oc == null:
		return
	_wait_start_btn.disabled = true
	_wait_status.text = "Starting game..."
	oc.send_start_game()

func _on_room_deleted(_rid: String, reason: String) -> void:
	if wait_panel.visible or create_panel.visible or join_panel.visible:
		_show_panel(lobby_panel)
	if _menu != null and _menu.has_method("show_online_toast"):
		_menu.call("show_online_toast", "Room closed: %s" % reason)
	var oc := _online_client()
	if oc != null:
		oc.send_list_rooms()

func _on_game_starting(payload: Dictionary) -> void:
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
