## main_menu.gd
## Main menu: PvP, PvAI, Stats, Settings, Quit.
## Handles player name selection / creation before starting a game.

extends Control

# ── Node refs ──────────────────────────────────────────────────────────────
@onready var _main_panel:     Control = $MainPanel
@onready var _pvp_panel: Control = $PvPPanel
@onready var _pvai_panel: Control = $PvAIPanel
@onready var _stats_panel:    Control = $StatsPanel
@onready var _settings_panel: Control = $SettingsPanel

# PvP panel
@onready var _pvp_p1_input: Node = $PvPPanel/VBox/P1Row/Input
@onready var _pvp_p2_input: Node = $PvPPanel/VBox/P2Row/Input
@onready var _pvp_time_opt: OptionButton = $PvPPanel/VBox/TimeControlRow/TimeOption
@onready var _pvp_start_btn: Button = $PvPPanel/VBox/StartBtn
@onready var _pvp_validation_label: Label = $PvPPanel/VBox/ValidationLabel

# PvAI panel
@onready var _pvai_player_input: Node = $PvAIPanel/VBox/PlayerRow/Input
@onready var _pvai_time_opt: OptionButton = $PvAIPanel/VBox/TimeControlRow/TimeOption
@onready var _pvai_ai_label: Label = $PvAIPanel/VBox/AIStrengthRow/Label
@onready var _pvai_ai_slider: HSlider = $PvAIPanel/VBox/AIStrengthRow/Slider
@onready var _pvai_color_opt: OptionButton = $PvAIPanel/VBox/ColorRow/ColorOption
@onready var _pvai_start_btn: Button = $PvAIPanel/VBox/StartBtn
@onready var _pvai_validation_label: Label = $PvAIPanel/VBox/ValidationLabel

# Settings
@onready var _settings_ai_row:    Control  = $SettingsPanel/VBox/AIStrengthRow
@onready var _pan_sens_slider:    HSlider  = $SettingsPanel/VBox/PanSensRow/PanSensSlider
@onready var _pan_sens_label:     Label    = $SettingsPanel/VBox/PanSensRow/PanSensLabel
@onready var _tilt_sens_slider:   HSlider  = $SettingsPanel/VBox/TiltSensRow/TiltSensSlider
@onready var _tilt_sens_label:    Label    = $SettingsPanel/VBox/TiltSensRow/TiltSensLabel
@onready var _kill_cam_check:     CheckBox = $SettingsPanel/VBox/KillCamRow/KillCamCheck
@onready var _face_player_check:  CheckBox = $SettingsPanel/VBox/FacePlayerRow/FacePlayerCheck
@onready var _music_vol_slider:   HSlider  = $SettingsPanel/VBox/MusicVolRow/MusicVolSlider
@onready var _music_vol_label:    Label    = $SettingsPanel/VBox/MusicVolRow/MusicVolLabel
@onready var _sfx_vol_slider:     HSlider  = $SettingsPanel/VBox/SFXVolRow/SFXVolSlider
@onready var _sfx_vol_label:      Label    = $SettingsPanel/VBox/SFXVolRow/SFXVolLabel

var _save: Node = null
var _stats_vbox:        VBoxContainer = null
var _profiles_sorted:   Array[Dictionary] = []

# ──────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_save = get_node("/root/SaveManager")
	MusicManager.play_menu_music()
	_show_panel(_main_panel)
	_setup_signals()
	_populate_time_options(_pvp_time_opt)
	_populate_time_options(_pvai_time_opt)
	_stats_vbox = get_node_or_null("StatsPanel/VBox/ScrollContainer/VBox") as VBoxContainer
	_setup_pvai_controls()
	_setup_settings_extra()
	_setup_font_sizes()
	_apply_roblox_theme()
	_connect_button_sounds()
	if _settings_ai_row:
		_settings_ai_row.visible = false

