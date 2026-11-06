# Harry Potter 1 on PS Vita (Flipendo / SurrealEngine port)

Goal: HP1 (PC 2001, Unreal Engine 1 build 433) running on a PS Vita with the user's own game files. Engine: Flipendo
(github.com/kroplabeskidu/flipendo) on SurrealEngine (submodule `src/engine`). Everything for the Vita is in `vita/`.
WSL2 on Windows, VitaSDK in /usr/local/vitasdk, Vita hacked (h-encore).
The game runs: menus, all of levels 1-3, saves, sound, lighting like the original. The problem is SPEED (13-25 fps, want 30) and
memory (192 MB heap). Testing on the console is manual: you build, the user installs the VPK, plays and sends logs back.

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
touch and stick rails), sce_sys/ (bubble icon and LiveArea, made by tools/make_livearea.py).

## On the Vita: ux0:data/flipendo/
hp1/ (HP1 files; the old game/ is still used when there is no hp1/), fonts/NotoSans-Regular.ttf, resources/, render.cfg, flipendo.log (the engine log), vita-main.log
("profiler thread: N" proves a profiling build), profile.txt, core dumps ux0:data/*.psp2dmp (or `.tmp` when unfinished).
render.cfg keys (name=value): lightmap_scale lightmap macro fog exposure flip_y texture16 texture_budget_mb texture_lod
free_lightmap_data world meshes particles(percent) mesh_distance clipper_scale(percent of 2048x1080) engine_priority gc(keep 0)
flush_to_zero tick_far_distance tick_far_rate bspinfo_cache texture_fps slow_frame_ms device_timing light_anim_divider
trace_cache mover_trace surface_batching atlas_pages atlas_direct still_lights lightmap_incremental dynamic_light_list tick_far_visible skin_cache skin_cache_age mesh_light_max section_timers vsync mipmaps upload_budget_ms texture_inplace heartbeat probes
gl_thread gl_thread_core gl_thread_priority surface_cache surface_chunks parallel_vis(0 default/1/2=auto; was vis_threads) lightmap_skip shadow_skip spell_touch spell_assist
spell_speed spell_time.
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
