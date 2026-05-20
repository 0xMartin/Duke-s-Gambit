# Duke's AI (GDExtension)

Native C++ chess AI backend for Duke's Gambit (Godot 4). Exposes a single
class `DukesAINative` to GDScript via GDExtension. All chess logic — board
representation, move generation, search, and evaluation — lives here; the
Godot side only serialises the position and reads back the chosen move.

---

## Architecture

```
ai_constants.h   — board types, enums, magic-bitboard externs
ai_state.h/.cpp  — BoardState, MoveList, move generation, Zobrist hashing
ai_eval.h/.cpp   — tapered PeSTO PSQT evaluation (MG + EG blended by phase)
ai_search.h/.cpp — iterative-deepening negamax + all search heuristics
dukes_ai_native  — GDExtension class; bridges Godot ↔ search
register_types   — GDExtension init/deinit (called by Godot loader)
```

### Search features

| Feature | Detail |
|---|---|
| Algorithm | Fail-soft Negamax with Principal Variation Search (PVS) |
| Transposition table | Lockless, 1 M × 16 B entries (~16 MiB), shared across threads |
| Quiescence search | Captures + delta pruning |
| Null-move pruning | Adaptive R (2 or 3 plies) |
| Reverse futility pruning | Static eval − margin ≥ beta → cutoff |
| Late Move Reductions (LMR) | Reduces depth for late quiet moves at non-shallow nodes |
| Aspiration windows | Iterative-deepening reuses prior score; re-searches on fail-high/low |
| Move ordering | TT move → captures (MVV/LVA) → killers × 2 → history heuristic |
| History heuristic | Bonus on beta-cutoff quiet moves; malus on quiet moves that failed |
| Killer moves | 2 killer slots per ply |
| Lazy SMP | 1–4 threads (`std::thread::hardware_concurrency()`, capped at 4); shared TT + global stop flag; per-thread `SearchState` / `SearchContext` |
| Time management | Soft limit (stop after current iteration) + hard limit (abort mid-search via `global_stop`) |

### Evaluation

Tapered PeSTO piece-square tables (Ronald Friederich, public domain).
Material values and PSQT are merged into a single 64-entry table per piece,
pre-mirrored for Black, so the hot path is a plain bitboard sum.
Game phase is computed from remaining material and used to blend
middlegame and endgame scores.

---

## 1) Prerequisites

- Python 3 (SCons requires it)
- SCons (`pip install scons`)
- C++ toolchain for the target platform
- Godot C++ bindings (`godot-cpp`) checked out into `native/dukes_ai/godot-cpp`

---

## 2) Build godot-cpp

Run once per platform/arch combination, from `native/dukes_ai`:

```bash
# macOS arm64 (Apple Silicon)
scons -C godot-cpp platform=macos target=template_release arch=arm64
scons -C godot-cpp platform=macos target=template_debug  arch=arm64

# macOS x86_64 (Intel / Rosetta)
scons -C godot-cpp platform=macos target=template_release arch=x86_64

# Linux x86_64
scons -C godot-cpp platform=linux target=template_release arch=x86_64
scons -C godot-cpp platform=linux target=template_debug  arch=x86_64

# Windows x86_64 (cross-compile or native)
scons -C godot-cpp platform=windows target=template_release arch=x86_64
```

---

## 3) Build the extension

From `native/dukes_ai` (same cwd as above):

```bash
# macOS arm64 — both targets
scons platform=macos target=template_release arch=arm64 -j8
scons platform=macos target=template_debug  arch=arm64 -j8

# Linux x86_64
scons platform=linux target=template_release arch=x86_64 -j8
scons platform=linux target=template_debug  arch=x86_64 -j8

# Windows x86_64
scons platform=windows target=template_release arch=x86_64 -j8
```

Output binaries land in `native/dukes_ai/bin/` with names like:

```
libdukes_ai_native.macos.template_release.arm64.dylib
libdukes_ai_native.macos.template_debug.arm64.dylib
```

These names match the paths declared in
`addons/dukes_ai_native/dukes_ai_native.gdextension`.

> **Tip:** When only a `template_release` binary is present, the editor
> (which runs in debug mode) won't find the extension.
> Either build `template_debug` too, or temporarily point the
> `macos.debug.arm64` key in `.gdextension` at the release binary.

---

## 4) Platform notes

| Platform | Arch(es) |
|---|---|
| macOS | `arm64` (Apple Silicon) and/or `x86_64` (Intel) |
| Linux | `x86_64` |
| Windows | `x86_64` |
| Android | `arm64` (primary), `arm32` (optional) |

---

## 5) Godot integration

`AIController` (GDScript) calls `DukesAINative.find_best_move()` via
`ClassDB.instantiate` and checks `ClassDB.class_exists("DukesAINative")`
before use. If the native class is unavailable it falls back to the first
legal move with a warning.

The call runs on a `WorkerThreadPool` task so the Godot main thread stays
responsive while the AI thinks.

### Method signature

```
find_best_move(position: Dictionary, depth: int, time_limit_ms: int) -> Dictionary
```

- `depth` — hard ply limit (set to 64 for "unlimited depth").
- `time_limit_ms` — soft wall-clock limit in ms. Whichever fires first stops
  the search. Time is enforced both as a soft limit (skip remaining
  iterations) and a hard limit (abort mid-search via shared atomic stop flag).

---

## 6) Position payload (`position` dict)

| Key | Type | Description |
|---|---|---|
| `board` | `PackedInt32Array[64]` | `row * 8 + col`; codes 0 = empty, 1–6 = white P/N/B/R/Q/K, 7–12 = black P/N/B/R/Q/K |
| `active_color` | `int` | `0` = White, `1` = Black |
| `castling_rights` | `int` | Bitmask: bit 0 = W-K, bit 1 = W-Q, bit 2 = B-K, bit 3 = B-Q |
| `en_passant_index` | `int` | `-1` or `0..63` (`row * 8 + col`) |
| `halfmove_clock` | `int` | Plies since last pawn move or capture (50-move rule) |
| `fullmove_number` | `int` | Full move counter (starts at 1) |

---

## 7) Result payload (returned dict)

| Key | Type | Description |
|---|---|---|
| `ok` | `bool` | `true` if a move was found |
| `from_col`, `from_row` | `int` | Source square (0-based) |
| `to_col`, `to_row` | `int` | Destination square (0-based) |
| `move_type` | `int` | `ChessEnums.MoveType` value |
| `piece_type` | `int` | Moving piece type |
| `piece_color` | `int` | Moving piece colour |
| `captured_type` | `int` | Captured piece type (or `NONE`) |
| `promotion_type` | `int` | Promotion target type (or `NONE`) |
| `score` | `int` | Evaluation in centipawns from the moving side's perspective |
| `reached_depth` | `int` | Deepest completed iteration |
| `fallback` | `Dictionary` | First legal move as a safe fallback |

---

## Author

**0xM4R71N** — [github.com/0xMartin](https://github.com/0xMartin)
