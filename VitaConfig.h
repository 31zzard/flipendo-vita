#pragma once

// A setting from ux0:data/flipendo/render.cfg (lines "name=value"), for the engine patches made by apply_fixes.sh.
// Read on every call, so use it where that is rare (map changes), not every frame.

#ifdef __vita__
// The app's folder on the memory card: ux0:data/flipendo (HP1), ux0:data/flipendo2 (HP2). Set by CMake for every file
// (flipendo-vita.cmake); this default is for files compiled without it.
#ifndef VITA_DATA_ROOT
#define VITA_DATA_ROOT "ux0:data/flipendo"
#endif
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <malloc.h>

inline int VitaConfigInt(const char* wanted, int defaultValue)
{
	int result = defaultValue;
	if (FILE* file = fopen(VITA_DATA_ROOT "/render.cfg", "r"))
	{
		char line[256];
		while (fgets(line, sizeof(line), file))
		{
			char name[64];
			int value = 0;
			if (sscanf(line, " %63[a-z_0-9] = %d", name, &value) == 2 && !strcmp(name, wanted))
				result = value;
		}
		fclose(file);
	}
	return result;
}

// mesh_distance in render.cfg: meshes (characters, objects) farther from the camera than this are not drawn. 0 = all
inline float VitaMeshDistance()
{
	static const float distance = (float)VitaConfigInt("mesh_distance", 0);
	return distance;
}

// clipper_scale in render.cfg: the size of the visibility clipper's virtual screen, in percent of 2048x1080. The clipper
// (BspClipper) rasterizes every wall of the level in software to find out what hides what: at 100 it works on four times
// the pixels the Vita's screen has. 50 = 1024x540, about the screen's own size. 25 is faster still, and may drop thin walls.
inline int VitaClipperPercent()
{
	static const int percent = std::clamp(VitaConfigInt("clipper_scale", 50), 10, 100);
	return percent;
}
inline int VitaClipperWidth() { return std::max(2048 * VitaClipperPercent() / 100, 128); }
inline int VitaClipperHeight() { return std::max(1080 * VitaClipperPercent() / 100, 64); }

// tick_far_distance / tick_far_rate in render.cfg: mesh actors (characters, props) not drawn for a second and farther than this from
// the camera are ticked only every tick_far_rate frames, with the time of those frames added up. 0 = every actor every frame
inline float VitaTickFarDistance() { static const float d = (float)VitaConfigInt("tick_far_distance", 2500); return d; }
inline int VitaTickFarRate() { static const int r = std::clamp(VitaConfigInt("tick_far_rate", 3), 2, 10); return r; }
// bspinfo_cache=1: an actor that has not moved is not placed in the BSP again every frame
inline bool VitaBspInfoCache() { static const bool on = VitaConfigInt("bspinfo_cache", 1) != 0; return on; }
// texture_fps: how often procedural textures (water, fire) are updated (the engine's default is 25)
inline float VitaTextureFps() { static const float fps = (float)std::clamp(VitaConfigInt("texture_fps", 12), 1, 60); return fps; }
// water_fps: new pictures of water textures (UWaterTexture, UWetTexture) a second at most: one costs several ms (apply_fixes #87)
inline float VitaWaterFps() { static const float fps = (float)std::clamp(VitaConfigInt("water_fps", 10), 1, 60); return fps; }
// fog_rate: a fog map (volumetric light in a fog zone, changes with the camera) is built again every n-th frame, not every frame
inline int VitaFogRate() { static const int n = std::clamp(VitaConfigInt("fog_rate", 3), 1, 8); return n; }

// light_anim_divider: lights that pulse, flicker or waver (torches) make their lightmaps change; that is a rebuild of the lightmap
// and an upload every frame. They are marked as changed only every n-th frame (3 = about 20 changes a second at 60 fps)
inline int VitaLightAnimDivider() { static const int n = std::clamp(VitaConfigInt("light_anim_divider", 3), 1, 12); return n; }
// trace_cache=1: a ray that ignores actors (is a wall in the way?) between the same two points is answered from memory for 0.12 s
inline bool VitaTraceCache() { static const bool on = VitaConfigInt("trace_cache", 1) != 0; return on; }
// mover_trace=1: such a ray only looks at the movers (doors) instead of walking every cell of the collision grid
inline bool VitaMoverTrace() { static const bool on = VitaConfigInt("mover_trace", 1) != 0; return on; }

