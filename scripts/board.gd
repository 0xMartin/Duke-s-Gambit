## board.gd
## Manages the visual 8x8 chessboard and tile highlighting.
## Each tile is a MeshInstance3D. Highlight overlays are separate
## transparent quads rendered just above the board surface.

class_name Board
extends Node3D

# ── Colours (easily tweakable) ────────────────────────────────────────────
const TILE_WHITE     := Color(0.90, 0.85, 0.75)
const TILE_BLACK     := Color(0.30, 0.20, 0.12)
const HL_SELECT      := Color(0.20, 0.85, 0.30, 0.75)  # selected piece
const HL_MOVE        := Color(0.20, 0.80, 0.25, 0.65)  # valid move
const HL_CAPTURE     := Color(0.90, 0.20, 0.15, 0.70)  # capture target
const HL_CHECK       := Color(1.00, 0.85, 0.00, 0.80)  # king in check

const TILE_SIZE      := 1.0   # world-units per square
const BLINK_SPEED    := 3.0   # radians/sec for sin() blink
const TILE_HEIGHT    := 0.05  # thickness of board tiles
const OVERLAY_OFFSET := 0.001 # tiny Y above tile surface

# ── Internal state ────────────────────────────────────────────────────────
var _tiles: Array = []         # [col][row] -> MeshInstance3D
var _overlays: Array = []      # [col][row] -> MeshInstance3D (highlight quad)
var _overlay_state: Array = [] # [col][row] -> { active, color, blink }
var _time: float = 0.0

# ── Initialisation ────────────────────────────────────────────────────────
func _ready() -> void:
	_build_board()

func _build_board() -> void:
	var tile_mesh  := BoxMesh.new()
	tile_mesh.size = Vector3(TILE_SIZE, TILE_HEIGHT, TILE_SIZE)

	var quad_mesh := PlaneMesh.new()
	quad_mesh.size = Vector2(TILE_SIZE, TILE_SIZE)

	for c in range(8):
		_tiles.append([])
		_overlays.append([])
		_overlay_state.append([])
		for r in range(8):
			# --- tile ---
			var tile_mat := StandardMaterial3D.new()
			tile_mat.albedo_color = TILE_WHITE if (c + r) % 2 == 0 else TILE_BLACK

			var tile := MeshInstance3D.new()
			tile.mesh = tile_mesh.duplicate()
			tile.material_override = tile_mat
			tile.position = _sq_to_world(Vector2i(c, r)) + Vector3(0, -TILE_HEIGHT * 0.5, 0)
			add_child(tile)
			_tiles[c].append(tile)

			# --- highlight overlay ---
			var ov_mat := StandardMaterial3D.new()
			ov_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			ov_mat.albedo_color  = Color(0, 0, 0, 0)
			ov_mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
			ov_mat.no_depth_test = false
			ov_mat.render_priority = 1

			var ov := MeshInstance3D.new()
			ov.mesh = quad_mesh.duplicate()
			ov.material_override = ov_mat
			ov.position = _sq_to_world(Vector2i(c, r)) + Vector3(0, OVERLAY_OFFSET, 0)
			ov.visible = false
			add_child(ov)
			_overlays[c].append(ov)
			_overlay_state[c].append({ "active": false, "color": Color.TRANSPARENT, "blink": true })

# ── Public API ────────────────────────────────────────────────────────────
func clear_highlights() -> void:
	for c in range(8):
		for r in range(8):
			_set_overlay(Vector2i(c, r), Color.TRANSPARENT, false, false)

func highlight_selected(sq: Vector2i) -> void:
	_set_overlay(sq, HL_SELECT, true, true)

func highlight_moves(moves: Array) -> void:
	for mv in moves:
		if mv.is_capture():
			_set_overlay(mv.to_sq, HL_CAPTURE, true, true)
		else:
			_set_overlay(mv.to_sq, HL_MOVE, true, true)

func highlight_check(sq: Vector2i) -> void:
	_set_overlay(sq, HL_CHECK, true, true)

## World position of the centre of a square (Y = 0 = top of board surface)
func sq_to_world(sq: Vector2i) -> Vector3:
	return _sq_to_world(sq)

## Convert a world XZ position to board square (returns (-1,-1) if off-board)
func world_to_sq(world_pos: Vector3) -> Vector2i:
	var c := int(floor(world_pos.x / TILE_SIZE + 4.0))
	var r := int(floor(world_pos.z / TILE_SIZE + 4.0))
	if c < 0 or c > 7 or r < 0 or r > 7:
		return Vector2i(-1, -1)
	return Vector2i(c, r)

## Centre of the entire board in world space
func board_center() -> Vector3:
	return Vector3(0, 0, 0)

# ── Internal ──────────────────────────────────────────────────────────────
func _sq_to_world(sq: Vector2i) -> Vector3:
	# Centre board at origin: columns a..h → x = -3.5..3.5
	return Vector3((sq.x - 3.5) * TILE_SIZE, 0.0, (sq.y - 3.5) * TILE_SIZE)

func _set_overlay(sq: Vector2i, color: Color, active: bool, blink: bool) -> void:
	var state := _overlay_state[sq.x][sq.y]
	state["active"] = active
	state["color"]  = color
	state["blink"]  = blink
	var ov: MeshInstance3D = _overlays[sq.x][sq.y]
	ov.visible = active
	if active:
		(ov.material_override as StandardMaterial3D).albedo_color = color

func _process(delta: float) -> void:
	_time += delta
	var alpha_mod := (sin(_time * BLINK_SPEED) * 0.5 + 0.5)  # 0..1
	for c in range(8):
		for r in range(8):
			var state := _overlay_state[c][r]
			if not state["active"] or not state["blink"]:
				continue
			var base_color: Color = state["color"]
			var blinked := Color(base_color.r, base_color.g, base_color.b,
								 base_color.a * (0.4 + 0.6 * alpha_mod))
			(_overlays[c][r].material_override as StandardMaterial3D).albedo_color = blinked
