#pragma once

#include "RenderDevice/RenderDevice.h"
#include <unordered_map>
#include <vector>
#include <cstdint>
#include "VitaHash.h"

namespace VitaGL { struct Texture; class Queue; }

// The Vita renderer (vitaGL, fixed function pipeline).
//
// Level surfaces (DrawComplexSurface) are drawn in passes, each one multiplied or blended over the last: the
// texture, the macro texture, the lightmap (times two, like the shader of the OpenGL renderer) and the fog map.
// Meshes (DrawGouraudPolygon) and flat tiles (DrawTile) are collected into batches that are drawn with one call
// per texture and blend mode (the engine hands over one polygon at a time).
// Not done yet: detail textures, fog on meshes, mip maps, the near clip plane of portals and mirrors, lines,
// and depth for sprites.
//
// Settings can be changed without a rebuild in ux0:data/flipendo/render.cfg (lines "name=value"):
//   lightmap_scale=2       lightmap brightness: 2 is what the original shader does, 1 is darker
//   lightmap=1             0 leaves the lightmaps out (to see what they do)
//   macro=1                0 leaves the macro textures out
//   fog=1                  0 leaves the fog maps out
//   exposure=100           brightness of the textures in percent, 10..100
//   flip_y=1               the world is drawn upside down: set 0
//   texture16=1            16 bit textures (half the memory); 0 = 32 bit, if colours look wrong
//   texture_budget_mb=64   textures not used for a while are thrown out when they take more than this
//   texture_lod=0          0..3: the level's textures are drawn from a smaller mip level (1 = half the width and height)
//   free_lightmap_data=1   the engine's float copy of a lightmap is freed once it is on the GPU (saves memory)
//   slow_frame_ms=150      a frame longer than this many milliseconds is written to the log, with its parts
//   device_timing=0        1 measures the time inside the renderer's draw calls (the 'device' figure in the log): slows it down
//   section_timers=1       0 turns off the timing of the engine's parts (the 'engine parts' figures): a little faster
//   vsync=1                0 does not wait for the screen's refresh: no rounding of the frame time up, but tearing is possible
//   surface_batching=1     plain level surfaces are drawn together (by texture, and all lightmaps from a few big textures):
//                          far fewer draw calls. 0 = every surface drawn at once, as before
//   atlas_pages=8          how many 512x512 lightmap textures there may be
//   atlas_direct=1         a lightmap is written straight into its atlas page. 0 = glTexSubImage2D, which in vitaGL makes a new copy of
//                          the whole page (1 MB) every time the page was drawn in the last frames: one per changed lightmap
//   mipmaps=0              0 = one picture per texture; 2 = the texture's own smaller pictures are uploaded too (less shimmering far
//                          away, about a third more video memory); 1 = the GPU makes them (glGenerateMipmap). Level and mesh textures only
//   upload_budget_ms=6     a frame that has spent this long uploading textures draws the next new ones from a coarse picture (an eighth
//                          of the size) and sharpens them in later frames: no long frame when many textures appear. 0 = off
//   texture_inplace=1      a texture that changes (water, fire) is changed in place, not made again (no new video memory every time)
//   heartbeat=0            1 draws the small flashing square in the top left corner (proof that frames are drawn)
//   world=1                0 hides the level surfaces
//   meshes=1               0 hides the meshes (characters, objects)
//   gl_thread=1            the OpenGL calls and presenting the picture are made on a thread of their own (VitaGLQueue.h), while the
//                          engine goes on with the next frame. 0 = on the engine's thread, as before
//   gl_thread_core=2       the core of that thread: 0, 1, 2, or -1 for any (the mesh workers are on 1 and 2)
//   gl_thread_priority=100 its priority (smaller is more urgent; the engine and its workers have engine_priority, 96)
//   surface_cache=1        plain level surfaces keep their vertices in video memory (vertex buffers): a surface drawn again only adds
//                          its triangles' indices, nothing is computed or copied. 0 = the vertices are made every frame, as before
//   surface_chunks=6       at most this many vertex buffers of 65536 vertices (1.75 MB each) for it
class VitaRenderDevice : public RenderDevice
{
public:
	VitaRenderDevice(Widget* viewport);
	~VitaRenderDevice() override;

