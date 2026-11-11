# Harry Potter 1 on PS Vita (Flipendo / SurrealEngine port)

Goal: HP1 (PC 2001, Unreal Engine 1 build 433) running on a PS Vita with the user's own game files. Engine: Flipendo
(github.com/kroplabeskidu/flipendo) on SurrealEngine (submodule `src/engine`). Everything for the Vita is in `vita/`.
WSL2 on Windows, VitaSDK in /usr/local/vitasdk, Vita hacked (h-encore).
The game runs: menus, all of levels 1-3, saves, sound, lighting like the original. The problem is SPEED (13-25 fps, want 30) and
memory (192 MB heap). Testing on the console is manual: you build, the user installs the VPK, plays and sends logs back.

## HP2 split off (2026-11-08)
Chamber of Secrets now builds from its own copy ~/flipendo2/flipendo (taken at #213, user's decision: HP2 work must not risk HP1).
This tree is HP1's only; the flipendo2 app no longer uses it.

## Rules
- Never change the SurrealEngine submodule history or push it (upstream forbids AI contributions). Engine/Flipendo sources are
  changed ONLY by `vita/apply_fixes.sh` (idempotent python edits, each guarded by a marker text; backups `.orig`).
  A new patch = a new `edit(...)` with a UNIQUE marker. A marker that is a prefix of another marker made edits silently skip
  ("already patched") more than once: use distinct names (`vita-foo-inc`, not `vita-foo:include`).
- `export VITASDK=/usr/local/vitasdk; export PATH=$VITASDK/bin:$PATH` is needed in every new shell (addr2line, cmake toolchain).
- Files copied from elsewhere can look OLDER than the objects (time zones): `vita/build.sh` touches the sources. Use it.
- Do not guess script property names: `UActor::LastRenderTime()` does not exist in HP1's Actor class ("Property offset out of
  bounds!" at the first tick). Use properties the engine code already reads, or plain C++ members.
- Never run `GC::Collect()`: only `PackageManager::packages` are GC roots, it frees the viewport/console (crash in LoadEntryMap).

- Code that runs on the meshjobs workers or the glsubmit thread (kernel threads, sceKernelCreateThread, no pthread data) must not be
  the first to touch a function-local static (VitaConfig.h's settings!), nor use std::mutex, condition_variable, thread_local or
  anything else that waits through pthreads: a wait there crashes (data abort in pte_osSemaphoreCancellablePend; 2026-10-24, the
  visibility strips and VitaClipperPolygons). Make such statics on the main thread before the work starts.
- Crash dumps: vita/tools/psp2core.py (written again 2026-10-24, the old one was gone). A dump is a gzip'd ELF core (.tmp when
  unfinished, still readable); notes THREAD_INFO (stop reason at +0x74: 0x30004 data abort, 0x30002 undefined instruction),
  THREAD_REG_INFO (r0..r15 at +8), MODULE_INFO (segment bases); text address - flipendo's base + 0x81000000 = ELF address.

## Build / install
- `cd ~/flipendo/vita && bash build.sh` (apply_fixes + touch + cmake + make; prints errors only; result `build/flipendo.vpk` + sha256).
  `bash build.sh debug`: HP1's own debug mode on (HPConsole.bDebugMode, #198: the title menu's Level Select, Language, Credits,
  Version; 'Debug' top left), for working on the game; `bash build.sh release`: off, THE BUILD TO PUBLISH. Same folder build/
  (cmake VITA_GAME_DEBUG, only vita_main.cpp changes); plain `bash build.sh` keeps the last mode, the output's end says which.
  render.cfg game_debug=0/1 overrides either. The user asked (08 Nov) for debug builds while working, release when publishing.
  `bash build.sh profile` -> `build-profile/` (sampling profiler, game is slow on purpose).
- cmake options: `VITA_HEAP_MB` (192; build/ is at 256 with VITA_EXTRA_MEMORY=ON since 2026-10-24), `VITA_TEXT_PAD_BYTES` (28672, raised to 45056 on 2026-10-22 and 61440 on 2026-10-23; only stubs.cpp rebuilds), `VITA_TUNE_FLAGS` (-mtune=cortex-a9 -fno-math-errno),
  `VITA_AGGRESSIVE` (-O3 -marm), `VITA_PROFILE`, `VITA_EXTRA_MEMORY` (experimental, unverified).
- "Cannot allocate N bytes for SCE data at end of segment 0; segment 1 overlaps" (vita-elf-create): the end of the code is within 4.5 KB
  of the next 64 KB boundary; raise VITA_TEXT_PAD_BYTES by 16384 (cmake -DVITA_TEXT_PAD_BYTES=45056 ..) and rebuild.
- Install by hand: delete the app, copy build/flipendo.vpk, install in VitaShell, compare sha256, delete old logs. (Idea: VitaShell's
  FTP server, port 1337, could automate upload and log download.) TITLEID FLPD00001.

## Files in vita/
CMakeLists.txt, patches/0300-vita-core.patch (32 bit NEON, memalign, the fixed game folder; apply_fixes.sh applies it first),
vita_main.cpp (HP1 only, no launcher: finds hp1/ or game/, 16 MB engine thread, flush-to-zero, thread priority, args), VitaRenderDevice.h/.cpp (vitaGL fixed
function renderer), RenderDeviceVita.cpp (factory), stubs.cpp, resourcedata_vita.cpp, vita_input.cpp (hooks in the SDL window: left
stick walks (arrow keys), right stick = cursor/camera, cross/R = left mouse, circle/L = right mouse), VitaConfig.h (reads render.cfg),
VitaTimers.h (section timers), VitaStats.h (counters), VitaProbes.h (lap timers), LightActorTree.h/.cpp (replacement files), profile.cpp (sampler),
resolve_profile.py, tools/psp2core.py (crash dump reader), render.cfg (template), VitaGLQueue.h (every GL call of the renderer: at once
or on the glsubmit thread), tests/pcstub/ (PC stand-ins: vitaGL that records calls and triangles, psp2 threads on std::thread, Widget),
tests/glqueuetest.cpp, tests/surfacecachetest.cpp and tests/stripvistest.cpp (the compile lines are at their top),
VitaParallelVis.inc (the visibility walk on three cores, included by VisibleFrame.cpp), VitaSpellLesson.cpp (spell lessons:
touch and stick rails), sce_sys/ (bubble icon and LiveArea: tools/make_livearea_cover.ps1 draws them from images/branding/coverhq.jpg (bg + watermark),
GamePlayButton.jpg (gate) and icon.png (bubble) in
Windows PowerShell, tools/make_livearea.py --from <folder> turns them into palette PNGs; without --from it makes the old Flipendo-logo set).

