## main_menu.gd
## Main menu: PvP, PvAI, Stats, Settings, Quit.
## Handles player name selection / creation before starting a game.

extends Control

# ── Node refs ──────────────────────────────────────────────────────────────
@onready var _main_panel:     Control = $MainPanel
@onready var _main_menu_panel: Control = $MainPanel/MainVBox
@onready var _title_label: Label = $Title
@onready var _pvp_panel: Control = $MainPanel/PvPVBox
@onready var _pvai_panel: Control = $MainPanel/PvAIVBox
@onready var _stats_panel:    Control = $MainPanel/StatsVBox
@onready var _stats_scroll: ScrollContainer = $MainPanel/StatsVBox/ScrollContainer
@onready var _settings_panel: Control = $MainPanel/SettingsVBox

# PvP panel
@onready var _pvp_p1_input: Node = $MainPanel/PvPVBox/P1Row/Input
@onready var _pvp_p2_input: Node = $MainPanel/PvPVBox/P2Row/Input
@onready var _pvp_time_opt: OptionButton = $MainPanel/PvPVBox/TimeControlRow/TimeOption
@onready var _pvp_start_btn: Button = $MainPanel/PvPVBox/StartBtn
@onready var _pvp_validation_label: Label = $MainPanel/PvPVBox/ValidationLabel

# PvAI panel
@onready var _pvai_player_input: Node = $MainPanel/PvAIVBox/PlayerRow/Input
@onready var _pvai_time_opt: OptionButton = $MainPanel/PvAIVBox/TimeControlRow/TimeOption
@onready var _pvai_ai_label: Label = $MainPanel/PvAIVBox/AIStrengthRow/AIDifficultyLabel
@onready var _pvai_ai_option: OptionButton = $MainPanel/PvAIVBox/AIStrengthRow/AIDifficultyOption
@onready var _pvai_color_opt: OptionButton = $MainPanel/PvAIVBox/ColorRow/ColorOption
@onready var _pvai_start_btn: Button = $MainPanel/PvAIVBox/StartBtn
@onready var _pvai_validation_label: Label = $MainPanel/PvAIVBox/ValidationLabel

# Settings
@onready var _settings_ai_row:    Control  = $MainPanel/SettingsVBox/AIStrengthRow
@onready var _pan_sens_slider:    HSlider  = $MainPanel/SettingsVBox/PanSensRow/PanSensSlider
@onready var _pan_sens_value_label: Label  = $MainPanel/SettingsVBox/PanSensRow/PanSensValueLabel
@onready var _tilt_sens_slider:   HSlider  = $MainPanel/SettingsVBox/TiltSensRow/TiltSensSlider
@onready var _tilt_sens_value_label: Label = $MainPanel/SettingsVBox/TiltSensRow/TiltSensValueLabel
@onready var _kill_cam_check:     CheckButton = $MainPanel/SettingsVBox/KillCamRow/KillCamCheck
@onready var _face_player_check:  CheckButton = $MainPanel/SettingsVBox/FacePlayerRow/FacePlayerCheck
@onready var _music_vol_slider:   HSlider  = $MainPanel/SettingsVBox/MusicVolRow/MusicVolSlider
@onready var _music_vol_value_label: Label = $MainPanel/SettingsVBox/MusicVolRow/MusicVolValueLabel
@onready var _sfx_vol_slider:     HSlider  = $MainPanel/SettingsVBox/SFXVolRow/SFXVolSlider
@onready var _sfx_vol_value_label: Label   = $MainPanel/SettingsVBox/SFXVolRow/SFXVolValueLabel

var _save: Node = null
var _stats_table:       GridContainer = null
var _profiles_sorted:   Array[Dictionary] = []
const _STATS_HEADER_CELLS := 7
const _TABLE_VALUE_THEME := preload("res://themes/table_value.tres")
const _STATS_SCROLLBAR_THICKNESS := 24.0
const _TITLE_FONT_MIN_SIZE := 44
const _TITLE_FONT_MAX_SIZE := 110
const _TITLE_HORIZONTAL_PADDING := 12.0
const _TITLE_VERTICAL_PADDING := 8.0