	void Flush(bool AllowPrecache) override;
	void Lock(vec4 FlashScale, vec4 FlashFog, vec4 ScreenClear, uint8_t* HitData, int* HitSize) override;
	void Unlock(bool Blit) override;
	void DrawComplexSurface(SceneNode* Frame, SurfaceInfo& Surface, SurfaceFacet& Facet) override;
	void DrawGouraudPolygon(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumPts, uint32_t PolyFlags) override;
	void DrawGouraudTriangles(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumTriangles, uint32_t PolyFlags) override;
	void DrawTile(SceneNode* Frame, TextureInfo& Info, float X, float Y, float XL, float YL, float U, float V, float UL, float VL, float Z, vec4 Color, vec4 Fog, uint32_t PolyFlags) override;
	void Draw3DLine(SceneNode* Frame, vec4 Color, uint32_t LineFlags, vec3 P1, vec3 P2) override;
	void Draw2DLine(SceneNode* Frame, vec4 Color, uint32_t LineFlags, vec3 P1, vec3 P2) override;
	void Draw2DPoint(SceneNode* Frame, vec4 Color, uint32_t LineFlags, float X1, float Y1, float X2, float Y2, float Z) override;
	void ClearZ() override;
	void PushHit(const uint8_t* Data, int Count) override;
	void PopHit(int Count, bool bForce) override;
	void ReadPixels(TextureColor* Pixels) override;
	void EndFlash() override;
	void SetSceneNode(SceneNode* Frame) override;
	void PrecacheTexture(TextureInfo& Info, uint32_t PolyFlags) override;
	bool SupportsTextureFormat(TextureFormat Format) override;
	void UpdateTextureRect(TextureInfo& Info, int U, int V, int UL, int VL) override;

private:
	enum class Mode { None, Tiles, Scene };

	struct Settings
	{
		int lightmapScale = 2;
		bool lightmap = true;
		bool macro = true;
		bool fog = true;
		int exposure = 100;
		bool flipY = true;
		bool texture16 = true;
		int textureBudgetMb = 64;
		int textureLod = 0;
		int slowFrameMs = 150;   // a frame longer than this is logged with where its time went
		bool freeLightmapData = true;
		bool drawWorld = true;
		bool drawMeshes = true;
		bool batchSurfaces = true;
		int mipmaps = 0;
		int uploadBudgetMs = 6;
		bool textureInplace = true;
		bool heartbeat = false;
		bool sectionTimers = true;   // time the engine's parts (the log's 'engine parts' and SLOW FRAME lines); each is two system calls
		bool vsync = true;           // wait for the screen's refresh: smoother, but a frame is always a multiple of 16.7 ms long
		int atlasPages = 8;
		bool atlasDirect = true;
		bool deviceTiming = false;   // time every draw call (a system call each: slows the polygons down; for measuring only)
		bool glThread = true;
		int glThreadCore = 2;
		int glThreadPriority = 100;
		bool surfaceCache = true;
		int surfaceChunks = 6;
	};

	// A texture on the GPU, and what we know of its sampler settings (so they are only set when they change)
	struct TextureEntry
	{
		VitaGL::Texture* gpu = nullptr;   // the GL texture (made and deleted through the queue)
		int nearest = -1;
		int clamp = -1;
		uint32_t bytes = 0;
		int lastUsed = 0;   // frame number
		bool pinned = false;   // lightmaps and fog maps: their data is freed after the upload, so they cannot be loaded again
		bool provisional = false;   // only a coarse picture is on the GPU so far (see upload_budget_ms)
		uint8_t levels = 1;         // mip levels on the GPU
		uint16_t width = 0, height = 0;          // of level 0 as uploaded
		unsigned short format = 0, type = 0;     // what level 0 was uploaded as (a changed texture of the same kind is changed in place)
	};

