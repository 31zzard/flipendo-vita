#pragma once

// Counters for the memory line in the log (VitaRenderDevice.cpp): where the heap goes. Filled in by the engine patches
// of apply_fixes.sh and by the renderer.

#include <cstddef>

namespace VitaStats
{
	inline size_t soundCount = 0;        // sounds buffered in OpenAL
	inline size_t soundSamples = 0;      // their samples (each is kept as a float by the engine: 4 bytes)
	inline size_t textureCount = 0;      // textures uploaded to the GPU
	inline size_t textureBytes = 0;      // what their picture data (all mip levels) takes on the heap
	inline size_t lightmapCount = 0;     // lightmaps and fog maps uploaded
	inline size_t lightmapBytes = 0;     // their float data (16 bytes per texel)
	inline size_t lightmapFreed = 0;     // of which already given back after the upload
	inline size_t meshesSkipped = 0;     // meshes not drawn because of mesh_distance (per log period)

	// light maps, per log period
	inline size_t lightmapCalls = 0;         // surfaces that asked for their light map
	inline size_t lightmapRebuilds = 0;      // light maps built again (a light changed)
	inline size_t lightmapIncremental = 0;   // of which only the animated lights were added to the kept sum of the steady ones
	inline size_t lightmapTexels = 0;        // texels of the light maps built again
	inline double lightmapRebuildMs = 0.0;   // time spent building them
	inline size_t lightTreeBuilds = 0;       // times the light tree was built again (a light moved, came or went)
	inline size_t dynamicLights = 0;         // dynamic lights in the level in the last frame
	inline size_t lightmapListLights = 0;    // static lights looked at by the light map requests (their lists' lengths summed)

	// rays and the VisibleActors iterator, per log period
	inline size_t traceCalls = 0;            // rays that ignore actors (FastTrace and the like): the ones the trace cache sees
	inline size_t traceCacheHits = 0;        // of which answered from the cache
	inline size_t visibleActorsCalls = 0;    // foreach VisibleActors
	inline size_t visibleActorsTraced = 0;   // actors it traced a ray to
	inline double visibleActorsMs = 0.0;

	// mesh LOD (HP1's DrawLodMesh), per log period
	inline size_t lodMeshes = 0;          // skeletal meshes whose level was worked out
	inline size_t facesThreaded = 0, facesThreadedFog = 0, facesSerial = 0;   // #98: skeletal meshes drawn with the face loop on three cores (of which with fog), the old way
	inline double lodVerts = 0.0;         // the vertices they asked for
	inline double lodModelVerts = 0.0;    // and the vertices they have
	inline float lodAdjust = 1.0f;        // URender's LODAdjust now

	// the visibility walk on three cores (vis_threads, vita/VitaParallelVis.inc), per log period
	inline size_t visFrames = 0;          // frames (and portal frames) walked that way
	inline size_t visSerial = 0;          // walked the old way (vis_threads=0, no workers, or bounds that do not nest)
	inline size_t visRedone = 0;          // walked again the old way because the strips' guess was wrong (a warp zone made its other side)
	inline double visStripUs[3] = {};     // each strip's time
	inline double visReplayUs = 0.0;      // the main thread's walk with the strips' answers
	inline int visSplit[2] = {};          // the strips' borders now (pixels of the clipper's screen)
	inline size_t lightmapFast = 0;       // light map requests answered without looking at their lights (lightmap_skip)
	inline double lightmapDirtyMs = 0.0;   // BeginFrame checking every light of the level's light maps for it

	// For the on-screen counter (VitaOverlay.cpp): the renderer's last frame, and sums that are never reset (it takes differences)
	inline unsigned lastSurfaces = 0, lastPolygons = 0, lastDraws = 0;
	inline double totalEngineMs = 0.0;    // from the end of one frame to the start of the next picture (scripts, physics, sound)
	inline double totalPictureMs = 0.0;   // Lock to Unlock: the picture made by the engine and the renderer
	inline double totalPresentMs = 0.0;   // handing the frame over (waiting for the GL thread / vsync)
	inline double totalUploadMs = 0.0;    // texture uploads (procedural textures' new pictures included)
	inline unsigned totalUploads = 0;
}