# ──────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_save = get_node("/root/SaveManager")
	MusicManager.play_menu_music()
	_main_panel.visible = true
	_setup_signals()
	_populate_time_options(_pvp_time_opt)
	_populate_time_options(_pvai_time_opt)
	_stats_table = get_node_or_null("MainPanel/StatsVBox/ScrollContainer/StatsTable") as GridContainer
	_apply_stats_scrollbar_thickness()
	_setup_pvai_controls()
	_setup_settings_extra()
	_connect_button_sounds()
	call_deferred("_fit_title_font_size")
	if _settings_ai_row:
		_settings_ai_row.visible = false
	_show_panel(_main_menu_panel)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_fit_title_font_size()

func _fit_title_font_size() -> void:
	if _title_label == null:
		return
	var font := _title_label.get_theme_font("font")
	if font == null:
		return

	var text := _title_label.text
	if text.is_empty():
		return

	var available_width := maxf(10.0, _title_label.size.x - _TITLE_HORIZONTAL_PADDING)
	var available_height := maxf(10.0, _title_label.size.y - _TITLE_VERTICAL_PADDING)

	var low := _TITLE_FONT_MIN_SIZE
	var high := _TITLE_FONT_MAX_SIZE
	var best := _TITLE_FONT_MIN_SIZE

	while low <= high:
		var mid := int((low + high) / 2)
		var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, mid)
		var text_height := font.get_height(mid)
		if text_size.x <= available_width and text_height <= available_height:
			best = mid
			low = mid + 1
		else:
			high = mid - 1

	_title_label.add_theme_font_size_override("font_size", best)

func _setup_signals() -> void:
	$MainPanel/MainVBox/PvPBtn.pressed.connect(_open_pvp_menu)
	$MainPanel/MainVBox/PvAIBtn.pressed.connect(_open_pvai_menu)
	$MainPanel/MainVBox/StatsBtn.pressed.connect( _show_stats)
	$MainPanel/MainVBox/SettingsBtn.pressed.connect(_show_settings)
	$MainPanel/MainVBox/QuitBtn.pressed.connect(  get_tree().quit)

	$MainPanel/PvPVBox/StartBtn.pressed.connect(_on_pvp_start_pressed)
	$MainPanel/PvPVBox/BackBtn.pressed.connect(func(): _show_panel(_main_menu_panel))
	$MainPanel/PvAIVBox/StartBtn.pressed.connect(_on_pvai_start_pressed)
	$MainPanel/PvAIVBox/BackBtn.pressed.connect(func(): _show_panel(_main_menu_panel))

	$MainPanel/StatsVBox/BackBtn.pressed.connect(   func(): _show_panel(_main_menu_panel))
	$MainPanel/SettingsVBox/BackBtn.pressed.connect(func(): _show_panel(_main_menu_panel))

	_pan_sens_slider.value_changed.connect(_on_pan_sens_changed)
	_tilt_sens_slider.value_changed.connect(_on_tilt_sens_changed)
	_kill_cam_check.toggled.connect(_on_kill_cam_toggled)
	_face_player_check.toggled.connect(_on_face_player_toggled)
	_music_vol_slider.value_changed.connect(_on_music_vol_changed)
	_sfx_vol_slider.value_changed.connect(_on_sfx_vol_changed)
	_pvai_ai_option.item_selected.connect(_on_ai_difficulty_selected)
	_pvai_color_opt.item_selected.connect(_on_player_color_selected)

	if _pvp_p1_input != null and _pvp_p1_input.has_signal("value_changed"):
		_pvp_p1_input.connect("value_changed", func(_t: String) -> void: _update_pvp_validation())
	if _pvp_p2_input != null and _pvp_p2_input.has_signal("value_changed"):
		_pvp_p2_input.connect("value_changed", func(_t: String) -> void: _update_pvp_validation())
	if _pvai_player_input != null and _pvai_player_input.has_signal("value_changed"):
		_pvai_player_input.connect("value_changed", func(_t: String) -> void: _update_pvai_validation())