	// What makes two polygons part of the same batch
	struct BatchKey
	{
		TextureEntry* texture = nullptr;
		uint32_t flags = 0;
		bool nearest = false;
		bool clamp = false;
		Mode mode = Mode::None;
		bool operator==(const BatchKey& o) const { return texture == o.texture && flags == o.flags && nearest == o.nearest && clamp == o.clamp && mode == o.mode; }
	};

	void LoadSettings();
	void Begin2D();
	void Begin3D();
	void LoadMatrixes(SceneNode* Frame);

	// GL state, set only when it changes
	void ResetStateCache();
	void SetBlend(int blend, bool alphaTest);
	void SetDepthMask(bool write);
	void SetDepthFunc(bool equal);
	void SetColorArray(bool on);
	void BindTexture(TextureEntry& entry, bool nearest, bool clamp);

	// textures
	// world: a level or mesh texture (may be drawn from a smaller picture first, and gets mip levels); not the HUD
	TextureEntry* GetTextureEntry(TextureInfo& Info, bool masked, int lod = 0, bool world = false);
	TextureEntry* WhiteTexture();
	void UploadTexture(TextureEntry& entry, TextureInfo& Info, bool masked, int lod, bool useMips);

	// One mip level in a form the GPU takes (the pixels live in a buffer of the device that the next call overwrites)
	struct LevelPixels
	{
		unsigned int internalFormat = 0;
		unsigned int format = 0;
		unsigned int type = 0;
		const void* data = nullptr;
		size_t bytes = 0;
		bool compressed = false;
		int width = 0, height = 0;
	};
	bool ConvertLevel(TextureInfo& Info, int mipIndex, bool masked, LevelPixels& out);
	std::vector<uint16_t> scratch16;
	std::vector<uint8_t> scratch32;
	uint16_t paletteLut16[256] = {};
	uint32_t paletteLut32[256] = {};
	const void* lutPalette = nullptr;   // which palette (and masked or not) the tables above are made for
	bool lutMasked = false;
	bool lutValid = false;
	void RemoveTexture(uint64_t key);
	void DeleteGpuTexture(TextureEntry& entry);
	void EvictTextures();
	void ClearTextureCache();

	// batches
	void SwitchBatch(const BatchKey& key);
	void FlushBatch();       // everything that was collected: the surfaces, then the polygons
	void FlushPolygons();    // the collected mesh polygons and tiles
	void FlushSurfaces();    // the collected level surfaces


	void DrawHeartbeat();

	std::unordered_map<uint64_t, TextureEntry, VitaHash64> textures;   // by (CacheID * 2 + masked) * 4 + mip level
	TextureEntry whiteTexture;
	size_t textureBytes = 0;
	uint64_t lastKey = 0;
	TextureEntry* lastEntry = nullptr;
	uint64_t lastCacheId = ~0ull;   // what the last GetTextureEntry call asked for: the same again returns lastEntry
	int lastLod = -1;
	bool lastMasked = false;

	Settings settings;
	Mode mode = Mode::None;
	// The frame set by SetSceneNode. Its numbers are copied: the engine's frame for a mover is a local variable that is
	// gone when the mover is drawn. The Frame given to the draw calls is not used: the original renderers go by
	// SetSceneNode too (a mover's polygons are drawn with the main frame but the mover's own matrices).
	bool haveFrame = false;
	int frameX = 0, frameY = 0, frameXB = 0, frameYB = 0;
	bool columnMajor = true;           // how mat4 stores its values (detected at start)
	float projectionMatrix[16] = {};
	float modelViewMatrix[16] = {};

	// GL state cache
	int curBlend = -1;
	int curAlphaTest = -1;
	int curDepthMask = -1;
	int curDepthFunc = -1;
	int curColorArray = -1;
	int curTexEnabled = -1;
	const VitaGL::Texture* curTexture = nullptr;   // null: not known
	unsigned int curArrayBuffer = 0;
	VitaGL::Queue* gl = nullptr;   // every GL call goes through it (VitaGLQueue.h)
	int cacheGeneration = 0;       // goes up when textures or lightmaps are dropped: pointers to them that were kept are void