func _setup_signals() -> void:
	$MainPanel/VBox/PvPBtn.pressed.connect(_open_pvp_menu)
	$MainPanel/VBox/PvAIBtn.pressed.connect(_open_pvai_menu)
	$MainPanel/VBox/StatsBtn.pressed.connect( _show_stats)
	$MainPanel/VBox/SettingsBtn.pressed.connect(_show_settings)
	$MainPanel/VBox/QuitBtn.pressed.connect(  get_tree().quit)

	$PvPPanel/VBox/StartBtn.pressed.connect(_on_pvp_start_pressed)
	$PvPPanel/VBox/BackBtn.pressed.connect(func(): _show_panel(_main_panel))
	$PvAIPanel/VBox/StartBtn.pressed.connect(_on_pvai_start_pressed)
	$PvAIPanel/VBox/BackBtn.pressed.connect(func(): _show_panel(_main_panel))

	$StatsPanel/VBox/BackBtn.pressed.connect(   func(): _show_panel(_main_panel))
	$SettingsPanel/VBox/BackBtn.pressed.connect(func(): _show_panel(_main_panel))

	_pan_sens_slider.value_changed.connect(_on_pan_sens_changed)
	_tilt_sens_slider.value_changed.connect(_on_tilt_sens_changed)
	_kill_cam_check.toggled.connect(_on_kill_cam_toggled)
	_face_player_check.toggled.connect(_on_face_player_toggled)
	_music_vol_slider.value_changed.connect(_on_music_vol_changed)
	_sfx_vol_slider.value_changed.connect(_on_sfx_vol_changed)
	_pvai_ai_slider.value_changed.connect(_on_name_ai_strength_changed)
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
	for p in [_main_panel, _pvp_panel, _pvai_panel, _stats_panel, _settings_panel]:
		p.visible = (p == panel)

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

	var strength := int(_pvai_ai_slider.value)
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
		return "Vypln jmeno bileho hrace."
	if _is_ai_reserved_name(p1):
		return "Nickname 'AI/Computer/Bot' neni povoleny pro lidskeho hrace."
	var p2: String = _nick_get_value(_pvp_p2_input)
	if p2.is_empty():
		return "Vypln jmeno cerneho hrace."
	if _is_ai_reserved_name(p2):
		return "Nickname 'AI/Computer/Bot' neni povoleny pro lidskeho hrace."
	if p1.to_lower() == p2.to_lower():
		return "Vybrani hraci musi mit odlisne jmeno."
	return ""

func _pvai_dialog_error() -> String:
	var p1: String = _nick_get_value(_pvai_player_input)
	if p1.is_empty():
		return "Vypln svoje jmeno."
	if _is_ai_reserved_name(p1):
		return "Nickname 'AI/Computer/Bot' neni povoleny pro lidskeho hrace."
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
	_populate_stats()
	_show_panel(_stats_panel)

func _populate_stats() -> void:
	for child in _stats_vbox.get_children():
		child.queue_free()
	if _save == null:
		return

	var table := GridContainer.new()
	table.columns = 7
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.add_theme_constant_override("h_separation", 18)
	table.add_theme_constant_override("v_separation", 8)

	for title in ["Player", "ELO", "Wins", "Losses", "Draws", "Avg Move", "Games"]:
		table.add_child(_make_stats_cell(title, true, HORIZONTAL_ALIGNMENT_LEFT))

	for key: String in _save.get_all_player_names():
		var p: Dictionary = _save.get_player(key)
		var avg_ms: float = _save.average_move_time_ms(key)
		var avg_s: String = "%.1fs" % (avg_ms / 1000.0) if avg_ms > 0 else "-"
		table.add_child(_make_stats_cell(str(p["name"]), false, HORIZONTAL_ALIGNMENT_LEFT))
		table.add_child(_make_stats_cell(str(p["elo"])))
		table.add_child(_make_stats_cell(str(p["wins"])))
		table.add_child(_make_stats_cell(str(p["losses"])))
		table.add_child(_make_stats_cell(str(p["draws"])))
		table.add_child(_make_stats_cell(avg_s))
		table.add_child(_make_stats_cell(str(p["games_played"])))

	_stats_vbox.add_child(table)

func _make_stats_cell(text: String, is_header: bool = false,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = align
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 24 if is_header else 22)
	lbl.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.2, 1.0) if is_header else Color(0.93, 0.93, 0.90, 1.0))
	return lbl

# ── Settings ───────────────────────────────────────────────────────────────
func _show_settings() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		_pan_sens_slider.value  = cam_cfg.pan_sensitivity
		_pan_sens_label.text    = "Pan Sensitivity: %d" % cam_cfg.pan_sensitivity
		_tilt_sens_slider.value = cam_cfg.tilt_sensitivity
		_tilt_sens_label.text   = "Tilt Sensitivity: %d" % cam_cfg.tilt_sensitivity
		_kill_cam_check.button_pressed = cam_cfg.kill_cam_enabled
		if _face_player_check:
			_face_player_check.button_pressed = cam_cfg.get("face_player_after_move") != false
		# Populate volume sliders without triggering callbacks
		var mv: int = int(cam_cfg.get("music_volume"))
		var sv: int = int(cam_cfg.get("sfx_volume"))
		if _music_vol_slider:
			_music_vol_slider.set_value_no_signal(mv)
			_music_vol_label.text = "Music Volume: %d%%" % mv
		if _sfx_vol_slider:
			_sfx_vol_slider.set_value_no_signal(sv)
			_sfx_vol_label.text = "SFX Volume: %d%%" % sv
	_show_panel(_settings_panel)