func _populate_time_options(option_btn: OptionButton) -> void:
	if option_btn == null:
		return
	option_btn.clear()
	option_btn.add_item("No limit",  0)
	option_btn.add_item("3 min",     3 * 60 * 1000)
	option_btn.add_item("5 min",     5 * 60 * 1000)
	option_btn.add_item("10 min",   10 * 60 * 1000)
	option_btn.add_item("15 min",   15 * 60 * 1000)
	option_btn.select(3)

# ── Panel navigation ───────────────────────────────────────────────────────
func _show_panel(panel: Control) -> void:
	_main_panel.visible = true
	_main_menu_panel.visible = (panel == _main_menu_panel)
	_pvp_panel.visible = (panel == _pvp_panel)
	_pvai_panel.visible = (panel == _pvai_panel)
	_stats_panel.visible = (panel == _stats_panel)
	_settings_panel.visible = (panel == _settings_panel)

# ── Name entry ─────────────────────────────────────────────────────────────
func _open_pvp_menu() -> void:
	_populate_name_lists()
	_update_pvp_validation()
	_show_panel(_pvp_panel)
	if _pvp_p1_input != null and _pvp_p1_input.has_method("grab_input_focus"):
		_pvp_p1_input.call("grab_input_focus")

func _open_pvai_menu() -> void:
	_populate_name_lists()
	_update_pvai_validation()
	_show_panel(_pvai_panel)
	if _pvai_player_input != null and _pvai_player_input.has_method("grab_input_focus"):
		_pvai_player_input.call("grab_input_focus")

func _populate_name_lists() -> void:
	_profiles_sorted.clear()
	if _save == null:
		return
	for n in _save.get_all_player_names():
		var profile: Dictionary = _save.get_player(n)
		var profile_name: String = str(profile["name"])
		# Reserved AI aliases should never be selectable as human player profiles.
		if _is_ai_reserved_name(profile_name):
			continue
		_profiles_sorted.append(profile)

	_profiles_sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_games: int = int(a.get("games_played", 0))
		var b_games: int = int(b.get("games_played", 0))
		if a_games != b_games:
			return a_games > b_games
		var a_elo: int = int(a.get("elo", 1000))
		var b_elo: int = int(b.get("elo", 1000))
		if a_elo != b_elo:
			return a_elo > b_elo
		return str(a.get("name", "")) < str(b.get("name", ""))
	)

	var count: int = _profiles_sorted.size()
	if count == 0:
		_nick_set_profiles(_pvp_p1_input, [])
		_nick_set_profiles(_pvp_p2_input, [])
		_nick_set_profiles(_pvai_player_input, [])
		_nick_set_value(_pvp_p1_input, "")
		_nick_set_value(_pvp_p2_input, "")
		_nick_set_value(_pvai_player_input, "")
		return

	_nick_set_profiles(_pvp_p1_input, _profiles_sorted)
	_nick_set_profiles(_pvp_p2_input, _profiles_sorted)
	_nick_set_profiles(_pvai_player_input, _profiles_sorted)

	# Prefill from most active players (already sorted desc by games played)
	_nick_set_value(_pvp_p1_input, str(_profiles_sorted[0].get("name", "")))
	_nick_set_value(_pvai_player_input, str(_profiles_sorted[0].get("name", "")))
	if count > 1:
		_nick_set_value(_pvp_p2_input, str(_profiles_sorted[1].get("name", "")))
	else:
		_nick_set_value(_pvp_p2_input, str(_profiles_sorted[0].get("name", "")))

