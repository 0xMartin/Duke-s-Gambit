# dukes_ai_native (GDExtension)

Native C++ chess AI backend for Godot 4 (C++ only runtime AI).

## 1) Prerequisites

- Python 3
- SCons
- C++ toolchain for target platform
- Godot C++ bindings (`godot-cpp`) checked out into:
  - `native/dukes_ai/godot-cpp`

## 2) Build godot-cpp for each target

Example (from `native/dukes_ai`):

```bash
scons -C godot-cpp platform=linux target=template_release arch=x86_64
scons -C godot-cpp platform=linux target=template_debug arch=x86_64
```

Repeat analogously for `windows`, `macos`, `android` and required `arch`.

## 3) Build this extension

From `native/dukes_ai`:

```bash
scons platform=linux target=template_release arch=x86_64
scons platform=linux target=template_debug arch=x86_64
```

Generated binaries are placed in `native/dukes_ai/bin` with names matching `addons/dukes_ai_native/dukes_ai_native.gdextension`.

## 4) Platform notes

- Windows: use `arch=x86_64`.
- Linux: use `arch=x86_64`.
- macOS: build both `arch=x86_64` and `arch=arm64`.
- Android: build at least `arch=arm64` (optionally `arm32`).

## 5) Godot integration

`AIController` now uses native class `DukesAINative` directly via method:

- `find_best_move(position: Dictionary, depth: int, time_limit_ms: int) -> Dictionary`

The previous GDScript AI backend (`ai_engine.gd`, `ai_bitboard_state.gd`) was removed.

## 6) Position payload format

`position` dictionary fields expected by native search:

- `board`: `PackedInt32Array` length 64 (`row * 8 + col`, codes `0..12`)
- `active_color`: `0` white, `1` black
- `castling_rights`: bitmask (`bit0=W-K`, `bit1=W-Q`, `bit2=B-K`, `bit3=B-Q`)
- `en_passant_index`: `-1` or `0..63`
- `halfmove_clock`: int
- `fullmove_number`: int

Returned dictionary contains best move fields (`from_col`, `from_row`, `to_col`, `to_row`, `move_type`, `promotion_type`, etc.).
