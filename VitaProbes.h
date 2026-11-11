#pragma once

// Lap timers for finding out where the time of one call goes: VITA_LAP_START at the top of a function, then VITA_LAP(Name)
// after each part adds the time since the last mark to that part. The renderer prints every part every 120 frames
// (ms per frame and microseconds per call) and starts again. render.cfg probes=0 turns them off. One reading of the
// clock costs about 0.7 us on the Vita.

#ifdef __vita__
#include <psp2/kernel/processmgr.h>
#include <cstdint>
#include <string>
#include <unordered_map>

namespace VitaProbes
{
	enum Id
	{
		// VisibleNode::Draw (one BSP surface)
		NodeTexture,    // the zone, the texture and its info
		NodeExtraTex,   // detail and macro texture
		NodeVerts,      // the surface's points
		NodeLightmap,   // LightSystem::GetLevelLightmap, all of it
		NodeFogmap,     // LightSystem::GetLevelFogmap
		NodeDevice,     // RenderDevice::DrawComplexSurface
		NodeDecals,     // decals
		// LightSystem::GetLightmap
		LmPrologue,     // the zone's ambient light, the cache ID
		LmStatic,       // the surface's static lights (CheckLight)
		LmDynamic,      // its dynamic lights
		LmBuild,        // the cache lookup and, when a light changed, the build
		LmInfo,         // the TextureInfo handed back
		// VitaRenderDevice::DrawComplexSurface
		DevSetup,       // flags, which passes
		DevLmSlot,      // the lightmap's place in the atlas (and its upload when it changed)
		DevFlush,       // drawing what was collected before (meshes, tiles)
		DevVerts,       // positions and texture coordinates
		DevBatch,       // into the batches (or drawn at once)
		// VisibleFrame::Process (what is visible), timed around the calls (not laps)
		ProcNodeBox,    // a BSP node's bounding box against the clipper (IsAABBVisible): one call per node visited
		ProcActors,     // the actors of the visible nodes (VisibleActor::Process)
		ProcSurface,    // a surface into the clipper (CheckSurface): its triangles drawn as spans
		// a mesh (VisibleMesh::DrawMesh, KW::DrawSkeletalMesh)
		MeshLightList,  // UpdateLightList: which lights touch the actor (a ray to each, when it moved)
		MeshPose,       // GetFrame: the bones' animation and the skinning of every vertex (or the skin cache)
		MeshNormals,    // smooth normals from the skinned faces
		MeshLight,      // the light of every vertex
		MeshFaces,      // every face: texture coordinates, back faces, fog, handed to the renderer
		MeshLightInit,  //   (inside 'mesh: light') the fog setup (InitVertexLight)
		MeshLightSetup, //   the lights picked for the mesh (SetupMeshLighting)
		MeshLightVerts, //   the light of every vertex
		MeshLightStore, //   the skin cache's copy of the vertices, normals and lights
		MeshDevice,     //   (inside 'mesh: faces') the renderer's part (DrawGouraudTriangles)
		GlDraw,         // every glDrawArrays of the renderer's batches (meshes, tiles, level surfaces)
		MeshPrepass,    // KW::VitaPrepareMeshes: the visible meshes posed, skinned and lit before the actors are drawn (all threads)
		ProcShadows,    // KW::UpdateActorShadows at the start of the process step
		ProcNodeSurface,// VisibleFrame::ProcessNodeSurface, all of it (includes 'process: surfaces')
		BspActor,       // UActor::UpdateBspInfo of one actor (the 'bsp info' step: every actor of the level, every frame)
		BspSkelBox,     //   of which KW::GetRenderBoundingBox (skeletal meshes: their box changes with the animation)
		// UActor::Tick of every actor ticked (#88): where the level tick goes
		TickNative,     // KW::TickNativeActor (ParticleFX, Wind)
		TickAnim,       // TickAnimation
		TickEvent,      // the script's Tick event
		TickState,      // latent actions and state code
		TickPhysics,    // TickPhysics (walking, falling, projectiles, rotation...)
		TickTimer,      // the Timer event
		TickRoot,       // root motion
		// UActor::SetLocation (#90): the scripts move actors with it every frame (BroomHoop bobbing: 164 hoops in Lev_Tut2)
		SetLocCheck,    // CheckLocation (FindSpot when bCollideWorld / bCollideWhenPlacing)
		SetLocRelink,   // out of the collision hash and in again
		SetLocTouch,    // touch and untouch
		// KW::FarMoveActor (HP1's SetLocation: the BroomHoop bobbing goes through it, profile 2-3%)
		FarSpot,        // out of the collision hash, FindSpot
		FarEncroach,    // CheckEncroachment (touches)
		FarZone,        // the move, back into the hash, SetActorZone
		// VisibleBrush (#100): movers drawn polygon by polygon
		BrushStart,     // UpdateLightList and the brush frame, once per mover
		BrushTex,       // a polygon's textures
		BrushLight,     // its light map (GetMoverLightmap: DynamicMoverLights for bDynamicLightMover)
		BrushFog,       // its fog map
		BrushDevice,    // DrawComplexSurface
		MoverLights,    // KW::DynamicMoverLights inside 'brush poly: light map' (#103)
		BeginScan,      // LightSystem::BeginFrame (#108): every actor looked at for its light
		BeginTree,      //   the light tree (CreateTLAS)
		BeginDirty,     //   VitaUpdateLightmapDirty
		CheckWorld,     // KW::MultiLineCheck (#111): the level's BSP (ModelLineCheck)
		CheckActors,    //   the actors (ActorLineCheck and the loop over its hits)
		CheckHash,      //   of which the collision hash query (CollisionSystem::ActorsInBox)
		CheckPrims,     //   of which the actors' primitives (PrimitiveLineCheck)
		ShadowUpdate,   // KW::UpdateActorShadows (#115): the Update events it raises (the rest of 'process: shadows' is the actor loop)
		ShadowSkipped,  //   VitaShadowSkip's own work, per shadow it looks at
		DecalAttach,    // UDecal::AttachDecal, all of it (#117)
		DecalTrace,     //   of which the trace (Collision.TraceDecal)
		DecalDetach,    // UDecal::DetachDecal
		PfxUpdate,      // KW::DrawParticleSystem (#126): UpdateParticleSystem, the system's simulation where it is drawn
		PfxSetup,       //   texture, light colour
		PfxDraw,        //   the passes (one DrawGouraudPolygon per particle)
		PfxCount,       //   (not timed) particles in the systems drawn: calls = particles
		KeepCopy,       // VitaRenderDevice::FlushPolygons: gl->Keep (the batch's vertices copied for the GL thread); calls = KB
		EmptySkip,      // (not timed) Frame::Call of an empty script function skipped (#129): calls = skips
		FastOp,         // (not timed) native operators called without a Frame (#130): calls = calls
		PfxBounce,      // KW::UpdateParticle (#132): the bounce check of a particle with Elasticity (the level trace), per particle step
		NoiseAll,       // UActor::MakeNoise (#136), all of it
		NoiseHear,      //   CanHearNoise of every other pawn (calls = pawns asked)
		NoiseEvent,     //   the HearNoise events
		RestSkip,       // (not timed) PHYS_Falling of a resting bouncer skipped (#139): calls = skips
		VmSetup,        // (vm_laps=1, #141) Frame::Call of a script function: the frame made and the arguments stored
		VmRun,          //   Frame::Run
		VmFinish,       //   the result and out parameters, the frame dropped
		VmStatements,   //   (not timed) statements run: calls = statements
		EvEnabled,      // (vm_laps=1, #145) VitaCallEvent: IsEventEnabled
		EvChecks,       //   the actor / level checks
		EvFind,         //   FindEventFunction
		EvCall,         //   Frame::Call
		TickGuard,      // (not timed) script calls answered by the guard prefix (#142): calls = calls
		PfxDevice,      //   of the draw: the DrawGouraudPolygon calls (a probe: two clock readings each, ~1.4 us)
		SkySort,        // DrawPortals (sky frame): the portal spans sorted
		SkyProcess,     //   the sky frame's Process
		SkyDraw,        //   its Draw and ClearZ
		PortalSetup,    // VisibleFrame::Process of a portal (sky/mirror) frame: SetupSceneFrame
		PortalClipper,  //   Clipper.Setup with the portal's spans
		PortalZone,     //   FindZoneAt and the lists cleared
		PortalShadows,  //   UpdateActorShadows
		PortalWalk,     //   the BSP walk
		MeshMats,       // KW::DrawSkeletalMesh (faces on three cores): the materials looked at (a loop over every face)
		MeshFacesRun,   //   the three parts of the face loop (VitaJobs::Run)
		PrepassSetup,   // the mesh prepass: the jobs set up on the main thread
		PrepassJoin,    //   the main thread joining the workers and waiting for them (FinishAsync)
		PrepassStore,   //   the results stored (skin cache, faces)
		SetupLod,       // prepass setup of one mesh: LOD and the skin cache test
		SetupAnim,      //   the pose (ApplyAnim on the main thread, or the worker's preparations)
		SetupLight,     //   mesh-to-world and SetupMeshLighting
		SetupFaces,     //   the faces' materials, fog and textures (#174)
		SetupBuffers,   //   the job's buffers sized
		ShadowBone,     // VitaShadowSkip: the owner's first bone (BonePos)
		ShadowMoved,    //   the native Update of a shadow whose owner moved (detach, move, AttachDecal)
		CheckPrimBrush, // check: actor primitives that are brushes (movers: their BSP)
		ClipProject,    // VitaCheckPolygon: points projected and clipped
		ClipEdges,      //   the edges walked into the lines' extents
		ClipSpans,      //   DrawSpan per line
		ModA, ModB, ModC, ModD, ModE, ModF, ModG, ModH, ModI, ModJ, // HP1::TickMods, each mod (#183)
		JobAnim, JobSkin, JobNormals, JobLight, JobFaces,  // a prepass job on its thread (timed there, added up on the main thread)
		OldFacesTransl, OldFacesWeapon, OldFacesNoJob,     // (not timed) DrawSkeletalMesh's own face loop, by why: calls = meshes
		LmRSetup, LmRStaticAll, LmRStaticKept, LmRDynamic, LmRConvert,   // a light map built again (#200): setup, static lights made / loaded, dynamic, to RGBA
		MeshLightSee,   // KW::SetupMeshLighting's 'does the light see the actor' level line checks (#206)
		MeshLightCand,  //   (not timed) its candidate lights: calls = candidates
		MeshLightPick,  //   the candidates' sort and the picking loop
		MeshLightBegin, //   its BeginFrame (once a frame: the lights' snapshot, the grid, the flicker table)
		MeshLightRest,  //   SetupMeshLighting as a whole
		MLBFlicker, MLBSnapshot, MLBFill, MLBGrid,   //   BeginFrame's steps: flicker table, the lights' list, their locations/radii, the grid
		Count
	};

