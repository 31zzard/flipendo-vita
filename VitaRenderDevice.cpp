#include "Precomp.h"
#include "VitaRenderDevice.h"
#include "Utils/Logger.h"
#include "VitaTimers.h"
#include "VitaStats.h"
#include "VitaProbes.h"
#include "VitaConfig.h"
#include "VitaBoot.h"
#include "GC/GC.h"
#include <malloc.h>
#include "Packages/Engine/Resources/Level/UModel.h"
#include <surrealwidgets/core/widget.h>

#include <vitaGL.h>
#include <psp2/gxm.h>
#include <psp2/display.h>
#include <psp2/kernel/cpu.h>
#include "VitaGLQueue.h"
#include <psp2/kernel/processmgr.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <vector>
#include <arm_neon.h>

// A light or fog map's floats to bytes, as (uint8_t)(clamp(v, 0, 1) * 255 + 0.5) one by one did (NEON's conversion truncates like the
// C cast; a NaN stays NaN through the clamps and converts to 0 both ways; flush to zero is on for both). Four at a time: the scalar
// loop's float to integer conversions were ~4 ms a frame in Lev4_Sneak2's opening (36 light maps built again a frame).
// Input to screen (log line 'input to screen'): when each frame the engine began (the input of that frame is read at its start)
// went to the screen. The display callback (vglSetDisplayCallback) runs on the display queue's thread: plain globals only.
static uint64_t vitaFrameStarts[64];
static volatile uint32_t vitaFramesSwapped = 0, vitaFramesShown = 0;
static volatile uint64_t vitaShownUsSum = 0, vitaShownCount = 0;
static uint64_t vitaNextFrameStart = 0;   // the end of the last Unlock: where the next frame's input is read (main thread)
static void VitaFrameShown(void*)
{
	vitaShownVcount = sceDisplayGetVcount();   // fps_lock's pacing (VitaGLQueue.h)
	const uint32_t shown = vitaFramesShown;
	if (shown >= vitaFramesSwapped)
		return;
	__sync_synchronize();
	const uint64_t start = vitaFrameStarts[shown % 64];
	vitaShownUsSum += sceKernelGetProcessTimeWide() - start;
	vitaShownCount++;
	vitaFramesShown = shown + 1;
}

static void VitaFloatsToBytes(const float* in, uint8_t* out, size_t n)
{
	const float32x4_t zero = vdupq_n_f32(0.0f), one = vdupq_n_f32(1.0f), scale = vdupq_n_f32(255.0f), half = vdupq_n_f32(0.5f);
	size_t i = 0;
	for (; i + 8 <= n; i += 8)
	{
		float32x4_t a = vld1q_f32(in + i), b = vld1q_f32(in + i + 4);
		a = vminq_f32(vmaxq_f32(a, zero), one);
		b = vminq_f32(vmaxq_f32(b, zero), one);
		a = vaddq_f32(vmulq_f32(a, scale), half);
		b = vaddq_f32(vmulq_f32(b, scale), half);
		const uint16x8_t w = vcombine_u16(vmovn_u32(vcvtq_u32_f32(a)), vmovn_u32(vcvtq_u32_f32(b)));
		vst1_u8(out + i, vmovn_u16(w));
	}
	for (; i < n; i++)
	{
		float v = in[i];
		v = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
		out[i] = (uint8_t)(v * 255.0f + 0.5f);
	}
}

#ifndef GL_COMPRESSED_RGBA_S3TC_DXT1_EXT
#define GL_COMPRESSED_RGBA_S3TC_DXT1_EXT 0x83F1
#endif

static double NowMs()
{
	return sceKernelGetProcessTimeWide() / 1000.0;
}

// Time spent inside the renderer's own draw calls (not the engine preparing the picture), summed up
static double deviceMs = 0.0;
static int meshCallsPeriod = 0;   // meshes drawn in the last log period (for the 'laps' line)

// (the clock is a system call: only when device_timing=1, or every polygon would pay for two of them)
static bool deviceTimingOn = false;

struct ScopedDeviceTimer
{
	double start = deviceTimingOn ? NowMs() : 0.0;
	~ScopedDeviceTimer()
	{
		if (deviceTimingOn)
			deviceMs += NowMs() - start;
	}
};

// Blend modes
enum
{
	BlendNone,
	BlendTranslucent,
	BlendModulated,
	BlendHighlighted,
	BlendFont,
	BlendLightmap1,
	BlendLightmap2,
	BlendFog
};

// The flags that matter for a batch
enum
{
	KeyTranslucent = 1,
	KeyModulated = 2,
	KeyHighlighted = 4,
	KeyMasked = 8,
	KeyFont = 16,
	KeyOcclude = 32
};

static uint32_t KeyFlags(uint32_t polyFlags)
{
	uint32_t flags = 0;
	if (polyFlags == PF_SubpixelFont) flags |= KeyFont;
	if (polyFlags & PF_Translucent) flags |= KeyTranslucent;
	if (polyFlags & PF_Modulated) flags |= KeyModulated;
	if (polyFlags & PF_Highlighted) flags |= KeyHighlighted;
	if (polyFlags & PF_Masked) flags |= KeyMasked;
	if (polyFlags & PF_Occlude) flags |= KeyOcclude;
	return flags;
}

static int BlendFor(uint32_t flags)
{
	if (flags & KeyFont) return BlendFont;   // approximation of the OpenGL renderer's constant-colour blend
	if (flags & KeyTranslucent) return BlendTranslucent;
	if (flags & KeyModulated) return BlendModulated;
	if (flags & KeyHighlighted) return BlendHighlighted;
	return BlendNone;
}

VitaRenderDevice::VitaRenderDevice(Widget* viewport)
{
	Viewport = viewport;

	Viewport->CreateGLContext();
	Viewport->MakeGLContextCurrent();
	Viewport->SetGLSwapInterval(1);

	const char* version = (const char*)glGetString(GL_VERSION);
	const char* renderer = (const char*)glGetString(GL_RENDERER);
	LogMessage("VitaRenderDevice: sizeof is " + std::to_string(sizeof(VitaRenderDevice)) + " in the constructor");
	// __DATE__ / __TIME__ tell which build is running (they change whenever this file is compiled again)
	LogMessage(std::string("VitaRenderDevice: built ") + __DATE__ + " " + __TIME__ + ", OpenGL " + (version ? version : "?") + " on " + (renderer ? renderer : "?"));

	// Where does mat4 keep a translation? OpenGL (column major) wants it in the last column: values 12, 13, 14.
	mat4 t = mat4::translate(1.0f, 2.0f, 3.0f);
	if (t.matrix[12] == 1.0f && t.matrix[13] == 2.0f && t.matrix[14] == 3.0f)
		columnMajor = true;
	else if (t.matrix[3] == 1.0f && t.matrix[7] == 2.0f && t.matrix[11] == 3.0f)
		columnMajor = false;
	LogMessage(std::string("VitaRenderDevice: mat4 is ") + (columnMajor ? "column major" : "row major"));

	LoadSettings();
	Viewport->SetGLSwapInterval(settings.vsync ? 1 : 0);
	vglSetDisplayCallback(&VitaFrameShown);

	// VitaFloatsToBytes against the scalar loop it replaced: edges, NaN, and a sweep (log line; it must say 0 differ)
	{
		std::vector<float> in;
		const float edges[] = { -1.0f, -0.0f, 0.0f, 1e-40f, 0.5f / 255.0f, 0.5f, 0.998f, 1.0f, 1.0001f, 7.0f, NAN, INFINITY, -INFINITY };
		for (float e : edges)
			in.push_back(e);
		for (int i = 0; i < 200000; i++)
			in.push_back(-0.1f + 1.2f * (float)i / 200000.0f);
		std::vector<uint8_t> fast(in.size()), slow(in.size());
		VitaFloatsToBytes(in.data(), fast.data(), in.size());
		size_t differ = 0;
		for (size_t i = 0; i < in.size(); i++)
		{
			float v = in[i];
			v = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
			slow[i] = (uint8_t)(v * 255.0f + 0.5f);
			if (slow[i] != fast[i])
				differ++;
		}
		LogMessage("VitaFloatsToBytes self-test: " + std::to_string(in.size()) + " values, " + std::to_string(differ) + " differ from the scalar loop");
	}

	// The GL calls go through the queue: on the "glsubmit" thread (gl_thread=1) or at once
	gl = new VitaGL::Queue();
	if (settings.glThread)
	{
		const int masks[3] = { SCE_KERNEL_CPU_MASK_USER_0, SCE_KERNEL_CPU_MASK_USER_1, SCE_KERNEL_CPU_MASK_USER_2 };
		const int mask = settings.glThreadCore >= 0 && settings.glThreadCore <= 2 ? masks[settings.glThreadCore] : 0;
		const bool started = gl->Start(settings.glThreadPriority, mask);
		LogMessage(std::string("VitaRenderDevice: GL calls ") + (started ? "on the glsubmit thread (core " + std::to_string(settings.glThreadCore) +
			", priority " + std::to_string(settings.glThreadPriority) + ")" : "on the engine's thread: the glsubmit thread could not be started"));
	}
}

VitaRenderDevice::~VitaRenderDevice()
{
	ClearTextureCache();
	ResetSurfaceCache();
	ReleaseRetiredChunks(true);
	gl->WaitIdle();
	// (the thread stays, waiting: it holds no memory of the device)
}

// ux0:data/flipendo/render.cfg: lines "name=value", see VitaRenderDevice.h
void VitaRenderDevice::LoadSettings()
{
	if (const char* env = getenv("RCFG_fps_lock"))   // newer than most render.cfg files on the card: the override needs no line there
		settings.fpsLock = atoi(env);
	FILE* file = fopen(VITA_DATA_ROOT "/render.cfg", "r");
	if (file)
	{
		char line[256];
		while (fgets(line, sizeof(line), file))
		{
			char name[64];
			int value = 0;
			if (sscanf(line, " %63[a-z_0-9] = %d", name, &value) != 2)
				continue;
			char envName[80]; // RCFG_<name> wins here too, as in VitaConfigInt (a key must be in the file)
			snprintf(envName, sizeof(envName), "RCFG_%s", name);
			if (const char* env = getenv(envName))
				value = atoi(env);
			if (!strcmp(name, "lightmap_scale")) settings.lightmapScale = value;
			else if (!strcmp(name, "lightmap")) settings.lightmap = value != 0;
			else if (!strcmp(name, "macro")) settings.macro = value != 0;
			else if (!strcmp(name, "fog")) settings.fog = value != 0;
			else if (!strcmp(name, "exposure")) settings.exposure = std::clamp(value, 10, 100);
			else if (!strcmp(name, "flip_y")) settings.flipY = value != 0;
			else if (!strcmp(name, "texture16")) settings.texture16 = value != 0;
			else if (!strcmp(name, "texture_budget_mb")) settings.textureBudgetMb = std::clamp(value, 8, 512);
			else if (!strcmp(name, "texture_lod")) settings.textureLod = std::clamp(value, 0, 3);
			else if (!strcmp(name, "free_lightmap_data")) settings.freeLightmapData = value != 0;
			else if (!strcmp(name, "slow_frame_ms")) settings.slowFrameMs = std::clamp(value, 30, 5000);
			else if (!strcmp(name, "device_timing")) settings.deviceTiming = value != 0;
			else if (!strcmp(name, "surface_batching")) settings.batchSurfaces = value != 0;
			else if (!strcmp(name, "mipmaps")) settings.mipmaps = std::clamp(value, 0, 2);
			else if (!strcmp(name, "upload_budget_ms")) settings.uploadBudgetMs = std::clamp(value, 0, 100);
			else if (!strcmp(name, "texture_inplace")) settings.textureInplace = value != 0;
			else if (!strcmp(name, "heartbeat")) settings.heartbeat = value != 0;
			else if (!strcmp(name, "section_timers")) settings.sectionTimers = value != 0;
			else if (!strcmp(name, "vsync")) settings.vsync = value != 0;
			else if (!strcmp(name, "fps_lock")) settings.fpsLock = value;
			else if (!strcmp(name, "atlas_pages")) settings.atlasPages = std::clamp(value, 1, 16);
			else if (!strcmp(name, "atlas_direct")) settings.atlasDirect = value != 0;
			else if (!strcmp(name, "probes")) VitaProbes::wanted = value != 0;
			else if (!strcmp(name, "world")) settings.drawWorld = value != 0;
			else if (!strcmp(name, "meshes")) settings.drawMeshes = value != 0;
			else if (!strcmp(name, "gl_thread")) settings.glThread = value != 0;
			else if (!strcmp(name, "gl_thread_core")) settings.glThreadCore = std::clamp(value, -1, 2);
			else if (!strcmp(name, "gl_thread_priority")) settings.glThreadPriority = std::clamp(value, 64, 191);
			else if (!strcmp(name, "surface_cache")) settings.surfaceCache = value != 0;
			else if (!strcmp(name, "surface_chunks")) settings.surfaceChunks = std::clamp(value, 1, 16);
		}
		fclose(file);
	}
	// The player's frame rate cap: 30 (every game frame two refreshes long, even) or 60 (vsync only); anything else is 60
	settings.fpsLock = settings.fpsLock == 30 ? 30 : 60;
	deviceTimingOn = settings.deviceTiming;
	VitaTimers::enabled = settings.sectionTimers;
	LogMessage("VitaRenderDevice: settings lightmap_scale=" + std::to_string(settings.lightmapScale) +
		" lightmap=" + std::to_string(settings.lightmap) + " macro=" + std::to_string(settings.macro) + " fog=" + std::to_string(settings.fog) +
		" exposure=" + std::to_string(settings.exposure) +
		" flip_y=" + std::to_string(settings.flipY) + " texture16=" + std::to_string(settings.texture16) +
		" texture_budget_mb=" + std::to_string(settings.textureBudgetMb) + " texture_lod=" + std::to_string(settings.textureLod) +
		" free_lightmap_data=" + std::to_string(settings.freeLightmapData) +
		" world=" + std::to_string(settings.drawWorld) + " meshes=" + std::to_string(settings.drawMeshes) +
		" device_timing=" + std::to_string(settings.deviceTiming) + " surface_batching=" + std::to_string(settings.batchSurfaces) + " section_timers=" + std::to_string(settings.sectionTimers) + " mipmaps=" + std::to_string(settings.mipmaps) + " upload_budget_ms=" + std::to_string(settings.uploadBudgetMs) + " texture_inplace=" + std::to_string(settings.textureInplace) + " heartbeat=" + std::to_string(settings.heartbeat) + " vsync=" + std::to_string(settings.vsync) + " fps_lock=" + std::to_string(settings.fpsLock) +
		" atlas_pages=" + std::to_string(settings.atlasPages) + " atlas_direct=" + std::to_string(settings.atlasDirect) +
		" gl_thread=" + std::to_string(settings.glThread) + " gl_thread_core=" + std::to_string(settings.glThreadCore) +
		" gl_thread_priority=" + std::to_string(settings.glThreadPriority) + " surface_cache=" + std::to_string(settings.surfaceCache) +
		" surface_chunks=" + std::to_string(settings.surfaceChunks) +
		(file ? "" : " (no render.cfg: defaults)"));
}

/////////////////////////////////////////////////////////////////////////////
// GL state, set only when it changes

void VitaRenderDevice::ResetStateCache()
{
	curBlend = -1;
	curAlphaTest = -1;
	curDepthMask = -1;
	curDepthFunc = -1;
	curColorArray = -1;
	curTexEnabled = -1;
	curTexture = nullptr;
}

