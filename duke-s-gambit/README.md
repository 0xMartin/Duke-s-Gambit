# Duke's Gambit

An arcade-styled 3D chess game built in Godot, featuring animated piece combat, a native AI opponent, and a Java-inspired visual theme.

## Tech Stack

- Engine: Godot 4.6
- Native AI: C++ via GDExtension

## Project Structure

- `scenes/` - main and supporting scenes (menu, gameplay, camera, pieces, effects)
- `scripts/` - game logic (controllers, chess rules/system, UI, camera, piece behavior)
- `assets/` - 3D models, textures, sounds, and VFX
- `shaders/` - custom visual shaders (outline, highlight, shadows)
- `addons/` - project add-ons and editor/runtime extensions
- `native/` - native modules and integrations
- `project.godot` - root Godot project configuration

## Native AI Module

- [dukes_ai](native/dukes_ai) - C++ chess AI module used by the game.

## Author

**0xM4R71N** — [github.com/0xMartin](https://github.com/0xMartin)