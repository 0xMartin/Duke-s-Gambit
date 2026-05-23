## board_notation_highlighter.gd
## Attached to the BoardNotation Node3D in game.tscn.
## Highlights the rank and file Label3D children that correspond to the
## destination square of the last move, and resets the previous ones.

class_name BoardNotationHighlighter
extends Node3D

## Resting colour for all labels (matches the authored modulate in game.tscn).
const DEFAULT_COLOR   := Color(0.807098, 0.742497, 0.677341, 1.0)   # #cebdad
## Highlight colour applied to the rank and file of the last move's target square.
const HIGHLIGHT_COLOR := Color(0.984314, 0.8, 0.133333, 1.0)        # warm yellow

# Currently highlighted label nodes (null when none).
var _prev_rank: Label3D = null
var _prev_file: Label3D = null

# ── Public API ─────────────────────────────────────────────────────────────

## Highlight the rank and file labels for ``to_sq``.
## Uses the engine's internal (mirrored) coordinate frame:
##   x = column 0–7  (col 0 → file H … col 7 → file A)
##   y = rank  0–7   (row 0 → rank 1 … row 7 → rank 8)
func highlight(to_sq: Vector2i) -> void:
	_reset_prev()
	var file_letter := "HGFEDCBA"[to_sq.x]
	var rank_lbl := get_node_or_null("Label%d" % (to_sq.y + 1)) as Label3D
	var file_lbl := get_node_or_null("Label%s" % file_letter) as Label3D
	if rank_lbl:
		rank_lbl.modulate = HIGHLIGHT_COLOR
		_prev_rank = rank_lbl
	if file_lbl:
		file_lbl.modulate = HIGHLIGHT_COLOR
		_prev_file = file_lbl

## Reset any currently highlighted labels back to the default colour.
func reset_highlight() -> void:
	_reset_prev()

# ── Private ────────────────────────────────────────────────────────────────

func _reset_prev() -> void:
	if _prev_rank:
		_prev_rank.modulate = DEFAULT_COLOR
		_prev_rank = null
	if _prev_file:
		_prev_file.modulate = DEFAULT_COLOR
		_prev_file = null