func _on_pvp_start_pressed() -> void:
	_update_pvp_validation()
	if _pvp_start_btn != null and _pvp_start_btn.disabled:
		return

	var p1: String = _nick_get_value(_pvp_p1_input)
	var p2: String = _nick_get_value(_pvp_p2_input)

	if _save:
		if not _save.player_exists(p1):
			_save.create_player(p1)
		if not _save.player_exists(p2):
			_save.create_player(p2)

	var time_ms: int = _pvp_time_opt.get_item_id(_pvp_time_opt.selected)
	_start_game(p1, p2, false, false, 2, time_ms)

func _on_pvai_start_pressed() -> void:
	_update_pvai_validation()
	if _pvai_start_btn != null and _pvai_start_btn.disabled:
		return

	var player_name: String = _nick_get_value(_pvai_player_input)
	var ai_name := "AI"
	if _save and not _save.player_exists(player_name):
		_save.create_player(player_name)

	var strength := int(_pvai_ai_option.get_selected_id())
	var time_ms: int = _pvai_time_opt.get_item_id(_pvai_time_opt.selected)
	var player_color: int = int(_pvai_color_opt.get_selected_id())
	if player_color == ChessEnums.PieceColor.WHITE:
		_start_game(player_name, ai_name, false, true, strength, time_ms)
	else:
		_start_game(ai_name, player_name, true, false, strength, time_ms)

func _start_game(white_name: String, black_name: String, white_is_ai: bool,
		black_is_ai: bool, strength: int, time_ms: int) -> void:
	hide()   # prevent one-frame overlap when game scene loads
	var game_scene_pack := load("res://scenes/game.tscn") as PackedScene
	if game_scene_pack == null:
		push_error("MainMenu: could not load game scene")
		return
	var game_scene_node := game_scene_pack.instantiate()
	var game_scene := game_scene_node as GameController
	if game_scene == null:
		push_error("MainMenu: game scene root is not GameController")
		return
	get_tree().root.add_child(game_scene)
	game_scene.setup(white_name, black_name, white_is_ai, black_is_ai, strength, time_ms)
	game_scene.start_game()
	queue_free()

func _update_pvp_validation() -> void:
	var err := _pvp_dialog_error()
	if _pvp_start_btn != null:
		_pvp_start_btn.disabled = err != ""
	if _pvp_validation_label != null:
		_pvp_validation_label.text = err
		_pvp_validation_label.visible = err != ""

func _update_pvai_validation() -> void:
	var err := _pvai_dialog_error()
	if _pvai_start_btn != null:
		_pvai_start_btn.disabled = err != ""
	if _pvai_validation_label != null:
		_pvai_validation_label.text = err
		_pvai_validation_label.visible = err != ""

func _pvp_dialog_error() -> String:
	var p1: String = _nick_get_value(_pvp_p1_input)
	if p1.is_empty():
		return "Enter the white player's name"
	if _is_ai_reserved_name(p1):
		return "Nickname 'AI' is not allowed for a human player"
	var p2: String = _nick_get_value(_pvp_p2_input)
	if p2.is_empty():
		return "Enter the black player's name"
	if _is_ai_reserved_name(p2):
		return "Nickname 'AI' is not allowed for a human player"
	if p1.to_lower() == p2.to_lower():
		return "Selected players must have different names"
	return ""

func _pvai_dialog_error() -> String:
	var p1: String = _nick_get_value(_pvai_player_input)
	if p1.is_empty():
		return "Enter your name"
	if _is_ai_reserved_name(p1):
		return "Nickname 'AI' is not allowed for a human player"
	return ""

func _is_ai_reserved_name(candidate_name: String) -> bool:
	var normalized := candidate_name.strip_edges().to_lower()
	return normalized == "ai" or normalized == "computer" or normalized == "bot"

func _nick_set_profiles(input_node: Node, profiles: Array[Dictionary]) -> void:
	if input_node != null and input_node.has_method("set_profiles"):
		input_node.call("set_profiles", profiles)

func _nick_set_value(input_node: Node, value: String) -> void:
	if input_node != null and input_node.has_method("set_value"):
		input_node.call("set_value", value)

