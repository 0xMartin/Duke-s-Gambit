## AI player controller with difficulty levels
## Uses ChessAIEngine for move selection via minimax + alpha-beta pruning

class_name AIController
extends PlayerController

# Difficulty modes with search depth and time limit
enum Difficulty {
	CASUAL = 1,      # 4 plies
	CHALLENGER = 2,  # 8 plies
	MASTER = 3,      # 12 plies
	GRANDMASTER = 4, # 15 plies
}

var engine: ChessAIEngine = null
var difficulty: int = Difficulty.CASUAL
var _search_result: ChessMove = null
var _search_in_progress: bool = false
var _parallel_results: Array = []
var _result_mutex := Mutex.new()


func _init() -> void:
	is_ai = true
	player_name = "AI"
	if engine == null:
		engine = ChessAIEngine.new()

func request_move(board: ChessBoardState, legal_moves: Array) -> void:
	if legal_moves.is_empty():
		return
	if _search_in_progress:
		return

	# Get difficulty parameters
	var search_depth := 4
	var time_limit_ms := 2000
	match difficulty:
		Difficulty.CASUAL:
			search_depth = 4
			time_limit_ms = 2000
		Difficulty.CHALLENGER:
			search_depth = 8
			time_limit_ms = 4000
		Difficulty.MASTER:
			search_depth = 12
			time_limit_ms = 8000
		Difficulty.GRANDMASTER:
			search_depth = 15
			time_limit_ms = 12000

	var t := Engine.get_main_loop() as SceneTree

	_search_in_progress = true
	_search_result = null

	var board_state: AIBitboardState = AIBitboardState.from_chess_board(board)
	var legal_moves_copy: Array = legal_moves.duplicate()
	var fallback_move: ChessMove = legal_moves[0]
	var worker_count: int = _recommended_worker_count(legal_moves_copy.size())
	if worker_count <= 1:
		await _run_single_worker_search(board_state, legal_moves_copy, search_depth, time_limit_ms, fallback_move, t)
	else:
		await _run_parallel_root_search(board_state, legal_moves_copy, search_depth, time_limit_ms, fallback_move, worker_count, t)

	_search_in_progress = false

	var chosen: ChessMove = _search_result
	if chosen == null:
		chosen = fallback_move

	emit_signal("move_chosen", chosen)

func _run_single_worker_search(state: AIBitboardState, legal_moves: Array, search_depth: int, time_limit_ms: int, fallback_move: ChessMove, tree: SceneTree) -> void:
	var deadline_ms: int = Time.get_ticks_msec() + time_limit_ms
	var task_id := WorkerThreadPool.add_task(
		_run_search_task.bind(state, legal_moves, search_depth, deadline_ms, fallback_move),
		false,
		"Chess AI Search"
	)
	await _wait_for_tasks([task_id], tree)
	WorkerThreadPool.wait_for_task_completion(task_id)

func _run_parallel_root_search(state: AIBitboardState, legal_moves: Array, search_depth: int, time_limit_ms: int, fallback_move: ChessMove, worker_count: int, tree: SceneTree) -> void:
	var deadline_ms: int = Time.get_ticks_msec() + time_limit_ms
	var move_chunks: Array = _split_root_moves(legal_moves, worker_count)
	_parallel_results = []
	_parallel_results.resize(move_chunks.size())
	var task_ids: Array = []

	for idx in range(move_chunks.size()):
		var chunk: Array = move_chunks[idx]
		if chunk.is_empty():
			continue
		var task_id := WorkerThreadPool.add_task(
			_run_parallel_chunk_task.bind(idx, state.duplicate_state(), chunk, search_depth, deadline_ms, fallback_move),
			false,
			"Chess AI Root Search %d" % idx
		)
		task_ids.append(task_id)

	await _wait_for_tasks(task_ids, tree)
	for task_id in task_ids:
		WorkerThreadPool.wait_for_task_completion(task_id)

	var best_move: ChessMove = fallback_move
	var best_score: int = -100000
	var best_depth: int = -1
	for result in _parallel_results:
		if result == null:
			continue
		var result_dict: Dictionary = result
		if result_dict.is_empty():
			continue
		var reached_depth: int = int(result_dict.get("reached_depth", -1))
		var score: int = int(result_dict.get("score", -100000))
		var move := result_dict.get("move") as ChessMove
		if move == null:
			continue
		if reached_depth > best_depth or (reached_depth == best_depth and score > best_score):
			best_depth = reached_depth
			best_score = score
			best_move = move

	_search_result = best_move

func _wait_for_tasks(task_ids: Array, tree: SceneTree) -> void:
	if task_ids.is_empty():
		return
	while true:
		var all_done := true
		for task_id in task_ids:
			if not WorkerThreadPool.is_task_completed(task_id):
				all_done = false
				break
		if all_done:
			return
		if tree:
			await tree.process_frame
		else:
			return

func _run_search_task(state: AIBitboardState, legal_moves: Array, search_depth: int, deadline_ms: int, fallback_move: ChessMove) -> void:
	var local_engine := ChessAIEngine.new()
	var result: Dictionary = local_engine.search_root_subset(state, legal_moves, search_depth, deadline_ms)
	var chosen := result.get("move") as ChessMove
	_result_mutex.lock()
	_search_result = chosen if chosen != null else fallback_move
	_result_mutex.unlock()

func _run_parallel_chunk_task(slot: int, state: AIBitboardState, legal_moves: Array, search_depth: int, deadline_ms: int, fallback_move: ChessMove) -> void:
	var local_engine := ChessAIEngine.new()
	var result: Dictionary = local_engine.search_root_subset(state, legal_moves, search_depth, deadline_ms)
	if result.get("move") == null:
		result["move"] = fallback_move
	_result_mutex.lock()
	_parallel_results[slot] = result
	_result_mutex.unlock()

func _recommended_worker_count(root_move_count: int) -> int:
	if root_move_count <= 1:
		return 1
	var cpu_budget: int = maxi(OS.get_processor_count() - 1, 1)
	var device_cap: int = 2 if OS.has_feature("mobile") else 4
	match difficulty:
		Difficulty.CASUAL:
			device_cap = 1
		Difficulty.CHALLENGER:
			device_cap = mini(device_cap, 2)
		_:
			pass
	return mini(root_move_count, maxi(1, mini(cpu_budget, device_cap)))

func _split_root_moves(moves: Array, worker_count: int) -> Array:
	var chunks: Array = []
	for _idx in range(worker_count):
		chunks.append([])
	for idx in range(moves.size()):
		chunks[idx % worker_count].append(moves[idx])
	return chunks