## On the Vita: ux0:data/flipendo/
hp1/ (HP1 files; the old game/ is still used when there is no hp1/), fonts/NotoSans-Regular.ttf, resources/, render.cfg, flipendo.log (the engine log), vita-main.log
("profiler thread: N" proves a profiling build), profile.txt, core dumps ux0:data/*.psp2dmp (or `.tmp` when unfinished).
render.cfg keys (name=value): lightmap_scale lightmap macro fog exposure flip_y texture16 texture_budget_mb texture_lod
free_lightmap_data world meshes particles(percent) mesh_distance clipper_scale(percent of 2048x1080) engine_priority gc(keep 0)
flush_to_zero tick_far_distance tick_far_rate bspinfo_cache texture_fps slow_frame_ms device_timing light_anim_divider
trace_cache mover_trace surface_batching atlas_pages atlas_direct still_lights lightmap_incremental dynamic_light_list tick_far_visible skin_cache skin_cache_age mesh_light_max section_timers vsync mipmaps upload_budget_ms texture_inplace heartbeat probes
gl_thread gl_thread_core gl_thread_priority surface_cache surface_chunks parallel_vis(0 default/1/2=auto; was vis_threads) lightmap_skip shadow_skip spell_touch spell_assist
spell_speed spell_time water_thread water_thread_priority water_thread_cores entry_tick_rate camera_speed menu_touch debug_mode fps_counter. Any key can be overridden for one
automated run by RCFG_<key>=<n> in the scenario's env (VitaConfig.h).
Graphics audit with findings and ideas not done: /GRAPHICS_AUDIT.md (next to this file).
vita/render_turbo.cfg is the lowest-quality preset (lightmap=0 etc.); render.cfg is the balanced one.

## Automated runs on the console (since 2026-11-06)
- vitacompanion 1.08 on the Vita (ur0:tai/vitacompanion.suprx under *main, vitacompanion_kernel.skprx under *KERNEL; copies in
  ~/vita-tools/vitacompanion): FTP on 1337, commands on 1338 (launch/quit TITLEID, press/release buttons, sticks, touch, screen).
  WSL2 is in NAT mode; outgoing connections to the home LAN (the Vita on Wi-Fi) work.
- vita/tools/vitarun.py: find (scan for port 1338 -> tools/.vita_ip), deploy (build/flipendo.self -> ux0:app/FLPD00001/eboot.bin),
  run <scenario> [--deploy] (env.txt/args.txt into ux0:data/flipendo, launch, wait until the log stops growing, fetch it to
  logs/bench-*.log, delete env/args, print the per-segment table), summary <log>, cmd "<vitacompanion command>", get.
- vita_main.cpp reads ux0:data/flipendo/env.txt (NAME=VALUE: setenv, so every HP1_* debug tool of docs/debug-tools.md works on
  the Vita) and args.txt (extra engine arguments, e.g. --level=Lev_Tut1 --slot=5). VITA_BENCH=1: the overlay in full mode and
  a 'VitaBench: | FPS ... | engine ... | ...' log line every 0.5 s; 'HP1 exec t=..' lines split the table into segments.
- Scenarios in vita/tools/bench/*.txt (timeout=, arg=, env=). Always --slot=5 (the player's saves stay untouched) and end with
  HP1_EXEC '<t>:exit'. Compare builds on the SAME scenario only.

## Reading the log
Lines `LoadMap: files: read X MB in N reads, T ms on the card (S MB/s)`, `LoadMap done: ...`, `SaveGame: start/done ...` (each starts with `at N s`, seconds since the app started) show the file I/O: how much was read, how fast, how many files were read whole into memory, how much was written.
File reader (Utils/File.cpp, vita-fileread3): read() on the fd, 8 KB blocks for scattered reads (up to 256 KB when scanning), a file with 48 scattered reads is read whole (<=20 MB, heap must have 72 MB free; released at the end of LoadMap), saves are written in 256 KB blocks.
Every 120 frames: `per frame: engine A ms, picture B ms (device C ms), present D`, then `engine parts, ms per game frame: level tick,
console, audio, draw game [bsp info, process, draw nodes (meshes, particles, lightmaps)]`, `memory: heap X MB in use of Y`, `memory by
kind`. `LoadMap: heap` at each map load. "FATAL: ..." = engine exception (bad_alloc = out of heap).

## Crashes
- `python3 vita/tools/psp2core.py <dump> build/flipendo` BEFORE rebuilding (the ELF must be the crashed build); it prints each
  thread's pc/lr/sp and the ELF addresses (and function names when addr2line works).
- Seen: null deref in UPropertyT<int>::CopyConstructElement = heap exhausted (AlignedAlloc/memalign returned null; now throws bad_alloc).
  Heap: ~44 MB at start, ~170 MB at the end of level 1 before the fixes, ~140 MB after (textures were kept 3x, sounds 2x as float).
  Level changes need the new level (~60-100 MB) on top of the old one: the old level is never freed (no unloading in the engine).

## Performance state (heavy halls, ms per frame): level tick 17-20, bsp info 4-4.5, process 9-18, draw nodes 25-42
(meshes 10-24, lightmap builds 4-8, ~10 surfaces+device), device 9-10 ms for ~200-270 draw calls (~40 us each in vitaGL).
It is CPU bound (Cortex-A9, 444 MHz): render.cfg texture/GPU settings do not change fps.
Profile (instrumented, small accessors are inflated): LightActorTree 9% (fixed), BspClipper ~10%, skeletal meshes 12% (DrawSkeletalMesh,
SetupMeshLighting, GetRenderBoundingBox, TickAnimation), script VM 8%, actor tick loops 7%, ray traces (double) 5%, UWetTexture 6% in the
broom scene. Loading was dominated by FileImpl::seek (fixed with a 32 KB read cache).
Done so far: lightmap RGBA32_F upload + float lightmaps freed after upload, batching of tiles and mesh polygons, texture cache,
LightActorTree cached/skipped rebuild, file read cache, texture mips 3x copy removed, sound bytes freed + 16 bit OpenAL buffers,
clipper virtual screen 2048x1080 -> clipper_scale, engine thread priority below audio (96), corona trace cache (0.15 s), light list
only after 6 units of movement, per-material cache in KW::DrawSkeletalMesh, texture update rate 12 Hz, -O3 -marm,
RISKY (can change behaviour): tick_far_* (far unseen mesh actors ticked every 3rd frame with 3x dt) and bspinfo_cache.
The user saw NO gain from the last round (risky patches + O3): FIRST check that they really ran (flags in
build/CMakeFiles/SurrealCoreVita.dir/flags.make, `sizeof`/`built` line in the log), then A/B with the render.cfg toggles
(tick_far_distance=0, bspinfo_cache=0) and `bash build.sh` with -DVITA_AGGRESSIVE=OFF, comparing `engine parts` in the same spot.
Next ideas: (1) DONE: level surfaces batched by texture with a lightmap atlas (surface_batching; check lighting seams/black patches); (2) DONE partly: skin_cache + mesh_light_max; NEON skinning / skip normals
and lighting for far meshes; (3) float ray tracing is NOT wanted (BSP precision); (4) -flto for the core; (5) profile again with
`build.sh profile` in a heavy hall and while casting (casting still freezes: unexplained), (6) AllActors iterators in scripts.

## Gotchas
- vitaGL r1488 `glTexSubImage2D` on a texture drawn in the last 4 frames allocates a new buffer and copies the WHOLE texture
  (checked in the disassembly of libvitaGL.a). The lightmap atlas therefore writes into `vglGetTexDataPointer` memory (atlas_direct).
  Measured 2026-10-22 (logs/1, logs/0): only ~0.5 lightmap uploads a frame, atlas never full: atlas_direct changed nothing.
  In heavy halls 'lightmaps' was 17-42 ms with few uploads -> apply_fixes #40 (still_lights, lightmap_incremental,
  dynamic_light_list) and the log line 'light maps per frame: N asked for, R built again ..., ms building; light tree built again'.
  Result (logs of 09:04/09:08): rebuilds ~0/frame, 0.00 ms building, 0 dynamic lights, yet 'lightmaps' 36-51 ms for 277-373
  requests = ~100-140 us per request doing nothing. Suspect: the section timer itself (sceKernelGetProcessTimeWide twice per
  surface/mesh). DISPROVED (logs 09:24/09:29): one clock reading = 0.69 us, section_timers=0 gives the same picture ms (~130).
  ~9.6 static lights per request. Next: lap timers (VitaProbes.h, apply_fixes #42, render.cfg probes=1, log line 'laps')
  along VisibleNode::Draw, LightSystem::GetLightmap and VitaRenderDevice::DrawComplexSurface.
  FOUND (laps, log 09:40): three hash lookups per surface at ~65-70 us each. std::hash<uint64_t> keeps only the low 32 bits
  of size_t on the Vita, and a lightmap CacheID's low 32 bits are the zone's ambient: one bucket for a whole zone. Fixed with
  VitaHash64 (vita/VitaHash.h, apply_fixes #43) for lmtextures, fogtextures and the renderer's textures/lightmaps maps.
  RULE: never key an unordered_map by a 64 bit ID on the Vita without VitaHash64.
  Result (logs 12:42/12:46): picture 130-140 -> 30-47 ms in the same halls, lightmaps 1-3 ms; frame ~55-65 ms (16-18 fps).
  Left: SLOW FRAMEs of 150-360 ms from 'sound decoding' (minimp3, NEON is on by default; first play decodes the whole sound;
  log line 'Sound decoded: name (format, s, ch, Hz): ms' since #44), process 11-25, level tick 12-20, meshes 8-14 ms.
  59 sounds keep 17 MB of float samples (USound::samples; read by Audio/AudioMixer.cpp, check which path the Vita uses before freeing).
  Log 12:57: every slow sound is MP2 (HP1's dialogue/ambience), ~11 ms per second of mono: dialogue 15-107 ms, AMB_generic_room2
  231 ms. -> #45 + VitaSoundDecode.h: MP2/MP3 decoded on a thread 'sounddecode' (prio 140, any user core), the sound starts on
  the device when ready (UpdateSounds waits; StartTime reset for lip sync). sound_thread=0 = old way. Playback is OpenAL static
  buffers (AudioDevice.cpp AddSound, 16 bit); AudioMixer.cpp is not the Vita's path.
  Log 13:09: no more sound-decoding stalls. Spell aiming: level tick ~100 ms every frame. Cause found in the script (seen in a
  MagiPacks fan build of HarryPotter.u at <game folder>, retail may differ): target.setTarget -> baseHarry.ExtendTarget does
  `foreach VisibleActors(class'Actor', a)` with no radius every frame = a FastTrace to every unhidden actor of the level.
  -> #46 trace cache valid while the movers' signature is unchanged (8192 entries) + #47 log line 'rays per frame ... foreach
  VisibleActors N a frame, M actors traced, X ms'. If Harry moves while aiming the cache misses: next idea = a cheaper
  BSP-only line check, or skipping actors the script would drop anyway is NOT generic.
  Log 13:28: cache 91-93% standing, 15-57% walking (VisibleActors 23-41 ms/frame). -> #48: VisibleActors uses KW::ModelFastLineCheck
  (HP1's own execVisibleActors does, docs/re/hp1/spells.md); SurrealEngine's FastTrace was slower and also counted movers.
  Should become a src/surreal-patches change for Flipendo PC too (gated IsKnowWonder).
  The 'off target' sound repeating while aiming: target.SetTargetUnlock -> StopEffect -> PlaySound(spell_off_target3, SLOT_Misc)
  EVERY frame without a victim; Galaxy restarts a same-Id channel too (sound.md), so at PC frame rates it is inaudible and at
  ~6-10 fps one hears its start over and over. Faithful; it goes away with frame rate.
  Log 23:17 (level 1, casting fixed): heavy spots process 25-30, meshes 11-19, level tick 16-28, surfaces+device 6-9, bsp info 4.
  -> #49 probes in VisibleFrame::Process (node boxes, actors, surfaces into the clipper; clipper triangles/spans; meshes a frame),
  in the 'laps' line with probes=1.
  Log 23:41: process 28-29 ms = surfaces into the clipper ~20 (30 us x ~660, 2300 tris, 19700 spans), node boxes 1.7, actors 0.4.
  meshes ~18 ms for ~17 meshes (~1 ms each: next target). -> #50 polygon clipper (VitaClipperPolygon.h, clipper_polygons=1) and
  #51 DrawSpan bug: merging two covered runs skipped the next gap (coverage left half open). PC test vita/tests/cliptest.cpp
  (g++ -std=gnu++20 -O2 -D__vita__ -I<engine>/SurrealEngine -Ivita cliptest.cpp BspClipper.cpp Math/mat.cpp Math/FrustumPlanes.cpp):
  polygon == triangles on 120000 random surfaces after #51, 2.9x faster on the PC.
  Log 00:01 (23 Oct): process 9-16 ms (surfaces 5-7). Log 00:50 mesh probes, per mesh: light list 30 (up to 400 when actors walk),
  pose 140, normals 67, vertex light ~330, faces ~375 us. -> #53 mesh_fast: NEON vertex light (VitaMeshLight4.h, PC test
  vita/tests/meshlighttest.cpp: max diff 2.4e-6 vs MeshLighting::Light) + faces in material runs (RenderDevice::DrawGouraudTriangles).
  Log 01:05: #53 changed almost nothing (light ~300, faces ~390 us a mesh): the time is not in the light maths. Clocks are
  already 444/222/222 (vita_main.cpp). -> #54 finer probes (mesh light: fog setup / lights / vertices / cache copy; mesh faces:
  renderer; glDrawArrays) and #55 'ticks by class' log line (actor tick time per class, probes=1).
  Log 01:26 (build 01:16) per mesh: SetupMeshLighting ~270 us (walked all ~715 level lights reading script properties), vertex
  light ~160 (NEON), faces ~385 (renderer ~130 a run), pose ~150, normals ~75; glDrawArrays ~45 us each (~60 a frame = 2.9 ms).
  Level tick ~17 ms = ~1218 actors ticked a frame (715 Light 2.8 ms, Harry 2.1, students ~1.2 each, ActorShadow 0.9 ...); it
  barely changes with the view. -> #56 per-frame light snapshot for SetupMeshLighting, #57 early back-face cull of mesh faces.
  Ideas left: skip ticking actors whose tick provably does nothing (needs HP1's ULevel::Tick from IDA: does it tick bStatic?),
  smaller batch vertices (bytes for colour), pose/skinning.
  Log 05:02: SetupMeshLighting 270 -> 135 us a mesh, meshes ~13.5 ms; the hall ~69 ms a frame, the wall ~34.
  2026-10-23 round (one build, not yet run on the console):
  - #58 static actors not ticked, as HP1 (ULevel::Tick from iFirstDynamicActor; LoadMap sorts static first), read from the retail
    Engine.dll with objdump (<game folder>/System/Engine.dll, dated 2001-10-29; export thunks jump to the bodies):
    docs/re/engine/level_tick.md. render.cfg tick_static=1 = old way.
  - #59 mesh prepass (VitaMeshPrepass.inc + VitaJobs.h): ApplyAnim/bones/matrix/SetupMeshLighting on the main thread, skinning,
    normals and vertex light on 2 workers (cores 1, 2) + main; results into the skin cache. mesh_threads=2/1/0. The pool was
    stress-tested on the PC with std::thread stand-ins for sceKernel* (vita/tests/jobstest: 60000 runs, each job
    exactly once; TSAN clean apart from the stand-ins).
  - #60 probes 'process: shadows', 'process: node surfaces (all)', 'mesh prepass'; #61 early back-face drop in ProcessNodeSurface.
  Log 05:41 (3 levels, all drawn right): hall picture 47-50 -> 35-38 ms, process 15 -> 7-10, ticked actors 1218 -> 346, level tick
  ~16 (scripts: CutScene, GameReplicationInfo 1-3 ms for 2 actors, Harry ~2, Lev2 BroomHoopStage5 5.4 ms for 50). Mesh prepass
  ~370 us a mesh (was ~520): ApplyAnim (main thread only: it writes SkelCaches, aux channels Destroy) is most of it.
  REGRESSION to explain: bsp info 4.0-4.2 -> 6.0-6.7 ms in Lev_Tut1 (every period). -> #62 probes 'bsp info: actor' / 'skeletal box';
  asked for an A/B with tick_static=1.
  A/B (logs/0, logs/1, 05:52/05:55): bsp info ~6.3 ms in both (not caused by #58); tick_static=0 saves ~10 ms of level tick
  (11.7 vs 21.7) in Lev_Tut1's hall. bsp info = every actor (~1270) at ~3-4 us (property reads = cache misses) + 138 skeletal
  boxes 1.6 ms. -> #63 static actors placed in the BSP rechecked every 16th frame only (bStatic cached in BspInfo), #64 per-actor
  probe removed, #65 the actor array is rebuilt at the end of ULevel::Tick only when it has a null.
  Log 06:11: hall ~67-70 ms (eng 18 = tick 14; pic 48-51 = bsp 3.5, process 16-17 (clipper 7, shadows 3.9), nodes 26-28 (meshes 8.6 +
  prepass 4.9, lightmaps 3)); light spots 40-45 ms. NOTE: the probes themselves cost ~8 ms a frame in the hall (thousands of clock
  readings) -> now sampled in 1 frame of 8 (VitaProbes::SampleEvery; ns vs n in the log code).
  2026-10-23 06:3x round: #66 HP1 mesh LOD from Render.dll (VitaMeshLod.inc; formula in docs/re/engine/animation.md 'LOD'; render.cfg
  mesh_lod, lod_min_fps; log 'Mesh LOD: <mesh> ...' once per mesh and 'mesh LOD: ... LODAdjust' in laps), #67 IsEventEnabled fast
  path when no event is disabled, ApplyAnim on the workers (anim_threads; serial for aux channels and shared animators).
  A profiling build (build-profile/flipendo.vpk) was made for one run in the hall: resolve with resolve_profile.py.
  Log 22:51 (build 07:12, #66/#67): real fps from the frame timestamps: wall/corridor spots 30.0 (vsync cap), hall 18-20
  (52-56 ms = engine 14.5 (level tick 11) + picture 37-41: process 13 (surfaces 7.2, shadows 3.3, node boxes 1.6), draw nodes
  18-21 (per BSP surface ~32 us x 360: lightmap lookup 10.8, device 12.8, decals 3.7; meshes 5-7 = faces 4.4 + prepass 4.8),
  glDrawArrays 2.8, bsp info 3.3). Mesh LOD works (71% of vertices). Ticks: gen_fem_2 1-2.6 ms for ONE actor, GameReplicationInfo
  0.6-2.2 for 2, Harry 1.5-2, CutScene 0.4-2. Decision: no rewrite in another language; next = static surface buffers,
  GL submission on its own thread (overlapping the next tick), clipper split across cores, the costly scripts.
  2026-10-24 round (one build, not yet run on the console), the two biggest items of the plan in the log entry above:
  - surface_cache (VitaRenderDevice.h/.cpp, apply_fixes #70): a plain level surface (the batched kind: opaque, not masked, no macro,
    no fog map) keeps its vertices in video memory: vertex buffers of 65536 vertices x 28 bytes (position, texture uv, lightmap uv in the
    atlas), written straight into the memory glMapBuffer gives. Per frame only uint16 index lists by texture / atlas page and buffer
    (glDrawElements). Key: SurfaceFacet::VitaKey = BSP node * 4 + side * 2 + mirror + 1 (VisibleNode::Draw; not HP2: Lumos). Rewritten
    (appended) when its texture pan/scale or lightmap slot changes; after 3 texture changes it is 'unstable' (old path). All buffers
    full: flushed, retired (deleted 8 frames later), new ones. Also keeps the TextureEntry and LightmapPixels it used (no lookups).
  - #71 LightSystem::GetLightmap: lmtextures' entry kept by lightmap index (VitaLmDirect): no hash lookup, was two per surface.
  - gl_thread (VitaGLQueue.h): every GL call is a command; at Unlock the frame goes to the 'glsubmit' thread (core 2, priority 95,
    1 MB stack) which makes the calls and vglSwapBuffers(GL_TRUE) while the engine makes the next frame (at most one frame ahead: Submit
    waits for the frame before). Data the commands read later is copied into the frame's arena (Keep). GL objects whose results are
    needed at once (atlas pages, vertex buffers) are made in RunNow: wait until the thread is idle, then call GL on the engine thread.
    Textures are VitaGL::Texture objects (GL name made/deleted on the GL side).
  - PC tests: glqueuetest (40 seeds, 134628 calls: at once == through the thread, Keep holds; TSAN/ASAN/UBSAN clean);
    surfacecachetest (VitaRenderDevice.cpp itself on the PC with tests/pcstub: 6 cases, 907490 triangles a run with their state, the
    old way == vertex buffers == through the thread == thread working beside the next frame; TSAN/ASAN/UBSAN clean).
  - What to read in the next log: 'GL calls on the glsubmit thread', 'level surfaces are drawn from vertex buffers', and every 120
    frames 'surface cache: N surfaces a frame from video memory, ... GL thread: X ms a frame making the calls, Y ms presenting; the engine
    waited Z ms'. A/B in the same hall: gl_thread=0, surface_cache=0. If the picture is wrong: surface_cache=0 first, then gl_thread=0.
  Result (logs/1 = both on, logs/2 = gl_thread=0 surface_cache=0, build 00:32, Lev_Tut1 hall ~370-410 surfaces): it works, picture
  right; hall 17.5-18.3 fps (55-57 ms) -> 19.5-21 fps (48-51 ms): draw nodes 19.5-20.5 -> 15.6-15.9 ms, node: device 12.7 -> 8.5 us
  a surface, decals 4.1 -> 1.2, glDrawArrays 3.1 ms -> 0.1 (on the thread: 2.1-2.4 ms a frame, the engine never waits for it). Light
  spots 28.6-29.8 fps. Only ~3700-4300 vertices in one buffer for the whole level so far. The user felt no gain (the +1 frame of input
  latency of gl_thread may hide it). Left in the hall (~50 ms, all on the engine thread): level tick 11.5 (Harry 2.1-2.4, scripts),
  process 14.2 (clipper surfaces 7.5, shadows 3.6, node boxes 1.6), draw nodes 15.9 (meshes 5.7 + prepass 5.2, per surface ~24 us of
  which lightmap request 9.5), bsp info 3.4. Cores 1 and 2 are nearly idle (GL thread 2 ms, mesh workers ~5 ms).
  2026-10-24 01:10 round (one build, not yet run on the console):
  - vis_threads (#72, VitaParallelVis.inc): VisibleFrame::Process's walk on three cores. The clipper's screen is cut into three
    column strips (borders follow the strips' times); each strip (2 mesh workers + main, VitaJobs::Run) walks the BSP with its own
    clipper open only in its columns (BspClipper::VitaKeepColumns), skipping what its strip finds hidden and testing the actors of a
    skipped subtree at that moment; answers by node (box, surface, portal spans, actors). Then ProcessNode once more on the main thread
    with VitaReplay: the actors/portals/lists as before, every clipper question answered by OR over the strips (VitaForcedVisible for
    VisibleActor::Process). A surface the strips classified otherwise (a warp zone's Generate) -> the frame is walked again the old way.
    Needs nested render bounds: checked once per level (log 'VitaParallelVis: render bounds of N nodes checked: ...'), else old way.
    Not HP2. Mover mirrors (VisibleBrush::CheckPortal during actors) see the main clipper's initial state: drawn a little more, not less.
  - #74 IsAABBVisible's right edge rounded up ((int)(max2d.x + 1)): a polygon's spans (+0.5 rounding) could reach one column past its
    box; with that, stripvistest: 3000 random trees (nested bounds, portals, non-occluding polygons, actors reaching past their node,
    portal frames) give the same answers as one clipper, 0 differences either way (before #74: 21 polygons of 348k hidden by mistake).
  - lightmap_skip (#73): BeginFrame calls CheckLight on every light the level's light maps name and keeps per light map the newest
    LastUpdate of its lights (VitaLmDirty); GetLightmap returns the kept light map at once when that equals its LastStaticUpdate, it had
    no dynamic lights and none reaches it now (the slow path's own test). Log: 'light maps without looking at their lights'.
  - gl_thread_priority default 100 (was 95): the strips and mesh jobs on core 2 must not be preempted by the GL thread.
  - Log lines to read: 'visibility on three cores: ... strips a / b / c ms, borders ..., the main thread's walk ... ms' and the
    'engine parts' process figure (was 14.2 in the hall). A/B: vis_threads=0, lightmap_skip=0.
  2026-10-24 01:39 build: #75 native-font bCenter text centred on OrgX + CurX like HP1's DrawString (the loading screen's title and
  objective were 0.35 of the screen right of the middle); #76 'Boot: <step>: at X s, +N ms (card: M MB in K ms)' log lines for
  starting the game and each LoadMap / LoadFromSaveFile step, packages opened and native fonts made (>= 20 ms each), the first frame.
  The loading screen's dim parchment is HP1's own: Canvas.Reset's DrawColor 127 times the texture (docs/re/engine/rendering.md).
  2026-10-24 02:08 build: the launcher (HP1 / HP2). HP2 is started with --url=PrivetDr.unr (what Game.exe's New Game starts): its
  front end (HP2::RunFrontEnd, a SurrealWidgets dialog window with New/Load/Options and save slots) is not used on the Vita yet, so
  there is no Load Game and no Slot<n> save folder. HP2 needs its Game.exe in UE1GameDatabase.h (SHA-1) to be recognised. The
  Vita-only work that is HP1-tested: vis_threads and surface_cache are off for HP2 (their code checks IsHarryPotter2).
  HP2 first run (log 02:19): starts (EA logo skipped, PrivetDr intro cutscenes play), crashes entering Adv1Willow with "Failed to buffer
  sound data" = the heap full: old maps are never freed, heap 92 (start) -> 133 (PrivetDr) -> 139 (PrivetDr again: game state change)
  -> 165 (FlyingFordCutScene) -> ~200 MB (Adv1Willow, 1889 actors, 33 MB read, 15.8 s). -> 02:26 build: #77 sound float samples freed
  once OpenAL has its 16 bit buffer (USound::VitaFreeSamples, vitaBuffered; HP2 had 13 MB of them), AL error code + heap in the
  message, and cmake -DVITA_EXTRA_MEMORY=ON -DVITA_HEAP_MB=256 (param.sfo ATTRIBUTE2=12, checked in the VPK). Not yet run. If the app
  does not start: VITA_EXTRA_MEMORY=OFF and VITA_HEAP_MB=192 again. The real fix is freeing the old level (GC with real roots: see #13).
  HP2 reached Adv1Willow with the 02:26 build. 02:38 build: #78 the window is always 960x544 (HP2's ini has FullscreenViewport 640x480:
  SDL's vitaGL driver reported the window size as the drawable, the picture was 640x480 in the bottom left corner); #79
  SDL2DisplayWindow::GetKeyState also asks vita_input.cpp's VitaKeyHeld (pad mouse buttons, stick arrows): HP2 lets Harry walk while
  casting only when GetCurrentKeyState(LeftMouse/RightMouse) is true (docs/re/hp2/gameplay.md), else the stick aimed the spell.
  Not done yet: level tick (scripts) beyond static actors, glDrawArrays ~45 us each, ActorShadow Update events ~2 ms (process: shadows).
  Flickering/animated lights are static lights baked into lightmaps: every surface in their radius is rebuilt and re-uploaded.
- vitaGL r1488 internals (disassembly of libvitaGL.a, 2026-10-24): the fixed function pipeline does take vertex buffers
  (glVertexPointer/glTexCoordPointer record the GL_ARRAY_BUFFER bound at the call; _glDrawElements_FixedFunctionIMPL skips copying
  when every array is a buffer, else it scans the uint16 indices for the highest one and copies the client arrays). A buffer object is
  {data, size, alloc fn, last frame used, mapped}: glMapBuffer returns data itself (no copy), glUnmapBuffer only clears flags;
  glBufferSubData on a buffer drawn in the last 4 frames makes a new buffer and copies ALL of it (like glTexSubImage2D on textures);
  glDeleteBuffers frees at once unless the buffer was drawn in the last 4 frames. GL_STATIC_DRAW memory is 'mapped for gpu',
  GL_STREAM_*/GL_DYNAMIC_* 'for cpu'. SDL's swap (VITA_GLES_SwapWindow) is vglSwapBuffers(GL_TRUE) (+ sceImeUpdate when the IME is
  up), but SDL_GL_SwapWindow refuses a thread on which the context was not made current (TLS): the glsubmit thread calls vglSwapBuffers.
