## save_manager.gd
## Autoload singleton. Persists player profiles (name, stats) to user://saves/players.json

extends Node

const SAVE_PATH := "user://saves/players.json"

# Data structure per player:
# { "name": String, "elo": int, "wins": int, "losses": int, "draws": int,
#   "total_moves": int, "total_move_time_ms": int, "games_played": int }

var players: Dictionary = {}   # keyed by lowercase name

func _ready() -> void:
	load_data()

# ── Load / Save ────────────────────────────────────────────────────────────
func load_data() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_error("SaveManager: cannot open %s" % SAVE_PATH)
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		players = parsed as Dictionary
	else:
		push_error("SaveManager: corrupt save file")

func save_data() -> void:
	DirAccess.make_dir_recursive_absolute("user://saves")
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot write %s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(players, "\t"))
	f.close()

# ── Player management ──────────────────────────────────────────────────────
func get_all_player_names() -> Array:
	return players.keys()

func player_exists(name: String) -> bool:
	return players.has(name.to_lower())

func get_player(name: String) -> Dictionary:
	var key := name.to_lower()
	if not players.has(key):
		return {}
	return players[key].duplicate()

func create_player(name: String) -> void:
	var key := name.to_lower()
	if players.has(key):
		return
	players[key] = {
		"name": name,
		"elo": 1200,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"total_moves": 0,
		"total_move_time_ms": 0,
		"games_played": 0,
	}
	save_data()

## Call at game end. results = { winner_name, loser_name } or { draw: true, p1, p2 }
func record_game_result(winner: String, loser: String, is_draw: bool,
		w_moves: int, l_moves: int, w_time_ms: int, l_time_ms: int) -> void:
	_ensure_player(winner)
	_ensure_player(loser)
	var wk := winner.to_lower()
	var lk := loser.to_lower()

	if is_draw:
		players[wk]["draws"] += 1
		players[lk]["draws"] += 1
	else:
		players[wk]["wins"] += 1
		players[lk]["losses"] += 1

	players[wk]["games_played"] += 1
	players[lk]["games_played"] += 1
	players[wk]["total_moves"] += w_moves
	players[lk]["total_moves"] += l_moves
	players[wk]["total_move_time_ms"] += w_time_ms
	players[lk]["total_move_time_ms"] += l_time_ms

	# Simple ELO update (K=32)
	if not is_draw:
		var elo_w: int = players[wk]["elo"]
		var elo_l: int = players[lk]["elo"]
		var expected_w := 1.0 / (1.0 + pow(10.0, (elo_l - elo_w) / 400.0))
		var k := 32
		players[wk]["elo"] = elo_w + int(k * (1.0 - expected_w))
		players[lk]["elo"] = elo_l + int(k * (0.0 - (1.0 - expected_w)))

	save_data()

func average_move_time_ms(name: String) -> float:
	var p := get_player(name)
	if p.is_empty() or p["total_moves"] == 0:
		return 0.0
	return float(p["total_move_time_ms"]) / float(p["total_moves"])

func _ensure_player(name: String) -> void:
	if not player_exists(name):
		create_player(name)