	inline const char* const names[Count] =
	{
		"node: texture", "node: detail/macro", "node: points", "node: lightmap", "node: fogmap", "node: device", "node: decals",
		"lightmap: prologue", "lightmap: static lights", "lightmap: dynamic lights", "lightmap: lookup/build", "lightmap: info",
		"device: setup", "device: atlas slot", "device: flush", "device: vertices", "device: batch",
		"process: node boxes", "process: actors", "process: surfaces",
		"mesh: light list", "mesh: pose", "mesh: normals", "mesh: light", "mesh: faces",
		"mesh light: fog setup", "mesh light: lights", "mesh light: vertices", "mesh light: cache copy", "mesh faces: renderer", "glDrawArrays",
		"mesh prepass", "process: shadows", "process: node surfaces (all)",
		"bsp info: actor", "bsp info: skeletal box",
		"tick: native", "tick: animation", "tick: Tick event", "tick: state code", "tick: physics", "tick: Timer", "tick: root motion",
		"SetLocation: check", "SetLocation: collision hash", "SetLocation: touches",
		"FarMoveActor: find spot", "FarMoveActor: encroachment", "FarMoveActor: move and zone",
		"brush: start", "brush poly: textures", "brush poly: light map", "brush poly: fog map", "brush poly: device", "brush poly: mover lights",
		"light begin: actor scan", "light begin: tree", "light begin: dirty maps",
		"check: world", "check: actors", "check: hash query", "check: actor primitives",
		"shadows: Update events", "shadows: skip test",
		"decal: attach", "decal: attach trace", "decal: detach",
		"particles: update", "particles: setup", "particles: draw", "particles: count", "polygons: keep copy (calls = KB)", "script: empty calls skipped", "script: operators without a frame", "particles: bounce trace", "noise: MakeNoise", "noise: CanHearNoise", "noise: HearNoise events", "physics: resting bouncers skipped", "vm: setup", "vm: run", "vm: finish", "vm: statements", "event: enabled", "event: checks", "event: find", "event: call", "script: guard prefix answered", "particles: device calls", "sky: sort spans", "sky: process", "sky: draw", "portal frame: setup", "portal frame: clipper setup", "portal frame: zone", "portal frame: shadows", "portal frame: walk", "mesh faces mt: materials", "mesh faces mt: run", "prepass: setup", "prepass: join", "prepass: store", "prepass setup: lod/skin test", "prepass setup: pose", "prepass setup: light", "prepass setup: faces", "prepass setup: buffers", "shadow: bone", "shadow: moved", "check: brush primitives", "clip: project", "clip: edges", "clip: spans", "mod: loading hold", "mod: launch skips", "mod: level start", "mod: storybook", "mod: discord", "mod: path fixes", "mod: spell lesson", "mod: improved movement", "mod: free camera", "mod: frame limit", "job: pose", "job: skinning", "job: normals", "job: vertex light", "job: faces", "old faces: translucent pass", "old faces: other light actor", "old faces: no prepared faces", "lm build: setup", "lm build: static lights made", "lm build: static lights kept", "lm build: dynamic lights", "lm build: convert", "mesh light: sees the actor", "mesh light: candidates", "mesh light: sort and pick", "mesh light: BeginFrame", "mesh light: SetupMeshLighting", "light begin2: flicker", "light begin2: list", "light begin2: locations", "light begin2: grid"
	};