- newlib's malloc on the Vita is locked (__malloc_lock = sceKernelLockLwMutex): allocating on several threads is safe.
- The sampling profiler (profile.cpp) is instrumented: time in non-instrumented code (vitaGL, inlined helpers) is charged to the
  calling function (e.g. GetTextureEntry 12% = texture/lightmap uploads, not the hash lookup).
- vitaGL fixed function: GL_DST_COLOR/GL_SRC_COLOR blending works; ES 2.0 context via SDL2; Y is flipped in the projection (flip_y).
- Original lightmap shader: colour = texture * macro * (lightmap*2); engine brightness 0.4 (gamma not applied; looks fine).
- 2026-11-04: back to HP1 only. The launcher (VitaLauncher.cpp/.h, tests/launchertest.cpp) and HP2's start are removed; src/hp2
  is still compiled (the engine's KnowWonder hooks link to HP2::), the IsHarryPotter2 checks in Vita code stay harmless.
  Updated to Flipendo 3e3a9c5 (48 commits: improved movement mod, free cam, cutscene skip, Italian/EU exe detection) and
  SurrealEngine c41d349e. apply_fixes.sh moved along: OpenAL code is now Audio/OpenAL/OpenALAudioDevice.cpp (AUDIO), USound::GetSound
  is CheckSoundSamples, Engine::Run ticks in steps (stepElapsed), the fog map is looked up for unlit surfaces too and movers take the
  camera's zone for fog, InitVertexLight takes the mesh's bounding sphere (GetRenderBoundingBox per mesh: watch 'mesh: light'),
  #75 removed (Flipendo's KW::CenteredTextLineX does it). Reset to clean sources before re-running: git -C src/engine checkout -- . &&
  git -C src/engine clean -fd; git checkout -- src/knowwonder src/hp1 src/hp2; delete their *.orig; bash tools/apply_patches.sh.
  Not yet run on the console.
- flipendo-droid (../flipendo-droid, github.com/Ihor-Ihorevych/flipendo-droid) is the Android fork; ideas for the Vita there:
  fbff86d (sky frame walks only its zone's BSP subtrees, vertex meshes lit once per draw), 967f58b (frame phase timers), KWProf.h.
- 2026-11-05 build (log of 04 Nov 23:31, the first after the Flipendo update): heavy spots ~38 ms (tick 11, process 8-13, draw nodes
  9-11, bsp info 2.9); Lev_Tut1 never used vis_threads ('141 of 3324 render bounds do not enclose their subtree by up to 256').
  -> VitaParallelVis.inc: the strips test those nodes with the bound grown to the subtree's polygons (VitaVis::walkBox): the walk
  runs on three cores on every level (a grown box only hides less). The cast animation (wave on HarryAnimChannel) did not show:
  apply_fixes #80 (improved-movement off with AdamJD's packages, which have no playeraiming). #81 + VitaSpellLesson.cpp: spell
  lessons drawn with a finger (front touch, absolute: wand = finger) or along the template's line with a stick (render.cfg
  spell_touch, spell_assist, spell_speed, spell_time). LiveArea: sce_sys/ (tools/make_livearea.py from images/branding, 8 bit
  palette PNGs, plain Python; no Pillow here), VITA_VERSION 00.03. The user's game files are the MagiPacks build (AdamJD's
  HarryPotter.u / HPBase.u, <game folder>): read scripts from there (strings -n 3 on the .u gives the source text).
  Cutscene skip (Flipendo mod) runs 8 bounded steps a frame: 400-500 ms frames on the Vita while it fast-forwards (works, slow).
  Left in heavy spots: process: shadows 2.6 ms (ActorShadow), mesh faces ~390 us a mesh, mesh prepass 3.7 ms, level tick ~11.
- Log of 05 Nov 00:11 (build 00:05): with the grown boxes Lev_Tut1 did walk on three cores, and each strip took 8.3-9.2 ms, as long
  as the whole serial walk (clipper triangles 1800 -> 3800 a frame: every strip projects nearly every polygon, only the spans are
  split), + 1.1 ms replay, shadows 2.6 -> 3.5 (cores shared with the mesh workers): process 8-13 -> 17-22 ms, the user saw lower fps.
  -> the three-core walk is off by default; its key is now parallel_vis (the old vis_threads=1 in the Vita's render.cfg is ignored).
  To make it pay, a strip would have to skip polygons outside its columns before projecting them (screen box test first).
- 2026-11-05 00:41 build: the strips made cheaper (#82, VitaClipperPolygon.h): a strip's clipper knows its open columns
  (VitaKeepX0/X1: boxes and spans cut to them) and the two world planes of its wedge (VitaStripLeft/Right, 2 px wider): a node box
  or polygon wholly outside is hidden without projecting it. stripvistest (THIRDS=1 TIMING=1, NOKEEP=1 for before): answers still
  identical; strips' work 161 -> 114 ms against 88 ms for one clipper (PC). On the Vita the three strips summed to 2.7x the serial
  walk (shared cache, cores busy with mesh/GL work), so #83 parallel_vis=2 (auto, default): 48 walks each way, the faster (by 5%)
  held for 1200 walks, then measured again; log line 'VitaParallelVis auto: X ms a walk on one core, Y ms on three: ...' on change.
- Log of 05 Nov 00:48 (build 00:41): with #82 the strips still took 7-8.5 ms each (was 8.3): the cuts that saved 30% on the PC
  saved almost nothing on the Vita, the strips are bound by the shared memory/cache, not by arithmetic. Auto measured 10.6 ms a walk
  on one core, 17.1 on three, and chose one core. The trials (48 walks the slow way every ~1200) stutter: parallel_vis default 0
  again. The three-core visibility walk is a dead end on the Vita. Heavy spot then (360 surfaces, 16 meshes): process 14 (surfaces
  694 x 11.4 us, shadows 3.6, node boxes 1.6), draw nodes 15 (node: device 8.3 us x 367, lightmap 5.6 us x 367; mesh faces 272 us x 17,
  mesh prepass 5.1), level tick 11 (Harry 2.2, GameReplicationInfo 1.0 for 2 actors).
- 2026-11-05 01:03 build: #84 VitaShadows.cpp (render.cfg shadow_skip=3): ActorShadow.Update (~130 us a shadow, 27 in the hall)
  only when the owner moved/turned, else what Update then does (bUpdated, Opacity) natively; a real Update every 4th frame catches
  the first bone's idle sway. #85 mesh faces: the second back-face test dropped (vita-earlycull made it), a vertex's fog once per
  draw (only zones with fog balls cost). clipper_scale is already 25 in the user's render.cfg (512x270, 'borders ... of 512'):
  the 11 us a surface is the walk itself (scattered geometry reads, projection), not the clipper's lines; 18 (turbo) is the A/B.
- Log of 06 Nov 06:07 (build 01:03, #84/#85; Lev1 from a save, Lev2_Inc_A/B, Lev2_HogFront_2/3, Lev2_RemChase, Lev2_Fire2):
  fps per map (frame timestamps): Lev2_Inc_A 17 avg (11-25), Lev2_Inc_B 22.5 (14.6-30), HogFront ~29, RemChase 27. Level tick a
  steady 15-18 ms in Lev1/Lev2_Inc (Snail 2-6 ms for 6, VenomousTent2 3-5 for 14-25, ActorShadow ticks 1.5-2.5 for 54, SpikyBush 1.8,
  Harry 1.5-3.6, GameReplicationInfo ~1 for 2; ~400 more actors at ~20 us). Worst spots (Lev2_Inc_A, 11-14 fps): draw nodes 40-46 ms
  with only 90-180 surfaces and meshes 3-5: ~30-40 ms of draw nodes NOT in meshes/particles/lightmaps/BSP surface laps, always with
  ~113 texture uploads per 120 frames (= a procedural texture at texture_fps 12) -> suspected the water (UWaterTexture::UpdateFrame:
  256x256 sim + a normalize per pixel, never timed) or the sky/mirror frame (DrawPortals: its whole Process+Draw is inside draw nodes).
  The user: fps drops hard when water/a fountain with particles is in view. Cutscene skip: 48 level ticks of 1/60 s a frame
  (~700 ms frames), ~1.1x real time = no faster than watching. parallel_vis=2 on the console still made trial walks on three cores.
  Heap 120 -> 146 -> 162 -> 175 -> 199 -> 208 MB over 6 maps (of 256; old levels never freed). 774 lines 'Idle not found' (neville).
  -> 06 Nov 06:38 build, #86: on-screen counter vita/VitaOverlay.cpp (render.cfg overlay=0/1/2, default 1; two fingers on the REAR
  touch pad cycle off/FPS/full; full shows engine/picture/present, tick, bsp/vis/draw/hud, draw steps sky/surf/actors/transl,
  mesh/particles/lightmaps/water, uploads, surfaces/dc/tris, heap, map + Harry's position), VitaTimers DrawPortals/DrawOpaque/DrawActors/
  DrawTranslucent/TexUpdate (+ total[] sums never reset), new log line 'draw nodes by step ... procedural textures X (name (class) ms,
  new pictures)', the water normal without normalize (same value), cutscene skip steps 1/20 s on the Vita, template parallel_vis=0.
  Not yet run on the console.
- Log of 06 Nov 06:51 (build 06:38, #86; only Lev2_Fire1 from a save, the user also played level 1: ~20 fps, 30 in spots, lower
  with more geometry): Lev2_Fire1 7-14 fps. 'draw nodes by step' showed opaque surfaces 40-68 ms = 'node: fogmap' 26 ms (235 us x
  110 surfaces: a FOG ZONE, every fog map built again (FogmapBuilder, every fog ball x every texel) and uploaded (TexImage2D RGBA)
  every frame: 70-140 'texture uploads' a frame, device 41 us a surface) + 'node: texture' 24 ms = WetWater (WetTexture 256x256)
  19-32 ms per new picture. Level tick 23-27 (Snail 6.5-8 ms for 9: SnailTrailFX SetLocation + goo boxes every tick; Doxie1 ~2,
  GameReplicationInfo 1-1.8, CutNorbertEggShake 2.5). The user saw wrong lighting, some geometry and the water's tint wrong there.
  -> 07:03 build, #87: fog maps every fog_rate (3) frames staggered, NEON water step + wet refraction (vita/VitaWater.h; log
  'VitaWater: water check' compares with the scalar loop), water_fps 10; device: a light map uploaded through UploadTexture is
  kept in 'lightmaps' (before, the atlas path meeting it after the float data was freed filled its slot WHITE), the other path's
  texture dropped when the atlas path gets a rebuilt light map, a fog map without data uploads as no fog (was white).
  Water tint: SurrealEngine's UWetTexture copies the source's palette INDEXES and draws with the WetTexture's own palette; HP1's
  Fire.dll PostLoad keeps the WetTexture's own palette (copied when it lives in another package): not settled (export ordinals
  of Fire.dll seemed shifted against the bodies in objdump). Not yet run on the console.