func _nick_get_value(input_node: Node) -> String:
	if input_node != null and input_node.has_method("get_value"):
		return str(input_node.call("get_value"))
	return ""

func _nick_set_enabled(input_node: Node, enabled: bool) -> void:
	if input_node != null and input_node.has_method("set_enabled"):
		input_node.call("set_enabled", enabled)

# ── Stats ──────────────────────────────────────────────────────────────────
func _show_stats() -> void:
	_apply_stats_scrollbar_thickness()
	_populate_stats()
	_show_panel(_stats_panel)

func _apply_stats_scrollbar_thickness() -> void:
	if _stats_scroll == null:
		return
	var v_scroll := _stats_scroll.get_v_scroll_bar()
	if v_scroll:
		v_scroll.custom_minimum_size.x = _STATS_SCROLLBAR_THICKNESS
	var h_scroll := _stats_scroll.get_h_scroll_bar()
	if h_scroll:
		h_scroll.custom_minimum_size.y = _STATS_SCROLLBAR_THICKNESS

func _populate_stats() -> void:
	if _stats_table == null:
		return

	# Keep the header row from the scene and clear only dynamic data rows.
	for i in range(_stats_table.get_child_count() - 1, _STATS_HEADER_CELLS - 1, -1):
		_stats_table.get_child(i).queue_free()

	if _save == null:
		return

	for key: String in _save.get_all_player_names():
		var p: Dictionary = _save.get_player(key)
		var avg_ms: float = _save.average_move_time_ms(key)
		var avg_s: String = "%.1fs" % (avg_ms / 1000.0) if avg_ms > 0 else "-"
		_stats_table.add_child(_make_stats_cell(str(p["name"]), HORIZONTAL_ALIGNMENT_LEFT))
		_stats_table.add_child(_make_stats_cell(str(p["elo"])))
		_stats_table.add_child(_make_stats_cell(str(p["wins"])))
		_stats_table.add_child(_make_stats_cell(str(p["losses"])))
		_stats_table.add_child(_make_stats_cell(str(p["draws"])))
		_stats_table.add_child(_make_stats_cell(avg_s))
		_stats_table.add_child(_make_stats_cell(str(p["games_played"])))