	inline unsigned exprCounts[128] = {};   // (vm_laps=1) expression nodes run, by ExpressionType: the 'expressions' log line
	inline bool enabled = true;      // timing this frame (only one frame in SampleEvery: each reading of the clock costs ~0.7 us)
	inline bool wanted = true;       // render.cfg probes
	enum { SampleEvery = 8 };
	inline unsigned sampledFrames = 0;   // frames timed in the log period
	inline double us[Count] = {};
	inline unsigned calls[Count] = {};

	inline uint64_t Now() { return sceKernelGetProcessTimeWide(); }

	// the time of actor ticks by class (ULevel::TickActor), for the log's 'ticks by class' line
	struct ClassTime
	{
		std::string name;
		double us = 0.0;
		unsigned calls = 0;
		double eventUs = 0.0;     // of which the script Tick event (#95)
		double physicsUs = 0.0;   // and TickPhysics
		long long heapBytes = 0;  // heap_probe=1: the heap's growth in this class's ticks (#138)
	};
	inline ClassTime* currentClass = nullptr;   // the class whose actor is being ticked (ULevel::TickActor, probes on)
	inline std::unordered_map<const void*, ClassTime> classTimes;

	// render.cfg script_profile=1 (#135): every script function's time, inclusive (Frame::Call; native operators not counted),
	// logged as 'script functions by time' (the biggest 16 of the log period)
	struct FuncTime
	{
		std::string name;
		double us = 0.0;
		unsigned calls = 0;
	};
	inline int scriptProfile = -1;
	inline int vmLaps = -1;   // render.cfg vm_laps=1 (#141)
	inline std::unordered_map<const void*, FuncTime> funcTimes;

