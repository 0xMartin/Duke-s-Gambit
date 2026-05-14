## main_menu.gd
## Main menu: PvP, PvAI, Stats, Settings, Quit.
## Handles player name selection / creation before starting a game.

extends Control

# ── Node refs ──────────────────────────────────────────────────────────────
@onready var _main_panel:     Control = $MainPanel
@onready var _name_panel:     Control = $NamePanel
@onready var _stats_panel:    Control = $StatsPanel
@onready var _settings_panel: Control = $SettingsPanel

# Name panel
@onready var _p1_edit:   LineEdit    = $NamePanel/VBox/P1Row/LineEdit
@onready var _p1_list:   ItemList    = $NamePanel/VBox/P1Row/ItemList
@onready var _p2_edit:   LineEdit    = $NamePanel/VBox/P2Row/LineEdit
@onready var _p2_list:   ItemList    = $NamePanel/VBox/P2Row/ItemList
@onready var _p2_label:  Label       = $NamePanel/VBox/P2Row/Label
@onready var _time_opt:  OptionButton = $NamePanel/VBox/TimeControlRow/TimeOption

# Settings
@onready var _ai_strength_slider: HSlider = $SettingsPanel/VBox/AIStrengthRow/HSlider
@onready var _ai_strength_label:  Label   = $SettingsPanel/VBox/AIStrengthRow/Label
@onready var _pan_sens_slider:    HSlider  = $SettingsPanel/VBox/PanSensRow/PanSensSlider
@onready var _pan_sens_label:     Label    = $SettingsPanel/VBox/PanSensRow/PanSensLabel
@onready var _tilt_sens_slider:   HSlider  = $SettingsPanel/VBox/TiltSensRow/TiltSensSlider
@onready var _tilt_sens_label:    Label    = $SettingsPanel/VBox/TiltSensRow/TiltSensLabel
@onready var _kill_cam_check:     CheckBox = $SettingsPanel/VBox/KillCamRow/KillCamCheck

var _mode: String = "pvp"   # "pvp" or "pvai"
var _save: Node = null
var _stats_vbox:        VBoxContainer = null
var _face_player_check: CheckBox      = null

# ──────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_save = get_node("/root/SaveManager")
	_show_panel(_main_panel)
	_setup_signals()
	# Populate time control options
	_time_opt.add_item("No limit",  0)
	_time_opt.add_item("3 min",     3 * 60 * 1000)
	_time_opt.add_item("5 min",     5 * 60 * 1000)
	_time_opt.add_item("10 min",   10 * 60 * 1000)
	_time_opt.add_item("15 min",   15 * 60 * 1000)
	_time_opt.select(3)   # default: 10 min
	_stats_vbox = get_node_or_null("StatsPanel/VBox/ScrollContainer/VBox") as VBoxContainer
	_setup_settings_extra()
	_setup_font_sizes()
	_apply_roblox_theme()

func _setup_signals() -> void:
	$MainPanel/VBox/PvPBtn.pressed.connect(   func(): _start_name_entry("pvp"))
	$MainPanel/VBox/PvAIBtn.pressed.connect(  func(): _start_name_entry("pvai"))
	$MainPanel/VBox/StatsBtn.pressed.connect( _show_stats)
	$MainPanel/VBox/SettingsBtn.pressed.connect(_show_settings)
	$MainPanel/VBox/QuitBtn.pressed.connect(  get_tree().quit)

	$NamePanel/VBox/StartBtn.pressed.connect(_on_start_pressed)
	$NamePanel/VBox/BackBtn.pressed.connect(  func(): _show_panel(_main_panel))

	$StatsPanel/BackBtn.pressed.connect(      func(): _show_panel(_main_panel))
	$SettingsPanel/VBox/BackBtn.pressed.connect(func(): _show_panel(_main_panel))

	_ai_strength_slider.value_changed.connect(_on_ai_strength_changed)
	_pan_sens_slider.value_changed.connect(_on_pan_sens_changed)
	_tilt_sens_slider.value_changed.connect(_on_tilt_sens_changed)
	_kill_cam_check.toggled.connect(_on_kill_cam_toggled)

	_p1_list.item_selected.connect(func(idx): _p1_edit.text = _p1_list.get_item_text(idx))
	_p2_list.item_selected.connect(func(idx): _p2_edit.text = _p2_list.get_item_text(idx))

# ── Panel navigation ───────────────────────────────────────────────────────
func _show_panel(panel: Control) -> void:
	for p in [_main_panel, _name_panel, _stats_panel, _settings_panel]:
		p.visible = (p == panel)

# ── Name entry ─────────────────────────────────────────────────────────────
func _start_name_entry(mode: String) -> void:
	_mode = mode
	_populate_name_lists()
	_p2_label.visible = (mode == "pvp")
	_p2_edit.visible  = (mode == "pvp")
	_p2_list.visible  = (mode == "pvp")
	_show_panel(_name_panel)

func _populate_name_lists() -> void:
	_p1_list.clear()
	_p2_list.clear()
	if _save == null:
		return
	for n in _save.get_all_player_names():
		_p1_list.add_item(_save.get_player(n)["name"])
		_p2_list.add_item(_save.get_player(n)["name"])
	# Auto-select random players (different ones for P1 and P2)
	var count: int = _p1_list.get_item_count()
	if count == 0:
		return
	var idx1: int = randi() % count
	_p1_list.select(idx1)
	_p1_edit.text = _p1_list.get_item_text(idx1)
	if _mode == "pvp" and count > 1:
		var idx2: int = idx1
		while idx2 == idx1:
			idx2 = randi() % count
		_p2_list.select(idx2)
		_p2_edit.text = _p2_list.get_item_text(idx2)
	elif _mode == "pvp":
		_p2_list.select(0)
		_p2_edit.text = _p2_list.get_item_text(0)