	// the batch being collected: position, texture coordinates and colour of every vertex together (one write per vertex)
	bool batchOpen = false;
	BatchKey batchKey;
	struct BatchVertex { float x, y, z; float u, v; float r, g, b, a; };   // 36 bytes
	std::vector<BatchVertex> batchVerts;

	// Plain level surfaces (opaque, with a lightmap) are collected and drawn together at the next flush: the textures in batches by
	// texture, the lightmaps in batches by atlas page (all lightmaps live in a few big textures). Order is kept: anything else that is
	// drawn flushes them first.
	struct SurfaceBatch
	{
		TextureEntry* texture = nullptr;
		bool nearest = false;
		bool occlude = false;
		std::vector<BatchVertex> verts;
	};
	std::vector<SurfaceBatch> surfaceBatches;
	size_t surfaceBatchCount = 0;
	std::vector<std::vector<BatchVertex>> lightmapBatches;   // by atlas page
	bool surfacesPending = false;
	SurfaceBatch& GetSurfaceBatch(TextureEntry* texture, bool nearest, bool occlude);

	static constexpr int AtlasSize = 512;
	struct AtlasPage
	{
		TextureEntry entry;
		int shelfX = 0, shelfY = 0, shelfHeight = 0;
		uint8_t* pixels = nullptr;   // the page's texels in video memory (atlas_direct), null: glTexSubImage2D
		unsigned stride = 0;         // bytes per row of pixels
	};
	std::vector<AtlasPage> atlasPages;
	std::vector<uint8_t> atlasScratch;   // a lightmap with its border, for glTexSubImage2D
	int atlasCurrent = 0;
	int atlasGeneration = 0;   // goes up when the atlas starts again: every slot of an older generation is void
	struct LightmapPixels
	{
		int width = 0, height = 0;
		std::vector<uint8_t> rgba;      // our copy (the engine's float copy is given back)
		int page = -1, x = 0, y = 0;    // where it is in the atlas, with a border of one texel
		int generation = -1;
		bool stale = false;             // the picture changed through the texture path: the atlas copy is old
	};
	std::unordered_map<uint64_t, LightmapPixels, VitaHash64> lightmaps;   // by CacheID
	bool PlaceInPage(AtlasPage& page, int width, int height, int& x, int& y);
	void UploadLightmapSlot(LightmapPixels& lightmap);
	LightmapPixels* GetLightmapSlot(TextureInfo& Info, LightmapPixels* hint = nullptr);
	bool AllocateAtlasSlot(LightmapPixels& lightmap);

