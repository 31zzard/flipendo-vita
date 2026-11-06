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
		"decal: attach", "decal: attach trace", "decal: detach"
	};

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
	};
	inline ClassTime* currentClass = nullptr;   // the class whose actor is being ticked (ULevel::TickActor, probes on)
	inline std::unordered_map<const void*, ClassTime> classTimes;

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