func _make_stats_cell(text: String,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.theme = _TABLE_VALUE_THEME
	lbl.horizontal_alignment = align
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

# ── Settings ───────────────────────────────────────────────────────────────
func _show_settings() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		_pan_sens_slider.value  = cam_cfg.pan_sensitivity
		_pan_sens_value_label.text = "%d" % cam_cfg.pan_sensitivity
		_tilt_sens_slider.value = cam_cfg.tilt_sensitivity
		_tilt_sens_value_label.text = "%d" % cam_cfg.tilt_sensitivity
		_kill_cam_check.button_pressed = cam_cfg.kill_cam_enabled
		if _face_player_check:
			_face_player_check.button_pressed = cam_cfg.get("face_player_after_move") != false
		# Populate volume sliders without triggering callbacks
		var mv: int = int(cam_cfg.get("music_volume"))
		var sv: int = int(cam_cfg.get("sfx_volume"))
		if _music_vol_slider:
			_music_vol_slider.set_value_no_signal(mv)
			_music_vol_value_label.text = "%d%%" % mv
		if _sfx_vol_slider:
			_sfx_vol_slider.set_value_no_signal(sv)
			_sfx_vol_value_label.text = "%d%%" % sv
	_show_panel(_settings_panel)


func _on_ai_difficulty_selected(index: int) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("ai_strength", index + 1)
		cam_cfg.save_config()

func _setup_pvai_controls() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var init_ai: int = 2
	if cam_cfg:
		var ai_strength_val = cam_cfg.get("ai_strength")
		if ai_strength_val != null:
			init_ai = clampi(int(ai_strength_val), 1, 3)

	_pvai_ai_option.clear()
	_pvai_ai_option.add_item("Casual", 1)
	_pvai_ai_option.add_item("Challenger", 2)
	_pvai_ai_option.add_item("Master", 3)
	_pvai_ai_option.select(init_ai - 1)
	_on_ai_difficulty_selected(init_ai - 1)

	_pvai_color_opt.clear()
	_pvai_color_opt.add_item("White", ChessEnums.PieceColor.WHITE)
	_pvai_color_opt.add_item("Black", ChessEnums.PieceColor.BLACK)

	var stored_color: int = ChessEnums.PieceColor.WHITE
	if cam_cfg:
		var c = cam_cfg.get("player_color")
		if c != null:
			stored_color = int(c)
	if stored_color == ChessEnums.PieceColor.BLACK:
		_pvai_color_opt.select(1)
	else:
		_pvai_color_opt.select(0)

func _on_player_color_selected(index: int) -> void:
	if _pvai_color_opt == null:
		return
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("player_color", _pvai_color_opt.get_item_id(index))
		cam_cfg.save_config()

func _on_pan_sens_changed(value: float) -> void:
	_pan_sens_value_label.text = "%d" % int(value)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.pan_sensitivity = int(value)
		cam_cfg.save_config()

func _on_tilt_sens_changed(value: float) -> void:
	_tilt_sens_value_label.text = "%d" % int(value)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.tilt_sensitivity = int(value)
		cam_cfg.save_config()

func _on_kill_cam_toggled(pressed: bool) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.kill_cam_enabled = pressed
		cam_cfg.save_config()

# ── Runtime setup ─────────────────────────────────────────────────────────
func _setup_settings_extra() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var init_mv: int = int(cam_cfg.get("music_volume")) if cam_cfg else 50
	var init_sv: int = int(cam_cfg.get("sfx_volume"))   if cam_cfg else 100
	_music_vol_slider.set_value_no_signal(init_mv)
	_sfx_vol_slider.set_value_no_signal(init_sv)
	_music_vol_value_label.text = "%d%%" % init_mv
	_sfx_vol_value_label.text = "%d%%" % init_sv

func _on_face_player_toggled(pressed: bool) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("face_player_after_move", pressed)
		cam_cfg.save_config()


func _on_music_vol_changed(value: float) -> void:
	var pct := int(value)
	if _music_vol_value_label:
		_music_vol_value_label.text = "%d%%" % pct
	MusicManager.set_music_volume(pct)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("music_volume", pct)
		cam_cfg.save_config()

func _on_sfx_vol_changed(value: float) -> void:
	var pct := int(value)
	if _sfx_vol_value_label:
		_sfx_vol_value_label.text = "%d%%" % pct
	MusicManager.set_sfx_volume(pct)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("sfx_volume", pct)
		cam_cfg.save_config()

func _connect_button_sounds() -> void:
	for btn_path: String in [
		"MainPanel/MainVBox/PvPBtn", "MainPanel/MainVBox/PvAIBtn",
		"MainPanel/MainVBox/StatsBtn", "MainPanel/MainVBox/SettingsBtn", "MainPanel/MainVBox/QuitBtn",
		"MainPanel/PvPVBox/StartBtn", "MainPanel/PvPVBox/BackBtn",
		"MainPanel/PvAIVBox/StartBtn", "MainPanel/PvAIVBox/BackBtn",
		"MainPanel/SettingsVBox/BackBtn", "MainPanel/StatsVBox/BackBtn",
	]:
		var btn := get_node_or_null(btn_path) as Button
		if btn:
			btn.pressed.connect(_play_menu_click)

## Spawns a root-level AudioStreamPlayer per click so the sound survives queue_free().
func _play_menu_click() -> void:
	if not is_inside_tree():
		return
	var tmp := AudioStreamPlayer.new()
	tmp.bus = "SFX"
	get_tree().root.add_child(tmp)
	tmp.stream = preload("res://assets/sounds/ui_button.mp3")
	tmp.finished.connect(tmp.queue_free)
	tmp.play()