	inline unsigned long long clipTris = 0, clipSpans = 0;   // the clipper's triangles and spans drawn, per log period

	// The time of one call, for a part that is not a lap (called from many places, or recursively)
	struct Scope
	{
		Id id;
		uint64_t start;
		explicit Scope(Id i) : id(i), start(enabled ? Now() : 0) {}
		~Scope()
		{
			if (!enabled)
				return;
			us[id] += (double)(Now() - start);
			calls[id]++;
		}
	};

	struct Lap
	{
		uint64_t last = enabled ? Now() : 0;
		double Mark(Id id)
		{
			if (!enabled)
				return 0.0;
			const uint64_t now = Now();
			us[id] += (double)(now - last);
			calls[id]++;
			const double added = (double)(now - last);
			last = now;
			return added;
		}
	};
}

#define VITA_LAP_START VitaProbes::Lap vitaLap
#define VITA_LAP(name) vitaLap.Mark(VitaProbes::name)
// the same, and the time added to this class's share (ClassTime::eventUs / physicsUs)
#define VITA_LAP_CLASS(name, field) do { const double vitaAdded = vitaLap.Mark(VitaProbes::name); if (VitaProbes::currentClass) VitaProbes::currentClass->field += vitaAdded; } while (0)
#define VITA_PROBE(name) VitaProbes::Scope vitaProbe_##name(VitaProbes::name)
#else
#define VITA_PROBE(name)
#define VITA_LAP_START
#define VITA_LAP(name)
#define VITA_LAP_CLASS(name, field)
#endif