void VitaRenderDevice::SetBlend(int blend, bool alphaTest)
{
	if (blend != curBlend)
	{
		curBlend = blend;
		switch (blend)
		{
		case BlendNone:
			gl->Disable(GL_BLEND);
			break;
		case BlendTranslucent:
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
			break;
		case BlendModulated:
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_DST_COLOR, GL_SRC_COLOR);
			break;
		case BlendHighlighted:
		case BlendFog:   // fog colour plus what is below, less the fog's opacity
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
			break;
		case BlendFont:
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			break;
		case BlendLightmap1:
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_DST_COLOR, GL_ZERO);
			break;
		case BlendLightmap2:
			gl->Enable(GL_BLEND);
			gl->BlendFunc(GL_DST_COLOR, GL_SRC_COLOR);
			break;
		}
	}

	// The alpha test cuts a masked texture's holes. Under a premultiplied (PF_Highlighted) blend the fragment's alpha is the texel's
	// times the vertex alpha (a faded mesh: Harry under the invisibility cloak, ~0.3): there only the holes (alpha 0) are cut, or the
	// whole masked material of a faded mesh would vanish. The texel alphas of masked textures are 0 or 1, so 0.5 and 0 cut the same.
	const int alphaMode = !alphaTest ? 0 : (blend == BlendHighlighted ? 2 : 1);
	if (alphaMode != curAlphaTest)
	{
		curAlphaTest = alphaMode;
		if (alphaMode)
		{
			gl->Enable(GL_ALPHA_TEST);
			gl->AlphaFunc(GL_GREATER, alphaMode == 2 ? 0.0f : 0.5f);
		}
		else
		{
			gl->Disable(GL_ALPHA_TEST);
		}
	}
}

void VitaRenderDevice::SetDepthMask(bool write)
{
	if ((int)write != curDepthMask)
	{
		curDepthMask = (int)write;
		gl->DepthMask(write ? GL_TRUE : GL_FALSE);
	}
}

void VitaRenderDevice::SetDepthFunc(bool equal)
{
	if ((int)equal != curDepthFunc)
	{
		curDepthFunc = (int)equal;
		gl->DepthFunc(equal ? GL_EQUAL : GL_LEQUAL);
	}
}

void VitaRenderDevice::SetColorArray(bool on)
{
	if ((int)on != curColorArray)
	{
		curColorArray = (int)on;
		if (on)
			gl->EnableClientState(GL_COLOR_ARRAY);
		else
			gl->DisableClientState(GL_COLOR_ARRAY);
	}
}

void VitaRenderDevice::BindTexture(TextureEntry& entry, bool nearest, bool clamp)
{
	if (curTexEnabled != 1)
	{
		curTexEnabled = 1;
		gl->Enable(GL_TEXTURE_2D);
	}
	if (curTexture != entry.gpu)
	{
		curTexture = entry.gpu;
		gl->BindTexture(entry.gpu);
	}
	if (entry.nearest != (int)nearest)
	{
		entry.nearest = (int)nearest;
		const bool mips = entry.levels > 1;
		const GLint magFilter = nearest ? GL_NEAREST : GL_LINEAR;
		const GLint minFilter = nearest ? (mips ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST) : (mips ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR);
		gl->TexParameteri(GL_TEXTURE_MIN_FILTER, minFilter);
		gl->TexParameteri(GL_TEXTURE_MAG_FILTER, magFilter);
	}
	if (entry.clamp != (int)clamp)
	{
		entry.clamp = (int)clamp;
		GLint wrap = clamp ? GL_CLAMP_TO_EDGE : GL_REPEAT;
		gl->TexParameteri(GL_TEXTURE_WRAP_S, wrap);
		gl->TexParameteri(GL_TEXTURE_WRAP_T, wrap);
	}
}

/////////////////////////////////////////////////////////////////////////////
// frames

void VitaRenderDevice::Flush(bool AllowPrecache)
{
	ClearTextureCache();
	// a new level: the keys of the surface cache (BSP nodes) name other surfaces now
	ResetSurfaceCache();
	surfaceIndex.clear();
	cachedSurfaces.clear();
}

void VitaRenderDevice::Lock(vec4 FlashScale, vec4 FlashFog, vec4 ScreenClear, uint8_t* HitData, int* HitSize)
{
	if (Brightness != loggedBrightness)
	{
		loggedBrightness = Brightness;
		LogMessage("VitaRenderDevice: the engine's brightness is " + std::to_string(Brightness) + " (0.5 means no gamma change), gamma mode " + std::to_string(GammaMode) + ", light mode " + std::to_string(LightMode));
	}

	lockTime = NowMs();
	// The lap timers run in one frame of VitaProbes::SampleEvery (from this frame's drawing to the next frame's tick)
	static const int probeEvery = std::max(1, VitaConfigInt("probe_every", VitaProbes::SampleEvery)); // render.cfg probe_every=1: every frame (slow frames get their laps)
	VitaProbes::enabled = VitaProbes::wanted && (frameCount % probeEvery) == 0;
	if (VitaProbes::enabled)
		VitaProbes::sampledFrames++;
	if (lastUnlockEnd > 0.0)
	{
		accEngine += lockTime - lastUnlockEnd;
		VitaStats::totalEngineMs += lockTime - lastUnlockEnd;
	}

	width = Viewport->GetNativePixelWidth();
	height = Viewport->GetNativePixelHeight();
	mode = Mode::None;
	haveFrame = false;
	batchOpen = false;
	batchVerts.clear();
	surfacesPending = false;
	surfaceBatchCount = 0;
	uploadMsFrame = 0.0;
	uploadsFrame = 0;
	statSurfaces = statPolygons = statTiles = statDraws = 0;

	gl->Viewport(0, 0, width, height);
	gl->DepthMask(GL_TRUE);
	gl->ClearColor(ScreenClear.x, ScreenClear.y, ScreenClear.z, 1.0f);
	gl->Clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	gl->Disable(GL_CULL_FACE);
	gl->EnableClientState(GL_VERTEX_ARRAY);
	gl->EnableClientState(GL_TEXTURE_COORD_ARRAY);
	gl->DisableClientState(GL_COLOR_ARRAY);
	gl->BindArrayBuffer(0);
	curArrayBuffer = 0;
	textureIndexCount = lightIndexCount = 0;
	lastTextureIndexBatch = 0;
	ResetStateCache();
	curDepthMask = 1;
	curColorArray = 0;
}

