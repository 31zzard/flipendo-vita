# Flipendo for PS Vita

A PS Vita port of [Flipendo](https://github.com/kroplabeskidu/flipendo), the source port of KnowWonder's
*Harry Potter and the Philosopher's Stone* (PC, 2001) on [SurrealEngine](https://github.com/dpjudas/SurrealEngine).

You need your own copy of the PC game: no game files are included here.

Status: the game is playable (menus, levels, saves, sound). Work in progress on speed; the goal is a steady 30 fps.

## What is in here

This folder sits on top of a Flipendo checkout (`<flipendo>/vita/`):

- `CMakeLists.txt`, `build.sh`: the VitaSDK build (VPK, title ID `FLPD00001`).
- `vita_main.cpp`, `vita_input.cpp`, `VitaRenderDevice.*` (vitaGL), `Vita*.h`: the Vita platform layer, renderer and
  optimisations.
- `apply_fixes.sh`: the changes to Flipendo's and SurrealEngine's sources, applied as idempotent edits before every build
  (`patches/0300-vita-core.patch` first). The Flipendo and SurrealEngine repositories themselves are not changed.
- `render.cfg`: run-time settings (copied to `ux0:data/flipendo/`).
- `tools/vitarun.py`: deploy, run and benchmark on a Vita over Wi-Fi (vitacompanion + FTP).
- `tests/`: small PC tests of the Vita-only code.
- `CLAUDE.md`: the development journal (what was measured and changed, and why).

## Building

1. Install [VitaSDK](https://vitasdk.org) (`/usr/local/vitasdk`) with vitaGL.
2. Clone Flipendo with its submodule and put this repository in it as `vita/`:
   ```sh
   git clone --recursive https://github.com/kroplabeskidu/flipendo
   cd flipendo
   git clone <this repository> vita
   ```
3. `cd vita && bash build.sh` → `build/flipendo.vpk`.

## Installing

Install `flipendo.vpk` with VitaShell, copy the game's folders (`System`, `Maps`, `Textures`, `Sounds`, `Music`, ...) to
`ux0:data/flipendo/hp1/` and `render.cfg` and `SurrealEngine.pk3` (a zip of
`src/engine/Resources`: `cd ../src/engine/Resources && zip -r ../../../vita/SurrealEngine.pk3 .`) to `ux0:data/flipendo/`.

## Licence

GPLv3 (`LICENSE`), like Flipendo. SurrealEngine's code, and the changes to it, stay under its zlib licence.
Harry Potter is a trademark of Warner Bros.; this project is not affiliated with Warner Bros., EA or KnowWonder.