func _on_start_pressed() -> void:
	var p1 := _p1_edit.text.strip_edges()
	var p2 := _p2_edit.text.strip_edges() if _mode == "pvp" else "AI"

	if p1.is_empty():
		p1 = "Player 1"
	if p2.is_empty() and _mode == "pvp":
		p2 = "Player 2"

	if _save:
		if not _save.player_exists(p1):
			_save.create_player(p1)
		if _mode == "pvp" and not _save.player_exists(p2):
			_save.create_player(p2)

	var strength := int(_ai_strength_slider.value)
	var time_ms: int = _time_opt.get_item_id(_time_opt.selected)
	hide()   # prevent one-frame overlap when game scene loads
	var game_scene := load("res://scenes/game.tscn").instantiate() as GameController
	get_tree().root.add_child(game_scene)
	game_scene.setup(p1, p2, false, _mode == "pvai", strength, time_ms)
	game_scene.start_game()
	queue_free()

# ── Stats ──────────────────────────────────────────────────────────────────
func _show_stats() -> void:
	_populate_stats()
	_show_panel(_stats_panel)

func _populate_stats() -> void:
	for child in _stats_vbox.get_children():
		child.queue_free()
	if _save == null:
		return
	for key: String in _save.get_all_player_names():
		var p: Dictionary = _save.get_player(key)
		var avg_ms: float = _save.average_move_time_ms(key)
		var avg_s: String = "%.1fs" % (avg_ms / 1000.0) if avg_ms > 0 else "-"
		var lbl := Label.new()
		lbl.text = "%s  |  ELO: %d  |  W:%d L:%d D:%d  |  Avg move: %s  |  Games: %d" % [
			p["name"], p["elo"],
			p["wins"], p["losses"], p["draws"],
			avg_s, p["games_played"]
		]
		_stats_vbox.add_child(lbl)

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
	_show_panel(_settings_panel)

func _on_ai_strength_changed(value: float) -> void:
	_ai_strength_label.text = "AI Strength: %d" % int(value)

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
	var vbox := _settings_panel.get_node_or_null("VBox") as VBoxContainer
	if vbox == null:
		return
	var row := HBoxContainer.new()
	row.name = "FacePlayerRow"
	var lbl := Label.new()
	lbl.text = "Auto-rotate camera after move"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_face_player_check = CheckBox.new()
	_face_player_check.name = "FacePlayerCheck"
	row.add_child(lbl)
	row.add_child(_face_player_check)
	vbox.add_child(row)
	_face_player_check.toggled.connect(_on_face_player_toggled)

func _on_face_player_toggled(pressed: bool) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	if cam_cfg:
		cam_cfg.set("face_player_after_move", pressed)
		cam_cfg.save_config()

func _setup_font_sizes() -> void:
	# Title
	var main_title := get_node_or_null("MainPanel/VBox/Title") as Label
	if main_title:
		main_title.add_theme_font_size_override("font_size", 72)
	for lbl_path: String in ["NamePanel/VBox/TitleLabel", "StatsPanel/VBox/Title",
			"SettingsPanel/VBox/Title"]:
		var lbl := get_node_or_null(lbl_path) as Label
		if lbl:
			lbl.add_theme_font_size_override("font_size", 48)
	# Buttons
	for btn_path: String in [
		"MainPanel/VBox/PvPBtn", "MainPanel/VBox/PvAIBtn",
		"MainPanel/VBox/StatsBtn", "MainPanel/VBox/SettingsBtn", "MainPanel/VBox/QuitBtn",
		"NamePanel/VBox/StartBtn", "NamePanel/VBox/BackBtn",
		"SettingsPanel/VBox/BackBtn", "StatsPanel/BackBtn",
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
	]:
		var lbl := get_node_or_null(lbl_path) as Label
		if lbl:
			lbl.add_theme_font_size_override("font_size", 28)

# ── Roblox-like visual theme ──────────────────────────────────────────────────
func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color    = Color(0.05, 0.06, 0.12, 0.93)
	s.border_color = Color(0.82, 0.62, 0.10, 1.0)
	s.set_border_width_all(4)
	s.set_corner_radius_all(14)
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
	for p: Control in [_main_panel, _name_panel, _stats_panel, _settings_panel]:
		p.add_theme_stylebox_override("panel", ps)

	# — Buttons —
	var bdr_n := Color(0.68, 0.50, 0.10, 1.0)
	var bdr_h := Color(1.00, 0.82, 0.20, 1.0)
	for btn_path: String in [
		"MainPanel/VBox/PvPBtn", "MainPanel/VBox/PvAIBtn",
		"MainPanel/VBox/StatsBtn", "MainPanel/VBox/SettingsBtn", "MainPanel/VBox/QuitBtn",
		"NamePanel/VBox/StartBtn", "NamePanel/VBox/BackBtn",
		"SettingsPanel/VBox/BackBtn", "StatsPanel/BackBtn",
	]:
		var btn := get_node_or_null(btn_path) as Button
		if btn == null:
			continue
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
		"NamePanel/VBox/TitleLabel", "StatsPanel/VBox/Title", "SettingsPanel/VBox/Title",
	]:
		var lbl := get_node_or_null(title_path) as Label
		if lbl == null:
			continue
		lbl.add_theme_color_override("font_color",         Color(1.0, 0.85, 0.20, 1.0))
		lbl.add_theme_constant_override("outline_size", 4)
		lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
