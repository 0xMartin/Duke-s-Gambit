## game_intro_animator.gd
## Plays the pre-game intro sequence: spawns each side's pieces with VFX
## while showing the player's name card full-screen.
## Added as a child of GameController in its _ready(); call play(gc) from
## start_game() instead of the old _play_intro_animation() coroutine.

class_name GameIntroAnimator
extends Node

# ── Constants ──────────────────────────────────────────────────────────────
const _PROMO_VFX_IMPACT_SCENE: PackedScene = preload("res://scenes/effects/spell.tscn")
const _INTRO_PIECE_INTERVAL  := 0.25   # seconds between successive piece appearances
const _INTRO_VFX_PIECE_DELAY := 0.10   # VFX fires this many seconds before piece becomes visible

const _INTRO_FONT: FontFile      = preload("res://assets/fonts/Montserrat-Bold.ttf")
const _INTRO_WHITE_QUEEN: Texture2D = preload("res://assets/textures/pieces/white_queen.svg")
const _INTRO_WHITE_KING:  Texture2D = preload("res://assets/textures/pieces/white_king.svg")
const _INTRO_BLACK_QUEEN: Texture2D = preload("res://assets/textures/pieces/black_queen.svg")
const _INTRO_BLACK_KING:  Texture2D = preload("res://assets/textures/pieces/black_king.svg")

# ── Overlay nodes (built in _ready) ───────────────────────────────────────
var _overlay:     CanvasLayer = null
var _name_label:  Label       = null
var _left_icon:   TextureRect = null
var _right_icon:  TextureRect = null

# ── Lifecycle ──────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_overlay()

# ── Public API ─────────────────────────────────────────────────────────────

## Main entry — call with `await intro_animator.play(self)` from GameController.
func play(gc: GameController) -> void:
	if gc._ui != null:
		gc._ui.visible = false
	gc._camera.lock_input()

	# Camera sways for the full shot duration.
	var sway_dur: float = 16.0 * _INTRO_PIECE_INTERVAL + 0.5
	var white_target := (gc._board.sq_to_world(Vector2i(3, 0)) \
		+ gc._board.sq_to_world(Vector2i(4, 0))) * 0.5 + Vector3(0, 0.5, 0)
	var black_target := (gc._board.sq_to_world(Vector2i(3, 7)) \
		+ gc._board.sq_to_world(Vector2i(4, 7))) * 0.5 + Vector3(0, 0.5, 0)

	# Phase 1 — white side.
	gc._camera.set_intro_view(ChessEnums.PieceColor.WHITE, white_target, sway_dur)
	_show_label(gc._player_names[ChessEnums.PieceColor.WHITE], ChessEnums.PieceColor.WHITE)
	await _spawn_side(gc, ChessEnums.PieceColor.WHITE)
	await get_tree().create_timer(0.5).timeout
	_hide_label()

	# Phase 2 — black side.
	gc._camera.set_intro_view(ChessEnums.PieceColor.BLACK, black_target, sway_dur)
	_show_label(gc._player_names[ChessEnums.PieceColor.BLACK], ChessEnums.PieceColor.BLACK)
	await _spawn_side(gc, ChessEnums.PieceColor.BLACK)
	await get_tree().create_timer(0.4).timeout
	_hide_label()

	gc._camera.stop_intro_sway()
	gc._camera.unlock_input()
	if gc._ui != null:
		gc._ui.visible = true

# ── Internal helpers ───────────────────────────────────────────────────────

func _spawn_side(gc: GameController, color: int) -> void:
	var squares: Array = []
	for c in range(8):
		for r in range(8):
			var p: Variant = gc._chess.board[c][r]
			if p == null:
				continue
			var pd: Dictionary = p
			if pd["color"] == color:
				squares.append(Vector2i(c, r))
	squares.shuffle()
	for sq in squares:
		var p: Variant = gc._chess.board[sq.x][sq.y]
		if p == null:
			continue
		var pd: Dictionary = p
		var piece := gc._spawn_piece(sq, pd["type"], pd["color"])
		if piece == null:
			continue
		piece.visible = false
		_spawn_vfx(gc._board.sq_to_world(sq) + Vector3(0, 0.5, 0))
		await get_tree().create_timer(_INTRO_VFX_PIECE_DELAY).timeout
		if is_instance_valid(piece):
			piece.visible = true
		await get_tree().create_timer(_INTRO_PIECE_INTERVAL - _INTRO_VFX_PIECE_DELAY).timeout

func _spawn_vfx(world_pos: Vector3) -> void:
	var cam_cfg: Node = get_node_or_null("/root/CameraConfig")
	var vfx: Node3D = _PROMO_VFX_IMPACT_SCENE.instantiate() as Node3D
	vfx.position = world_pos
	if cam_cfg != null and cam_cfg.get("vfx_enabled") == false:
		vfx.visible = false    # hide visuals; audio in the scene still plays
	get_tree().root.add_child(vfx)

func _show_label(player_name: String, color: int) -> void:
	if _overlay == null:
		return
	var is_white := color == ChessEnums.PieceColor.WHITE
	_left_icon.texture  = _INTRO_WHITE_QUEEN if is_white else _INTRO_BLACK_QUEEN
	_right_icon.texture = _INTRO_WHITE_KING  if is_white else _INTRO_BLACK_KING
	_name_label.text    = player_name
	var accent := Color(1.0, 0.95, 0.76) if is_white else Color(0.74, 0.88, 1.0)
	_name_label.add_theme_color_override("font_color", accent)
	_left_icon.modulate  = accent
	_right_icon.modulate = accent
	_overlay.visible = true

func _hide_label() -> void:
	if _overlay != null:
		_overlay.visible = false

# ── Overlay construction ───────────────────────────────────────────────────

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 10
	_overlay.visible = false
	add_child(_overlay)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color                   = Color(0.0, 0.0, 0.0, 0.45)
	style.corner_radius_top_left     = 10
	style.corner_radius_top_right    = 10
	style.corner_radius_bottom_left  = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left   = 36.0
	style.content_margin_right  = 36.0
	style.content_margin_top    = 18.0
	style.content_margin_bottom = 18.0
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 22)
	panel.add_child(hbox)

	_left_icon = TextureRect.new()
	_left_icon.custom_minimum_size = Vector2(54, 54)
	_left_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_left_icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	hbox.add_child(_left_icon)

	_name_label = Label.new()
	_name_label.add_theme_font_override("font", _INTRO_FONT)
	_name_label.add_theme_font_size_override("font_size", 50)
	_name_label.add_theme_color_override("font_color", Color.WHITE)
	_name_label.add_theme_constant_override("outline_size", 20)
	_name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_name_label)

	_right_icon = TextureRect.new()
	_right_icon.custom_minimum_size = Vector2(54, 54)
	_right_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_right_icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	hbox.add_child(_right_icon)