void VitaRenderDevice::Unlock(bool Blit)
{
	{
		ScopedDeviceTimer timer;
		FlushBatch();
	}
	EvictTextures();
	if (settings.heartbeat)
		DrawHeartbeat();

	ReleaseRetiredChunks(false);

	double beforeSwap = NowMs();
	accRender += beforeSwap - lockTime;
	VitaStats::totalPictureMs += beforeSwap - lockTime;   // the on-screen counter (VitaOverlay.cpp)
	VitaStats::lastSurfaces = statSurfaces;
	VitaStats::lastPolygons = statPolygons;
	VitaStats::lastDraws = statDraws;
	VitaStats::totalUploadMs += uploadMsFrame;
	VitaStats::totalUploads += uploadsFrame;

	// With the thread: the frame is handed over (waiting for the one before); the thread presents it
	// fps_lock=30 (render.cfg, with vsync): a frame of the game stays two refreshes on the screen, every frame 33.3 ms; the menus and
	// loading screens (no level surface drawn) keep 60
	const int swapInterval = !settings.vsync ? 0 : (settings.fpsLock == 30 && statSurfaces > 0 ? 2 : 1);
	{
		const uint32_t n = vitaFramesSwapped;
		if (n - vitaFramesShown < 60)   // the callback keeps up (else nothing is added: measuring stops, nothing breaks)
		{
			vitaFrameStarts[n % 64] = vitaNextFrameStart ? vitaNextFrameStart : sceKernelGetProcessTimeWide();
			__sync_synchronize();
			vitaFramesSwapped = n + 1;
		}
	}
	if (gl->Threaded())
	{
		// fps_lock: paced here, on the engine's thread, before the hand-over: the next frame then starts (and reads the sticks)
		// after the wait, not a frame earlier (pacing on the GL thread: 70 ms from input to screen, here: less)
		if (swapInterval >= 2)
			VitaPaceTwoRefreshes();
		gl->Swap(swapInterval >= 2 ? 1 : swapInterval);
		gl->Submit();
	}
	else
	{
		static int lastInterval = -1;
		const int wanted = swapInterval >= 2 ? 1 : swapInterval;   // 2: paced here, vitaGL at 1 (VitaGLQueue.h)
		if (wanted != lastInterval)
		{
			lastInterval = wanted;
			eglSwapInterval(0, wanted);
		}
		if (swapInterval >= 2)
			VitaPaceTwoRefreshes();
		Viewport->SwapGLBuffers();
	}

	double now = NowMs();
	accSwap += now - beforeSwap;
	VitaStats::totalPresentMs += now - beforeSwap;
	const double frameMs = lastUnlockEnd > 0.0 ? now - lastUnlockEnd : 0.0;
	lastUnlockEnd = now;
	vitaNextFrameStart = sceKernelGetProcessTimeWide();
	frameCount++;
	if (frameCount == 1)
		VitaBootMark("the first frame is shown");

	// A frame that took long (a spell being cast, a sound being loaded): where did its time go? The timers are sums, so the
	// parts of this frame are what they gained since the end of the last frame.
	{
		using namespace VitaTimers;
		static_assert(Count <= 32, "slowBefore is too small");
		double* before = slowBefore;
		static double slowProbeBefore[VitaProbes::Count] = {};
		if (frameMs > settings.slowFrameMs && slowLogged < 400)
		{
			slowLogged++;
			auto d = [&](Section section)
			{
				char text[32];
				snprintf(text, sizeof(text), "%.0f", ms[section] - before[section]);
				return std::string(text);
			};
			LogMessage("SLOW FRAME " + std::to_string((int)frameMs) + " ms: level tick " + d(LevelTick) + " (particles " + d(ParticleTick) +
				", sound decoding " + d(SoundLoad) + "), console " + d(ConsoleTick) + ", audio " + d(Audio) + ", draw game " + d(DrawGame) +
				" [bsp info " + d(BspInfo) + ", process " + d(Process) + ", draw nodes " + d(DrawNodes) + " (meshes " + d(Mesh) +
				", particles " + d(Particles) + ", lightmaps " + d(Lightmaps) + "; sky/mirrors " + d(DrawPortals) + ", translucent " + d(DrawTranslucent) +
				", procedural textures " + d(TexUpdate) + ")]; " + std::to_string(statSurfaces) + " surfaces, " +
				std::to_string(statPolygons) + " polygons, " + std::to_string(statTiles) + " tiles, " + std::to_string(statDraws) + " draw calls; texture uploads " + std::to_string(uploadsFrame) +
				" (" + std::to_string((int)uploadMsFrame) + " ms)");
			if (VitaProbes::enabled && VitaProbes::wanted)   // probe_every=1: this frame's biggest laps
			{
				std::vector<std::pair<double, int>> top;
				for (int i = 0; i < VitaProbes::Count; i++)
					if (VitaProbes::us[i] - slowProbeBefore[i] > 1000.0)
						top.push_back({ VitaProbes::us[i] - slowProbeBefore[i], i });
				std::sort(top.begin(), top.end(), [](auto& a, auto& b) { return a.first > b.first; });
				std::string text = "SLOW FRAME laps (ms):";
				for (size_t i = 0; i < top.size() && i < 16; i++)
				{
					char part[96];
					snprintf(part, sizeof(part), " %s %.1f;", VitaProbes::names[top[i].second], top[i].first / 1000.0);
					text += part;
				}
				LogMessage(text);
			}
		}
		for (int i = 0; i < Count; i++)
			before[i] = ms[i];
		for (int i = 0; i < VitaProbes::Count; i++)
			slowProbeBefore[i] = VitaProbes::us[i];
	}

	// Where the time goes, every 120 frames: engine (scripts, physics, sound), the picture (the engine preparing it
	// plus the renderer's own calls, of which "device" is the part inside this file), waiting to present
	if (++accFrames == 120)
	{
		{
			const uint64_t sum = vitaShownUsSum, cnt = vitaShownCount;
			static uint64_t lastSum = 0, lastCnt = 0;
			if (cnt > lastCnt)
				LogMessage("VitaRenderDevice: input to screen " + std::to_string((double)(sum - lastSum) / (double)(cnt - lastCnt) / 1000.0) +
					" ms on average (a frame's start to its showing; " + std::to_string(cnt - lastCnt) + " frames shown)");
			lastSum = sum;
			lastCnt = cnt;
		}
		LogMessage("VitaRenderDevice: frame " + std::to_string(frameCount) + ", per frame: engine " +
			std::to_string(accEngine / accFrames) + " ms, picture " + std::to_string(accRender / accFrames) +
			" ms (device " + std::to_string(deviceMs / accFrames) + " ms), present " + std::to_string(accSwap / accFrames) +
			" ms; last frame " + std::to_string(statSurfaces) + " surfaces, " + std::to_string(statPolygons) +
			" polygons, " + std::to_string(statTiles) + " tiles, " + std::to_string(statDraws) + " draw calls; " +
			std::to_string(textures.size()) + " textures, " + std::to_string(textureBytes / (1024 * 1024)) + " MB, " +
			std::to_string(statEvicted) + " thrown out; texture uploads in the period: " + std::to_string(statUploads) + " (" +
			std::to_string((int)statUploadMs) + " ms, " + std::to_string(statDeferred) + " coarse first); lightmaps into the atlas: " +
			std::to_string(statLightmapUploads) + ", atlas full and started again: " + std::to_string(statAtlasResets) + " times (" +
			std::to_string(atlasPages.size()) + " pages, " + std::to_string(lightmaps.size()) + " lightmaps known)");

		// The surface cache and the GL thread
		{
			const double n = std::max(1, accFrames);
			size_t chunkVertices = 0;
			for (const SurfaceChunk& c : surfaceChunks)
				chunkVertices += c.used;
			const VitaGL::Queue::Stats q = gl->TakeStats();
			const double qn = std::max(1, q.frames);
			char text[512];
			snprintf(text, sizeof(text), "VitaRenderDevice: surface cache: %.0f surfaces a frame from video memory, %.1f written, %d changing too "
				"often (drawn the old way), %d buffers (%.1f MB, %u vertices used), all dropped %d times; GL thread: %s",
				statCachedSurfaces / n, statWrittenSurfaces / n, statUnstableSurfaces, (int)surfaceChunks.size(),
				surfaceChunks.size() * ChunkVertices * sizeof(SurfaceVertex) / (1024.0 * 1024.0), (unsigned)chunkVertices, statSurfaceResets,
				gl->Threaded() ? "" : "off");
			std::string line = text;
			if (gl->Threaded())
			{
				snprintf(text, sizeof(text), "%.1f ms a frame making the calls (%.0f calls), %.1f ms presenting; the engine waited for it %.1f ms a frame",
					q.execUs / 1000.0 / qn, q.commands / qn, q.swapUs / 1000.0 / qn, q.waitedUs / 1000.0 / n);
				line += text;
			}
			LogMessage(line);
			statCachedSurfaces = statWrittenSurfaces = 0;
		}

		// Where the engine's own time goes, per game frame
		{
			using namespace VitaTimers;
			const double n = std::max(1, calls[LevelTick]);
			auto f = [&](Section section)
			{
				char text[32];
				snprintf(text, sizeof(text), "%.1f", ms[section] / n);
				return std::string(text);
			};
			if (VitaTimers::heapProbe == 1) // heap_probe=1: where the heap grew
			{
				static const char* const sectionNames[] = { "LevelTick", "ConsoleTick", "Audio", "DrawGame", "BspInfo", "Process", "DrawNodes", "Mesh",
					"Particles", "Lightmaps", "ParticleTick", "SoundLoad", "DrawPortals", "DrawOpaque", "DrawActors", "DrawTranslucent", "DrawBrushes",
					"Hud", "Overlays", "LightBegin", "Coronas", "Unlock", "Input", "Mods", "ViewFlash", "LoopRest", "EntryTick", "TexUpdate" };
				static_assert(sizeof(sectionNames) / sizeof(sectionNames[0]) == VitaTimers::Count, "section names");
				std::string text = "VitaRenderDevice: heap growth by section, KB in the period:";
				for (int i = 0; i < VitaTimers::Count; i++)
				{
					if (VitaTimers::heapGrowth[i] != 0)
						text += std::string(" ") + sectionNames[i] + " " + std::to_string(VitaTimers::heapGrowth[i] / 1024);
					VitaTimers::heapGrowth[i] = 0;
				}
				LogMessage(text + "; heap now " + std::to_string(VitaTimers::HeapInUse() / 1024) + " KB");
			}
			LogMessage("VitaRenderDevice: engine parts, ms per game frame (" + std::to_string((int)n) + " frames): level tick " + f(LevelTick) +
				", console " + f(ConsoleTick) + ", audio " + f(Audio) + ", draw game " + f(DrawGame) +
				" [bsp info " + f(BspInfo) + ", process " + f(Process) + ", draw nodes " + f(DrawNodes) +
				" (meshes " + f(Mesh) + ", particles " + f(Particles) + ", lightmaps " + f(Lightmaps) + ")]; in level tick: particles " +
				f(ParticleTick) + ", sound decoding " + f(SoundLoad) + "; outside: input " + f(Input) + ", mods " + f(Mods) +
				", ViewFlash/CalcView " + f(ViewFlash) + ", clock/localtime " + f(LoopRest) + ", entry level " + f(EntryTick));
			// draw nodes by step (the main view; a sky zone's or mirror's whole frame is in 'sky/mirrors'), and the procedural textures
			std::string texts;
			{
				std::vector<const TexTime*> sorted;
				for (auto& it : texTimes)
					sorted.push_back(&it.second);
				std::sort(sorted.begin(), sorted.end(), [](const TexTime* a, const TexTime* b) { return a->ms > b->ms; });
				for (size_t i = 0; i < sorted.size() && i < 7; i++)
				{
					char text[160];
					snprintf(text, sizeof(text), "%s%s %.2f ms (%.1f new pictures)", i ? ", " : "", sorted[i]->name.c_str(),
						sorted[i]->ms / n, sorted[i]->updates / n);
					texts += text;
				}
				texTimes.clear();
			}
			LogMessage("VitaRenderDevice: draw nodes by step, ms per game frame: sky/mirrors/warp zones " + f(DrawPortals) + ", opaque surfaces " +
				f(DrawOpaque) + ", opaque actors " + f(DrawActors) + " (brushes " + f(DrawBrushes) + ")" + ", translucent " + f(DrawTranslucent) + "; HUD/PostRender " + f(Hud) + ", PreRender/overlays " + f(Overlays) + ", Unlock " + f(VitaTimers::Unlock) + ", light BeginFrame " + f(LightBegin) + ", coronas " + f(Coronas) + "; procedural textures " + f(TexUpdate) +
				(texts.empty() ? std::string() : " (" + texts + ")"));
			{
				char text[200];
				snprintf(text, sizeof(text), "VitaRenderDevice: mesh faces on three cores: %.1f meshes a frame (%.1f with fog), %.1f the old way",
					VitaStats::facesThreaded / n, VitaStats::facesThreadedFog / n, VitaStats::facesSerial / n);
				LogMessage(text);
				VitaStats::facesThreaded = VitaStats::facesThreadedFog = VitaStats::facesSerial = 0;
			}
			meshCallsPeriod = calls[Mesh];
			for (int i = 0; i < Count; i++)
			{
				ms[i] = 0.0;
				calls[i] = 0;
				slowBefore[i] = 0.0;
			}
		}

		// Memory: the engine's heap (newlib) and its garbage collected objects. The Vita's heap size is fixed at build
		// time (VITA_HEAP_MB); "std::bad_alloc" means it ran out.
		{
			struct mallinfo info = mallinfo();
			GCStats gc = GC::GetStats();
			LogMessage("VitaRenderDevice: memory: heap " + std::to_string((size_t)info.uordblks / (1024 * 1024)) + " MB in use of " +
				std::to_string((size_t)info.arena / (1024 * 1024)) + " MB taken from the system; garbage collected objects " +
				std::to_string(gc.numObjects) + " (" + std::to_string(gc.memoryUsage / (1024 * 1024)) + " MB)");
			LogMessage("VitaRenderDevice: memory by kind: " + std::to_string(VitaStats::soundCount) + " sounds with " +
				std::to_string(VitaStats::soundSamples * 4 / (1024 * 1024)) + " MB of float samples; " +
				std::to_string(VitaStats::textureCount) + " textures with " + std::to_string(VitaStats::textureBytes / (1024 * 1024)) +
				" MB of pictures; " + std::to_string(VitaStats::lightmapCount) + " lightmaps/fog maps with " +
				std::to_string(VitaStats::lightmapBytes / (1024 * 1024)) + " MB of float data (" +
				std::to_string(VitaStats::lightmapFreed / (1024 * 1024)) + " MB freed); meshes skipped by distance in the last " +
				"period: " + std::to_string(VitaStats::meshesSkipped));
			VitaStats::meshesSkipped = 0;

			// What one reading of the clock costs (each section timer reads it twice): 200 readings, timed by the clock itself
			double clockUs = 0.0;
			{
				const double first = NowMs();
				double last = first;
				for (int i = 0; i < 200; i++)
					last = NowMs();
				clockUs = (last - first) * 1000.0 / 200.0;
			}

			const double n = std::max(1, accFrames);
			char text[512];
			snprintf(text, sizeof(text), "VitaRenderDevice: light maps per frame: %.0f asked for, %.1f built again (%.1f only the animated lights), "
				"%.0f texels, %.2f ms building; light tree built again %.2f times a frame; %u dynamic lights; %.1f static lights per request; "
				"one reading of the clock %.2f us",
				VitaStats::lightmapCalls / n, VitaStats::lightmapRebuilds / n, VitaStats::lightmapIncremental / n, VitaStats::lightmapTexels / n,
				VitaStats::lightmapRebuildMs / n, VitaStats::lightTreeBuilds / n, (unsigned)VitaStats::dynamicLights,
				VitaStats::lightmapCalls ? (double)VitaStats::lightmapListLights / VitaStats::lightmapCalls : 0.0, clockUs);
			LogMessage(text);
			VitaStats::lightmapListLights = 0;
			snprintf(text, sizeof(text), "VitaRenderDevice: light maps without looking at their lights (lightmap_skip): %.0f a frame; checking every light "
				"of the level once a frame: %.2f ms", VitaStats::lightmapFast / n, VitaStats::lightmapDirtyMs / n);
			LogMessage(text);
			VitaStats::lightmapFast = 0;
			VitaStats::lightmapDirtyMs = 0.0;
			{
				const double vf = std::max<double>(1.0, (double)VitaStats::visFrames);
				snprintf(text, sizeof(text), "VitaRenderDevice: visibility on three cores (vis_threads): %.1f walks a frame (%.1f the old way, %u walked again); "
					"strips %.2f / %.2f / %.2f ms, borders at %d and %d of %d; the main thread's walk with their answers %.2f ms",
					VitaStats::visFrames / n, VitaStats::visSerial / n, (unsigned)VitaStats::visRedone, VitaStats::visStripUs[0] / 1000.0 / vf,
					VitaStats::visStripUs[1] / 1000.0 / vf, VitaStats::visStripUs[2] / 1000.0 / vf, VitaStats::visSplit[0], VitaStats::visSplit[1],
					VitaClipperWidth(), VitaStats::visReplayUs / 1000.0 / vf);
				LogMessage(text);
				VitaStats::visFrames = VitaStats::visSerial = VitaStats::visRedone = 0;
				VitaStats::visStripUs[0] = VitaStats::visStripUs[1] = VitaStats::visStripUs[2] = VitaStats::visReplayUs = 0.0;
			}
			snprintf(text, sizeof(text), "VitaRenderDevice: rays per frame: %.0f that ignore actors, %.0f%% from the cache; foreach VisibleActors "
				"%.1f a frame, %.0f actors traced, %.1f ms", VitaStats::traceCalls / n,
				VitaStats::traceCalls ? 100.0 * VitaStats::traceCacheHits / VitaStats::traceCalls : 0.0, VitaStats::visibleActorsCalls / n,
				VitaStats::visibleActorsTraced / n, VitaStats::visibleActorsMs / n);
			LogMessage(text);
			VitaStats::traceCalls = VitaStats::traceCacheHits = VitaStats::visibleActorsCalls = VitaStats::visibleActorsTraced = 0;
			VitaStats::visibleActorsMs = 0.0;

			// The lap timers (VitaProbes.h): ms per frame, and microseconds per call x calls per frame
			if (VitaProbes::wanted)
			{
				const double ns = std::max(1u, VitaProbes::sampledFrames);   // the probes ran in these frames only (n: every frame)
				VitaProbes::sampledFrames = 0;
				std::string line = "VitaRenderDevice: laps, ms per frame (us per call x calls per frame):";
				for (int i = 0; i < VitaProbes::Count; i++)
				{
					if (!VitaProbes::calls[i])
						continue;
					char part[128];
					snprintf(part, sizeof(part), " %s %.1f (%.1f x %.0f);", VitaProbes::names[i], VitaProbes::us[i] / 1000.0 / ns,
						VitaProbes::us[i] / VitaProbes::calls[i], VitaProbes::calls[i] / ns);
					line += part;
					VitaProbes::us[i] = 0.0;
					VitaProbes::calls[i] = 0;
				}
				char clip[160];
				snprintf(clip, sizeof(clip), " clipper: %.0f triangles, %.0f spans a frame; %.1f meshes a frame", VitaProbes::clipTris / n,
					VitaProbes::clipSpans / n, meshCallsPeriod / n);
				line += clip;
				VitaProbes::clipTris = VitaProbes::clipSpans = 0;
				char lodText[160];
				snprintf(lodText, sizeof(lodText), "; mesh LOD: %.1f meshes a frame with LOD data, drawn at %.0f%% of their vertices, LODAdjust %.2f",
					VitaStats::lodMeshes / n, VitaStats::lodModelVerts > 0.0 ? 100.0 * VitaStats::lodVerts / VitaStats::lodModelVerts : 100.0,
					VitaStats::lodAdjust);
				line += lodText;
				VitaStats::lodMeshes = 0;
				VitaStats::lodVerts = VitaStats::lodModelVerts = 0.0;
				LogMessage(line);

				// (vm_laps=1) the script expression nodes run, by kind (VM/Expression.h ExpressionType order)
				if (VitaProbes::vmLaps == 1)
				{
					static const char* const exprNames[] = { "LocalVariable", "InstanceVariable", "DefaultVariable", "Return", "Switch", "Jump",
						"JumpIfNot", "Stop", "Assert", "Case", "Nothing", "LabelTable", "GotoLabel", "EatString", "Let", "DynArrayElement", "New",
						"ClassContext", "MetaCast", "LetBool", "Unknown0x15", "Self", "Skip", "Context", "ArrayElement", "IntConst", "FloatConst",
						"StringConst", "ObjectConst", "NameConst", "RotationConst", "VectorConst", "ByteConst", "IntZero", "IntOne", "True", "False",
						"NativeParm", "NoObject", "Unknown0x2b", "IntConstByte", "BoolVariable", "DynamicCast", "Iterator", "IteratorPop",
						"IteratorNext", "StructCmpEq", "StructCmpNe", "UnicodeStringConst", "StructMember", "RotatorToVector", "ByteToInt",
						"ByteToBool", "ByteToFloat", "IntToByte", "IntToBool", "IntToFloat", "BoolToByte", "BoolToInt", "BoolToFloat",
						"FloatToByte", "FloatToInt", "FloatToBool", "Unknown0x46", "ObjectToBool", "NameToBool", "StringToByte", "StringToInt",
						"StringToBool", "StringToFloat", "StringToVector", "StringToRotator", "VectorToBool", "VectorToRotator", "RotatorToBool",
						"ByteToString", "IntToString", "BoolToString", "FloatToString", "ObjectToString", "NameToString", "VectorToString",
						"RotatorToString", "StringToName", "DynArrayToInt", "VirtualFunction", "FinalFunction", "GlobalFunction",
						"NativeFunction", "FunctionArguments", "Construct" };
					const int known = (int)(sizeof(exprNames) / sizeof(exprNames[0]));
					std::vector<std::pair<unsigned, int>> kinds;
					unsigned total = 0;
					for (int i = 0; i < 128; i++)
					{
						if (VitaProbes::exprCounts[i])
							kinds.push_back({ VitaProbes::exprCounts[i], i });
						total += VitaProbes::exprCounts[i];
						VitaProbes::exprCounts[i] = 0;
					}
					std::sort(kinds.begin(), kinds.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
					char head[96];
					snprintf(head, sizeof(head), "VitaRenderDevice: expressions run a frame: all %.0f;", total / n);
					std::string exprLine = head;
					for (size_t i = 0; i < kinds.size() && i < 24; i++)
					{
						char part[80];
						snprintf(part, sizeof(part), " %s %.0f;", kinds[i].second < known ? exprNames[kinds[i].second] : "?", kinds[i].first / n);
						exprLine += part;
					}
					LogMessage(exprLine);
				}

				// The actor classes whose ticks took the most time
				std::vector<const VitaProbes::ClassTime*> classes;
				double tickTotal = 0.0;
				unsigned tickCalls = 0;
				for (auto& it : VitaProbes::classTimes)
				{
					classes.push_back(&it.second);
					tickTotal += it.second.us;
					tickCalls += it.second.calls;
				}
				std::sort(classes.begin(), classes.end(), [](const VitaProbes::ClassTime* a, const VitaProbes::ClassTime* b) { return a->us > b->us; });
				char head[160];
				snprintf(head, sizeof(head), "VitaRenderDevice: ticks by class, ms per frame (actors per frame): all %.1f (%.0f);", tickTotal / 1000.0 / ns, tickCalls / ns);
				std::string ticks = head;
				for (size_t i = 0; i < classes.size() && i < 12; i++)
				{
					char part[160];
					snprintf(part, sizeof(part), " %s %.2f (%.0f) [event %.2f, physics %.2f];", classes[i]->name.c_str(), classes[i]->us / 1000.0 / ns,
						classes[i]->calls / ns, classes[i]->eventUs / 1000.0 / ns, classes[i]->physicsUs / 1000.0 / ns);
					ticks += part;
				}
				if (VitaTimers::heapProbe == 1) // #138: the classes whose ticks took heap
				{
					std::vector<const VitaProbes::ClassTime*> heapy;
					for (auto& it : VitaProbes::classTimes)
						if (it.second.heapBytes > 64 * 1024)
							heapy.push_back(&it.second);
					std::sort(heapy.begin(), heapy.end(), [](const VitaProbes::ClassTime* a, const VitaProbes::ClassTime* b) { return a->heapBytes > b->heapBytes; });
					ticks += " heap growth in ticks:";
					for (size_t i = 0; i < heapy.size() && i < 12; i++)
						ticks += " " + heapy[i]->name + " +" + std::to_string(heapy[i]->heapBytes / 1024) + " KB;";
					for (auto& it : VitaProbes::classTimes)
						it.second.heapBytes = 0;
				}
				LogMessage(ticks);
				for (auto& it : VitaProbes::classTimes)
				{
					it.second.us = 0.0;
					it.second.calls = 0;
					it.second.eventUs = it.second.physicsUs = 0.0;
				}
				if (VitaProbes::scriptProfile == 1 && !VitaProbes::funcTimes.empty()) // #135 script_profile=1
				{
					std::vector<const VitaProbes::FuncTime*> funcs;
					for (auto& it : VitaProbes::funcTimes)
						funcs.push_back(&it.second);
					std::sort(funcs.begin(), funcs.end(), [](const VitaProbes::FuncTime* a, const VitaProbes::FuncTime* b) { return a->us > b->us; });
					std::string text = "VitaRenderDevice: script functions by time, ms per frame inclusive (calls per frame):";
					for (size_t i = 0; i < funcs.size() && i < 24; i++)
					{
						char part[200];
						snprintf(part, sizeof(part), " %s %.2f (%.1f);", funcs[i]->name.c_str(), funcs[i]->us / 1000.0 / ns, funcs[i]->calls / ns);
						text += part;
					}
					LogMessage(text);
					for (auto& it : VitaProbes::funcTimes)
					{
						it.second.us = 0.0;
						it.second.calls = 0;
					}
				}
			}
			VitaStats::lightmapCalls = VitaStats::lightmapRebuilds = VitaStats::lightmapIncremental = VitaStats::lightmapTexels = 0;
			VitaStats::lightTreeBuilds = 0;
			VitaStats::lightmapRebuildMs = 0.0;
		}

		accEngine = accRender = accSwap = 0.0;
		deviceMs = 0.0;
		slowLogged = 0;
		accFrames = 0;
		statEvicted = 0;
		statUploads = 0;
		statUploadMs = 0.0;
		statDeferred = 0;
		statLightmapUploads = 0;
		statAtlasResets = 0;
	}
}

// A 24 pixel square in the top left corner that changes colour twice a second: proof that frames are drawn
// and presented, even when the game itself draws nothing yet.
void VitaRenderDevice::DrawHeartbeat()
{
	mode = Mode::None;

	gl->Viewport(0, 0, width, height);
	gl->MatrixMode(GL_PROJECTION);
	gl->LoadIdentity();
	gl->Ortho(0.0f, (float)width, (float)height, 0.0f, -1.0f, 1.0f);
	gl->MatrixMode(GL_MODELVIEW);
	gl->LoadIdentity();

	gl->Disable(GL_DEPTH_TEST);
	gl->Disable(GL_TEXTURE_2D);
	gl->Disable(GL_BLEND);
	gl->Disable(GL_ALPHA_TEST);
	gl->DisableClientState(GL_COLOR_ARRAY);
	ResetStateCache();
	curColorArray = 0;

	float c = ((frameCount / 30) & 1) ? 1.0f : 0.0f;
	gl->Color4f(c, 1.0f - c, 0.2f, 1.0f);

	const float s = 24.0f;
	const float verts[12] = { 0, 0, s, 0, s, s, 0, 0, s, s, 0, s };
	const float uvs[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	gl->VertexPointer(2, 0, gl->Keep(verts, sizeof(verts)));
	gl->TexCoordPointer(2, 0, gl->Keep(uvs, sizeof(uvs)));
	gl->DrawArrays(GL_TRIANGLES, 0, 6);
}

/////////////////////////////////////////////////////////////////////////////
// frames of the scene: matrices, 2D and 3D drawing

// The frame's matrices, ready for OpenGL: projection (with the y flip) and the view of the world.
void VitaRenderDevice::LoadMatrixes(SceneNode* Frame)
{
	float aspect = Frame->FY / Frame->FX;
	float rprojz = (float)std::tan(radians(Frame->FovAngle) * 0.5f);

	mat4 projection = mat4::frustum(-rprojz, rprojz, -aspect * rprojz, aspect * rprojz, 1.0f, 32768.0f, handedness::left, clipzrange::negative_positive_w);
	if (settings.flipY)
		projection = mat4::scale(1.0f, -1.0f, 1.0f) * projection;
	mat4 view = Frame->WorldToView * Frame->ObjectToWorld;

	if (!columnMajor)
	{
		projection = mat4::transpose(projection);
		view = mat4::transpose(view);
	}
	std::memcpy(projectionMatrix, projection.matrix, sizeof(projectionMatrix));
	std::memcpy(modelViewMatrix, view.matrix, sizeof(modelViewMatrix));
}

void VitaRenderDevice::SetSceneNode(SceneNode* Frame)
{
	FlushBatch();
	haveFrame = true;
	frameX = Frame->X;
	frameY = Frame->Y;
	frameXB = Frame->XB;
	frameYB = Frame->YB;
	mode = Mode::None;
	LoadMatrixes(Frame);
}

// Flat drawing: everything in the pixels of the frame, top left is (0, 0), y goes down.
void VitaRenderDevice::Begin2D()
{
	if (mode == Mode::Tiles)
		return;
	FlushBatch();
	mode = Mode::Tiles;

	int x = 0, y = 0, w = width, h = height;
	if (haveFrame)
	{
		x = frameXB;
		y = height - frameYB - frameY;
		w = frameX;
		h = frameY;
	}
	gl->Viewport(x, y, w, h);
	gl->MatrixMode(GL_PROJECTION);
	gl->LoadIdentity();
	gl->Ortho(0.0f, (float)w, (float)h, 0.0f, -1.0f, 1.0f);
	gl->MatrixMode(GL_MODELVIEW);
	gl->LoadIdentity();
	gl->Disable(GL_DEPTH_TEST);
}

// The 3D world: the frame's own projection and view, depth tested.
void VitaRenderDevice::Begin3D()
{
	if (mode == Mode::Scene)
		return;
	FlushBatch();
	mode = Mode::Scene;

	int x = 0, y = 0, w = width, h = height;
	if (haveFrame)
	{
		x = frameXB;
		y = height - frameYB - frameY;
		w = frameX;
		h = frameY;
	}
	gl->Viewport(x, y, w, h);
	gl->MatrixMode(GL_PROJECTION);
	gl->LoadMatrixf(projectionMatrix);
	gl->MatrixMode(GL_MODELVIEW);
	gl->LoadMatrixf(modelViewMatrix);
	gl->Enable(GL_DEPTH_TEST);
	gl->DepthFunc(GL_LEQUAL);
	curDepthFunc = 0;
}

void VitaRenderDevice::ClearZ()
{
	FlushBatch();
	gl->DepthMask(GL_TRUE);
	curDepthMask = 1;
	gl->Clear(GL_DEPTH_BUFFER_BIT);
}

/////////////////////////////////////////////////////////////////////////////
// batches

void VitaRenderDevice::SwitchBatch(const BatchKey& key)
{
	if (batchOpen && batchKey == key && batchVerts.size() < 24000)
		return;
	FlushBatch();
	batchKey = key;
	batchOpen = true;
}

// Everything collected so far: the level surfaces first, then the mesh polygons and tiles
void VitaRenderDevice::FlushBatch()
{
	FlushSurfaces();
	FlushPolygons();
}

void VitaRenderDevice::FlushPolygons()
{
	if (!batchOpen)
		return;
	batchOpen = false;

	size_t count = batchVerts.size();
	if (count == 0)
		return;

	BindTexture(*batchKey.texture, batchKey.nearest, batchKey.clamp);
	SetBlend(BlendFor(batchKey.flags), (batchKey.flags & (KeyMasked | KeyFont)) != 0);
	SetDepthMask((batchKey.flags & KeyOcclude) != 0);
	SetColorArray(true);

	const GLsizei stride = (GLsizei)sizeof(BatchVertex);
	const uint64_t vitaKeepStart = VitaProbes::enabled ? VitaProbes::Now() : 0;
	const BatchVertex* verts = (const BatchVertex*)gl->Keep(batchVerts.data(), count * sizeof(BatchVertex));
	if (VitaProbes::enabled)
	{
		VitaProbes::us[VitaProbes::KeepCopy] += (double)(VitaProbes::Now() - vitaKeepStart);
		VitaProbes::calls[VitaProbes::KeepCopy] += (unsigned)(count * sizeof(BatchVertex) / 1024);
	}
	gl->VertexPointer(3, stride, &verts[0].x);
	gl->TexCoordPointer(2, stride, &verts[0].u);
	gl->ColorPointer(4, stride, &verts[0].r);
	{
		VITA_PROBE(GlDraw);
		gl->DrawArrays(GL_TRIANGLES, 0, (GLsizei)count);
	}
	statDraws++;

	batchVerts.clear();
}

/////////////////////////////////////////////////////////////////////////////
// drawing

/////////////////////////////////////////////////////////////////////////////
// level surfaces in batches, lightmaps in an atlas

VitaRenderDevice::SurfaceBatch& VitaRenderDevice::GetSurfaceBatch(TextureEntry* texture, bool nearest, bool occlude)
{
	for (size_t i = 0; i < surfaceBatchCount; i++)
	{
		SurfaceBatch& batch = surfaceBatches[i];
		if (batch.texture == texture && batch.nearest == nearest && batch.occlude == occlude)
			return batch;
	}
	if (surfaceBatchCount == surfaceBatches.size())
		surfaceBatches.emplace_back();
	SurfaceBatch& batch = surfaceBatches[surfaceBatchCount++];
	batch.texture = texture;
	batch.nearest = nearest;
	batch.occlude = occlude;
	batch.verts.clear();
	return batch;
}

// Draws what GetSurfaceBatch / the lightmap batches collected: the textures, one draw call each, then the lightmaps over them,
// one draw call per atlas page. Opaque surfaces do not depend on the order (the depth buffer decides), so the order of the
// calls does not matter; the lightmap passes only change the pixels the texture pass left at their depth.
void VitaRenderDevice::FlushSurfaces()
{
	if (!surfacesPending)
		return;
	surfacesPending = false;

	const GLsizei stride = (GLsizei)sizeof(BatchVertex);
	SetColorArray(false);
	SetDepthFunc(false);

	const float exposure = settings.exposure / 100.0f;
	gl->Color4f(exposure, exposure, exposure, 1.0f);
	for (size_t i = 0; i < surfaceBatchCount; i++)
	{
		SurfaceBatch& batch = surfaceBatches[i];
		if (batch.verts.empty())
			continue;
		BindTexture(*batch.texture, batch.nearest, false);
		SetBlend(BlendNone, false);
		SetDepthMask(batch.occlude);
		const BatchVertex* verts = (const BatchVertex*)gl->Keep(batch.verts.data(), batch.verts.size() * sizeof(BatchVertex));
		gl->VertexPointer(3, stride, &verts[0].x);
		gl->TexCoordPointer(2, stride, &verts[0].u);
		{
			VITA_PROBE(GlDraw);
			gl->DrawArrays(GL_TRIANGLES, 0, (GLsizei)batch.verts.size());
		}
		statDraws++;
		batch.verts.clear();
	}
	surfaceBatchCount = 0;
	DrawIndexBatches(textureIndexBatches, textureIndexCount, false);

	gl->Color4f(1.0f, 1.0f, 1.0f, 1.0f);
	SetDepthMask(false);
	SetBlend(settings.lightmapScale >= 2 ? BlendLightmap2 : BlendLightmap1, false);
	for (size_t page = 0; page < lightmapBatches.size(); page++)
	{
		std::vector<BatchVertex>& verts = lightmapBatches[page];
		if (verts.empty())
			continue;
		if (page < atlasPages.size())
		{
			BindTexture(atlasPages[page].entry, false, true);
			const BatchVertex* kept = (const BatchVertex*)gl->Keep(verts.data(), verts.size() * sizeof(BatchVertex));
			gl->VertexPointer(3, stride, &kept[0].x);
			gl->TexCoordPointer(2, stride, &kept[0].u);
			{
				VITA_PROBE(GlDraw);
				gl->DrawArrays(GL_TRIANGLES, 0, (GLsizei)verts.size());
			}
			statDraws++;
		}
		verts.clear();
	}
	DrawIndexBatches(lightIndexBatches, lightIndexCount, true);
}

/////////////////////////////////////////////////////////////////////////////
// surface_cache: plain level surfaces with their vertices in video memory (see VitaRenderDevice.h)

void VitaRenderDevice::SetArrayBuffer(unsigned int buffer)
{
	if (curArrayBuffer != buffer)
	{
		curArrayBuffer = buffer;
		gl->BindArrayBuffer(buffer);
	}
}

// A place for count vertices: in the current buffer, a new one, or (every buffer full) in new buffers after dropping the old ones
bool VitaRenderDevice::AllocateSurface(uint16_t count, uint16_t& chunk, uint32_t& first)
{
	for (int attempt = 0; attempt < 2; attempt++)
	{
		while (surfaceChunkCurrent < (int)surfaceChunks.size())
		{
			SurfaceChunk& c = surfaceChunks[surfaceChunkCurrent];
			if (c.used + count <= ChunkVertices)
			{
				chunk = (uint16_t)surfaceChunkCurrent;
				first = c.used;
				c.used += count;
				return true;
			}
			surfaceChunkCurrent++;
		}
		if ((int)surfaceChunks.size() < settings.surfaceChunks)
		{
			// Made at once with the GL side idle: its memory is written from this thread from now on (only parts no frame has
			// drawn yet). glBufferSubData would not do: vitaGL copies the whole buffer when it was drawn in the last frames
			SurfaceChunk c;
			const GLsizei bytes = (GLsizei)(ChunkVertices * sizeof(SurfaceVertex));
			gl->RunNow([&]()
			{
				glGenBuffers(1, &c.buffer);
				glBindBuffer(GL_ARRAY_BUFFER, c.buffer);
				glBufferData(GL_ARRAY_BUFFER, bytes, nullptr, GL_STATIC_DRAW);
				c.data = (SurfaceVertex*)glMapBuffer(GL_ARRAY_BUFFER, GL_WRITE_ONLY);
				glUnmapBuffer(GL_ARRAY_BUFFER);
				glBindBuffer(GL_ARRAY_BUFFER, 0);
			});
			curArrayBuffer = 0;
			if (!c.data)
			{
				LogMessage("VitaRenderDevice: no video memory for a vertex buffer of the surface cache: surface_cache is off");
				if (c.buffer)
					gl->DeleteBuffer(c.buffer);
				settings.surfaceCache = false;
				return false;
			}
			if (surfaceChunks.empty() && statSurfaceResets == 0)
				LogMessage("VitaRenderDevice: level surfaces are drawn from vertex buffers (surface_cache)");
			surfaceChunks.push_back(c);
			continue;
		}
		if (attempt == 0)
		{
			FlushSurfaces();   // what was collected points into the old buffers
			ResetSurfaceCache();
			statSurfaceResets++;
		}
	}
	return false;
}

// Every buffer is dropped (freed some frames later: the GPU may still draw from them); the surfaces are written again when drawn
void VitaRenderDevice::ResetSurfaceCache()
{
	for (SurfaceChunk& c : surfaceChunks)
	{
		if (c.buffer)
			retiredChunks.push_back({ c.buffer, frameCount });
	}
	surfaceChunks.clear();
	surfaceChunkCurrent = 0;
	surfaceChunkGeneration++;
	textureIndexCount = lightIndexCount = 0;
	lastTextureIndexBatch = 0;
}

void VitaRenderDevice::ReleaseRetiredChunks(bool all)
{
	size_t kept = 0;
	for (RetiredChunk& r : retiredChunks)
	{
		if (all || frameCount - r.frame >= 8)
			gl->DeleteBuffer(r.buffer);
		else
			retiredChunks[kept++] = r;
	}
	retiredChunks.resize(kept);
}

VitaRenderDevice::IndexBatch& VitaRenderDevice::GetIndexBatch(std::vector<IndexBatch>& list, size_t& count, TextureEntry* texture, int page, bool nearest, bool occlude, uint16_t chunk)
{
	auto same = [&](const IndexBatch& b) { return b.texture == texture && b.page == page && b.nearest == nearest && b.occlude == occlude && b.chunk == chunk; };
	if (&list == &textureIndexBatches && lastTextureIndexBatch < count && same(list[lastTextureIndexBatch]))
		return list[lastTextureIndexBatch];
	for (size_t i = 0; i < count; i++)
	{
		if (same(list[i]))
		{
			if (&list == &textureIndexBatches)
				lastTextureIndexBatch = i;
			return list[i];
		}
	}
	if (count == list.size())
		list.emplace_back();
	IndexBatch& b = list[count];
	if (&list == &textureIndexBatches)
		lastTextureIndexBatch = count;
	count++;
	b.texture = texture;
	b.page = page;
	b.nearest = nearest;
	b.occlude = occlude;
	b.chunk = chunk;
	b.indices.clear();
	return b;
}

// The surface from its vertices in video memory: written there first if it is new or what its coordinates come from changed; then only
// its triangles' indices go into the batches. False: draw it the old way (it changes too often, or there is no video memory)
bool VitaRenderDevice::DrawCachedSurface(CachedSurface& e, const SurfaceFacet& Facet, TextureEntry* texture, bool nearest, bool occlude, LightmapPixels* slot, const float* sig)
{
	const uint16_t count = (uint16_t)Facet.VertexCount;
	const vec3 p0 = Facet.Vertices[0];
	const int page = slot ? slot->page : -1;

	const bool sameTexture = e.uPan == sig[0] && e.vPan == sig[1] && e.uMult == sig[2] && e.vMult == sig[3];
	bool same = e.written && e.chunkGeneration == surfaceChunkGeneration && e.count == count && e.x0 == p0.x && e.y0 == p0.y && e.z0 == p0.z &&
		sameTexture && e.lmUPan == sig[4] && e.lmVPan == sig[5] && e.lmUMult == sig[6] && e.lmVMult == sig[7] && e.lmPage == page;
	if (same && slot)
		same = e.lmX == slot->x && e.lmY == slot->y && e.lmW == slot->width && e.lmH == slot->height;

	if (!same)
	{
		// The same surface with other texture coordinates (a panning texture): written again a few times, then the old way. (A lightmap
		// that moved in the atlas is not counted: that happens to every surface when the atlas starts again)
		if (e.written && e.chunkGeneration == surfaceChunkGeneration && e.count == count && e.x0 == p0.x && e.y0 == p0.y && e.z0 == p0.z && !sameTexture)
		{
			if (++e.rewrites > 3)
			{
				e.unstable = true;
				statUnstableSurfaces++;
				return false;
			}
		}

		uint16_t chunk = 0;
		uint32_t first = 0;
		if (!AllocateSurface(count, chunk, first))
			return false;

		SurfaceVertex* out = surfaceChunks[chunk].data + first;
		const vec3 xaxis = Facet.MapCoords.XAxis;
		const vec3 yaxis = Facet.MapCoords.YAxis;
		const float w = slot ? (float)slot->width : 1.0f, h = slot ? (float)slot->height : 1.0f;
		const float marginU = 0.4f / w, marginV = 0.4f / h;   // never read past the border of one texel
		const float slotU = slot ? (float)(slot->x + 1) : 0.0f, slotV = slot ? (float)(slot->y + 1) : 0.0f;
		for (int i = 0; i < count; i++)
		{
			const vec3 point = Facet.Vertices[i];
			const float u = dot(xaxis, point);
			const float v = dot(yaxis, point);
			SurfaceVertex sv;
			sv.x = point.x;
			sv.y = point.y;
			sv.z = point.z;
			sv.u = (u - sig[0]) * sig[2];
			sv.v = (v - sig[1]) * sig[3];
			if (slot)
			{
				const float lu = std::clamp((u - sig[4]) * sig[6], -marginU, 1.0f + marginU);
				const float lv = std::clamp((v - sig[5]) * sig[7], -marginV, 1.0f + marginV);
				sv.lu = (slotU + lu * w) * (1.0f / AtlasSize);
				sv.lv = (slotV + lv * h) * (1.0f / AtlasSize);
			}
			else
			{
				sv.lu = sv.lv = 0.0f;
			}
			out[i] = sv;
		}

		e.uPan = sig[0]; e.vPan = sig[1]; e.uMult = sig[2]; e.vMult = sig[3];
		e.lmUPan = sig[4]; e.lmVPan = sig[5]; e.lmUMult = sig[6]; e.lmVMult = sig[7];
		e.x0 = p0.x; e.y0 = p0.y; e.z0 = p0.z;
		e.lmPage = page;
		e.lmX = slot ? slot->x : 0;
		e.lmY = slot ? slot->y : 0;
		e.lmW = slot ? slot->width : 0;
		e.lmH = slot ? slot->height : 0;
		e.chunk = chunk;
		e.first = first;
		e.count = count;
		e.written = true;
		e.chunkGeneration = surfaceChunkGeneration;
		statWrittenSurfaces++;
	}
	statCachedSurfaces++;

	// the fan (0, i - 1, i), as indices into the buffer
	const size_t n = (size_t)(count - 2) * 3;
	const uint16_t base = (uint16_t)e.first;
	auto append = [&](std::vector<uint16_t>& indices)
	{
		const size_t at = indices.size();
		indices.resize(at + n);
		uint16_t* o = &indices[at];
		for (int i = 2; i < count; i++)
		{
			o[0] = base;
			o[1] = (uint16_t)(base + i - 1);
			o[2] = (uint16_t)(base + i);
			o += 3;
		}
	};
	append(GetIndexBatch(textureIndexBatches, textureIndexCount, texture, -1, nearest, occlude, e.chunk).indices);
	if (slot)
		append(GetIndexBatch(lightIndexBatches, lightIndexCount, nullptr, page, false, false, e.chunk).indices);
	return true;
}

// The collected index batches: the texture pass (each batch's texture and depth writing) or the lightmap pass (the state is set by the
// caller, each batch binds its atlas page). The vertices come from the buffers: the texture's or the lightmap's coordinates of them
void VitaRenderDevice::DrawIndexBatches(std::vector<IndexBatch>& list, size_t& count, bool lightmapPass)
{
	if (count == 0)
		return;
	const GLsizei stride = (GLsizei)sizeof(SurfaceVertex);
	int boundChunk = -1;
	for (size_t i = 0; i < count; i++)
	{
		IndexBatch& b = list[i];
		if (b.indices.empty())
			continue;
		if (b.chunk >= surfaceChunks.size() || (lightmapPass && (b.page < 0 || b.page >= (int)atlasPages.size())))
		{
			b.indices.clear();
			continue;
		}
		if (lightmapPass)
		{
			BindTexture(atlasPages[b.page].entry, false, true);
		}
		else
		{
			BindTexture(*b.texture, b.nearest, false);
			SetBlend(BlendNone, false);
			SetDepthMask(b.occlude);
		}
		if ((int)b.chunk != boundChunk)
		{
			SetArrayBuffer(surfaceChunks[b.chunk].buffer);
			gl->VertexPointer(3, stride, (const void*)(uintptr_t)offsetof(SurfaceVertex, x));
			gl->TexCoordPointer(2, stride, (const void*)(uintptr_t)(lightmapPass ? offsetof(SurfaceVertex, lu) : offsetof(SurfaceVertex, u)));
			boundChunk = b.chunk;
		}
		{
			VITA_PROBE(GlDraw);
			gl->DrawElements16(GL_TRIANGLES, (GLsizei)b.indices.size(), b.indices.data());
		}
		statDraws++;
		b.indices.clear();
	}
	count = 0;
	if (!lightmapPass)
		lastTextureIndexBatch = 0;
	SetArrayBuffer(0);   // the next vertex arrays are the caller's own memory again
}

// A rectangle of the page (a shelf packer: rows, left to right)
bool VitaRenderDevice::PlaceInPage(AtlasPage& page, int width, int height, int& x, int& y)
{
	if (page.shelfX + width > AtlasSize)
	{
		page.shelfY += page.shelfHeight;
		page.shelfX = 0;
		page.shelfHeight = 0;
	}
	if (page.shelfY + height > AtlasSize)
		return false;
	x = page.shelfX;
	y = page.shelfY;
	page.shelfX += width;
	page.shelfHeight = std::max(page.shelfHeight, height);
	return true;
}

// A place for the lightmap (with its border) in the atlas. When every page is full the atlas starts again: what was collected so far
// is drawn first (it points into the old layout), and every lightmap gets a new place when it is next drawn.
bool VitaRenderDevice::AllocateAtlasSlot(LightmapPixels& lightmap)
{
	const int width = lightmap.width + 2;
	const int height = lightmap.height + 2;
	if (width > AtlasSize || height > AtlasSize)
		return false;

	for (int attempt = 0; attempt < 2; attempt++)
	{
		while (true)
		{
			if (atlasCurrent < (int)atlasPages.size())
			{
				int x = 0, y = 0;
				if (PlaceInPage(atlasPages[atlasCurrent], width, height, x, y))
				{
					lightmap.page = atlasCurrent;
					lightmap.x = x;
					lightmap.y = y;
					lightmap.generation = atlasGeneration;
					if ((int)lightmapBatches.size() <= atlasCurrent)
						lightmapBatches.resize(atlasCurrent + 1);
					return true;
				}
				atlasCurrent++;   // this page is full: the next one
				continue;
			}
			if ((int)atlasPages.size() < settings.atlasPages)
			{
				atlasPages.emplace_back();
				AtlasPage& page = atlasPages.back();
				// Made at once (the pointer to its pixels is needed now): with the GL thread idle, on this thread. The page is bound
				// outside the recorded calls, so the binding is not known any more (without the thread; with it the calls of this
				// frame come after and set their own)
				page.entry.gpu = new VitaGL::Texture();
				gl->RunNow([&]()
				{
					glGenTextures(1, &page.entry.gpu->id);
					glBindTexture(GL_TEXTURE_2D, page.entry.gpu->id);
					std::vector<uint8_t> blank((size_t)AtlasSize * AtlasSize * 4, 0);
					glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, AtlasSize, AtlasSize, 0, GL_RGBA, GL_UNSIGNED_BYTE, blank.data());

					// The texels are written straight into video memory when the page is laid out as expected: linear rows of RGBA bytes
					if (settings.atlasDirect)
					{
						SceGxmTexture* gxm = vglGetGxmTexture(GL_TEXTURE_2D);
						void* data = vglGetTexDataPointer(GL_TEXTURE_2D);
						if (gxm && data && sceGxmTextureGetFormat(gxm) == SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR &&
							sceGxmTextureGetType(gxm) == SCE_GXM_TEXTURE_LINEAR && sceGxmTextureGetWidth(gxm) == AtlasSize)
						{
							page.pixels = (uint8_t*)data;
							page.stride = ((AtlasSize + 7) & ~7) * 4;   // vitaGL's rows are a multiple of 8 texels
						}
					}
				});
				if (!gl->Threaded())
					curTexture = nullptr;
				if (settings.atlasDirect)
				{
					if (atlasPages.size() == 1)
						LogMessage(page.pixels ? "VitaRenderDevice: lightmaps are written straight into the atlas" :
							"VitaRenderDevice: the atlas page is not laid out as expected: lightmaps go through glTexSubImage2D");
				}
				continue;
			}
			break;   // all the pages are full
		}

		FlushSurfaces();
		statAtlasResets++;
		for (AtlasPage& page : atlasPages)
			page.shelfX = page.shelfY = page.shelfHeight = 0;
		atlasCurrent = 0;
		atlasGeneration++;
	}
	return false;
}

// The lightmap's picture with a border of one texel (the same colours as the edge), into its place in the atlas.
// Straight into the page's video memory when we can: the GPU may still be drawing the last frame from the page, so a changed lightmap
// can show up one frame early, which a flickering light hides. glTexSubImage2D copies the whole page instead (see atlas_direct).
void VitaRenderDevice::UploadLightmapSlot(LightmapPixels& lightmap)
{
	statLightmapUploads++;
	const int pw = lightmap.width + 2;
	const int ph = lightmap.height + 2;
	AtlasPage& page = atlasPages[lightmap.page];
	uint8_t* target;
	size_t stride;
	if (page.pixels)
	{
		target = page.pixels + (size_t)lightmap.y * page.stride + (size_t)lightmap.x * 4;
		stride = page.stride;
	}
	else
	{
		atlasScratch.resize((size_t)pw * ph * 4);
		target = atlasScratch.data();
		stride = (size_t)pw * 4;
	}
	for (int y = 0; y < ph; y++)
	{
		const int sy = std::clamp(y - 1, 0, lightmap.height - 1);
		const uint8_t* source = &lightmap.rgba[(size_t)sy * lightmap.width * 4];
		uint8_t* dest = target + (size_t)y * stride;
		std::memcpy(dest + 4, source, (size_t)lightmap.width * 4);
		std::memcpy(dest, source, 4);
		std::memcpy(dest + (size_t)(pw - 1) * 4, source + (size_t)(lightmap.width - 1) * 4, 4);
	}
	if (page.pixels)
		return;
	gl->BindTexture(page.entry.gpu);
	curTexture = page.entry.gpu;
	gl->TexSubImage2D(0, lightmap.x, lightmap.y, pw, ph, GL_RGBA, GL_UNSIGNED_BYTE, atlasScratch.data(), atlasScratch.size());
}

// The lightmap's place in the atlas (made and filled when it is new or the engine rebuilt it), or null: use the old way
// hint: the slot this lightmap (the same CacheID) had last time, if the caller kept it: no lookup
VitaRenderDevice::LightmapPixels* VitaRenderDevice::GetLightmapSlot(TextureInfo& Info, LightmapPixels* hint)
{
	if (Info.Format != TextureFormat::RGBA32_F || !Info.Mips || Info.NumMips <= 0)
		return nullptr;
	const int w = Info.Mips[0].Width;
	const int h = Info.Mips[0].Height;
	if (w <= 0 || h <= 0 || w + 2 > AtlasSize || h + 2 > AtlasSize)
		return nullptr;

	LightmapPixels& lightmap = hint ? *hint : lightmaps[Info.CacheID];
	bool changed = false;
	if (lightmap.width != w || lightmap.height != h)
	{
		lightmap.width = w;
		lightmap.height = h;
		lightmap.rgba.assign((size_t)w * h * 4, 255);
		lightmap.page = -1;
		changed = true;
	}

	UnrealMipmap& mip = Info.Mips[0];
	const size_t count = (size_t)w * h;
	if (mip.Data.size() >= count * 16 && (changed || Info.bRealtimeChanged))
	{
		VitaFloatsToBytes((const float*)mip.Data.data(), lightmap.rgba.data(), count * 4);
		changed = true;
		if (lightmap.uploads < 255)
			lightmap.uploads++;
		if (settings.freeLightmapData && lightmap.uploads <= 1)
		{
			mip.Data.clear();
			mip.Data.shrink_to_fit();
		}
		// A texture of the same light map made by the other path (UploadTexture: masked, macro or fogged surfaces) is old now
		const uint64_t textureKey = (Info.CacheID * 2) * 4;
		if (textures.find(textureKey) != textures.end())
			RemoveTexture(textureKey);
	}
	Info.bRealtimeChanged = false;
	if (lightmap.stale)
	{
		lightmap.stale = false;
		changed = true;
	}

	if (lightmap.page < 0 || lightmap.generation != atlasGeneration)
	{
		if (!AllocateAtlasSlot(lightmap))
			return nullptr;
		changed = true;
	}
	if (changed)
		UploadLightmapSlot(lightmap);
	return &lightmap;
}

void VitaRenderDevice::DrawTile(SceneNode* Frame, TextureInfo& Info, float X, float Y, float XL, float YL, float U, float V, float UL, float VL, float Z, vec4 Color, vec4 Fog, uint32_t PolyFlags)
{
	ScopedDeviceTimer timer;
	PolyFlags = ApplyPrecedenceRules(PolyFlags);

	if (PolyFlags & PF_Invisible)
		return;

	if (!haveFrame)   // normally the engine has called SetSceneNode already
		SetSceneNode(Frame);
	Begin2D();
	statTiles++;
	if (surfacesPending)
		FlushSurfaces();

	TextureEntry* tex = GetTextureEntry(Info, !!(PolyFlags & PF_Masked));

	float umult = 1.0f / (Info.UScale * Info.USize);
	float vmult = 1.0f / (Info.VScale * Info.VSize);
	float u0 = U * umult;
	float v0 = V * vmult;
	float u1 = (U + UL) * umult;
	float v1 = (V + VL) * vmult;

	BatchKey key;
	key.texture = tex;
	key.flags = KeyFlags(PolyFlags);
	key.nearest = !!(PolyFlags & PF_NoSmooth);
	key.clamp = (u0 >= 0.0f && u1 <= 1.00001f && v0 >= 0.0f && v1 <= 1.00001f);
	key.mode = Mode::Tiles;
	SwitchBatch(key);

	float r = Color.x, g = Color.y, b = Color.z;
	if (PolyFlags & PF_Modulated)
		r = g = b = 1.0f;

	const float x0 = X, y0 = Y, x1 = X + XL, y1 = Y + YL;
	const BatchVertex quad[6] =
	{
		{ x0, y0, 0.0f, u0, v0, r, g, b, 1.0f }, { x1, y0, 0.0f, u1, v0, r, g, b, 1.0f }, { x1, y1, 0.0f, u1, v1, r, g, b, 1.0f },
		{ x0, y0, 0.0f, u0, v0, r, g, b, 1.0f }, { x1, y1, 0.0f, u1, v1, r, g, b, 1.0f }, { x0, y1, 0.0f, u0, v1, r, g, b, 1.0f }
	};
	batchVerts.insert(batchVerts.end(), quad, quad + 6);
}

// A level surface, in passes that are multiplied or blended over each other (the Vita's fixed function pipeline
// is simplest this way). What the OpenGL renderer's shader computes:
//   colour = texture * macro texture * (lightmap * 2), then the fog map: fog.rgb + colour * (1 - fog.a)
// Detail textures are left out for now.
void VitaRenderDevice::DrawComplexSurface(SceneNode* Frame, SurfaceInfo& Surface, SurfaceFacet& Facet)
{
	if (!settings.drawWorld || Facet.VertexCount < 3)
		return;

	uint32_t PolyFlags = ApplyPrecedenceRules(Surface.PolyFlags);
	if (PolyFlags & PF_Invisible)
		return;

	ScopedDeviceTimer timer;
	if (!haveFrame)   // normally the engine has called SetSceneNode already
		SetSceneNode(Frame);
	Begin3D();
	statSurfaces++;

	VITA_LAP_START;
	const int count = (int)Facet.VertexCount;
	TextureInfo* texInfo = Surface.Texture;
	const uint32_t flags = KeyFlags(PolyFlags);

	// The extra passes are multiplied over the texture, which only makes sense when that is opaque
	const bool opaque = BlendFor(flags) == BlendNone;
	TextureInfo* lmInfo = (opaque && settings.lightmap) ? Surface.LightMap : nullptr;
	TextureInfo* macroInfo = (opaque && settings.macro) ? Surface.MacroTexture : nullptr;
	TextureInfo* fogInfo = nullptr;
	if (opaque && settings.fog && Surface.FogMap && Surface.FogMap->NumMips > 0 && !Surface.FogMap->Mips[0].Data.empty())
		fogInfo = Surface.FogMap;

	// A plain surface (opaque, no cut-out holes, no macro texture, no fog map) is collected and drawn with the others: see FlushSurfaces.
	// Whatever else was collected before it (meshes, tiles) has to be drawn first, to keep the order.
	VITA_LAP(DevSetup);
	LightmapPixels* lightmapSlot = nullptr;
	bool batched = settings.batchSurfaces && opaque && !(flags & KeyMasked) && !macroInfo && !fogInfo;

	// surface_cache: what is kept of this BSP surface (its vertices in video memory, its lightmap slot and texture)
	CachedSurface* cached = nullptr;
	if (batched && settings.surfaceCache && Facet.VitaKey != 0 && count <= 4096)
	{
		const uint32_t key = Facet.VitaKey;
		if (key >= surfaceIndex.size())
			surfaceIndex.resize((size_t)key + 1024, -1);
		int32_t& index = surfaceIndex[key];
		if (index < 0)
		{
			index = (int32_t)cachedSurfaces.size();
			cachedSurfaces.emplace_back();
		}
		cached = &cachedSurfaces[index];
		if (cached->generation != cacheGeneration)
		{
			cached->lm = nullptr;
			cached->tex = nullptr;
			cached->generation = cacheGeneration;
		}
	}

	if (batched && lmInfo)
	{
		lightmapSlot = GetLightmapSlot(*lmInfo, (cached && cached->lm && cached->lmCacheId == lmInfo->CacheID) ? cached->lm : nullptr);
		if (!lightmapSlot)
			batched = false;
		else if (cached)
		{
			cached->lm = lightmapSlot;
			cached->lmCacheId = lmInfo->CacheID;
		}
	}
	VITA_LAP(DevLmSlot);
	if (batched)
		FlushPolygons();
	else
		FlushBatch();
	VITA_LAP(DevFlush);

	vec3 xaxis = Facet.MapCoords.XAxis;
	vec3 yaxis = Facet.MapCoords.YAxis;
	float UDot = dot(xaxis, Facet.MapCoords.Origin);
	float VDot = dot(yaxis, Facet.MapCoords.Origin);

	// texture coordinates: (u - pan) * multiplier, per pass
	float uPan = UDot, vPan = VDot, uMult = 1.0f, vMult = 1.0f;
	if (texInfo)
	{
		uPan += texInfo->Pan.x;
		vPan += texInfo->Pan.y;
		uMult = GetUMult(*texInfo);
		vMult = GetVMult(*texInfo);
	}

	float lmUPan = 0, lmVPan = 0, lmUMult = 1, lmVMult = 1;
	if (lmInfo)
	{
		lmUPan = UDot + lmInfo->Pan.x - 0.5f * lmInfo->UScale;
		lmVPan = VDot + lmInfo->Pan.y - 0.5f * lmInfo->VScale;
		lmUMult = GetUMult(*lmInfo);
		lmVMult = GetVMult(*lmInfo);
	}

	float macroUPan = 0, macroVPan = 0, macroUMult = 1, macroVMult = 1;
	if (macroInfo)
	{
		macroUPan = UDot + macroInfo->Pan.x;
		macroVPan = VDot + macroInfo->Pan.y;
		macroUMult = GetUMult(*macroInfo);
		macroVMult = GetVMult(*macroInfo);
	}

	float fogUPan = 0, fogVPan = 0, fogUMult = 1, fogVMult = 1;
	if (fogInfo)
	{
		fogUPan = UDot + fogInfo->Pan.x - 0.5f * fogInfo->UScale;
		fogVPan = VDot + fogInfo->Pan.y - 0.5f * fogInfo->VScale;
		fogUMult = GetUMult(*fogInfo);
		fogVMult = GetVMult(*fogInfo);
	}

	if (batched && cached && !cached->unstable)
	{
		// The texture: the one found last time, unless it changed or may have gone
		TextureEntry* batchTexture;
		if (!texInfo)
			batchTexture = WhiteTexture();
		else if (cached->tex && cached->texCacheId == texInfo->CacheID && !texInfo->bRealtimeChanged && !cached->tex->provisional)
		{
			batchTexture = cached->tex;
			batchTexture->lastUsed = frameCount;
		}
		else
		{
			batchTexture = GetTextureEntry(*texInfo, false, settings.textureLod, true);
			cached->tex = batchTexture;
			cached->texCacheId = texInfo->CacheID;
		}
		const float sig[8] = { uPan, vPan, uMult, vMult, lmUPan, lmVPan, lmUMult, lmVMult };
		if (DrawCachedSurface(*cached, Facet, batchTexture, !!(PolyFlags & PF_NoSmooth), (flags & KeyOcclude) != 0, lightmapSlot, sig))
		{
			surfacesPending = true;
			VITA_LAP(DevBatch);
			return;
		}
	}

	positions.resize((size_t)count * 3);
	uv0.resize((size_t)count * 2);
	if (lmInfo) uv1.resize((size_t)count * 2);
	if (macroInfo) uv2.resize((size_t)count * 2);
	if (fogInfo) uv3.resize((size_t)count * 2);
	for (int i = 0; i < count; i++)
	{
		vec3 point = Facet.Vertices[i];
		float u = dot(xaxis, point);
		float v = dot(yaxis, point);
		positions[i * 3 + 0] = point.x;
		positions[i * 3 + 1] = point.y;
		positions[i * 3 + 2] = point.z;
		uv0[i * 2 + 0] = (u - uPan) * uMult;
		uv0[i * 2 + 1] = (v - vPan) * vMult;
		if (lmInfo)
		{
			uv1[i * 2 + 0] = (u - lmUPan) * lmUMult;
			uv1[i * 2 + 1] = (v - lmVPan) * lmVMult;
		}
		if (macroInfo)
		{
			uv2[i * 2 + 0] = (u - macroUPan) * macroUMult;
			uv2[i * 2 + 1] = (v - macroVPan) * macroVMult;
		}
		if (fogInfo)
		{
			uv3[i * 2 + 0] = (u - fogUPan) * fogUMult;
			uv3[i * 2 + 1] = (v - fogVPan) * fogVMult;
		}
	}

	VITA_LAP(DevVerts);
	if (batched)
	{
		TextureEntry* batchTexture = texInfo ? GetTextureEntry(*texInfo, false, settings.textureLod, true) : WhiteTexture();
		SurfaceBatch& batch = GetSurfaceBatch(batchTexture, !!(PolyFlags & PF_NoSmooth), (flags & KeyOcclude) != 0);
		const size_t triangles = (size_t)(count - 2);

		const size_t first = batch.verts.size();
		batch.verts.resize(first + triangles * 3);
		BatchVertex* out = &batch.verts[first];
		for (int i = 2; i < count; i++)
		{
			const int corners[3] = { 0, i - 1, i };
			for (int k : corners)
			{
				out->x = positions[k * 3 + 0];
				out->y = positions[k * 3 + 1];
				out->z = positions[k * 3 + 2];
				out->u = uv0[k * 2 + 0];
				out->v = uv0[k * 2 + 1];
				out++;
			}
		}

		if (lightmapSlot)
		{
			std::vector<BatchVertex>& lightVerts = lightmapBatches[lightmapSlot->page];
			const size_t lightFirst = lightVerts.size();
			lightVerts.resize(lightFirst + triangles * 3);
			BatchVertex* lout = &lightVerts[lightFirst];
			const float w = (float)lightmapSlot->width, h = (float)lightmapSlot->height;
			const float marginU = 0.4f / w, marginV = 0.4f / h;   // never read past the border of one texel
			for (int i = 2; i < count; i++)
			{
				const int corners[3] = { 0, i - 1, i };
				for (int k : corners)
				{
					const float lu = std::clamp(uv1[k * 2 + 0], -marginU, 1.0f + marginU);
					const float lv = std::clamp(uv1[k * 2 + 1], -marginV, 1.0f + marginV);
					lout->x = positions[k * 3 + 0];
					lout->y = positions[k * 3 + 1];
					lout->z = positions[k * 3 + 2];
					lout->u = ((float)(lightmapSlot->x + 1) + lu * w) * (1.0f / AtlasSize);
					lout->v = ((float)(lightmapSlot->y + 1) + lv * h) * (1.0f / AtlasSize);
					lout++;
				}
			}
		}
		surfacesPending = true;
		VITA_LAP(DevBatch);
		return;
	}

	const float exposure = settings.exposure / 100.0f;

	// A translucent surface is lit like any other (texture x light map x 2, then blended), but the light map pass multiplies
	// what is already on the screen, which behind a translucent surface is the room seen through it. So its light comes as
	// vertex colours: the light map read at each vertex. Without this a translucent pane was drawn at full brightness: the
	// grey ripples of Lev_Tut3's Alohomora mirror (MirrorBlur, Translucent + SpecialLit, in a dim room) came out white.
	bool litByVertex = false;
	if (!opaque && (flags & KeyTranslucent) && !(flags & KeyModulated) && settings.lightmap && Surface.LightMap &&
		Surface.LightMap->Format == TextureFormat::RGBA32_F && Surface.LightMap->Mips && Surface.LightMap->NumMips > 0)
	{
		const UnrealMipmap& lm = Surface.LightMap->Mips[0];
		const int w = lm.Width, h = lm.Height;
		if (w > 0 && h > 0 && lm.Data.size() >= (size_t)w * h * 16)
		{
			const float* texels = (const float*)lm.Data.data();
			const TextureInfo& li = *Surface.LightMap;
			const float uPanLm = UDot + li.Pan.x - 0.5f * li.UScale, vPanLm = VDot + li.Pan.y - 0.5f * li.VScale;
			const float uMultLm = GetUMult(li), vMultLm = GetVMult(li);
			const float scale = (settings.lightmapScale >= 2 ? 2.0f : 1.0f) * exposure;
			vertexColors.resize((size_t)count * 4);
			for (int i = 0; i < count; i++)
			{
				const vec3 point = Facet.Vertices[i];
				// texel centres sit at i + 0.5 of these coordinates, as for the GPU's sampling: bilinear, clamped
				const float x = std::clamp((dot(xaxis, point) - uPanLm) * uMultLm * w - 0.5f, 0.0f, (float)(w - 1));
				const float y = std::clamp((dot(yaxis, point) - vPanLm) * vMultLm * h - 0.5f, 0.0f, (float)(h - 1));
				const int x0 = (int)x, y0 = (int)y;
				const int x1 = std::min(x0 + 1, w - 1), y1 = std::min(y0 + 1, h - 1);
				const float fx = x - x0, fy = y - y0;
				for (int c = 0; c < 3; c++)
				{
					const float top = texels[(y0 * w + x0) * 4 + c] * (1.0f - fx) + texels[(y0 * w + x1) * 4 + c] * fx;
					const float bottom = texels[(y1 * w + x0) * 4 + c] * (1.0f - fx) + texels[(y1 * w + x1) * 4 + c] * fx;
					vertexColors[i * 4 + c] = std::min((top * (1.0f - fy) + bottom * fy) * scale, 1.0f);
				}
				vertexColors[i * 4 + 3] = 1.0f;
			}
			litByVertex = true;
		}
	}

	SetColorArray(litByVertex);
	if (litByVertex)
		gl->ColorPointer(4, 0, gl->Keep(vertexColors.data(), (size_t)count * 4 * sizeof(float)));
	else
		gl->Color4f(exposure, exposure, exposure, 1.0f);
	gl->VertexPointer(3, 0, gl->Keep(positions.data(), (size_t)count * 3 * sizeof(float)));

	// Pass 1: the texture
	TextureEntry* tex = texInfo ? GetTextureEntry(*texInfo, !!(PolyFlags & PF_Masked), settings.textureLod, true) : WhiteTexture();
	BindTexture(*tex, !!(PolyFlags & PF_NoSmooth), false);
	SetBlend(BlendFor(flags), (flags & KeyMasked) != 0);
	SetDepthMask((flags & KeyOcclude) != 0);
	SetDepthFunc(false);
	gl->TexCoordPointer(2, 0, gl->Keep(uv0.data(), (size_t)count * 2 * sizeof(float)));
	gl->DrawArrays(GL_TRIANGLE_FAN, 0, count);
	statDraws++;
	if (litByVertex)
	{
		SetColorArray(false);
		gl->Color4f(exposure, exposure, exposure, 1.0f);   // the colour the next draws expect
	}

	if (!lmInfo && !macroInfo && !fogInfo)
		return;

	// The next passes go over the pixels of the first one: same depth, nothing written. (A cut-out texture
	// leaves holes in the first pass, so there the depth must be exactly the same: the holes stay empty.)
	SetDepthMask(false);
	SetDepthFunc((flags & KeyMasked) != 0);
	gl->Color4f(1.0f, 1.0f, 1.0f, 1.0f);

	// Pass 2: the macro texture, multiplied
	if (macroInfo)
	{
		BindTexture(*GetTextureEntry(*macroInfo, false, settings.textureLod, true), false, false);
		SetBlend(BlendLightmap1, false);
		gl->TexCoordPointer(2, 0, gl->Keep(uv2.data(), (size_t)count * 2 * sizeof(float)));
		gl->DrawArrays(GL_TRIANGLE_FAN, 0, count);
		statDraws++;
	}

	// Pass 3: the lightmap, multiplied by two (what the OpenGL renderer's shader does)
	if (lmInfo)
	{
		BindTexture(*GetTextureEntry(*lmInfo, false), false, true);
		SetBlend(settings.lightmapScale >= 2 ? BlendLightmap2 : BlendLightmap1, false);
		gl->TexCoordPointer(2, 0, gl->Keep(uv1.data(), (size_t)count * 2 * sizeof(float)));
		gl->DrawArrays(GL_TRIANGLE_FAN, 0, count);
		statDraws++;
	}

	// Pass 4: the fog map: its colour, plus what is there less the fog's opacity
	if (fogInfo)
	{
		BindTexture(*GetTextureEntry(*fogInfo, false), false, true);
		SetBlend(BlendFog, false);
		gl->TexCoordPointer(2, 0, gl->Keep(uv3.data(), (size_t)count * 2 * sizeof(float)));
		gl->DrawArrays(GL_TRIANGLE_FAN, 0, count);
		statDraws++;
	}
}

// A run of mesh triangles with one texture and the same flags (KW::DrawSkeletalMesh, mesh_fast): the state is set once
void VitaRenderDevice::DrawGouraudTriangles(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumTriangles, uint32_t PolyFlags)
{
	if (!settings.drawMeshes || NumTriangles <= 0)
		return;

	PolyFlags = ApplyPrecedenceRules(PolyFlags);
	if (PolyFlags & PF_Invisible)
		return;

	ScopedDeviceTimer timer;
	if (!haveFrame)
		SetSceneNode(Frame);
	Begin3D();
	statPolygons += NumTriangles;
	if (surfacesPending)
		FlushSurfaces();

	TextureEntry* tex = GetTextureEntry(Info, !!(PolyFlags & PF_Masked), settings.textureLod, true);

	BatchKey key;
	key.texture = tex;
	key.flags = KeyFlags(PolyFlags);
	key.nearest = !!(PolyFlags & PF_NoSmooth);
	key.clamp = false;
	key.mode = Mode::Scene;
	SwitchBatch(key);

	const float uMult = GetUMult(Info);
	const float vMult = GetVMult(Info);
	const bool modulated = !!(PolyFlags & PF_Modulated);
	const float exposure = settings.exposure / 100.0f;

	const size_t count = (size_t)NumTriangles * 3;
	const size_t first = batchVerts.size();
	batchVerts.resize(first + count);
	BatchVertex* out = &batchVerts[first];
	for (size_t i = 0; i < count; i++, out++)
	{
		const GouraudVertex& p = Pts[i];
		out->x = p.Point.x;
		out->y = p.Point.y;
		out->z = p.Point.z;
		out->u = p.UV.x * uMult;
		out->v = p.UV.y * vMult;
		out->r = modulated ? 1.0f : p.Light.x * exposure;
		out->g = modulated ? 1.0f : p.Light.y * exposure;
		out->b = modulated ? 1.0f : p.Light.z * exposure;
		out->a = p.Alpha;   // a faded mesh (Actor.Opacity < 1, KW::ApplyOpacityVertices): PF_Highlighted blends it as premultiplied alpha
	}
}

// A mesh polygon (characters, objects): textured, with the light given per vertex. Collected into a batch.
// Particles (#127, KW::DrawParticleSystem): room for maxVerts triangle vertices in the batch, written by the caller (fewer passes
// over memory than GouraudVertex arrays). params: u and v multipliers, the light multiplier, 1 when the colours are ignored.
float* VitaRenderDevice::VitaBeginTriangles(SceneNode* Frame, TextureInfo& Info, uint32_t PolyFlags, int maxVerts, float* params)
{
	if (!settings.drawMeshes || maxVerts <= 0)
		return nullptr;
	PolyFlags = ApplyPrecedenceRules(PolyFlags);
	if (PolyFlags & PF_Invisible)
		return nullptr;

	ScopedDeviceTimer timer;
	if (!haveFrame)
		SetSceneNode(Frame);
	Begin3D();
	if (surfacesPending)
		FlushSurfaces();

	TextureEntry* tex = GetTextureEntry(Info, !!(PolyFlags & PF_Masked), settings.textureLod, true);
	BatchKey key;
	key.texture = tex;
	key.flags = KeyFlags(PolyFlags);
	key.nearest = !!(PolyFlags & PF_NoSmooth);
	key.clamp = false;
	key.mode = Mode::Scene;
	SwitchBatch(key);

	const bool modulated = !!(PolyFlags & PF_Modulated);
	params[0] = GetUMult(Info);
	params[1] = GetVMult(Info);
	params[2] = settings.exposure / 100.0f;
	params[3] = modulated ? 1.0f : 0.0f;
	appendFirst = batchVerts.size();
	batchVerts.resize(appendFirst + (size_t)maxVerts);
	return &batchVerts[appendFirst].x;
}

void VitaRenderDevice::VitaEndTriangles(int usedVerts)
{
	batchVerts.resize(appendFirst + (size_t)std::max(usedVerts, 0));
	statPolygons += usedVerts / 3;
}

void VitaRenderDevice::DrawGouraudPolygon(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumPts, uint32_t PolyFlags)
{
	if (!settings.drawMeshes || NumPts < 3)
		return;

	PolyFlags = ApplyPrecedenceRules(PolyFlags);
	if (PolyFlags & PF_Invisible)
		return;

	ScopedDeviceTimer timer;
	if (!haveFrame)   // normally the engine has called SetSceneNode already
		SetSceneNode(Frame);
	Begin3D();
	statPolygons++;
	if (surfacesPending)
		FlushSurfaces();

	TextureEntry* tex = GetTextureEntry(Info, !!(PolyFlags & PF_Masked), settings.textureLod, true);

	BatchKey key;
	key.texture = tex;
	key.flags = KeyFlags(PolyFlags);
	key.nearest = !!(PolyFlags & PF_NoSmooth);
	key.clamp = false;
	key.mode = Mode::Scene;
	SwitchBatch(key);

	const float uMult = GetUMult(Info);
	const float vMult = GetVMult(Info);
	const bool modulated = !!(PolyFlags & PF_Modulated);
	const float exposure = settings.exposure / 100.0f;

	// the polygon is a fan: triangles (0, i - 1, i)
	const size_t first = batchVerts.size();
	batchVerts.resize(first + (size_t)(NumPts - 2) * 3);
	BatchVertex* out = &batchVerts[first];
	for (int i = 2; i < NumPts; i++)
	{
		const GouraudVertex* corners[3] = { &Pts[0], &Pts[i - 1], &Pts[i] };
		for (const GouraudVertex* p : corners)
		{
			out->x = p->Point.x;
			out->y = p->Point.y;
			out->z = p->Point.z;
			out->u = p->UV.x * uMult;
			out->v = p->UV.y * vMult;
			out->r = modulated ? 1.0f : p->Light.x * exposure;
			out->g = modulated ? 1.0f : p->Light.y * exposure;
			out->b = modulated ? 1.0f : p->Light.z * exposure;
			out->a = p->Alpha;   // as DrawGouraudTriangles
			out++;
		}
	}
}

void VitaRenderDevice::Draw3DLine(SceneNode* Frame, vec4 Color, uint32_t LineFlags, vec3 P1, vec3 P2)
{
}

void VitaRenderDevice::Draw2DLine(SceneNode* Frame, vec4 Color, uint32_t LineFlags, vec3 P1, vec3 P2)
{
}

void VitaRenderDevice::Draw2DPoint(SceneNode* Frame, vec4 Color, uint32_t LineFlags, float X1, float Y1, float X2, float Y2, float Z)
{
}

void VitaRenderDevice::PushHit(const uint8_t* Data, int Count)
{
}

void VitaRenderDevice::PopHit(int Count, bool bForce)
{
}

// The frame on the screen (HP1_SHOTS debug screenshots, vita/tools/vitarun.py): the GL thread is waited for (it presents the frame
// the engine just handed over), then a vertical blank, then the display's own frame buffer is copied. The display's pixels are
// A8B8G8R8 (R in the low byte); KWDebug writes TextureColor.R/G/B as the BMP's blue/green/red ("ReadPixels returns BGRA").
void VitaRenderDevice::ReadPixels(TextureColor* Pixels)
{
	if (gl->Threaded())
		gl->WaitIdle();
	sceDisplayWaitVblankStart();
	SceDisplayFrameBuf fb = {};
	fb.size = sizeof(fb);
	if (sceDisplayGetFrameBuf(&fb, SCE_DISPLAY_SETBUF_IMMEDIATE) < 0 || !fb.base)
		return;
	const int w = std::min<int>((int)fb.width, width), h = std::min<int>((int)fb.height, height);
	const uint32_t* src = (const uint32_t*)fb.base;
	for (int y = 0; y < h; y++)
	{
		const uint32_t* row = src + (size_t)y * fb.pitch;
		TextureColor* out = Pixels + (size_t)y * width;
		for (int x = 0; x < w; x++)
		{
			const uint32_t p = row[x];
			out[x] = TextureColor((uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p, 255);
		}
	}
}

void VitaRenderDevice::EndFlash()
{
}

void VitaRenderDevice::PrecacheTexture(TextureInfo& Info, uint32_t PolyFlags)
{
}

bool VitaRenderDevice::SupportsTextureFormat(TextureFormat Format)
{
	// The formats the OpenGL renderer uploads; the Vita GPU decodes BC1 (DXT1) itself.
	switch (Format)
	{
	case TextureFormat::P8:
	case TextureFormat::BGRA8_LM:
	case TextureFormat::R5G6B5:
	case TextureFormat::BC1:
	case TextureFormat::RGB8:
	case TextureFormat::BGRA8:
	case TextureFormat::RGBA32_F:
		return true;
	default:
		return false;
	}
}

/////////////////////////////////////////////////////////////////////////////
// textures

void VitaRenderDevice::RemoveTexture(uint64_t key)
{
	auto it = textures.find(key);
	if (it == textures.end())
		return;

	DeleteGpuTexture(it->second);
	textureBytes -= std::min<size_t>(textureBytes, it->second.bytes);
	textures.erase(it);
	lastEntry = nullptr;
	cacheGeneration++;
}

void VitaRenderDevice::ClearTextureCache()
{
	FlushBatch();
	lightmaps.clear();
	for (AtlasPage& page : atlasPages)
		page.shelfX = page.shelfY = page.shelfHeight = 0;
	atlasCurrent = 0;
	atlasGeneration++;
	for (auto& entry : textures)
		DeleteGpuTexture(entry.second);
	textures.clear();
	textureBytes = 0;
	lastEntry = nullptr;
	cacheGeneration++;
}

// The GL texture goes (through the queue: the GL thread may still draw the last frame with it)
void VitaRenderDevice::DeleteGpuTexture(TextureEntry& entry)
{
	if (!entry.gpu)
		return;
	if (curTexture == entry.gpu)
		curTexture = nullptr;
	gl->DeleteTexture(entry.gpu);
	entry.gpu = nullptr;
}

void VitaRenderDevice::UpdateTextureRect(TextureInfo& Info, int U, int V, int UL, int VL)
{
	// The simple way: drop the texture, it is uploaded again the next time it is drawn.
	FlushBatch();
	for (uint64_t masked = 0; masked < 2; masked++)
		for (uint64_t lod = 0; lod < 4; lod++)
			RemoveTexture((Info.CacheID * 2 + masked) * 4 + lod);
}

// Textures that were not used for a while are thrown out when the cache is over its budget. (The engine keeps
// the picture data, so a texture that comes back is simply uploaded again.)
void VitaRenderDevice::EvictTextures()
{
	const size_t budget = (size_t)settings.textureBudgetMb * 1024 * 1024;
	if (textureBytes <= budget)
		return;

	std::vector<std::pair<int, uint64_t>> candidates;
	for (auto& entry : textures)
	{
		if (!entry.second.pinned && entry.second.lastUsed + 2 < frameCount)   // not used in this frame or the two before
			candidates.push_back({ entry.second.lastUsed, entry.first });
	}
	std::sort(candidates.begin(), candidates.end());

	const size_t target = budget / 10 * 8;
	for (auto& candidate : candidates)
	{
		if (textureBytes <= target)
			break;
		RemoveTexture(candidate.second);
		statEvicted++;
	}
}

VitaRenderDevice::TextureEntry* VitaRenderDevice::WhiteTexture()
{
	if (!whiteTexture.gpu)
	{
		whiteTexture.gpu = gl->GenTexture();
		gl->BindTexture(whiteTexture.gpu);
		curTexture = whiteTexture.gpu;
		const uint32_t white = 0xffffffff;
		gl->TexImage2D(0, GL_RGBA, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &white, sizeof(white));
	}
	return &whiteTexture;
}

VitaRenderDevice::TextureEntry* VitaRenderDevice::GetTextureEntry(TextureInfo& Info, bool masked, int lod, bool world)
{
	// The same texture as the last call (the faces of a mesh, the letters of a text): no lookup
	if (lastEntry && !lastEntry->provisional && !Info.bRealtimeChanged && Info.CacheID == lastCacheId && lod == lastLod && masked == lastMasked)
	{
		lastEntry->lastUsed = frameCount;
		return lastEntry;
	}
	const bool requestedMasked = masked;

	if (Info.Format != TextureFormat::P8)
		masked = false;

	// A smaller mip level for the level's textures (not for lightmaps, which are one level, nor the HUD)
	int mipLevel = 0;
	if (lod > 0 && Info.Format != TextureFormat::RGBA32_F && Info.Format != TextureFormat::BGRA8_LM && Info.NumMips > 1)
		mipLevel = std::min(lod, Info.NumMips - 1);

	const uint64_t key = (Info.CacheID * 2 + (masked ? 1 : 0)) * 4 + (uint64_t)mipLevel;
	TextureEntry* entry = nullptr;
	if (lastEntry && lastKey == key)
	{
		entry = lastEntry;
	}
	else
	{
		auto it = textures.find(key);
		if (it != textures.end())
			entry = &it->second;
	}

	// What is done with the texture now: nothing, a first (maybe coarse) upload, a change, or the sharp picture after a coarse one
	const double budget = (double)settings.uploadBudgetMs;
	bool upload = false;
	bool coarse = false;
	int coarseLevel = 0;
	if (!entry)
	{
		entry = &textures[key];
		entry->gpu = gl->GenTexture();
		upload = true;

		// A frame that has spent its upload time: this texture starts from a picture an eighth of the size
		if (world && budget > 0.0 && uploadMsFrame > budget && Info.Format != TextureFormat::RGBA32_F && Info.Format != TextureFormat::BGRA8_LM &&
			Info.NumMips > mipLevel + 2)
		{
			coarseLevel = std::min(Info.NumMips - 1, mipLevel + 3);
			const UnrealMipmap& small = Info.Mips[coarseLevel];
			coarse = small.Width > 0 && small.Height > 0 && !small.Data.empty();
		}
	}
	else if (Info.bRealtimeChanged)
	{
		upload = true;
	}
	else if (entry->provisional && world && uploadMsFrame <= budget)
	{
		upload = true;   // there is time now: the sharp picture
	}

	if (upload)
	{
		const bool changing = Info.bRealtimeChanged;   // a texture that changes (water, fire) is not given mip levels
		Info.bRealtimeChanged = false;
		textureBytes -= std::min<size_t>(textureBytes, entry->bytes);
		const double started = NowMs();
		if (coarse)
		{
			UploadTexture(*entry, Info, masked, coarseLevel, false);
			entry->provisional = true;
			statDeferred++;
		}
		else
		{
			UploadTexture(*entry, Info, masked, mipLevel, world && settings.mipmaps != 0 && !changing);
			entry->provisional = false;
		}
		const double spent = NowMs() - started;
		uploadMsFrame += spent;
		statUploadMs += spent;
		statUploads++;
		uploadsFrame++;
		textureBytes += entry->bytes;
	}

	entry->lastUsed = frameCount;
	lastKey = key;
	lastEntry = entry;
	lastCacheId = Info.CacheID;
	lastLod = lod;
	lastMasked = requestedMasked;
	return entry;
}

static inline uint16_t Pack565(uint8_t r, uint8_t g, uint8_t b)
{
	return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

static inline uint16_t Pack5551(uint8_t r, uint8_t g, uint8_t b, bool a)
{
	return (uint16_t)(((r >> 3) << 11) | ((g >> 3) << 6) | ((b >> 3) << 1) | (a ? 1 : 0));
}

// Level 0 only. BC1 goes to the GPU as it is. Opaque palette, lightmap and 24 bit textures become 16 bit
// (half the memory: the Vita has little); textures with an alpha channel stay 32 bit.
// One mip level of a texture as pixels the GPU takes: 16 bit when the picture allows it (a table turns the palette index of every
// pixel into its 16 bit colour with one load), else 32 bit. The data is in scratch16 / scratch32 until the next call.
bool VitaRenderDevice::ConvertLevel(TextureInfo& Info, int mipIndex, bool masked, LevelPixels& out)
{
	UnrealMipmap& mip = Info.Mips[mipIndex];
	const int w = mip.Width;
	const int h = mip.Height;
	const size_t count = (size_t)w * h;
	const uint8_t* src = mip.Data.data();
	out = LevelPixels();
	out.width = w;
	out.height = h;
	if (w <= 0 || h <= 0 || mip.Data.empty())
		return false;

	if (Info.Format == TextureFormat::BC1)
	{
		out.compressed = true;
		out.internalFormat = GL_COMPRESSED_RGBA_S3TC_DXT1_EXT;
		out.bytes = (size_t)((w + 3) / 4) * ((h + 3) / 4) * 8;
		out.data = src;
		return mip.Data.size() >= out.bytes;
	}

	// The tables of a palette: made once for a texture, whatever its number of levels
	if (Info.Format == TextureFormat::P8 && Info.Palette && (!lutValid || lutPalette != Info.Palette || lutMasked != masked))
	{
		for (int i = 0; i < 256; i++)
		{
			const TextureColor& c = Info.Palette[i];
			paletteLut16[i] = masked ? Pack5551(c.R, c.G, c.B, i != 0) : Pack565(c.R, c.G, c.B);
			paletteLut32[i] = (uint32_t)c.R | ((uint32_t)c.G << 8) | ((uint32_t)c.B << 16) | ((masked && i == 0) ? 0u : 0xff000000u);
		}
		lutPalette = Info.Palette;
		lutMasked = masked;
		lutValid = true;
	}

	if (settings.texture16)
	{
		bool ok = true;
		bool alpha = false;
		switch (Info.Format)
		{
		case TextureFormat::P8:
			if (!Info.Palette || mip.Data.size() < count)
			{
				ok = false;
				break;
			}
			alpha = masked;
			scratch16.resize(count);
			{
				uint16_t* dst = scratch16.data();
				const uint16_t* lut = paletteLut16;
				size_t i = 0;
				for (; i + 4 <= count; i += 4)
				{
					dst[i + 0] = lut[src[i + 0]];
					dst[i + 1] = lut[src[i + 1]];
					dst[i + 2] = lut[src[i + 2]];
					dst[i + 3] = lut[src[i + 3]];
				}
				for (; i < count; i++)
					dst[i] = lut[src[i]];
			}
			break;
		case TextureFormat::BGRA8_LM: // lightmaps: half range, as the OpenGL renderer reads them
			if (mip.Data.size() < count * 4) { ok = false; break; }
			scratch16.resize(count);
			for (size_t i = 0; i < count; i++)
				scratch16[i] = Pack565((uint8_t)(src[i * 4 + 2] << 1), (uint8_t)(src[i * 4 + 1] << 1), (uint8_t)(src[i * 4 + 0] << 1));
			break;
		case TextureFormat::RGB8:
			if (mip.Data.size() < count * 3) { ok = false; break; }
			scratch16.resize(count);
			for (size_t i = 0; i < count; i++)
				scratch16[i] = Pack565(src[i * 3 + 0], src[i * 3 + 1], src[i * 3 + 2]);
			break;
		case TextureFormat::R5G6B5:
			if (mip.Data.size() < count * 2) { ok = false; break; }
			scratch16.resize(count);
			std::memcpy(scratch16.data(), src, count * 2);
			break;
		default:
			ok = false; // BGRA8 has an alpha channel: 32 bit below
			break;
		}
		if (ok)
		{
			out.data = scratch16.data();
			out.bytes = count * 2;
			out.format = alpha ? GL_RGBA : GL_RGB;
			out.internalFormat = out.format;
			out.type = alpha ? GL_UNSIGNED_SHORT_5_5_5_1 : GL_UNSIGNED_SHORT_5_6_5;
			return true;
		}
	}

	scratch32.resize(count * 4);
	uint8_t* dst = scratch32.data();
	switch (Info.Format)
	{
	case TextureFormat::P8:
		if (mip.Data.size() < count)
			return false;
		if (Info.Palette)
		{
			uint32_t* dst32 = (uint32_t*)dst;   // (the vector's memory is aligned for it)
			for (size_t i = 0; i < count; i++)
				dst32[i] = paletteLut32[src[i]];
		}
		else
		{
			for (size_t i = 0; i < count; i++)
			{
				const uint8_t index = src[i];
				dst[i * 4 + 0] = dst[i * 4 + 1] = dst[i * 4 + 2] = index;
				dst[i * 4 + 3] = 255;
			}
		}
		break;
	case TextureFormat::BGRA8:
		if (mip.Data.size() < count * 4)
			return false;
		for (size_t i = 0; i < count; i++)
		{
			dst[i * 4 + 0] = src[i * 4 + 2];
			dst[i * 4 + 1] = src[i * 4 + 1];
			dst[i * 4 + 2] = src[i * 4 + 0];
			dst[i * 4 + 3] = src[i * 4 + 3];
		}
		break;
	case TextureFormat::BGRA8_LM: // lightmaps: half range, as the OpenGL renderer reads them
		if (mip.Data.size() < count * 4)
			return false;
		for (size_t i = 0; i < count; i++)
		{
			dst[i * 4 + 0] = (uint8_t)(src[i * 4 + 2] << 1);
			dst[i * 4 + 1] = (uint8_t)(src[i * 4 + 1] << 1);
			dst[i * 4 + 2] = (uint8_t)(src[i * 4 + 0] << 1);
			dst[i * 4 + 3] = (uint8_t)(src[i * 4 + 3] << 1);
		}
		break;
	case TextureFormat::RGB8:
		if (mip.Data.size() < count * 3)
			return false;
		for (size_t i = 0; i < count; i++)
		{
			dst[i * 4 + 0] = src[i * 3 + 0];
			dst[i * 4 + 1] = src[i * 3 + 1];
			dst[i * 4 + 2] = src[i * 3 + 2];
			dst[i * 4 + 3] = 255;
		}
		break;
	case TextureFormat::R5G6B5:
		if (mip.Data.size() < count * 2)
			return false;
		for (size_t i = 0; i < count; i++)
		{
			uint16_t v = (uint16_t)(src[i * 2] | (src[i * 2 + 1] << 8));
			dst[i * 4 + 0] = (uint8_t)(((v >> 11) & 31) * 255 / 31);
			dst[i * 4 + 1] = (uint8_t)(((v >> 5) & 63) * 255 / 63);
			dst[i * 4 + 2] = (uint8_t)((v & 31) * 255 / 31);
			dst[i * 4 + 3] = 255;
		}
		break;
	default:
		return false; // an unsupported format stays white
	}
	out.data = dst;
	out.bytes = count * 4;
	out.format = GL_RGBA;
	out.internalFormat = GL_RGBA;
	out.type = GL_UNSIGNED_BYTE;
	return true;
}

void VitaRenderDevice::UploadTexture(TextureEntry& entry, TextureInfo& Info, bool masked, int lod, bool useMips)
{
	gl->BindTexture(entry.gpu);
	curTexture = entry.gpu;
	entry.nearest = -1;   // a new picture: the sampler settings are set again
	entry.clamp = -1;
	lutValid = false;     // the palette tables are made again for every upload: a palette can change under the same pointer

	auto white = [&]()
	{
		const uint32_t whitePixel = 0xffffffff;
		gl->TexImage2D(0, GL_RGBA, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &whitePixel, sizeof(whitePixel));
		entry.bytes = 4;
		entry.levels = 1;
		entry.width = entry.height = 1;
		entry.format = GL_RGBA;
		entry.type = GL_UNSIGNED_BYTE;
	};

	if (!Info.Mips || Info.NumMips <= 0 || Info.Mips[0].Width <= 0 || Info.Mips[0].Height <= 0)
	{
		white();
		return;
	}

	// The mip level to draw from; if its data is missing, the first one
	if (lod > 0 && (Info.NumMips <= lod || Info.Mips[lod].Width <= 0 || Info.Mips[lod].Height <= 0 || Info.Mips[lod].Data.empty()))
		lod = 0;

	// What the pictures take on the heap (counted when a texture is first uploaded)
	if (entry.bytes == 0 && Info.Format != TextureFormat::RGBA32_F)
	{
		VitaStats::textureCount++;
		for (int i = 0; i < Info.NumMips; i++)
			VitaStats::textureBytes += Info.Mips[i].Data.size();
	}

	UnrealMipmap& mip = Info.Mips[lod];
	const int w = mip.Width;
	const int h = mip.Height;
	const uint8_t* src = mip.Data.data();
	const size_t count = (size_t)w * h;

	// The lightmaps and fog maps the engine builds: four floats per texel, clamped to 0..1 here (the OpenGL renderer's
	// shader does the same). Eight bits per channel: they are small, and 16 bit would show bands.
	if (Info.Format == TextureFormat::RGBA32_F)
	{
		scratch32.assign(count * 4, 255);
		uint8_t* bytes = scratch32.data();
		if (mip.Data.size() < count * 16)
		{
			// the engine's copy was given back after the first upload: ours is the same picture
			auto kept = lightmaps.find(Info.CacheID);
			if (kept != lightmaps.end() && kept->second.width == w && kept->second.height == h)
				std::memcpy(bytes, kept->second.rgba.data(), count * 4);
			else if ((Info.CacheID & 0xff) == 2)
				std::fill(bytes, bytes + count * 4, (uint8_t)0);   // a fog map we have no picture of: no fog rather than white
		}
		else
		{
			VitaFloatsToBytes((const float*)src, bytes, count * 4);
			// A light map (CacheID ends in 1; fog maps in 2): keep our copy where the atlas path looks for it. Before this the atlas
			// path, meeting a light map whose float data this path had already given back, filled its slot WHITE (wrong lighting).
			if ((Info.CacheID & 0xff) == 1)
			{
				LightmapPixels& kept = lightmaps[Info.CacheID];
				if (kept.width != w || kept.height != h)
				{
					kept.width = w;
					kept.height = h;
					kept.page = -1;
				}
				else if (kept.page >= 0)
					kept.stale = true;
				kept.rgba.assign(bytes, bytes + count * 4);
			}
		}
		gl->TexImage2D(0, GL_RGBA, w, h, GL_RGBA, GL_UNSIGNED_BYTE, bytes, count * 4);
		entry.bytes = (uint32_t)(count * 4);
		entry.levels = 1;
		entry.width = (uint16_t)w;
		entry.height = (uint16_t)h;
		entry.format = GL_RGBA;
		entry.type = GL_UNSIGNED_BYTE;

		// The float copy takes 16 bytes per texel on the heap: give it back now that the GPU has it. (The engine makes
		// it again when the lightmap changes: see apply_fixes.sh. So these cannot be thrown out of the cache.)
		entry.pinned = true;
		VitaStats::lightmapCount++;
		VitaStats::lightmapBytes += mip.Data.size();
		bool vitaFirstUpload = true;   // a light map made again keeps its float copy (LightmapPixels::uploads)
		if ((Info.CacheID & 0xff) == 1)
		{
			LightmapPixels& kept = lightmaps[Info.CacheID];
			if (kept.uploads < 255)
				kept.uploads++;
			vitaFirstUpload = kept.uploads <= 1;
		}
		if (settings.freeLightmapData && vitaFirstUpload && mip.Data.size() >= count * 16)
		{
			VitaStats::lightmapFreed += mip.Data.size();
			mip.Data.clear();
			mip.Data.shrink_to_fit();
		}
		return;
	}

	// How many levels go to the GPU: this one and the smaller ones of the texture itself, as far as they are complete
	// (mipmaps=2), or the GPU makes them from this one (mipmaps=1)
	int levels = 1;
	if (useMips && settings.mipmaps == 2)
	{
		while (lod + levels < Info.NumMips && levels < 12)
		{
			const UnrealMipmap& next = Info.Mips[lod + levels];
			if (next.Width != std::max(1, w >> levels) || next.Height != std::max(1, h >> levels) || next.Data.empty())
				break;
			levels++;
		}
	}

	size_t totalBytes = 0;
	int uploaded = 0;
	for (int level = 0; level < levels; level++)
	{
		LevelPixels px;
		if (!ConvertLevel(Info, lod + level, masked, px))
			break;

		if (px.compressed)
		{
			gl->CompressedTexImage2D(level, px.internalFormat, px.width, px.height, (GLsizei)px.bytes, px.data);
		}
		else if (level == 0 && settings.textureInplace && levels == 1 && entry.levels == 1 && entry.width == px.width && entry.height == px.height &&
			entry.format == px.format && entry.type == px.type && entry.bytes != 0)
		{
			// the same kind of picture again (a texture that changes): into the memory it already has
			gl->TexSubImage2D(0, 0, 0, px.width, px.height, px.format, px.type, px.data, px.bytes);
		}
		else
		{
			gl->TexImage2D(level, px.internalFormat, px.width, px.height, px.format, px.type, px.data, px.bytes);
		}

		if (level == 0)
		{
			entry.width = (uint16_t)px.width;
			entry.height = (uint16_t)px.height;
			entry.format = (unsigned short)px.format;
			entry.type = (unsigned short)px.type;
		}
		totalBytes += px.bytes;
		uploaded++;
	}

	if (uploaded == 0)
	{
		white();   // an unsupported format stays white
		return;
	}

	if (useMips && settings.mipmaps == 1 && uploaded == 1 && w > 1 && h > 1 && Info.Format != TextureFormat::BC1)
	{
		gl->GenerateMipmap();
		totalBytes += totalBytes / 3;
		uploaded = 1 + (int)std::log2((double)std::min(w, h));
	}

	entry.levels = (uint8_t)std::min(uploaded, 255);
	entry.bytes = (uint32_t)totalBytes;

	// The work buffers are kept for the next upload, unless a big texture made them big
	if (scratch16.capacity() > (1u << 19))
		std::vector<uint16_t>().swap(scratch16);
	if (scratch32.capacity() > (1u << 20))
		std::vector<uint8_t>().swap(scratch32);
}
