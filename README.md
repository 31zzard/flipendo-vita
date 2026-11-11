# Flipendo for PS Vita

*Harry Potter and the Philosopher's Stone* (PC, 2001) running natively on the PlayStation Vita: a port of
[Flipendo](https://github.com/kroplabeskidu/flipendo), the source port of KnowWonder's game on
[SurrealEngine](https://github.com/dpjudas/SurrealEngine), an open reimplementation of Unreal Engine 1.

Port by **31zzard** · news and builds: **[t.me/hp1psvita](https://t.me/hp1psvita)**

You need your own copy of the PC game: no game files are included here.

## Status

The whole game is playable: the menus, every level, the spell lessons, the broom, Quidditch, saves, sound and music, with
lighting like the original. With the 30 fps cap the surveyed levels hold 28-30 fps (the Great Hall with all the students,
Hogwarts' front, the Fire and Sneak levels); the lighter levels run past 40 with the 60 fps cap.

## For players

### Controls

| Vita | In the game | In the menus | In a spell lesson |
|---|---|---|---|
| Left stick | walk | the cursor | the wand |
| Right stick | camera | the cursor | the wand |
| Cross, R | cast (hold to aim) | click | draw (hold) |
| Circle, L | jump | right click | |
| D-pad, square, triangle, Start, Select | the game's keys | | |
| Front touch screen | | tap = click, drag a slider | the finger is the wand |
| Rear touch pad, two fingers | switch the frame counter (when it is on in `render.cfg`) | | |

The camera speed follows the game's own *Mouse Speed* slider (Options), tuned for the stick.

Spell lessons are made for a mouse; on the Vita they get two helpers: draw the shape with a finger on the screen, or hold
the cast button and push either stick: the wand then runs along the shape's line (forward when you push roughly its way,
back when you push against it). The lesson's time is a bit longer.

### Settings that stay

Every setting of the game's Options page (sound and music volume, mouse speed, brightness, key bindings, ...) is written to
the memory card a moment after it changes, so it is kept even when the game is closed from the LiveArea (the usual way on
the Vita) rather than through the game's own Exit. The files are written whole and then swapped in, so closing the game in
the middle of a write cannot spoil them.

### render.cfg

`ux0:data/flipendo/render.cfg` is a text file of `name=value` lines (edit it with VitaShell, then start the game again):

| Setting | Values | |
|---|---|---|
| `fps_lock` | `60` (default) or `30` | 60: as fast as the console manages, up to 60 fps; 30: an even 30 fps in the game (smoother where 60 is out of reach). The menus always run at 60. |
| `fps_counter` | `0` (default), `1`, `2` | the frame counter in the top left corner: off / frames per second / also where the time goes. With 0 it can't be switched on at all. |
| `debug_mode` | `0` (default) or `1` | the game's own debug mode: Level Select, Language, Credits and the version in the title menu. |
| `camera_speed` | `25`-`400`, default `100` | the right stick's camera speed in percent, on top of the Mouse Speed slider. |

Everything else in the file is for development (each key is explained in the file itself).

## Installing

1. Install `flipendo.vpk` with VitaShell (title ID `FLPD00001`).
2. Copy the PC game's folders `System`, `Maps`, `Textures`, `Sounds`, `Music` and `Save` to `ux0:data/flipendo/hp1/`.
   `Save` holds the pictures of the save slots (`SGS <level>.bmp`); without it the slots show no picture.
3. Copy `render.cfg` and `SurrealEngine.pk3` (a zip of SurrealEngine's `Resources` folder, see Building) to
   `ux0:data/flipendo/`. A `render.cfg` that is missing is put there by the game on its first start.

The game's log is `ux0:data/flipendo/flipendo.log`; send it along with a bug report.

## What was done

SurrealEngine targets desktop PCs; the Vita is a 444 MHz quad-core ARM Cortex-A9 with 512 MB of memory. Getting a 2001 PC game
to run at 30 fps there took a long list of measured changes; `CLAUDE.md` is the full journal, with the numbers before and
after each one. The main parts:

**Platform.** `vita_main.cpp` (game folder, a 16 MB engine thread, CPU/GPU clocks, flush-to-zero, 256 MB heap),
`vita_input.cpp` (sticks, buttons and touch as mouse and keys), SDL2 on vitaGL, the game's settings saved as they change.

**Renderer** (`VitaRenderDevice.*`, vitaGL fixed function):
- every GL call goes to a second core (`VitaGLQueue.h`), which presents the frame while the engine makes the next one;
- level surfaces keep their vertices in video memory and are drawn in batches by texture, their light maps in an atlas;
- a standing view replays the last frame's visibility walk instead of walking the BSP again (`VitaViewReplay.*`), checked bit
  for bit against the full walk;
- skeletal meshes are posed, skinned and lit on three cores (`VitaMeshPrepass.inc`, `VitaJobs.h`), with HP1's own mesh LOD;
- water and wet textures in NEON on their own thread (`VitaWater*.h`); fog maps only rebuilt when the eye moves;
- the visibility clipper on a bit-per-pixel screen with polygon clipping (`VitaClipBits.h`, `VitaClipperPolygon.h`);
- translucent surfaces lit like the original (the Alohomora mirror), the invisibility cloak's fading, mirrors on movers;
- an even 30 fps pacing without the input lag of a swap interval of 2.

**Game code and engine:**
- the UnrealScript interpreter: a fast path for plain statements (`VitaFastEval.inc`), frameless native calls, cached
  function lookups, a few hot scripts natively (`VitaScriptNatives.cpp`: the menus' text and canvas helpers, actor shadows,
  `GameReplicationInfo.Timer`), each checked against the script it replaces;
- static actors not ticked (as HP1's own engine does), sleeping bouncers, cached line checks, an `AllActors` index;
- levels freed when the next one loads (`VitaLevelRelease.h`): before, every level stayed in memory until the heap ran out;
- sounds decoded on a thread, kept as 16 bit buffers; the log written by its own thread; files read with large blocks.

Every risky change has a `render.cfg` switch to turn it off, and most have a check mode that runs the old way beside the new
one and logs any difference.

## Testing on a real Vita, remotely

The console itself is the test machine. With [vitacompanion](https://github.com/devnoname120/vitacompanion) on the Vita
(FTP on port 1337, commands on port 1338), everything runs from the PC over Wi-Fi, no hands needed:

- `tools/vitarun.py find` looks for the Vita on the network; `deploy` puts a fresh build on it (only `eboot.bin`, in seconds).
- `tools/vitarun.py run <scenario>` runs a scenario from `tools/bench/*.txt` (183 of them): it writes the engine's arguments
  and environment to the card, starts the game, waits until it is done, brings the log back and prints a table of frame
  times per segment.
- A scenario drives the game through Flipendo's debug tools (`HP1_*`, see Flipendo's `docs/debug-tools.md`): start any level
  or save (`--level`, `--slot`), timed keys and mouse movement, skip cutscenes, god mode, console commands at given times
  (`@teleport`, `@trigger`, `@set` / `@get` a property, `@travel`, open a menu page, `@bench` a script function), screenshots
  read back from the GPU, dumps of every actor, traces.
- The real controls can be pushed from the PC too (`vitarun.py cmd "press right-stick 255 128"`, buttons, launch / quit),
  for what the scenarios can't reach.
- `VITA_BENCH=1` logs every half second: fps, the slowest frame, engine / picture / present times, level tick, the draw steps,
  uploads, heap, the map and the camera; `render.cfg probes=1` adds hundreds of lap timers through the engine.
- `tools/vitarun.py bench <label>` runs the standard benchmark and appends it to `tools/bench/results.txt`; compare builds on
  the same scenario.
- Crashes: `tools/psp2core.py` reads the Vita's core dumps (threads, registers, the crashing function); `bash build.sh profile`
  makes a sampling-profiler build, `resolve_profile.py` turns its output into a report.
- `tests/`: PC tests of the Vita-only code against the engine's own (clipper, light grid, mesh lighting, the GL queue, the
  surface cache, the visibility strips), run with sanitizers.

That loop (build, deploy, run, read the numbers, change) is how every change in the journal was measured.

## Building

1. Install [VitaSDK](https://vitasdk.org) in `/usr/local/vitasdk` with vitaGL, `sdl2_vitagl`, libopenmpt, libvorbis
   (`vdpm`).
2. Clone Flipendo with its submodule and put this repository in it as `vita/`:
   ```sh
   git clone --recursive https://github.com/kroplabeskidu/flipendo
   cd flipendo
   git clone https://github.com/31zzard/flipendo-vita vita
   ```
3. `cd vita && bash build.sh release` → `build/flipendo.vpk` (`bash build.sh debug`: with the game's debug mode on by
   default; `bash build.sh profile`: the profiling build).
4. `SurrealEngine.pk3`: `cd ../src/engine/Resources && zip -r ../../../vita/SurrealEngine.pk3 .`

`apply_fixes.sh` (run by `build.sh`) makes the Vita's changes to Flipendo's and SurrealEngine's sources as idempotent,
marked edits (`patches/0300-vita-core.patch` first); the two upstream repositories are not changed.
`tools/make_livearea_cover.ps1` + `tools/make_livearea.py --from` make the bubble and LiveArea pictures.

## How it was made

Developed by 31zzard together with Claude (Anthropic's AI, through Claude Code), which wrote most of the code, ran the
tests on the console and kept the journal. SurrealEngine does not accept AI-written contributions, so nothing here is sent
upstream: the changes live only in this repository.

## Licence

GPLv3 (`LICENSE`), like Flipendo. SurrealEngine's code, and the changes to it, stay under its zlib licence.
Harry Potter is a trademark of Warner Bros.; this project is not affiliated with Warner Bros., EA or KnowWonder.