func _on_name_ai_strength_changed(value: float) -> void:
	var diff_idx := clampi(int(value), 1, 3)
	var difficulty_names := ["", "Casual", "Challenger", "Master"]
	var difficulty_depths := [0, 4, 8, 12]
	if _pvai_ai_label:
		_pvai_ai_label.text = "AI Difficulty: %s (depth %d)" % [difficulty_names[diff_idx], difficulty_depths[diff_idx]]
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("ai_strength", diff_idx)
		cam_cfg.save_config()

func _setup_pvai_controls() -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var init_ai: int = 2
	if cam_cfg:
		var ai_strength_val = cam_cfg.get("ai_strength")
		if ai_strength_val != null:
			init_ai = clampi(int(ai_strength_val), 1, 3)
	_pvai_ai_slider.value = init_ai
	_on_name_ai_strength_changed(_pvai_ai_slider.value)

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
	_pan_sens_label.text = "Pan Sensitivity: %d" % int(value)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.pan_sensitivity = int(value)
		cam_cfg.save_config()

func _on_tilt_sens_changed(value: float) -> void:
	_tilt_sens_label.text = "Tilt Sensitivity: %d" % int(value)
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
	_music_vol_label.text = "Music Volume: %d%%" % init_mv
	_sfx_vol_label.text = "SFX Volume: %d%%" % init_sv

func _on_face_player_toggled(pressed: bool) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("face_player_after_move", pressed)
		cam_cfg.save_config()


func _on_music_vol_changed(value: float) -> void:
	var pct := int(value)
	if _music_vol_label:
		_music_vol_label.text = "Music Volume: %d%%" % pct
	MusicManager.set_music_volume(pct)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("music_volume", pct)
		cam_cfg.save_config()

func _on_sfx_vol_changed(value: float) -> void:
	var pct := int(value)
	if _sfx_vol_label:
		_sfx_vol_label.text = "SFX Volume: %d%%" % pct
	MusicManager.set_sfx_volume(pct)
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("sfx_volume", pct)
		cam_cfg.save_config()

func _setup_font_sizes() -> void:
	# Title
	var main_title := get_node_or_null("MainPanel/VBox/Title") as Label
	if main_title:
		main_title.add_theme_font_size_override("font_size", 72)
	for lbl_path: String in ["PvPPanel/VBox/TitleLabel", "PvAIPanel/VBox/TitleLabel", "StatsPanel/VBox/Title",
			"SettingsPanel/VBox/Title"]:
		var lbl := get_node_or_null(lbl_path) as Label
		if lbl:
			lbl.add_theme_font_size_override("font_size", 48)
	# Buttons
	for btn_path: String in [
		"MainPanel/VBox/PvPBtn", "MainPanel/VBox/PvAIBtn",
		"MainPanel/VBox/StatsBtn", "MainPanel/VBox/SettingsBtn", "MainPanel/VBox/QuitBtn",
		"PvPPanel/VBox/StartBtn", "PvPPanel/VBox/BackBtn",
		"PvAIPanel/VBox/StartBtn", "PvAIPanel/VBox/BackBtn",
		"SettingsPanel/VBox/BackBtn", "StatsPanel/VBox/BackBtn",
	]:
		var btn := get_node_or_null(btn_path) as Button
		if btn:
			btn.add_theme_font_size_override("font_size", 36)
	# Settings labels
	for lbl_path: String in [
		"SettingsPanel/VBox/AIStrengthRow/Label",
		"SettingsPanel/VBox/PanSensRow/PanSensLabel",
		"SettingsPanel/VBox/TiltSensRow/TiltSensLabel",
		"SettingsPanel/VBox/KillCamRow/KillCamLabel",
		"SettingsPanel/VBox/FacePlayerRow/FacePlayerLabel",
		"SettingsPanel/VBox/MusicVolRow/MusicVolLabel",
		"SettingsPanel/VBox/SFXVolRow/SFXVolLabel",
		"PvAIPanel/VBox/AIStrengthRow/Label",
		"PvAIPanel/VBox/ColorRow/Label",
	]:
		var lbl := get_node_or_null(lbl_path) as Label
		if lbl:
			lbl.add_theme_font_size_override("font_size", 28)

	for lbl_path: String in ["PvPPanel/VBox/ValidationLabel", "PvAIPanel/VBox/ValidationLabel"]:
		var v_lbl := get_node_or_null(lbl_path) as Label
		if v_lbl:
			v_lbl.add_theme_font_size_override("font_size", 22)
			v_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.30, 1.0))