- Log of 06 Nov 07:19 (build 07:03, #87; Lev2_Fire1 only, ~7 min): graphics right now (the user). 11-23 fps; water spots 11-13.
  'VitaWater: water check' 0.000000 (NEON exact) but WetWater still ~22 ms a picture: memory bound, not arithmetic. node: fogmap
  still 12 ms (146 us x 82). Level tick 18-23 (Snail 6-7 ms for 9, CutNorbertEggShake up to 4.6, VenomousTent2 2.2, ActorShadow 1.5,
  Harry 1.5, GameReplicationInfo 1.1-1.5), bsp info 4.1-4.4 always, process 5-12 (shadows 2-5).
  -> 07:30 build: #88 planar water (VitaWater::State: P[2] + V floats, gradients from the old pressure on demand; drops FixedDepth/
  PhaseSpot as the engine; log 'VitaWater: planar check'), fog maps built again only when the camera / mover surface moved (exact:
  the fog depends on nothing else, FogInfo is taken once), fog lights culled by segment-sphere (exact: SphereDensity 0); #89 laps
  'tick: native/animation/Tick event/state code/physics/Timer/root motion' (UActor::Tick). GOTCHA hit again: marker
  'vita-tickparts' was a prefix of 'vita-tickparts-inc' (skipped); renamed 'vita-tickparts-start'. Not yet run on the console.
- Log of 06 Nov 07:41 (build 07:30; Lev_Tut2 broom lesson from a save, ~22 fps): planar water exact (check 0.000000) and ~7 ms a
  picture (was 22). Level tick 16.5 = laps 'tick: Tick event' 10.1 (25.6 us x 395), physics 3.0 (3.8 us x 790), native 1.1, Timer
  0.9; BroomHoopStage5 5.8 ms for 50 hoops (HPBase.baseProps.Tick bobs with SetLocation every frame, hidden hoops too), Stage4 1.5,
  Ring4/5 ~1.1. bsp info skeletal box only 0.2 here, shadows ~1 (the planned box/shadow work pays little on this level).
  -> 07:51 build: #90 laps in SetLocation (check / collision hash / touches) + the touch query skipped when !bCollideActors (exact).
  Profiling build build-profile/flipendo.vpk (08:04, VITA_TEXT_PAD_BYTES 45056 there: 28672 failed with 'Cannot allocate 4576
  bytes for SCE data'): to run ~1-2 min in the broom lesson, then resolve_profile.py profile.txt build-profile/flipendo.
- Profile of 06 Nov 08:33 (build-profile, Lev_Tut2; dumps 1-2 = loading): in play the script VM is ~25-30% (Frame::RunExpr/Run/
  Call, ExpressionValue Deinit/move, UProperty::ConstructArray/DestructArray/ElementPitch, PropertyDataBlock::Ptr, ~Array<Iterator>,
  CallEvent, IsEventEnabled), KW::FarMoveActor 1.4-2.3% (+ ActorEncroachmentCheck 0.7, PhysTrailer 0.6), BspClipper ~5%, water ~2%.
  Log 07:59 (build 07:50): #90's SetLocation laps stayed empty: HP1's SetLocation is KW::FarMoveActor (FindSpot, encroachment,
  SetActorZone). -> 08:43 build: #91 (VitaTrivialLocals.h: a frame's plain-value locals by memset; Frame::Call skips locals when
  storing args / copying out), #92 laps in KW::FarMoveActor. Not yet run on the console.