// tick_far_visible: even an actor that was drawn a moment ago is ticked less often when it is farther than this many units (0 = never)
inline float VitaTickFarVisible() { static const float d = (float)std::max(VitaConfigInt("tick_far_visible", 0), 0); return d; }
// mesh_light_max: no more than this many lights per mesh (the game picks up to 3-5; each is a square root and two divisions per vertex)
inline int VitaMeshLightMax() { static const int n = std::clamp(VitaConfigInt("mesh_light_max", 16), 0, 16); return n; }
// skin_cache: the skinned vertices, normals and light of a mesh are kept: for the second pass of a frame, and for skin_cache_age
// frames while the mesh is far away and has not moved
inline bool VitaSkinCacheOn() { static const bool on = VitaConfigInt("skin_cache", 1) != 0; return on; }
inline unsigned VitaSkinFarAge() { static const unsigned n = (unsigned)std::clamp(VitaConfigInt("skin_cache_age", 2), 0, 8); return n; }
// lightmap=0 / fog=0: the engine does not even build the lightmaps / fog maps of the surfaces (the renderer would ignore them)
inline bool VitaLightmapsOn() { static const bool on = VitaConfigInt("lightmap", 1) != 0; return on; }
inline bool VitaFogOn() { static const bool on = VitaConfigInt("fog", 1) != 0; return on; }
// still_lights=1: HP1's light maps leave out the flicker of LE_TorchWaver / LE_FireWaver / LE_WateryShimmer, so a steady light with one
// of them gives the same light map every time: its surfaces are not rebuilt (the original SurrealEngine rebuilt them every frame)
inline bool VitaStillLights() { static const bool on = VitaConfigInt("still_lights", 1) != 0; return on; }
// lightmap_incremental=1: when a flickering or pulsing light changes, the sum of a surface's other (steady) lights is kept and only the
// animated ones are added to it again, instead of every light of the surface
inline bool VitaLightmapIncremental() { static const bool on = VitaConfigInt("lightmap_incremental", 1) != 0; return on; }
// dynamic_light_list=1: the dynamic lights (not bStatic, not bNoDelete) are listed once a frame, and a surface looks only at them for its
// dynamic lights, not at every light of the level in the light tree
inline bool VitaDynamicLightList() { static const bool on = VitaConfigInt("dynamic_light_list", 1) != 0; return on; }
// clipper_polygons=1: the visibility clipper draws a BSP surface as one polygon (one span per line) instead of a fan of triangles
inline bool VitaClipperPolygons() { static const bool on = VitaConfigInt("clipper_polygons", 1) != 0; return on; }
// mesh_fast=1: a mesh's vertex light four vertices at a time (NEON), and its faces handed to the renderer in runs of one material
inline bool VitaMeshFast() { static const bool on = VitaConfigInt("mesh_fast", 1) != 0; return on; }
// face_threads: a big skeletal mesh's face loop in three parts on the mesh job threads (apply_fixes #96)
inline bool VitaFaceThreads() { static const bool on = VitaConfigInt("face_threads", 1) != 0; return on; }
// tick_static=0: like HP1's ULevel::Tick, bStatic actors are not ticked (only through an owned actor). 1 = every actor, as SurrealEngine
inline bool VitaTickStatic() { static const bool on = VitaConfigInt("tick_static", 0) != 0; return on; }
// mesh_lod=1: skeletal meshes are drawn at the detail HP1's URender::DrawLodMesh picks (screen size, LODBias, LODStrength, and
// LODAdjust, which rises when the frame rate falls under MinDesiredFrameRate). 0 = always every vertex and face
inline bool VitaMeshLod() { static const bool on = VitaConfigInt("mesh_lod", 1) != 0; return on; }
// lightmap_skip=1: a light map request whose lights did not change (all of them are checked once a frame) and that no dynamic light
// reaches is answered at once, without looking at its lights
inline bool VitaLightmapSkip() { static const bool on = VitaConfigInt("lightmap_skip", 1) != 0; return on; }
#else
inline int VitaConfigInt(const char*, int defaultValue) { return defaultValue; }
inline float VitaTickFarVisible() { return 0.0f; }
inline int VitaMeshLightMax() { return 16; }
inline bool VitaSkinCacheOn() { return false; }
inline unsigned VitaSkinFarAge() { return 0; }
inline bool VitaLightmapsOn() { return true; }
inline bool VitaFogOn() { return true; }
inline bool VitaStillLights() { return false; }
inline bool VitaLightmapIncremental() { return false; }
inline bool VitaDynamicLightList() { return false; }
inline bool VitaClipperPolygons() { return false; }
inline bool VitaMeshFast() { return false; }
inline bool VitaFaceThreads() { return false; }
inline bool VitaTickStatic() { return true; }
inline bool VitaMeshLod() { return false; }
inline bool VitaLightmapSkip() { return false; }
inline int VitaLightAnimDivider() { return 1; }
inline bool VitaTraceCache() { return false; }
inline bool VitaMoverTrace() { return false; }
inline float VitaTickFarDistance() { return 0.0f; }
inline int VitaTickFarRate() { return 1; }
inline bool VitaBspInfoCache() { return false; }
inline float VitaTextureFps() { return 25.0f; }
inline float VitaWaterFps() { return 25.0f; }
inline int VitaFogRate() { return 1; }
inline int VitaClipperWidth() { return 2048; }
inline int VitaClipperHeight() { return 1080; }
inline float VitaMeshDistance() { return 0.0f; }
#endif
