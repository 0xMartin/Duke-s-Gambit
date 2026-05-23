## game_board_input.gd
## Handles all human-side board interaction: click-to-select, click-to-move,
## piece outline highlights (selected / attack / check), pawn-promotion
## trigger, and board raycasting.
## Added as a child of GameController in its _ready(); call setup(gc) once.

class_name GameBoardInput
extends Node

# Outline colours (kept in sync with game_controller constants for visuals).
const OUTLINE_SELECTED := Color(0.00, 1.00, 0.15, 1.0)
const OUTLINE_ATTACK   := Color(1.00, 0.05, 0.00, 1.0)
const OUTLINE_CHECK    := Color(1.00, 0.05, 0.00, 1.0)
const OUTLINE_WIDTH    := 0.5

# Emitted when the player's pawn reaches the back rank and must be promoted.
signal promotion_requested(sq: Vector2i, color: int)

# ── State ──────────────────────────────────────────────────────────────────
var _gc: GameController = null   # set by setup()

var selected_sq: Vector2i      = Vector2i(-1, -1)
var selected_piece: BasePiece  = null
var legal_from_selected: Array = []
var pending_promotion_moves: Array = []

var _attack_outlined: Array[BasePiece] = []
var _check_king: BasePiece = null

# ── Setup ──────────────────────────────────────────────────────────────────

func setup(gc: GameController) -> void:
	_gc = gc

# ── Public helpers (called by GameController) ──────────────────────────────

## Clears selection, legal moves, and board highlights.  Call at turn start
## and when sending a move in online mode.
func clear_selection() -> void:
	if _gc == null:
		return
	deselect()
	selected_sq = Vector2i(-1, -1)
	legal_from_selected.clear()
	_gc._board.clear_highlights()

## Removes the outline from the currently selected piece and all attack targets.
func deselect() -> void:
	if selected_piece != null and is_instance_valid(selected_piece):
		selected_piece.clear_outline()
	for bp in _attack_outlined:
		if bp != null and is_instance_valid(bp):
			bp.clear_outline()
	_attack_outlined.clear()
	selected_piece = null

## Removes the red outline from the king that was in check.
func clear_check_outline() -> void:
	if _check_king != null and is_instance_valid(_check_king):
		_check_king.clear_outline()
	_check_king = null

## Outlines the king of ``color`` in the check colour.
func apply_check_outline(color: int) -> void:
	clear_check_outline()
	if _gc == null:
		return
	var king_sq := _gc._chess._find_king(color)
	var king_piece: BasePiece = _gc._sq_pieces.get(king_sq) as BasePiece
	if king_piece != null and is_instance_valid(king_piece):
		king_piece.set_outline(OUTLINE_CHECK, OUTLINE_WIDTH)
		_check_king = king_piece

# ── Godot input callback ───────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if _gc == null or _gc._busy:
		return
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return

	var color: int = _gc._chess.active_color
	var ctrl: PlayerController = _gc._controllers[color] as PlayerController
	if ctrl.is_ai:
		return   # ignore clicks during AI or replay turns

	var clicked_sq := _raycast(mb.position)
	if clicked_sq.x < 0:
		return
	var human_ctrl := ctrl as HumanController
	if human_ctrl == null:
		return

	_handle_click(clicked_sq, human_ctrl)

# ── Click handling ─────────────────────────────────────────────────────────

func _handle_click(sq: Vector2i, ctrl: HumanController) -> void:
	var color := _gc._chess.active_color

	# Is this square a valid destination for the selected piece?
	for mv in legal_from_selected:
		if mv.to_sq == sq:
			if mv.move_type == ChessEnums.MoveType.PROMOTION \
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE:
				_trigger_promotion(sq, color)
				return
			_gc._board.clear_highlights()
			deselect()
			ctrl.try_move(mv)
			return

	# Click on own piece → select it.
	var piece := _gc._chess.get_piece(sq)
	if not piece.is_empty() and piece["color"] == color:
		deselect()
		selected_sq = sq
		_select(sq)
		legal_from_selected = ctrl.get_legal_moves_from(sq)
		_highlight_attacks(legal_from_selected)
		_gc._board.clear_highlights()
		_gc._board.highlight_selected(sq)
		_gc._board.highlight_moves(legal_from_selected)
		if _gc._sfx_select != null:
			_gc._sfx_select.play()
		# Re-draw check highlight if the king is still in check.
		if _gc._chess.get_game_state() == ChessEnums.GameState.CHECK:
			_gc._board.highlight_check(_gc._chess._find_king(color))
			apply_check_outline(color)
		return

	# Empty / enemy square with no selection → deselect.
	clear_selection()

# ── Selection helpers ──────────────────────────────────────────────────────

func _select(sq: Vector2i) -> void:
	var bp: BasePiece = _gc._sq_pieces.get(sq) as BasePiece
	if bp:
		selected_piece = bp
		selected_piece.set_outline(OUTLINE_SELECTED, OUTLINE_WIDTH)

func _highlight_attacks(moves: Array) -> void:
	_attack_outlined.clear()
	var seen := {}
	for mv in moves:
		if not mv.is_capture():
			continue
		var target_sq: Vector2i = mv.to_sq
		if mv.move_type == ChessEnums.MoveType.EN_PASSANT:
			target_sq = Vector2i(mv.to_sq.x, mv.from_sq.y)
		var key := "%d,%d" % [target_sq.x, target_sq.y]
		if seen.has(key):
			continue
		seen[key] = true
		var target: BasePiece = _gc._sq_pieces.get(target_sq) as BasePiece
		if target != null and is_instance_valid(target):
			target.set_outline(OUTLINE_ATTACK, OUTLINE_WIDTH)
			_attack_outlined.append(target)

# ── Pawn promotion ─────────────────────────────────────────────────────────

func _trigger_promotion(sq: Vector2i, color: int) -> void:
	pending_promotion_moves.clear()
	for mv in legal_from_selected:
		if mv.to_sq == sq and (
			mv.move_type == ChessEnums.MoveType.PROMOTION
			or mv.move_type == ChessEnums.MoveType.PROMOTION_CAPTURE
		):
			pending_promotion_moves.append(mv)
	if pending_promotion_moves.is_empty():
		return
	_gc._busy = true
	_gc._board.clear_highlights()
	deselect()
	emit_signal("promotion_requested", sq, color)

# ── Board raycast ──────────────────────────────────────────────────────────

func _raycast(screen_pos: Vector2) -> Vector2i:
	var camera := _gc._camera.get_node("Camera3D") as Camera3D
	if camera == null:
		return Vector2i(-1, -1)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir    := camera.project_ray_normal(screen_pos)
	if abs(ray_dir.y) < 0.001:
		return Vector2i(-1, -1)
	var t := -ray_origin.y / ray_dir.y
	if t < 0:
		return Vector2i(-1, -1)
	var hit := ray_origin + ray_dir * t
	return _gc._board.world_to_sq(hit)