	// surface_cache: the vertices of plain level surfaces (DrawComplexSurface with Facet.VitaKey, the BSP node) in vertex buffers. A
	// vertex has the world position, the texture's coordinates and the lightmap's in the atlas: the texture pass and the lightmap pass
	// draw the same vertices with other texture coordinates. Per frame only index lists are made, by texture / atlas page and buffer.
	// A surface is written again (to a new place) when what its coordinates come from changes; one that changes often (panning
	// textures) is drawn the old way. When every buffer is full they are all dropped (freed a few frames later: the GPU may still
	// read them) and the surfaces are written again.
	struct SurfaceVertex { float x, y, z, u, v, lu, lv; };   // 28 bytes
	static constexpr uint32_t ChunkVertices = 65536;          // 16 bit indices
	struct SurfaceChunk
	{
		unsigned int buffer = 0;
		SurfaceVertex* data = nullptr;   // the buffer's memory, written directly
		uint32_t used = 0;
	};
	struct CachedSurface
	{
		float uPan = 0, vPan = 0, uMult = 0, vMult = 0;
		float lmUPan = 0, lmVPan = 0, lmUMult = 0, lmVMult = 0;
		float x0 = 0, y0 = 0, z0 = 0;          // the first vertex: proof that the key still names this surface
		LightmapPixels* lm = nullptr;          // its atlas slot (a shortcut past the lookup by CacheID)
		uint64_t lmCacheId = 0;
		TextureEntry* tex = nullptr;           // its texture (a shortcut past GetTextureEntry)
		uint64_t texCacheId = 0;
		int lmGeneration = -1, lmPage = -1, lmX = 0, lmY = 0, lmW = 0, lmH = 0;
		int generation = -1;                   // cacheGeneration when lm and tex were taken
		int chunkGeneration = -1;              // surfaceChunkGeneration when it was written
		uint32_t first = 0;                    // its first vertex in the buffer
		uint16_t chunk = 0;
		uint16_t count = 0;
		uint8_t rewrites = 0;
		bool written = false;
		bool unstable = false;                 // changed too often: drawn the old way
	};
	struct IndexBatch
	{
		TextureEntry* texture = nullptr;       // null: a lightmap batch (page)
		int page = -1;
		bool nearest = false;
		bool occlude = false;
		uint16_t chunk = 0;
		std::vector<uint16_t> indices;
	};
	bool DrawCachedSurface(CachedSurface& cached, const SurfaceFacet& Facet, TextureEntry* texture, bool nearest, bool occlude, LightmapPixels* slot,
		const float* sig);
	void SetArrayBuffer(unsigned int buffer);
	IndexBatch& GetIndexBatch(std::vector<IndexBatch>& list, size_t& count, TextureEntry* texture, int page, bool nearest, bool occlude, uint16_t chunk);
	bool AllocateSurface(uint16_t count, uint16_t& chunk, uint32_t& first);
	void ResetSurfaceCache();
	void ReleaseRetiredChunks(bool all);
	void DrawIndexBatches(std::vector<IndexBatch>& list, size_t& count, bool lightmaps);
	std::vector<SurfaceChunk> surfaceChunks;
	int surfaceChunkCurrent = 0;
	int surfaceChunkGeneration = 0;
	struct RetiredChunk { unsigned int buffer; int frame; };
	std::vector<RetiredChunk> retiredChunks;
	std::vector<int32_t> surfaceIndex;          // by key: index into cachedSurfaces, -1 = none
	std::vector<CachedSurface> cachedSurfaces;
	std::vector<IndexBatch> textureIndexBatches, lightIndexBatches;
	size_t textureIndexCount = 0, lightIndexCount = 0;
	size_t lastTextureIndexBatch = 0;
	int statCachedSurfaces = 0, statWrittenSurfaces = 0, statUnstableSurfaces = 0, statSurfaceResets = 0;

	// vertex data of the level surface being drawn
	std::vector<float> positions;
	std::vector<float> uv0;
	std::vector<float> uv1;
	std::vector<float> uv2;
	std::vector<float> uv3;

	int width = 0;
	int height = 0;
	int frameCount = 0;
	int statSurfaces = 0;
	int statPolygons = 0;
	int statTiles = 0;
	int statDraws = 0;
	int statEvicted = 0;
	// texture uploads (in the log every 120 frames, and in SLOW FRAME lines)
	double uploadMsFrame = 0.0;   // spent on uploads in this frame so far
	int uploadsFrame = 0;
	int statUploads = 0;
	double statUploadMs = 0.0;
	int statDeferred = 0;         // textures that first got a coarse picture
	int statLightmapUploads = 0;  // lightmaps written into the atlas
	int statAtlasResets = 0;      // times every atlas page was full and the atlas started again
	float loggedBrightness = -1.0f;
	bool memoryLogged = false;

	// where the time goes, in milliseconds, summed over accFrames frames (logged every 120)
	double lockTime = 0.0;
	double lastUnlockEnd = 0.0;
	double accEngine = 0.0;   // between the end of one frame and the start of the next: scripts, physics, sound
	double accRender = 0.0;   // from Lock to Unlock: the engine preparing the picture and the renderer's own calls
	double accSwap = 0.0;     // presenting the frame (waiting for the screen)
	int accFrames = 0;
	int slowLogged = 0;       // slow frame lines written in this period (at most 20)
	double slowBefore[32] = {};   // the section timers at the end of the last frame
};