- Log of 06 Nov 08:49 (build 08:41 = #91 without #92; Lev_Tut1 then Lev_Tut2 from saves): #91 works: 'tick: Tick event' 25.6 ->
  21.7 us an actor, Lev_Tut2 level tick 16.2 -> 14.5 ms, 22-27 fps; Lev_Tut1 21-28 fps (level tick 9.5-11.5, process 7-15, draw
  nodes 7-13, bsp info 3.2). New in the log (cause unknown, maybe old): 'Tut1McGonagall4 fell out of the world' 2 s after loading
  the Lev_Tut1 save -> GameInfo.Killed / BaseCam.CutState Accessed None. The wand Accessed None (StartCasting wandEffect) is old.
  FindEventFunction is < 0.6% in the profile (not worth a cache). Next VM items: RunExpr/Run, ExpressionValue::Deinit,
  PropertyDataBlock::Ptr, ~Array<Iterator> per frame, CallEvent's Array by value.
- 08:59 build (#91 + #92 + #93 + #94; not yet run): #93 VitaFuncCache.h, the (class, state, function) -> UFunction lookup of
  VirtualFunction and FindEventFunction remembered, cleared by UClass::Load / UState::Load / WrapScriptFunction; #94 the Tick event
  through VitaCallEvent (argument on the stack, no Array allocation). The instrumented profiler charges inlined code too, so tiny
  VM helpers (PropertyDataBlock::Ptr, ExpressionValue::Deinit, AllFlags) look bigger than they are: judge VM work by the
  'tick: Tick event' us per actor in the laps (25.6 before #91, 21.7 after).
- Log of 06 Nov 09:07 (build 08:59, #93/#94): Tick event 21.7 -> 20.8 us an actor; Lev_Tut2 level tick ~14.0, ~25 fps; Lev_Tut1
  21-29 fps. FarMoveActor 219 calls a frame in Lev_Tut2 = 3.6 ms (find spot 3.9 us, encroachment 5.9, move+hash+zone 6.3 each).
  Lev_Tut1's hall (47 ms): engine 15.6 (Harry 3.46 ms alone, Target 1.1), picture 32 = process 12 (630 surfaces x 10.7 us, node
  boxes 1.5, shadows 2.1), opaque actors 10.1 (mesh prepass 4.5, mesh faces 248 us x 15), surfaces 3.4, bsp info 3.2 (skeletal box
  1.5). Ideas: mesh face loop onto the prepass workers (~3 ms), collision hash churn in FarMoveActor (std::list nodes per move).
  -> 09:12 build #95: 'ticks by class' entries get '[event X, physics Y]' (VITA_LAP_CLASS, VitaProbes::currentClass).
- Log of 06 Nov 09:17 (build 09:12, #95; Lev_Tut1): Harry 1.8 ms = event 0.00 + physics 0.14-0.47: the rest is PlayerInput +
  PlayerTick (UPlayerPawn::Tick calls them outside UActor::Tick's laps): plain script work. gen_* students: physics 0.4-0.8 for 2.
  Baseline for #96: 'mesh: faces' 3-4.6 ms a frame in the hall, of which 'mesh faces: renderer' (stays on the main thread) 1-1.5.
  -> 09:26 build: #96 face loop of meshes >= 192 faces in three parts on the job threads (vita-faces-mt in KWSkeletal.cpp, render.cfg
  face_threads=0 = old way; skipped when the zone has fog balls), #97 PlayerInput/PlayerTick through VitaCallEvent. Not yet run.
- 2026-11-06 automated rounds (vitarun.py, Vita's IP in tools/.vita_ip; user asked to bench slots 0 and 1 only):
  slot0 = Lev4_Sneak (heavy), slot1 = Lev_Tut2 on the broom (at the 30 fps cap: only a regression check; the mouse steers the broom,
  so its scenario has no turn). Results log: vita/tools/bench/results.txt. Bench noise ~0.5 ms.
  - The full overlay itself cost ~3 ms (~600 glyph tiles): bench mode logs without drawing (VitaOverlay.cpp benchLog).
  - #96/#98 faces on 3 cores (with per-vertex fog in parallel): slot0 -1.2 ms.
  - Lev4_Sneak: movers ('opaque actors (brushes)') 8.7 ms = 130 polygons/frame, light map 54 us each: #101 a bDynamicLightMover's
    light map rebuilt only when its signature changes (place, light list + LastUpdate) [engine's own 'To do'], #102 permeating lights
    cached per mover per frame, #104 VitaCollectDynamic instead of the light tree, #105 polygon world matrices cached, #106 mover fog
    early-out. Rebuilds 62 -> 4.5 a frame; brush light map 54 -> 19 us. slot0 stand 47.5 -> 41.9 ms, turn 42.1 -> 37.8.
  - Timers added: 'brushes', HUD/PostRender (1.4), PreRender/overlays, Unlock; laps 'brush poly: ...', 'tick: ...' per class.
- 2026-11-06 12:xx: #107-#110 timers (light BeginFrame, coronas, input/mods/ViewFlash/CalcView), #108 BeginFrame laps, #109 light
  tree of fixed lights only (moving ones tested one by one): 'light begin: tree' 1.9 -> 0.4 ms in Lev4_Sneak (slot0 ~40-42 ms).
  VITA_TEXT_PAD_BYTES in build/ is now 77824. NEW BENCH (user's choice): fire1 = Lev2_Fire1 by --level (slot 5) stand + turn, and
  slot1 = the broom circling (HP1_MOUSE held: flying straight hits a wall after ~10 s and shows a flat 30 fps).
  Baseline (build 12:2x): fire1 stand 52.6 ms (eng 21.7: tick 18.2 = Snail 6.2 [physics 4.5 for 9], VenomousTent2 2, ActorShadow
  1.7; pic 30.8: process 10.1 (shadows 5.5!), draw nodes 12.4 (sky 2.2, prepass 3.9, meshes 3), bsp 4.3 (skeletal box 2.0), light
  begin 2.2, HUD 1.7), fire1 turn 59.7, broom circling 42-43 ms. Next: Snail physics (profile), ActorShadow process 5.5, prepass.
  The profiling build hangs a long time before its first log line (scenario 'stall=150'); the Vita's battery died during that run:
  ON THE VITA NOW: eboot.bin = the PROFILING build, and env.txt/args.txt (Lev2_Fire1 autostart) may still be in ux0:data/flipendo.
  When it is back: 'vitarun.py clean' and 'vitarun.py deploy' (the normal build) first.
- 2026-11-06 afternoon (Vita back; after its battery died the game HUNG while loading Lev2_Fire1 until a 'vitarun.py cmd reboot':
  the console's state, not the code). Bench gotchas: STALL now 60 s (the profiling build is silent for long); a drifting/touched
  stick moved the camera mid-bench (+3 ms picture, fog maps rebuilt): vita_input ignores the sticks when VITA_BENCH=1; the bench
  line now ends with 'cam x y z yaw pitch'. @get harry0 prints nothing on Lev2_Fire1 (other player name): the bench line has Harry's
  position. Rounds: #111 laps in MultiLineCheck (116 checks a frame: world 23.6 us, actors 25.7 us), #112 ActorsInBox per-actor
  stamp instead of std::find (UActor::Collision.VitaBoxStamp), #113 level leaf hulls + bevel lists cached (world check 23.6 ->
  13.7 us), #114 insertion sort of hits, #115/#117 probes (shadows: 17 Update events x 205 us; AttachDecal only 5 a frame, its
  TraceDecal 185 us; the rest is the script + BonePos), #116 AttachDecal node box reject (no gain), #118 shadow (actor, shadow)
  pairs once per frame. fire1 stand 52.6 -> 50.4, turn 59.7 -> 57.9 (results.txt). Snail physics stays ~5 ms (many small checks).
- 2026-11-06 ~15:40 build (deployed to the Vita): FIX the invisibility cloak (Lev4_Sneak: Harry must be faded, Actor.Opacity < 1):
  VitaRenderDevice ignored GouraudVertex.Alpha (out->a = 1) in DrawGouraudTriangles/DrawGouraudPolygon; now the vertex alpha, and
  the alpha test under BlendHighlighted is GREATER 0 (not 0.5), so masked materials of a faded mesh stay. User confirmed it works.
  NEW: VitaRenderDevice::ReadPixels (waits for the GL thread, a vblank, copies sceDisplayGetFrameBuf): HP1_SHOTS screenshots work on
  the Vita (HP1_SHOT_DIR=ux0:data/flipendo; BMP -> PNG with a small zlib script). Scenarios broom_shots, broom_shot1, sneak_shots.
  OPEN BUG (user): Lev_Tut2 (broom lesson), a whole building wall is in shadow and should not be (slot1 shot at 46 s: the wall on
  the left). Not the atlas (surface_batching=0 surface_cache=0: same). The A/B with lightmap_skip=0 still_lights=0
  lightmap_incremental=0 dynamic_light_list=0 light_anim_divider=1 was shot but not looked at (the PNG failed to load); the user
  stopped there. Next: look at that shot again, then mover/static light changes of today (#101-#109), trace caches, the map's
  shadow maps.
- Lev4_Sneak 'boss-fight controls' (user: snappy Harry + camera from the level start): #119, Flipendo's free-cam mod wrapped only
  HarryPotter.Harry's PlayerWalking/playeraiming PlayerTick; Hub4.InvisibleHarry overrides PlayerWalking.PlayerTick (opacity), so
  events went to the unwrapped override (its Super reaches Harry's original) and only the mod's camera half ran. Now the player's
  subclass overrides are wrapped too (FreeCamera.cpp WrapPlayerSubclass, OriginalFor). A Flipendo bug (retail packages too): worth
  porting to Flipendo itself. Checked on the console (loads, no errors); the feel is for the user to confirm. Movement flags there
  (bStrafe, bLockedOnTarget, BossTarget) were normal before the fix; RotationRate of InvisibleHarry 50000 vs Harry 70000 (data).
- Controller: Vita has no L2/R2; mapping lives in vita_input.cpp and a few edits of sdl2_display_window.cpp.
- The sound thread (OpenAL, priority 0x40) and a same-priority engine thread made the sound stutter in heavy frames.
- 2026-11-06: Chamber of Secrets as a second app, ~/flipendo2 (flipendo2.vpk, FLPD00002, ux0:data/flipendo2/hp2). Shared here, not copied:
  flipendo-vita.cmake (the whole build; CMakeLists.txt only sets the HP1 app's variables), VITA_DATA_ROOT (card folder macro for every
  file; apply_fixes pass 0 turns old "ux0:data/flipendo/" literals into it), vita_main.cpp (VITA_GAME_FOLDER / VITA_GAME_EXE / VITA_HP2,
  app0:data/ files installed at the first start), #120 (HP2::RunFrontEnd calls flipendo2's HP2::VitaFrontEnd, weak; --saveslot=<n>),
  make_livearea.py --hp2, vitarun.py VITA_APP=hp2 (scenario tools/bench/hp2_fe.txt: VITA_FE_KEYS / VITA_FE_SHOTS of the front end).
  #121: fs::copy_file writes 0 bytes on the Vita (HP2's Save0.bmp was empty, so the front end showed no slot picture; the persistent
  actor cache too): VitaFile.h's VitaCopyFile in KWSave.cpp and HP2Persist.cpp. First HP2 run with the front end (user): works,
  PrivetDr ~15 fps outdoors, ~25 indoors. The HP1-tuned paths that are off for HP2 (vis_threads, surface_cache, mesh_lod) are the next look.
- 2026-11-06 evening, HP2 optimisation (flipendo2). Bench: `VITA_APP=hp2 vitarun.py run hp2_willow` = the user's Slot1 save
  (Adv1Willow, GSTATE010, the fountain courtyard) copied to Slot5, --saveslot=5 --loadgame=0 (Slot1 never touched). HP2's cutscene
  skip is Enter (bSkipCutScene), not Space; PrivetDr is cutscenes only (Enters skip into FlyingFordCutScene). RCFG_<key>=<n> in a
  scenario's env overrides any render.cfg key (VitaConfig.h), e.g. hp2_willow_w3_160.txt.
  Baseline (build 18:56): stand 65.6 ms (15.3 fps; engine 21, picture 44: 'procedural textures' 22 ms = WaterDE2 WaveTexture
  256x256 19 ms + liquid7 WetTexture 9 ms a picture, counted inside 'node: texture' and 'node: detail/macro'), turn 61.3.
  #122 water pictures on their own thread (VitaWaterJobs.h; water_thread, water_thread_priority 160, water_thread_cores 3; the
  log lists '<tex> WxH on the water thread' and '<tex> queued to done'), #123 NEON ShadePlanar (rsqrte + 2 Newton; WaterDE2
  ~19 -> ~11 ms a picture on the thread). On core 1 alone the thread starved (0.1 pictures a frame, ~290 ms late: something
  keeps core 1 busy, not looked into); cores 1+2: 0.5 a frame, ~25 ms late. stand 65.6 -> 42.9 ms (23.4 fps), turn 61.3 -> 52.4.
  Next in Adv1Willow: level tick 16.5 (Tick events 7.8 for 450 actor ticks; 'ticks by class' counts 2 per frame for harry,
  BaseCam, GameReplicationInfo: probably Entry's actors ticked too), bsp info 5, process 5, draw nodes 9.
- 2026-11-07 HP2 rounds (bench hp2_willow; all shared code, HP1 checked with 'vitarun.py bench': fire1 50.4 -> 49.4 / 57.9 -> 56.7):
  #124 HP1_DUMP lists the entry level ('HP1 dump entry'): HP2's Entry.unr has a placed Harry with his BaseCam, StatusManager and HUD
  items, ticking unseen. #125 entry level ticked every entry_tick_rate (10) frames ('entry level' in 'engine parts'): 1.6 -> 0.4 ms.
  #126 particle laps ('particles: update/setup/draw/count'): turning in Adv1Willow 1500 particles, draw 9.5 ms. #127 the CPU copies
  at ~0.4 GB/s ('polygons: keep copy', calls = KB): particle vertices now written straight into the device batch
  (RenderDevice::VitaBeginTriangles/VitaEndTriangles) and the batch resizes without zeroing (VitaNoInitAlloc): draw 9.5 -> 6.6 ms.
  #128 '@script <actor> <function>' prints a function's code (PrintPrettyExpression) from the actor's class chain and states
  (HP2's scripts are stripped). #129 an empty script function (bare 'return', nothing back) is not run: Frame::Call returns
  (~183 a frame: Super.Tick into Actor.Tick of torches, movers, HPawns). #130 native operators (Operator flag) run without a Frame,
  IsEventEnabled or TraceCall (~930 a frame): 'tick: Tick event' 15.0 -> 12.9 us a call.
  hp2_willow now: stand 65.6 -> 39.6 ms (15.3 -> 25.3 fps), turn 61.3 -> 47.4 ms. Left: level tick 14.4 (script frames ~13 us a
  Tick; jelly beans bounce forever by the original's code, ~0.4 ms of physics each: docs/re/engine/physics.md), bsp info 5,
  process 6, draw 9-14 (particles: update 2.2 us a particle, PFX accessors call GetParticleFXProps each time).
- 2026-11-07 ~11:00 USER: HP2 crashed (FATAL std::bad_alloc, heap 215 of 222 MB) 2-3 s after opening the chest before Adv1Willow's
  Alohomora wall, twice; no cursor in the in-game menu; camera pitch inverted. (1) A LEAK in VitaGLQueue.h's Arena, old (the
  baseline grew 139 -> 175 MB while turning too): a request bigger than a block (256 KB: a big particle batch, rain) went to a
  block at the end of the list and moved 'current' there, so the next small request added another 256 KB block while the kept
  ones went unused; Reset kept them all: +256 KB a frame (~4-7 MB/s among particles; #127's bigger batches made it worse). Big
  requests now have their own list. Checked: arena test (5000 frames: 2 blocks; the old code 5001), glqueuetest ok, the console
  turning 100 s: heap 139-142 MB (was 139 -> 232). New: render.cfg heap_probe=1 logs 'heap growth by section' (mallinfo around
  every VitaTimers section; slow, for leak hunts). (2) #131 HP2's UWindow menus draw their wand cursor only without a Windows
  mouse (the original's fullscreen): bWindowsMouseAvailable stays false for HP2, and the stick's / touch's absolute position goes
  into the console's MouseX/MouseY (= WindowsMouseX / Root.GUIScale; HPConsole's UWindow KeyEvent gives mouse deltas to its menu
  book first). Checked with the real stick: vitacompanion 'press right-stick X Y' (0-255, 128 = centre), 'release all'.
  (3) Not code: BaseCam.ApplyMouseYToDestPitch negates the pitch when Harry's bInvertMouse, and hp2/system/SE-User.ini had
  [Engine.PlayerPawn] bInvertMouse=True: set to False on the card (old file in logs/backup/hp2-SE-User.ini.1107); the menu's
  Options > Input toggles it. '@script' takes 'console' or 'Package.Class' too.
- 2026-11-07 afternoon (user away, 'continue optimising'; their pick: Grandstaircase_hub, big open hall with stairs):
  bench hp2_stairs = new game on PrivetDr (slot 6), '@set Harry CurrentGameState GSTATE050', '@travel Grandstaircase_hub' (a --url
  start of the hub runs every chapter's cutscenes: ~600 CutScriptDisk loaders and ~80 MB of heap, bad_alloc; --gamestate is
  applied only after 5 s), Enter, 4 s walking out of the corridor (user), then stand / turn / turn looking up. Heap ~200 MB there.
  Memory notes: the system has 8 MB of main RAM left after vitaGL (Boot lines now show 'heap' and 'system free'), so the 256 MB
  heap cannot grow; objects of the hub are 63 MB ('@memory', #137: textures 41, sounds 10); OpenAL keeps every played sound as
  16 bit PCM (hub ambients 2.7 MB each). Tools: #135 script_profile=1 ('script functions by time'), #136 MakeNoise probes,
  #138 heap_probe by actor class, #141 vm_laps=1 (Frame::Call setup ~1 us, finish ~1 us: the cost is volume, ~9900 script calls
  and ~49000 statements a frame in the hub), #132/#126 particle laps. Fixes: #133 particle props/light once per system, #134
  spinning particles' angle wrapped before cos/sin (newlib's slow reduction of huge angles), #139 resting bouncers (37 jelly
  beans, PHYS_Falling + bBounce, not moving for 30 steps) sleep until touched: bean physics 13 -> 2.4 ms, #140 hidden actors not
  placed in the BSP each frame (skeletal boxes 766 -> 516 a frame, bsp info 15.4 -> 10.8), #142 the 'Super.Tick; f += dt;
  if (f < c) return' prefix of a script function (HPawn.Tick: ~410 calls a frame) answered natively (tick_guard=0: off).
  hub: stand ~104 -> 91 ms, turn 86 -> 75 (level tick 55 -> 38). hp2_willow: stand 39.5 -> 35.1 (28.5 fps), turn 46.3 -> 41.8.
  Later the same afternoon: #144 a skeletal actor that has not moved and is > 1000 units from the camera gets its BSP placement
  (render box) every skel_box_rate (4) frames (bsp info 10.8 -> 5.5 ms in the hub; #143, a box cache keyed by pose, never hit:
  the candles animate; removed). #142 also takes a float instance variable as the limit (CreatureGenerator.Tick). #145
  vm_laps=1 splits VitaCallEvent: dispatch ~1-2 us, the rest is the scripts' own work (~6400 script calls, ~35000 statements a
  frame in the hub, ~0.5 us a statement): what is left is volume (fewer ticks or a faster interpreter, both big).
  hub (hp2_stairs): stand ~104 -> 87 ms, turn 86 -> 71. hp2_willow: 35.1 / 41.8. HP1 fire1: 49.4 -> 46.5, 56.7 -> 54.8, no errors.
- 2026-11-07 evening, USER: 'the game often crashes going from location to location' (HP2). Cause: no level was ever freed
  (PackageManager::LoadMap makes a new Package each load, UnloadMap only closed streams, GC::Collect unusable): +~20 MB a door,
  bad_alloc on the 3rd-4th door EntryHall_Hub <-> Grandstaircase_hub (bench hp2_hall_chain, the player's Slot1 save copied to Slot4).
  #146 VitaLevelRelease.h (end of UnloadMap; render.cfg level_release=0 = old way, level_free_actors=0 = hollow only,
  level_release_why=1 = log which outside objects keep old ones): RefCleaner nulls every property reference (recursive: structs,
  dynamic/fixed arrays) from outside objects to the old map's actors (UE1 does that for destroyed actors; Entry's BaseCam.Zone,
  GameReplicationInfo.PRIArray, HP_Scripted ScriptedTexture.NotifyActor, FE pages' PlayerHarry kept whole levels); GC::
  VitaFindUnreached marks from everything outside the old package; unreached actors get their properties destroyed (block -> one
  shared copy of the class defaults with bDeleteMe=true), BSP models emptied, the old ULevel's Actors/Collision/LightSystem reset;
  then actors + models + polys are FREED (GC::VitaFree), the package forgets them and its tables (Package::VitaForgetExports /
  VitaForgetTables). ULevel shells, textures, sounds, classes stay. Caches keyed by actor/model clear on vitaLevelEpoch
  (VitaLevelEpoch.h: KWSkeletal SkelCaches + VitaSkinCache, KWParticleFX States, KWPhysics vitaRests, KWSound music.player,
  VisibleCorona, KWBspCheck hull cache). Engine bug fixed: UObjectProperty::MarkPropertyElement marked the slot's address, not the
  object (nothing was ever marked through object properties). UObject::Mark skips unloaded objects. CallEvent to an actor with no
  Level is dropped + logged (was a data abort: Entry BaseCam sent ActorLeaving to a hollowed LevelInfo).
  Result (6 doors): heap at each LoadMap 185,195,197,197,197,197 MB (was 187,208,229,249 -> crash); release ~1.1 s per door.
  hp2_hall fps unchanged (stand ~85 ms, turn ~66). VitaOverlay: rear touch ignored in bench runs (a console lying on its back
  switched the overlay off: no VitaBench lines from 19:20 on).
  NOT DONE: HP1 check of #146 (tools/bench/hp1_chain.txt: Fire1 -> Tut1 -> Fire1 -> Tut1) ran 21:19 but the fetched log was
  EMPTY (0 bytes; the Vita log had grown to 382 KB): re-run / fetch ux0:data/flipendo/flipendo.log and check LevelRelease lines,
  no FATAL, no 'no level' events. Also not done: HP2 save -> load (LoadFromSaveFile path) after doors; hp2_willow / hp2_stairs fps.
- 2026-11-07 evening, NEW MACHINE: a desktop PC (16 cores, still WSL; kernel 4.4.0-19041-Microsoft = WSL1), the laptop is no
  longer used. VitaSDK 2026.08 here lacked packages: installed with vdpm (user's OK) libopenmpt libvorbis (+ mpg123, libogg) and
  sdl2_vitagl IN PLACE OF sdl2 (vdpm's plain sdl2 has no vitaGL video driver: link fails on glXxx; `vdpm remove sdl2` first,
  they conflict). Same flags (-O3 -marm), GCC 15.2: fire1 46.7 / 54.1 ms = the laptop's numbers. No ~/vita-tools here.
  Workflow made faster: build.sh runs make -j$(nproc) (full build ~75 s) and touches only vita/ sources whose sha256 changed
  (<dir>/.srcsums; touching all of them rebuilt every engine file including a Vita*.h): a build without changes 4.5 s; it raises
  VITA_TEXT_PAD_BYTES by 16384 by itself on 'Cannot allocate ... SCE data' (build/ is at 94208 now). vitarun.py: the run ends
  as soon as the log ends with 'Audio device has been shut down' or FATAL (FTP REST of the last 2 KB; was 60 s of STALL each
  run), polls every 3 s, a 0-byte log also counts as stalled, the log fetch is retried until its size matches the Vita's,
  VITA_BUILD=build-profile deploys the profiling build.
  HP1 check of #146 (hp1_chain, Fire1 -> Tut1 -> Fire1 -> Tut1): works, no FATAL, heap at LoadMap 103, 122, 131 MB.
  The game sometimes HANGS at the start with an EMPTY flipendo.log (vita-main.log complete, no dump; the next launch works):
  cause not found; #147/#148 make the log show where it stops next time.
  - VitaShadows: when the shadow's Update is Engine.ActorShadow's (not overridden, no state), its MoveThreshold early return is
    made natively and exactly (BonePos of bone 0 + 1 in Z vs OldOwnerLocation, bOriented rotation): Update events 15 -> 5 a frame
    in Lev2_Fire1 (snails), the test ~20 us a shadow. ~0.3 ms.
  - #148 VitaLogWriter.h: the log on a 'logwriter' thread (LwMutex, every 250 ms; FATAL and the end at once). The profile had 5-6%
    of the engine thread in the log callback (the once-a-second card write blocks tens of ms): fire1 46.7 -> 44.8 ms, the worst
    fps standing 7 -> 18.
  - #149 Package::FindObjectReference through a by-name index of the export table (was a walk of the whole table per lookup,
    ~20% of loading): first frame of Lev2_Fire1 by --level 27.3 -> 22.8 s. Loading is now mostly the card: 103 MB at ~8.5 MB/s.
  Profile of fire1 in play (build-profile, 07 Nov 21:19): script VM (RunExpr/Call/Run/ExpressionValue) ~20%, ULevel::Tick 2%,
  BoxSweep 1%, VitaProbes::Now 1% (probes on).
  - #150 'LoadMap done' ends with 'whole files at N MB/s': 11-12 MB/s (one read() of up to 20 MB) = the card's own speed. Of
    Lev2_Fire1's 103 MB, 76 MB come whole (~6.3 s) and 27 MB in ~1500 small reads (~5.7 s, ~4.7 MB/s): only that part could still
    gain (fewer scattered reads before a file is read whole, SlurpAfter 48); the rest is the card.
- 2026-11-07 evening/night (new PC), user: 'optimise until I say stop; first reach ~stable 30 fps here (Lev2_Fire1), then other
  levels'. Bench fire1 (stand / turn, ms): 46.7 / 54.1 at the start of the session -> 36.2 / 40.4 (27.6 / 24.9 fps).
  - render.cfg probes=0 section_timers=0 now (template AND the card; the card's old file: logs/backup/render.cfg.vita.1107):
    they cost ~2 ms a frame in normal play. fire1 = as the player plays; fire1_probes (RCFG_probes=1 RCFG_section_timers=1) for
    the breakdown; fire1_vm adds vm_laps + script_profile. RCFG_<key> now also overrides the keys VitaRenderDevice.cpp reads
    itself (probes, section_timers, vsync, ...): before, those were ignored.
  - vitarun.py deploys by itself when build/flipendo.self changed since the last deploy (tools/.deployed_<TITLEID>;
    VITA_NO_DEPLOY=1 to skip). Twice a 'run' without --deploy measured the old build: that is why.
  - #151 ActorShadow.Tick natively (52 shadows: 1.73 -> 0.79 ms), #160 ActorShadow.Update natively when the owner moved (the
    natives of its bytecode, '@script ActorShadow Update': the int Max, SetLocation = FarMoveActor, SetRotation = MoveActor),
    #156 AttachDecal's trace finds only the first hit (168 -> 73 us), #166 shadow pairs handled once a game frame (the sky frame
    did them again). process: shadows 4.4 -> ~2.6 ms.
  - #152/#153 fog maps: rebuilt when the eye moved > fog_move_percent (3) of the distance, at most fog_budget (10) a frame for
    eye movement (new ones and ones waiting 4 x fog_rate always): turn 49.5 -> 46.0. GOTCHA hit again: marker 'vita-fogmove'
    was a prefix of the existing 'vita-fogmoved' (#152 silently skipped); renamed 'vita-fogeyemove'.
  - #154 mesh prepass started (VitaJobs::BeginAsync) after DrawPortals, before the level surfaces are drawn; joined in
    DrawOpaqueActors. #155 LightSystem::BeginFrame on a worker while the main thread does 'bsp info' (first 3 frames on the main
    thread; the config statics it reads in some branches are touched first: vita-lightbegin-touch). ~1 + ~2 ms.
  - #157 SingleLineCheck with only TRACE_Movers|TRACE_Level skips non-mover actors before their primitive test (walking
    physics' ledge probes), #161 ActorsInBox into kept lists (no gain measurable), #162 script jumps through a dense offset ->
    statement table (was a std::map per jump; ~0.5 ms), #163 NativeByName entry kept in the UFunction, #158 IsA cache in the
    actor iterators.
  - #164 the sky frame walks only BSP subtrees touching its (sealed) zone: 'VitaSkyWalk: sky zone 22 sealed: walk keeps 16 of
    12660 nodes' in Lev2_Fire1; the sky step was not the walk though: 'sky: sort spans' (#168 counting sort: 0.4 -> 0.2 ms),
    'portal frame: clipper setup' 0.3 and 'walk' 0.6 ms come from thousands of portal spans (one per row per backdrop polygon).
  - Fire1 frame now (probes): level tick ~14 (Snail 3.9 [physics 2.7], VenomousTent2 1.7, Harry 1.2, BaseCam 0.7, GRI 0.6),
    process ~8 (clipper surfaces 5.5, shadows 2.6), draw ~10 (sky 1.3, surfaces 1.9, actors 4.7, HUD 1.1). VM: ~11500
    statements and ~2250 script calls a frame, ~1 us a statement: the biggest block left; per-call setup+finish ~2 us.
  - @script also takes a class name (first actor of it). Scripts of Lev2_Fire1's classes are in the map/other packages (the
    MagiPacks HarryPotter.u keeps source for 107 classes only): use @script on the console.
  - Survey 08 Nov 00:12 (lvl_<map>.txt: --level start, stand + turn): Lev_Tut1 and Lev4_Sneak at the vsync cap (30.0) there;
    Lev2_Inc_A 25.5 fps (its bench at 58-75 s is the Incendio spell lesson with Sprout): opaque actors 10 ms (19 meshes).
  - #172 face_threads_min (render.cfg, default 192 as before): with 64, 11 meshes went to the three-core face loop and the frame did
    not change: one mesh's parts are done before the woken workers start (probe 'mesh faces mt: run' 203 us a mesh vs ~270 serial).
  - #174 VitaMeshFaces.h: the prepass builds the main view's opaque faces of the meshes it skins (materials resolved on the main
    thread as DrawSkeletalMesh does, via VisibleMesh::VitaSetupLodMeshTextures); DrawSkeletalMesh hands the runs over. Screenshots
    identical (inca_faces_1/0). Lev2_Inc_A opaque actors 10.0 -> 8.4 ms. Left there: 'mesh faces: renderer' 57 us a run (the
    GouraudVertex -> BatchVertex copy in DrawGouraudTriangles; the device ignores GouraudVertex.Fog), mesh prepass ~2.6 ms on the
    main thread (setup + join).
  - #170 also made every non-latent, non-iterator native with an index frameless (fast_natives=0: off); #171 call results moved.
  - build.sh runs apply_fixes.sh twice and stops when the second run changes anything (#168's first marker was not in its own
    inserted text: the block was inserted again on every build, 15 copies nested before it was noticed).
  - Survey 2 (08 Nov 01:45, lvl_<map>.txt): at the vsync cap from their --level start: Lev_Tut1b, Lev3_Lumos, Lev3_Troll,
    Lev2_RemChase, Lev5_Final (and Lev_Tut1, Lev4_Sneak). Below: Lev3_Intro (Great Hall, students) 42-43 ms standing, Lev2_HogFront
    39, Lev4_Sneak2 36. HP1 level changes (hp1_chain) fine; heap 110/130/141 MB at the LoadMaps (+7-10 MB of new caches).
  - '@bench <actor|class> <function> <n>' (#175): microseconds a call (+ setup/run/finish with RCFG_vm_laps=1). Harry.Vec (4
    statements) 8.3 us, VenomousTent2.CheckForHarryHit 69 us. NOTE: 'vm: statements' in the laps is counted every frame but divided
    by the sampled frames (x8): really ~1400 statements a frame, so the interpreter's own overhead is ~2-3 ms a frame, not the
    biggest lever. #176 the event-ness of a function name kept in the UFunction (tiny gain).
  - #177 VitaLightGrid.h: SetupMeshLighting asks a grid for the lights that can reach the mesh (tests/lightgridtest.cpp: 200000
    queries equal to the full loop). Prepass setup split by probes ('prepass setup: pose/light/faces/...'): in Lev3_Intro 'light'
    143 -> 95 us a mesh, 'faces' 53 -> 29 (the material order per mesh+LOD kept). Still on the main thread: SetupMeshLighting
    (writes the light fade cache and the BSP hull caches through its visibility line checks: not for the workers as is).
  - Lev3_Intro left: process 10.8 (shadows 3.4: 52 students' shadows, most move a little every frame -> native Update +
    AttachDecal ~45 us each; clipper surfaces 5.1), draw 14.6 (surfaces 3.5 for ~300 surfaces, actors 7.3 incl. prepass).
  - #178 KW's mesh light snapshot takes LightSystem's list of the frame (same filter, same order) instead of scanning every
    actor again; the prepass stores its skinned arrays in the skin cache by swapping (VitaSkinStoreSwap: 'prepass: store' 0.5 ->
    0.06 ms). Lev3_Intro 42.4 -> 41.5 / 37.2; fire1 33.8 / 37.1 ms (29.6 / 27.2 fps) at 03:15 on 08 Nov.
- 2026-11-08 night (user: 'keep going until fully done, leaving you for the night'):
  - New probes: 'shadow: bone' / 'shadow: moved' (VitaShadowSkip laps), 'check: brush primitives' (#179), 'clip: project / edges /
    spans' (VitaCheckPolygon laps). HogFront: clip project 3.4, edges 4.2, spans 5.2 us a polygon (each lap mark ~0.7 us);
    actor line check 38 us (hash ~13, ~4.7 primitives of ~4 us; brushes 11 us); shadow bone 14 us a shadow.
  - Profile of Lev3_Intro (build-profile, intro_profile.txt, logs/profile-intro.txt): flat. Clipper ~9% (CheckSurface with the
    inlined VitaCheckPolygon 4%, DrawSpan 1.8, IsAABBVisible 1.4), VM ~12%, PropertyDataBlock::Ptr 3.3, NodeRayIntersect 2%.
  - #180 collision hash cells std::list -> std::vector (same order; an emptied cell is kept): Intro 41.5 -> 41.3, HogFront 39.0 -> 38.1.
  - #181 decal trace (VitaTraceFirst): 15 nodes but 173 polygons a trace (coplanar chains; their planes differ in the last bits,
    so a 'same plane' shortcut caught almost nothing). Each chain is now a contiguous list made once (member, copy of its plane,
    its box; chain box): the segment's box vs the chain's and member's box, NodeRayIntersect's own plane test from the copy,
    the plane point vs the box with a margin 1 + 1/cos. 110 -> 25 us a trace; Intro process shadows 3.5 -> 2.8 ms.
    trace_check=1 (render.cfg) compares every decal trace with the full TraceDecal walk: 17200 traces, 0 differ.
    Tried first and dropped: near side first (no gain; and NodeRayIntersect returns tmax for a miss, so a tie test can't tell).
  - fire1 stand at the vsync cap (33.3 ms) at 05:10, turn 37.0.
  - #182 VisibleMesh::Draw's UpdateLightList (a ray from every light in range each 6 units moved) skipped for KW skeletal meshes
    without a weapon: KW lights them from its own snapshot and nobody reads actor->TouchingLights for them (readers: engine
    DrawMesh/DrawLodMesh paths, i.e. a pawn's non-skeletal weapon; movers; particles use their own actor). Intro students walking:
    136 us each when it ran.
  - #183 probes 'mod: ...' (each mod of HP1::TickMods) -> 'mod: frame limit' 1.1 ms a frame in Lev3_Intro. #184 the frame-limit
    mod is off on the Vita (vsync paces it; the limit is for > 110 fps): Intro turning 36.8 -> 33.0 ms, HogFront 35.4 -> 33.4.
    Why it waited at all was not settled (it should only wait when a frame is under 16.7 ms; maybe TickMods ran twice a frame).
  - tools/laps.py <log> t0 t1 N: the probe laps (and engine parts / draw steps) averaged over a window of a probes log.
  - #185 (VitaMeshFaces.h / VitaMeshPrepass.inc) the prepass's faces are made on the workers as the device's batch vertices (9
    floats: u, v already times GetUMult/GetVMult of the material, set up on the main thread); VitaDrawPreparedFaces copies each run
    into VitaBeginTriangles' room (memcpy when exposure is 1, else the same products). Was DrawGouraudTriangles' per-vertex
    conversion on the main thread ('mesh faces: renderer' 57 us a run, 2 ms a frame in Inc_A). Screenshots (inca_faces_1): Sprout
    the same. ~1 ms a frame in Inc_A, Intro, HogFront.
  - #186 VitaJobs::BeginStream/Publish: a run whose jobs are handed over as they are set up (workers take an index only below
    'published', by compare-exchange; Publish signals them). VitaPrepareMeshJobs now has two passes: (A) LOD, skin cache test,
    pose or its preparations (every insertion into SkelCaches), then (B) light, faces' materials, buffers, and in the early
    prepass each job is published at the end of its (B) (prepass_stream=0: as before). Small gain alone (~0.3 ms): the
    workers' own work was the bottleneck: probes 'job: pose / skinning / normals / vertex light / faces' (timed on the worker,
    added up at the store): Inc_A per frame 0.7 / 1.1 / 1.0 / 1.5 / 2.4 ms for ~10 meshes.
  - #187 the faces job: every wedge's LOD wedge and vertex mapped once per job (VitaLodWedge was walked for each corner of
    each face, in the normals loop too), the 9 batch floats written straight (no GouraudVertex), no per-vertex fog (the
    device never reads it), and the main thread no longer makes the job's VertexLight (InitVertexLight + GetRenderBoundingBox:
    only that fog used them). faces_check=1 runs the old loop beside it and compares the bytes: 0 differ in Inc_A and Intro.
    GOTCHA (found by faces_check's first version, which allocated its buffers on the worker): the game HUNG within seconds.
    A meshjobs worker must not allocate either (malloc's lock): every buffer is sized/reserved on the main thread (batch,
    triMat, wedge maps, check buffers); the old faces loop's tris.reserve on the worker did allocate now and then.
  - 07:30 (#180-#187): Inc_A 35.4/35.0, Intro 38.0/31.3, HogFront 35.9/32.0, fire1 31.8/35.9 (stand/turn ms). hp1_chain fine
    (heap 110/129/139 MB, no FATAL).
  - #188 counts 'old faces: translucent pass / other light actor / no prepared faces' (why DrawSkeletalMesh made its own faces):
    Inc_A 7 meshes a frame without prepared faces = skin cache hits (the prepass made no job for them).
  - #189 a skin cache hit (VitaSkinWouldHit) in the main view gets a faces-only job: the worker reads the kept entry's verts /
    normals / lights (nothing writes the cache before the join), Unlit = the entry's (DrawSkeletalMesh's hit path calls no
    SetupMeshLighting either), and the store leaves the skin cache alone. Inc_A opaque actors 6.5 -> 5.6 ms.
  - #190 VitaCheckPolygon: before its edges and spans, the polygon's screen box (one pixel wider each side than any span it can
    make) is tested against the open gaps of its lines (IsVisible): none open -> hidden, and DrawSpan would have changed
    nothing. clip_check=1 runs the full way after such an answer: 160000 polygons (Intro, fire1), 0 visible. ~0.3 ms.
  - #191 MultiLineCheck's level part (ModelLineCheck on the level's static BSP) through a 1024-entry table keyed by the exact
    line, extent and node flags (emptied on a new model or level epoch; world_cache=0 off). Intro: 46% of the level checks
    answered from it; world_cache_check=1 makes each answered check again and compares the bytes: 127000, 0 differ.
    GOTCHA again: #191 replaced the line that carried #111's marker ('vita-checkprobe-world'): #111 then tried to apply on
    every build and failed; the new line keeps the old marker. A replacing edit must keep the markers of what it replaces.
  - #192 AllActors(Class): the slots of Level.Actors holding the class are kept per class (sorted indices; valid until the
    list is compacted: vitaActorsVersion in VitaLevelEpoch.h, bumped at ULevel::Tick's swap; new slots looked at on demand). The
    iterator still reads the live slot (null: destroyed) and checks Tag/Event there. GameReplicationInfo.Timer (every 0.2 s:
    AllActors(PlayerReplicationInfo) + two 32-step loops) 882 -> 687 us: the rest is ~280 statements at ~2.4 us (the VM).
  - #193 vita/VitaScriptNatives.cpp: Engine.GameReplicationInfo.Timer natively (only the class's own Timer, no state, not
    NM_Client, fewer PRIs than PRIArray holds; everything read is checked before anything is written, else the script).
    Found with temporary stamps inside UActor::Tick: GRI's 0.3-0.65 ms a frame in 'ticks by class' was its Timer (~820 us a call,
    ~0.3 calls a frame counting the entry level's). gri_timer_check=1: the script, then the native way, compared: 1000, 0 differ.
  - script_profile in HogFront (its figures are per 8 frames: divide by 8): VenomousTent2.Tick ~3 ms a frame for 14 (its
    CheckForHarryHit every 0.07 s), Snail.Tick ~1.9, HUD PostRender ~0.8, Harry.ViewFlash ~0.6, PlayerTick ~0.6, PotCam.Tick
    ~0.5, WingardiumBlock.Tick ~0.5 (54 a frame), Harry.Vec 0.24 (15 calls of a 3-line function). The VM costs ~2.4 us a
    statement (GRI.Timer: 280 statements = 687 us): a faster interpreter (ExpressionValue is a type-switched union moved on
    every push/pop, RunExpr a multi-pass stack machine) is the biggest lever left, and a big job.
  - Ideas not done: VitaReplay-style reuse of the BSP walk while the camera does not move; frustum box test per polygon before
    projecting; shadow bone (14 us a shadow) from the prepass pose; NEON for VitaCheckPolygon's projection/edges.
  - #194 ExpressionValue: a scalar's copy/move copies 4 bytes, not the 48-byte buffer (VITA_SCALAR_COPY): GRI.Timer in the VM
    687 -> 652 us; engine ~0.2-0.4 ms a frame. #184 now skips the frame limit only with vsync=1 (vita-nofps2).
  - Survey 3 (12:15, build of 11:00): the light levels run past 30 fps now (Lev_Tut1 37/41, Lumos 41/43, Troll 38/43, Sneak 38/43,
    Final 43/52, RemChase 60/53): the 30.0 'cap' of the earlier surveys was the frame-limit mod. Pacing with vsync at 60 Hz is
    uneven there (frames of 16.7 and 33.3 ms); a 30 fps lock (swap interval 2) is not made yet if that judders.
  - OPEN BUG (user, 08 Nov ~13:00): an actor's shadow blinks while it walks (Hagrid on Lev2_HogFront outdoors, Dumbledore in
    Lev_Tut1's opening). Looked at so far (temporary logging, all removed again):
      * AttachDecal does not fail (2 null of 12000 moved updates in Lev2_Fire1);
      * Dumbledore's shadow (ActorShadow, exact native path #160) is handled every rendered frame and its decal has 1-4 nodes
        attached frame after frame (a ~7 s stretch with 0 nodes, likely legit);
      * logging VisibleDecal::DrawDecals per frame: frames where the decal is attached to N nodes but 0 pieces are drawn
        (323 of 2463 in the opening, e.g. '2/1 2/1 2/0 2/1 2/0 2/0 ...'): the decal's nodes were not drawn those frames.
    So the suspect is which floor nodes get drawn (decals are drawn only with their node in OpaqueNodes), or a depth
    fight of the decal (depthOffset 1 unit along the view axis). Next: log the decal's node indices and whether each is in
    the frame's OpaqueNodes; A/B render.cfg shadow_native=0 / shadow_tick=0 / shadow_skip=0 (earlier shadow work, #151/#160/#166)
    and clip_check / clipper_scale=25 (#190 and the clipper scale decide which nodes are drawn); check whether the blink is
    there in the PC build (then it is SurrealEngine's decal code, not the Vita work).
- 08 Nov, user bugs (after the stop): (1) every cast drops the frame rate, by level; (2) Wingardium on the stone block -10 fps;
  (3) menus: main 60, video options 30, folio (wizard cards) 3-4 fps; (4) mouse sensitivity is reset at each level change.
  New scenarios: menu_pages (pause menu, OPTIONS, FOLIO by @console.MenuBook OpenBook/ChangePageNamed), menu_folio, menu_uwcheck,
  cast_tut1 / cast_hogfront (HP1_KEYS '01' = left mouse = AltFire: aim while held, cast on release; a bare '1' is the key '1').
  - Menus: all script time of UWindow painting (draw game, not the device). FOLIO: UWindowWrappedTextArea.Paint walks its whole
    ring buffer (I += J where J is never set: the loop ends only at Tail), ~375 WrapClipText("") per Paint, twice a frame: 278 ms.
    #195 (VitaScriptNatives.cpp, Frame::Call hook vita-scriptnative-call, UStruct::VitaScriptNative): Canvas.SetPos/SetOrigin/
    SetClip, UWindowWindow.TextSize/ClipText/DrawStretchedTextureSegment and WrapClipText of an empty line natively, exactly as
    their scripts (checks: own function, callee resolution, Root, argument types; else the script). uwindow_check=1: 128000
    calls compared, 0 differ. Result: pause menu 55 -> 60 fps, OPTIONS 25 -> 32, FOLIO 3.4 -> 25. Left on FOLIO: the Paint loop
    itself (~28 ms of loop statements); a native UWindowWrappedTextArea.Paint would finish it.
  - VitaRenderDevice.cpp: render.cfg probe_every (default 8; 1 = every frame) and, with probes on in that frame, a 'SLOW FRAME
    laps (ms): ...' line (the frame's 16 biggest laps); SLOW FRAME lines capped at 400 (the 20 went in the level load).
  - Casting (Lev2_HogFront): two frames of ~140 ms at each cast = 'prepass setup: light' 75 ms: KW::SetupMeshLighting's
    BeginFrame -> VitaLightGrid::Update made the whole grid again whenever the list of lights changed (the spell's light comes,
    then goes; outdoor lights with big radii). #196 VitaLightGrid.h: a slot per light kept while it is listed; a changed list
    only puts in / takes out the lights that came / went; past MaxLoose moved lights only those are put again (no full rebuild).
    tests/lightgridtest.cpp (now with lights coming anywhere in the list and huge radii): 200000 queries, 0 differ (ASan too).
    Aiming itself: Target.Tick -> setTarget -> Harry.ExtendTarget -> VisibleActors ~1.7 ms a call every other frame (+ the
    reticle's drawing): ~+3.7 ms engine on HogFront, ~1.6 ms on Lev_Tut1. Not changed yet.
  - #195b: the natives' classes were found with FindClass at the first script call of the boot, which loaded the UWindow package
    early: the title menu's cursor stopped moving (seen by the user; uwindow_natives=0 fixed it). Now taken from the window's class
    chain at the first UWindowWindow call (VitaFindScriptNative returns -1 until then: asked again). uwindow_mask (bit per
    function) for bisecting. Cursor checked with menu_cursor (HP1_MOUSE + HP1_SHOTS into ux0:data/flipendo).
  - #197 (Engine.cpp): mouse sensitivity reset at each level change: FEOptionsPage.SensitivityChanged only sets
    GetPlayerOwner().MouseSensitivity, no script saves it, and Engine::LoadMap's login reads PlayerPawn's options from User.ini
    (UPlayerPawn::LoadProperties). The player's SaveConfig before the old map goes (LoadMap and the save-game load path) and at
    exit, KnowWonder only. sens_travel: 2.4 set in Lev_Tut1 is 2.4 in Lev2_HogFront. Not checked against HP1's Engine.dll (no IDA here).
  - VITA_BENCH=1 in env.txt turns the sticks off (vita_input.cpp): never leave it in env.txt for the user's own play.
  - The user: no drop when casting or levitating any more (after #196). Slot 3 = the user's save in Lev_Tut3's big open part
    (copy in the session scratchpad); scenarios slot3_spot (probes), slot3_plain. Without probes: standing 31.1 ms (32 fps),
    turning 27.2 ms. Probes on: process 16 (node surfaces 1800 a frame, 930 into the clipper at ~10 us: project 3.5 x 766,
    edges 5.6 x 359, spans 7.5 x 359; node boxes 888 x 4.2 us), draw nodes 10, tick 7. clipper_scale 18 -> 12 only -1.5 ms.
  - render.cfg fps_lock (default 30, with vsync=1): the game at an even 30 fps by the swap interval (eglSwapInterval 2: a frame
    stays two refreshes on the screen); 1 for frames without level surfaces (menus, loading: 60 fps). The interval goes with
    VitaGL::Queue::Swap(interval) (the glsubmit thread sets it before vglSwapBuffers). fps_lock=0: the old uneven 16.7/33.3 ms.
    The mesh LOD (lod_min_fps=30) stays at full detail (target = 30 x 33.3 ms = 1.0). Lev_Tut1: 37-41 uneven -> 30.0 (33.3-33.4
    ms); slot 3 spot 32 -> 30.0; title menu 60.
  - #198 game debug build (above, Build); #199: Canvas text with Font None (debug mode's first title frame) crashed in
    RenderSubsystem::DrawText (data abort, dump 1794142810): no font = nothing drawn, size 0 (logged once).
  - Lev4_Sneak2 through the debug Level Select (FEBook.RunURL; scenario levsel_sneak2, levsel_chain): after the first cutscene
    18.7 fps (user: 18-19) = ~36 light maps built again a frame (6 dynamic lights) 9.9 ms + their atlas copies 3.9 ms. Done:
    #200 laps 'lm build: setup / static lights made / kept / dynamic / convert'; the float copy of a light map is given back
    after its FIRST upload only (LightmapPixels::uploads; it was malloc'd again at every build: convert 4.9 -> 1.0 ms);
    VitaFloatsToBytes (NEON; self-test line at start: 200013 values, 0 differ) for both float->byte loops (atlas slot 3.95 ->
    1.4 ms); #201 texel world locations kept from a light map's second build (setup 1.7 -> 0.65 ms). Lightmaps 9.9 -> 4.95 ms,
    that stretch 53 -> ~45 ms (probes on). After the Filch cutscene ~37.5 ms (26 fps with probes): not touched yet.
  - INPUT LAG (user: the camera on the stick lags since the first debug build) = fps_lock's eglSwapInterval 2. Measured with a
    new log line 'input to screen X ms' (a frame's start, where its input is read, to vitaGL's display callback for it;
    vglSetDisplayCallback): interval 2 ~100 ms, fps_lock=0 ~36 ms; display_buffers=2 (render.cfg, vglSetDisplayBufferCount in
    vita_main.cpp, default 3) changed nothing. Now: vitaGL always at interval 1, and the ENGINE thread waits before handing a
    frame over until two refreshes passed since the last hand-over (VitaPaceTwoRefreshes, VitaGLQueue.h): 30.0 fps, ~40 ms.
    (Pacing on the GL thread instead: 70 ms; pacing from the display callback's vcount: not even, the callback runs a refresh
    early or a frame is still queued.) RCFG_fps_lock now works without a fps_lock line in the card's render.cfg.
  - Script VM (user's item 2): #202 VitaFastEval.inc: statements made only of variables, constants, conversions, struct members,
    array elements, contexts, assignments, native operators and script calls evaluated by plain recursion, each node exactly as
    its RunExpr case (order: args left to right with context = self, Let right side first, ArrayElement array first; a None
    context marks AccessedNone and goes on). fast_eval_check=1: pure statements both ways: 1.52 M compared, 0 differ.
    fast_eval_stats=1: 94% of the statements run go the fast way in HogFront. #202d: Frame::Run takes them straight into its
    result. Engine (stand): HogFront 14.1 -> 12.5 ms, Intro 13.9 -> 12.7 ms. @bench: Harry.Vec (4 lines) ~10.8 us a call,
    impartInformation (early out) 6.8 us: call overhead + value handling dominate now; VenomousTent2 141 us a Tick (14 of them).
    Profiling build (build-profile, HEAP 256 + EXTRA_MEMORY now; resolve_profile.py takes TOP=n): HogFront in play VM ~20-28%,
    BSP walk ~13%; tiny always_inline helpers (PropertyDataBlock::Ptr, Deinit) show up only because inlined code is instrumented.
  - #203 point cache (projected level points kept per view, point_cache_check: 3.4 M, 0 differ) was SLOWER by ~1.7 ms at the
    slot 3 spot (fps_lock=0 A/B): random reads of the big arrays miss the cache, recomputing 16 multiplies is cheaper. Default
    point_cache=0. The clipper is memory bound, not arithmetic bound.
  - #202e VitaFastEval calls native operators itself (Frame::Call's frameless array, args evaluated into it; usual layout only);
    #204 LaunchInfo.IsHarryPotter1/2/IsKnowWonder cached (they compared std::strings at every call); #205 UpdateBspInfo skips the
    mesh box it overwrote for KW skeletal meshes (Sneak2 bsp info 4.25 -> 3.7 ms); #206 SetupMeshLighting's light visibility
    check through #191's level line table (only ~3 a frame in Intro: no gain, exact), probes 'mesh light: ...' and
    'light begin2: ...' (Intro: BeginFrame 0.8 ms a frame = the all-lights snapshot 0.4 + grid compare 0.3: memory bound).
  - Survey (08 Nov ~20:00, fps_lock=30, stand / turn fps): Intro 26.8 / 28.4 (37.3 ms standing), HogFront 28.6 / 29.8, Fire1
    30.0 / 27.9, Inc_A 29.9 / 29.8, Sneak2 29.6 / 29.6. Engine part 11-13.6 ms, picture 18-25 ms.
  - #207 one FogmapBuilder kept (no malloc per fog map; Fire1 turn node: fogmap 1.27 -> 1.17 ms). #208 VitaClipBits.h: the
    clipper's screen as one bit a pixel (IsVisible / DrawSpan / collected portal spans on 32-bit words; tests/clipbitstest.cpp:
    1.6 M random operations against the old span code, 0 differ; render.cfg clipper_bits). A/B fps_lock=0: slot 3 spot 23.9/20.0
    -> 23.4/19.0 ms picture, Intro 24.6/18.3 -> 23.9/18.0.
  - TRAP (found 08 Nov night): VitaConfigInt READS render.cfg FROM THE CARD AT EVERY CALL. #208 first called it in BspClipper's
    constructor: a VisibleFrame (with its clipper) is made for every sky / mirror portal every frame -> +4.5 ms 'sky: process'
    in Lev_Tut3. Now VitaClipperBits() (static). Any setting read outside a static initializer must be cached the same way.
  - #209 -fno-threadsafe-statics (cmake VITA_NO_SAFE_STATICS, default ON, core + app): every use of a function-local static
    was an acquire load + 'dmb' (22 sites in VM/Frame.cpp, 3-4 per script statement; objdump: 0 now). fps_lock=0, stand/turn ms:
    Intro 36.5/30.3 -> 35.7/30.1, slot 3 spot 30.5/26.0 -> 29.9/25.3, HogFront engine 12.2 -> 11.9. Thread rule unchanged
    (workers must not be first to touch a function-local static; now a race instead of a guard wait).
  - #210 LTO tried (cmake VITA_LTO, build-lto/ with gcc-ar/gcc-ranlib): first it crashed at start (static init order: a global
    NameString of another file before the name tables; #210b init_priority(101) on them, kept), then ran: Intro (fps_lock=0)
    35.4/29.9 ms against 35.7/30.1 without: within the noise, engine part even a bit slower. Not used (VITA_LTO OFF).
  - Thumb-2 -O2 tried (build-thumb/, VITA_AGGRESSIVE=OFF; self 6.7 MB against 7.5): Intro 37.2/30.7, slot 3 31.0/26.3 ms
    (ARM -O3: 35.7/30.1, 29.9/25.3): the picture part slower. ARM -O3 stays.
  - Survey 08 Nov ~20:30 (fps_lock=30, debug build with #195-#210b; stand / turn fps): Intro 28.0/28.8 (35.7/34.9 ms), HogFront
    29.1/29.9, Fire1 30.0/28.3, Inc_A 29.9/30.0, Sneak2 29.8/30.0, slot 3 (Lev_Tut3) 30/30, Sneak2 opening (level select) 24.8.
    Left to 30 everywhere: Intro standing ~2.4 ms, Fire1 turning ~2.2, HogFront standing ~1.1.
  - #211 'VitaViewSame' (log): standing still the main view is bit for bit the one before (Intro 600 of 600).
    #212 VitaViewReplay.inc/.h: the main view's BSP walk logged as events (node box answers, each surface's answer + PolyFlags +
    the clipper spans it filled, portals' spans + fills) and, while the view is bit for bit unchanged, replayed: no box/surface
    projection; the logged fills filled again at the same point of the walk, so the clipper is the same everywhere and the
    actors (tested live against it) get the full walk's answers; every event checked (node, flags), else the frame is walked
    again the full way (new FrameCounter). A mover's mirror (VisibleBrush CheckPortal fills the clipper) spoils a log / fails a
    replay. view_replay_check=1 (full walk, log compared): Intro 1775 + HogFront 1764 walks, 0 differ. With replay (fps_lock=30,
    stand): Intro picture 23.5 -> 19.2 ms (28.0 -> 30.0 fps), HogFront 22.1 -> 17.2 (29.1 -> 30.0), slot 3 22.8 -> 14.2;
    0 failed; hp1_chain fine. Turning (the view changes) gains nothing.
  - BUG FOUND + FIXED (#198b): the debug build's bDebugMode (HPBase.baseConsole config) went into SE-HP.ini when the console's
    config was saved: every later start, release builds too, showed Level Select. The card's SE-HP.ini had bDebugMode=True
    (backup logs/backup/SE-HP.ini.debugmode.1108; the line removed). Now the debug build keeps the ini's value at start and puts
    it back into the ini before it is written at exit (card now: bDebugMode=False, the default). game_debug=0 run: plain menu.
  - Title menu cursor: HP1_MOUSE (synthetic raw moves) no longer moves the UWindow cursor in these tests, whatever the natives /
    debug mode; the REAL right stick does (vitacompanion 'press right-stick 255 128' / 'release right-stick', scenario
    menu_stick: cursor at the right edge). A test tool limit, not a game bug (cause not looked into).
  - #213 VitaMatNeon.h: the clipper's box corner / polygon vertex projection with NEON (neon_check: 3.5 M compared, 0 differ)
    was NOT faster (Fire1 turn, fps_lock=0, two A/B pairs: picture 23.2 vs 22.7-22.9 ms scalar): NEON<->core register moves on
    the A9 eat it. Default mat_neon=0 (kept for reference).
  - Profile of Fire1 turning (build-profile, 08 Nov 21:30): no single hotspot left; clipper ~8% (IsAABBVisible, VitaCheckPolygon,
    CheckSurface), VM ~10%, the rest spread thin. RenderSubsystem::DrawGame's 2.3% self time is the waits in uninstrumented code.
- STATE at 22:00 08 Nov (night work, user asleep): build/ = debug build (VITA_GAME_DEBUG ON) with everything up to #213
  (mat_neon off), deployed to the Vita; env.txt/args.txt not on the card; SE-HP.ini bDebugMode=False. fps_lock=30 survey
  (stand / turn fps): Intro 30.0/28.6, HogFront 30.0/29.7, Fire1 30.0/28.1, Inc_A 30.0/30.0, Sneak2 30.0/29.7, slot 3 30/30,
  Sneak2 opening ~28. Standing views replay the BSP walk (#212); a moving camera needs the full walk (Intro picture 23-27 ms,
  Fire1 ~22): the walk is memory bound (point cache, NEON and LTO gave nothing). For a release: bash build.sh release.
- STATE at 13:15 08 Nov (stopped by the user): build/ = all of #179-#194, deployed to the Vita (clean, no temporary code).
  Bench (stand / turn ms): Lev3_Intro 36.3/29.4, Lev2_HogFront 34.7/30.9, Lev2_Fire1 31.2/34.8, Lev2_Inc_A 33.3/33.0,
  Lev4_Sneak2 33.8/31.9; all other surveyed levels well past 30 fps. hp1_chain fine (last run after #192).
- 2026-11-11 (release prep, user: camera too slow; settings lost when the app is closed from the LiveArea):
  - Camera: measured (bench cam_speed = HP1_MOUSE 30 counts a frame, cam_stick = the real stick pressed by vitacompanion,
    HP1_TRACE=PotCam): 900 counts/s turned ~126 deg/s at Mouse Sensitivity 10 (the slider's top; range 0.2-10, HP1 default 3:
    ~38 deg/s). vita_input.cpp: 2700 counts/s (render.cfg camera_speed, percent) with the response v*sqrt|v| (fine aim at small
    tilt). cam_stick at sensitivity 10: ~380 deg/s. The chain: counts * 6 (User.ini MouseX Speed) * MouseSensitivity / (dt*150)
    (Engine::UpdateInput) = SmoothMouseX; BaseCam.ApplyMouseXToDestYaw adds SmoothMouseX * dt * fRotSpeed: linear.
  - Settings: the ini files reached the card only at Engine::Run's end (a killed app never gets there), and the audio device /
    client options (menu volume 'set ini:Engine.Engine.AudioDevice SoundVolume', Brightness) reached the ini only when SE-HP.ini
    was missing. #214 vita-cfgautosave: every 2 s the player's, audiodev's and client's SaveConfig + the debug-mode restore, and
    when an ini changed, SaveAllIniFiles ('Settings written to the card (N ms)', ~90-140 ms: only after a change). #215
    vita-atomicini: an .ini is written to <name>.new and renamed (remove first: the Vita's rename does not replace); vita_main.cpp
    takes a lone .new as the ini at start. #216 SurrealEngine BUG: IniKey::SetIndexed returned 1 when the flag did NOT change, so
    every SetValue marked the ini modified (first build wrote every 2 s = a 135 ms hitch). Worth a Flipendo engine fix too
    (0010-engine-fixes), and the volume-not-saved part affects the PC build as well.
    Checked (bench cfg_kill: sensitivity 7.4, SoundVolume 96, Brightness 0.6 set in play, the app killed by 'quit FLPD00001'):
    all three in the card's SE-User.ini / SE-HP.ini, no .new left. The user's own values were put back afterwards (10, 192, 0.4).
    MusicVolume/SoundVolume are now written as ints ('128', not '128.000000'): read back the same.
  - User (after testing): the camera too fast at 3x -> 1350 counts/s (1.5x the old 900; ~57 / 95 / 190 deg/s at sensitivity 3 / 5 / 10).
  - User: 'closed the window, my sensitivity was not saved'. Their next session's log: the title menu only, ini loaded 10. Checked:
    the start does not overwrite a saved value (cfg_title: 5 stays 5). The slider (HPMenuOptionHSlider, bNoSlidingNotify) applies
    the value only on LMouseUp -> FEOptionsPage.SensitivityChanged ('Sensitivity changed to X' in the log): a drag whose release
    does not reach the slider changes the knob but not MouseSensitivity. Not reproduced yet: vitacompanion 'press front-touch 0 X Y'
    did not reach the game, the stick + cross cursor is too imprecise remotely. Asked the user how they changed it.
  - User: the front touch did nothing in the title / pause menus (SDL makes no mouse clicks from touches here), so the slider
    could only be moved with stick + cross. vita_input.cpp TouchInMenus (render.cfg menu_touch, default 1): while the cursor is
    not locked (a UWindow menu: Engine::TickWindow unlocks it when bShowWindowsMouse) sceTouchPeek's first finger is the cursor
    and holds the left mouse button (counted in leftHeld with cross / R): tap = click, drag = slider drag, lift = LMouseUp (the
    options page's sliders take their value there). In the game (locked) touch stays the spell lessons'. NOT verifiable remotely:
    vitacompanion 'press front-touch 0 X Y' reaches neither SDL nor sceTouchPeek. The user's own change (sensitivity 8, made with
    the 12:03 build) was found saved in SE-User.ini at the next start.
  - build/ = RELEASE build (bash build.sh release) with #214-#216, camera 1350 and menu touch, deployed to the Vita.
  - User: no pictures on the save slots (title menu > Start Game = FESlotPage 'SLOT'; 'load' is FELoadPage, unreachable in
    retail, SaveGameSnap<i>.bmp that nothing writes). Cause: the card had no SGS *.bmp in hp1/Save (only the saves; the user's
    install skipped the PC game's Save folder). The 30 BMPs (600 KB, from <game folder>/Save) copied to ux0:data/flipendo/hp1/save/:
    pictures shown (scenario load_page). README's install list now names Save; vita_main.cpp logs 'no save slot pictures ...'
    in vita-main.log when Save/DefaultGameSnap.bmp is missing.
  - User: Lev_Tut3's Alohomora mirror (Mirror1 mover, opens on spellTrigger3) showed its MirrorBlur pane (WetTexture 128x128,
    source Blur38, both on the grey Palette2; Translucent + SpecialLit BSP surface) WHITE. The animation was fine (checked by
    temporary logs: the refraction runs, frames change). Cause: VitaRenderDevice::DrawComplexSurface gave the light map pass only
    to opaque surfaces (a multiply pass over a translucent one would darken the room seen through it), so translucent surfaces
    were drawn at full brightness. Now a translucent (not modulated) surface takes its light as vertex colours: the float light
    map read bilinearly at each vertex, x2 (lightmap_scale) x exposure, clamped (MirrorBlur: 0.08, 0.08, 0.22: the dim blue
    room). Needs the float data (never uploaded for translucent surfaces, so it is kept). User confirmed the look. Scenario
    mirror_shots (teleport -2850 -11300 800, yaw 16384, @trigger Mirror1; the first teleport spots were inside the chest room or
    a wall). Watch other translucent surfaces (windows, glass): they are now lit too, as in UE1.
  - build/ = DEBUG build (bash build.sh debug, the user asked for one to check) with the above, deployed to the Vita.
- 2026-11-11, user: players switch the debug mode and the frame cap themselves in render.cfg. debug_mode=0/1 (vita_main.cpp
  VitaGameDebug: debug_mode, else the old game_debug, else the build's VITA_GAME_DEBUG; template and card: 0). fps_lock only 30 or
  60, default 60 (VitaRenderDevice::LoadSettings: anything but 30 is 60; 60 = swap interval 1, i.e. vsync only). Checked:
  dbg_mode0/1 (title menu plain / Debug + Level Select; SE-HP.ini keeps bDebugMode=False), fps30/fps60 (Lev_Tut1 stand / turn:
  29.7 / 29.6 fps against 48.6 / 42.4). Card render.cfg: fps_lock=60 and debug_mode=0 added (it had no fps_lock line, so it ran
  at the old default 30; backup in the session scratchpad). README.md has a Settings section for players.
  build/ = RELEASE build with this, deployed.
- 2026-11-11, user: the frame counter switchable in render.cfg, off by default. fps_counter=0/1/2 (VitaOverlay.cpp; the old
  overlay= key counts only without fps_counter; default 0; the rear-touch two-finger tap still cycles it). Template and card:
  overlay=1 replaced by fps_counter=0. Checked (fpsc0 / fpsc1 title shots): no counter / 'FPS 59.9'. build/ = RELEASE, deployed.
- 2026-11-11, user: the left stick as the mouse in the title / pause menus and in spell lessons, the right one still working.
  FOUND: HP1 keeps the cursor 'locked' in its menus too (CursorLocked 1 all the time: bWindowsMouseAvailable is false on the
  Vita), so TouchInMenus never ran (that is why the menu touch 'did not work'). #217 Engine::TickWindow passes
  Viewport.bShowWindowsMouse (the UWindow menus show their mouse) as VitaMenuMouse (vita_input.cpp); VitaTickSpellLesson sets
  VitaWandDrawing while a lesson's Draw state runs. With either, the left stick does not walk (held arrow keys let go) and
  moves the cursor / the wand like the right stick (the right one wins when both are pushed); menu touch now keyed to
  VitaMenuMouse. User: the left stick moves the pause menu's cursor (checked by hand during the run). Not yet checked: the
  spell lesson with the left stick, the menu touch with the new flag. The remote driving (drive.py polling the log by FTP
  during a vitarun run) broke the FTP: vitacompanion's FTP takes one session at a time; do not poll while vitarun runs.
- 2026-11-11, user: with fps_counter=0 the rear pad must not switch the counter on: VitaOverlay polls the rear touch only when
  render.cfg's mode is 1 or 2 (bench runs force 2 for the log, rear touch stays off there as before).
- 2026-11-11, user: the original art on the bubble and the LiveArea (images/branding/coverhq.jpg = the game's cover, 1509x1023;
  hp.ico = the game's icon, the Snitch 32x32, 16 colours, its background a plain grey, not transparent). No Pillow/ImageMagick in
  WSL: tools/make_livearea_cover.ps1 (Windows PowerShell, System.Drawing) renders full colour PNGs into a folder: bg 840x500 =
  the cover cut to shape with a dark band and the watermark bottom right ('port by 31zzard' gold Georgia 22 px,
  'https://t.me/hp1psvita' Segoe UI 16 px; the a1 style's gate sits in the middle), startup 280x158 = Harry's face, icon0 =
  the Snitch x4 nearest-neighbour on dark blue (its grey cleared by a fill from the corners). Then
  'python3 -I tools/make_livearea.py ~/flipendo sce_sys --from <folder>' (palette PNGs, ~4 s). Work files in build/livearea_work/.
  Installing art needs the VPK installed (eboot deploy does not touch sce_sys). vitacompanion 'promote <dir>' with the VPK's files
  in ux0:data/<dir>: the first call installed it silently (ur0:appmeta/FLPD00001 + ux0:app eboot new), a second call failed
  0x80010002 (folder consumed). The bubble/LiveArea read ur0:appmeta/<TITLEID>/; ux0:app/<TITLEID>/sce_sys was refreshed by FTP too.
  NOTE: coverhq.jpg and hp.ico are EA's art: do not commit them to the public repo (CLAUDE.md game-data rule).
- 2026-11-11, user's own art: images/branding/GamePlayButton.jpg (1370x784, the title on Hogwarts) for the gate (startup.png,
  a few rows cut) and icon.png (254x254, the Snitch on grey, used as is) for the bubble; the cover + watermark bg stays.
  Installed with 'promote ux0:data/flpd_promote' (the VPK's files uploaded there): reply 'Promoted.', the folder is consumed,
  eboot / icon0 / startup / bg in ux0:app and ur0:appmeta equal the VPK's. EA art again: do not commit those files.
