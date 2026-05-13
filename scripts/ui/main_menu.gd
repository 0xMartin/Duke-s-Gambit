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

var _mode: String = "pvp"   # "pvp" or "pvai"
var _save: Node = null

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
	var container := $StatsPanel/ScrollContainer/VBox as VBoxContainer
	for child in container.get_children():
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
		container.add_child(lbl)

# ── Settings ───────────────────────────────────────────────────────────────
func _show_settings() -> void:
	_show_panel(_settings_panel)

func _on_ai_strength_changed(value: float) -> void:
	_ai_strength_label.text = "AI Strength: %d" % int(value)