# ── Roblox-like visual theme ──────────────────────────────────────────────────
func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color    = Color(0.05, 0.06, 0.12, 0.93)
	s.border_color = Color(0.82, 0.62, 0.10, 1.0)
	s.set_border_width_all(4)
	s.set_corner_radius_all(14)
	s.content_margin_left   = 28
	s.content_margin_right  = 28
	s.content_margin_top    = 22
	s.content_margin_bottom = 22
	return s

func _make_btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color    = bg
	s.border_color = border
	s.set_border_width_all(3)
	s.set_corner_radius_all(10)
	s.content_margin_left   = 20
	s.content_margin_right  = 20
	s.content_margin_top    = 10
	s.content_margin_bottom = 10
	return s

func _apply_roblox_theme() -> void:
	# — Panels —
	var ps := _make_panel_style()
	for p: Control in [_main_panel, _pvp_panel, _pvai_panel, _stats_panel, _settings_panel]:
		p.add_theme_stylebox_override("panel", ps)
		var vbox := p.get_node_or_null("VBox") as VBoxContainer
		if vbox:
			vbox.add_theme_constant_override("separation", 14)

	# — Buttons —
	var bdr_n := Color(0.68, 0.50, 0.10, 1.0)
	var bdr_h := Color(1.00, 0.82, 0.20, 1.0)
	for btn_path: String in [
		"MainPanel/VBox/PvPBtn", "MainPanel/VBox/PvAIBtn",
		"MainPanel/VBox/StatsBtn", "MainPanel/VBox/SettingsBtn", "MainPanel/VBox/QuitBtn",
		"PvPPanel/VBox/StartBtn", "PvPPanel/VBox/BackBtn",
		"PvAIPanel/VBox/StartBtn", "PvAIPanel/VBox/BackBtn",
		"SettingsPanel/VBox/BackBtn", "StatsPanel/VBox/BackBtn",
	]:
		var btn := get_node_or_null(btn_path) as Button
		if btn == null:
			continue
		btn.custom_minimum_size = Vector2(0, 56)
		btn.add_theme_stylebox_override("normal",
				_make_btn_style(Color(0.13, 0.15, 0.25, 1.0), bdr_n))
		btn.add_theme_stylebox_override("hover",
				_make_btn_style(Color(0.22, 0.26, 0.42, 1.0), bdr_h))
		btn.add_theme_stylebox_override("pressed",
				_make_btn_style(Color(0.07, 0.08, 0.15, 1.0), bdr_n))
		btn.add_theme_stylebox_override("focus",
				_make_btn_style(Color(0.13, 0.15, 0.25, 1.0), bdr_h))
		btn.add_theme_color_override("font_color",         Color(1.0,  0.95, 0.80, 1.0))
		btn.add_theme_color_override("font_hover_color",   Color(1.0,  0.85, 0.20, 1.0))
		btn.add_theme_color_override("font_pressed_color", Color(0.85, 0.72, 0.30, 1.0))
		btn.add_theme_constant_override("outline_size", 2)
		btn.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))

	# — Title labels —
	for title_path: String in [
		"MainPanel/VBox/Title",
		"PvPPanel/VBox/TitleLabel", "PvAIPanel/VBox/TitleLabel",
		"StatsPanel/VBox/Title", "SettingsPanel/VBox/Title",
	]:
		var lbl := get_node_or_null(title_path) as Label
		if lbl == null:
			continue
		lbl.add_theme_color_override("font_color",         Color(1.0, 0.85, 0.20, 1.0))
		lbl.add_theme_constant_override("outline_size", 4)
		lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))

func _connect_button_sounds() -> void:
	for btn_path: String in [
		"MainPanel/VBox/PvPBtn", "MainPanel/VBox/PvAIBtn",
		"MainPanel/VBox/StatsBtn", "MainPanel/VBox/SettingsBtn", "MainPanel/VBox/QuitBtn",
		"PvPPanel/VBox/StartBtn", "PvPPanel/VBox/BackBtn",
		"PvAIPanel/VBox/StartBtn", "PvAIPanel/VBox/BackBtn",
		"SettingsPanel/VBox/BackBtn", "StatsPanel/VBox/BackBtn",
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
