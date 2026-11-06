// PC test of the Vita renderer's surface cache (surface_cache, VitaRenderDevice.h) and GL thread (gl_thread, VitaGLQueue.h): random
// frames of level surfaces (some panning, some masked or with a macro texture, lightmaps that change, the same node drawn mirrored)
// and mesh polygons in between are drawn by the renderer three times: the old way, from the vertex buffers, and from the vertex
// buffers through the GL thread. A recording stand-in for vitaGL (pcstub/vitaGL.h) collects every triangle with its state (texture,
// blend, depth, colour) and the positions and texture coordinates the GPU would read; the three must draw the same triangles.
//   E=../../src/engine/SurrealEngine
//   g++ -std=gnu++20 -O1 -g -D__vita__ -Ipcstub -I.. -I$E -I$E/../SurrealWidgets/include -I$E/../SurrealWidgets/include/surrealwidgets \
//       surfacecachetest.cpp $E/Math/mat.cpp -o surfacecachetest -lpthread && ./surfacecachetest
//   (also -fsanitize=address,undefined, and -fsanitize=thread run with setarch $(uname -m) -R)

// (the standard headers first: "private" is made public only for the engine's and the renderer's classes)
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <functional>
#include <iostream>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <malloc.h>
#define private public
#include "Precomp.h"
#include "../VitaRenderDevice.cpp"
#undef private
#include <algorithm>
#include <random>

void LogMessage(const std::string& message) { if (getenv("VERBOSE")) std::printf("%s\n", message.c_str()); }
void LogUnimplemented(const std::string&) {}
GCStats GC::GetStats() { return {}; }
RenderDevice::RenderDevice() {}

namespace
{
	struct Level
	{
		struct Surface
		{
			std::vector<vec3> points;
			Coords map;
			int texture = 0;
			uint32_t flags = 0;
			bool panning = false;
			bool macro = false;
			bool lit = true;
			TextureInfo lightmap;
			UnrealMipmap lightmapMip;
		};
		std::vector<Surface> surfaces;
		std::vector<TextureInfo> textures;
		std::vector<UnrealMipmap> textureMips;
		TextureColor palette[256];
	};

	void FillLightmap(Level::Surface& s, std::mt19937& rng)
	{
		const int w = s.lightmapMip.Width, h = s.lightmapMip.Height;
		s.lightmapMip.Data.resize((size_t)w * h * 16);
		float* f = (float*)s.lightmapMip.Data.data();
		for (int i = 0; i < w * h * 4; i++)
			f[i] = (float)(rng() % 1000) / 999.0f;
		s.lightmap.bRealtimeChanged = true;
	}

	void MakeLevel(Level& level, std::mt19937& rng, int count)
	{
		for (int i = 0; i < 256; i++)
			level.palette[i] = TextureColor((uint8_t)i, (uint8_t)(255 - i), (uint8_t)(i * 7), 255);
		level.textures.resize(6);
		level.textureMips.resize(6);
		for (int t = 0; t < 6; t++)
		{
			UnrealMipmap& mip = level.textureMips[t];
			mip.Width = mip.Height = 8 << (t % 3);
			mip.Data.resize((size_t)mip.Width * mip.Height);
			for (auto& b : mip.Data)
				b = (uint8_t)rng();
			TextureInfo& info = level.textures[t];
			info.CacheID = 0x1000 + t;
			info.Format = TextureFormat::P8;
			info.Mips = &mip;
			info.NumMips = 1;
			info.USize = info.VSize = mip.Width;
			info.UScale = info.VScale = 0.5f + (float)(t % 2);
			info.Palette = level.palette;
		}

		auto rnd = [&](float a, float b) { return a + (b - a) * (float)(rng() % 100000) / 99999.0f; };
		level.surfaces.resize(count);
		for (int i = 0; i < count; i++)
		{
			Level::Surface& s = level.surfaces[i];
			const vec3 center(rnd(-2000, 2000), rnd(-2000, 2000), rnd(-500, 500));
			const vec3 u = normalize(vec3(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)) + vec3(0.01f, 0, 0));
			vec3 v = cross(u, normalize(vec3(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)) + vec3(0, 0.01f, 0)));
			v = normalize(v);
			const int n = 3 + (int)(rng() % 10);
			for (int k = 0; k < n; k++)
			{
				const float a = 6.2831853f * k / n;
				const float r = rnd(20, 300);
				s.points.push_back(center + u * (std::cos(a) * r) + v * (std::sin(a) * r));
			}
			s.map.Origin = center + u * rnd(-50, 50);
			s.map.XAxis = u * rnd(0.5f, 2.0f);
			s.map.YAxis = v * rnd(0.5f, 2.0f);
			s.map.ZAxis = cross(u, v);
			s.texture = (int)(rng() % 6);
			const unsigned kind = rng() % 20;
			if (kind == 0) s.flags |= PF_Masked;
			if (kind == 1) s.macro = true;
			if (kind == 2) s.panning = true;
			if (kind == 3) s.lit = false;
			if (kind == 4) s.flags |= PF_NoSmooth;
			if (kind == 5) s.flags |= PF_Translucent;
			if (rng() % 3) s.flags |= PF_Occlude;

			s.lightmapMip.Width = 2 + (int)(rng() % 30);
			s.lightmapMip.Height = 2 + (int)(rng() % 30);
			s.lightmap.CacheID = (0x77ull << 32) | (uint64_t)(i * 2 + 1);
			s.lightmap.Format = TextureFormat::RGBA32_F;
			s.lightmap.Mips = &s.lightmapMip;
			s.lightmap.NumMips = 1;
			s.lightmap.USize = s.lightmapMip.Width;
			s.lightmap.VSize = s.lightmapMip.Height;
			s.lightmap.UScale = s.lightmap.VScale = rnd(8, 32);
			s.lightmap.Pan = { rnd(-100, 100), rnd(-100, 100) };
			FillLightmap(s, rng);
		}
	}

	typedef std::vector<std::string> Triangles;

	Triangles TakeTriangles()
	{
		Triangles out;
		for (const StubGL::Triangle& t : StubGL::Triangles())
			out.push_back(t.state + " " + StubGL::Hex(t.v, sizeof(t.v)));
		StubGL::Triangles().clear();
		std::sort(out.begin(), out.end());
		return out;
	}

	struct Result
	{
		std::vector<Triangles> frames;
		int draws = 0;
		int cached = 0, written = 0, unstable = 0;
	};

	// mode 0: the old way; 1: vertex buffers; 2: vertex buffers and the GL thread; 3: the same, the thread working on a frame while the next
	// one is made (the triangles of all frames are compared together)
	Result Run(unsigned seed, int mode, int frameCount, int surfaceCount, int chunkLimit)
	{
		StubGL::Triangles().clear();
		StubGL::Labels().clear();
		StubGL::AtlasCount() = 0;
		StubGL::NextName() = 1;
		StubGL::State() = StubGL::Arrays();
		StubGL::Current() = StubGL::DrawState();
		StubGL::Capture() = true;
		StubGL::Logging() = getenv("DUMP") != nullptr && seed == 2;
		StubGL::Log().clear();
		StubGL::Draws() = 0;

		std::mt19937 rng(seed);
		Level level;
		MakeLevel(level, rng, surfaceCount);

		Widget widget;
		VitaRenderDevice device(&widget);
		// the constructor started the thread (gl_thread defaults to 1): the other modes get a queue without one
		if (mode < 2)
			device.gl = new VitaGL::Queue();
		device.settings.surfaceCache = mode != 0;
		device.settings.surfaceChunks = chunkLimit;

		Result result;
		SceneNode frame = {};
		frame.X = 960; frame.Y = 544; frame.FX = 960; frame.FY = 544; frame.FX2 = 480; frame.FY2 = 272;
		frame.FovAngle = 90.0f;
		frame.ObjectToWorld = mat4::identity();
		frame.WorldToView = mat4::identity();

		std::mt19937 drawRng(seed * 7 + 1);
		for (int f = 0; f < frameCount; f++)
		{
			if (getenv("PROGRESS"))
			{
				std::printf("mode %d frame %d\n", mode, f);
				std::fflush(stdout);
			}
			device.Lock(vec4(0.0f), vec4(0.0f), vec4(0.0f), nullptr, nullptr);
			device.SetSceneNode(&frame);
			std::vector<int> order(level.surfaces.size());
			for (size_t i = 0; i < order.size(); i++)
				order[i] = (int)i;
			std::shuffle(order.begin(), order.end(), drawRng);
			order.resize(order.size() / 2 + drawRng() % (order.size() / 2));
			for (int i : order)
			{
				Level::Surface& s = level.surfaces[i];
				if (drawRng() % 50 == 0)
					FillLightmap(s, drawRng);   // a light changed: the lightmap is built again
				TextureInfo texture = level.textures[s.texture];
				if (s.panning)
					texture.Pan = { (float)f * 3.0f, (float)f * -1.5f };
				TextureInfo macro = level.textures[(s.texture + 1) % 6];
				SurfaceInfo info;
				info.PolyFlags = s.flags;
				info.Texture = &texture;
				info.LightMap = s.lit ? &s.lightmap : nullptr;
				info.MacroTexture = s.macro ? &macro : nullptr;
				const bool mirror = drawRng() % 10 == 0;
				std::vector<vec3> points = s.points;
				if (mirror)
					std::reverse(points.begin(), points.end());
				SurfaceFacet facet;
				facet.MapCoords = s.map;
				facet.Vertices = points.data();
				facet.VertexCount = (uint32_t)points.size();
				facet.VitaKey = (uint32_t)i * 4 + (mirror ? 1 : 0) + 1;
				device.DrawComplexSurface(&frame, info, facet);

				// a mesh polygon now and then: everything collected so far is drawn first
				if (drawRng() % 25 == 0)
				{
					GouraudVertex pts[3];
					for (int k = 0; k < 3; k++)
					{
						pts[k].Point = s.points[k];
						pts[k].Light = vec3(0.5f);
						pts[k].UV = vec2((float)k, 1.0f);
					}
					device.DrawGouraudPolygon(&frame, level.textures[0], pts, 3, 0);
				}
			}
			device.Unlock(true);
			if (mode == 3)
				continue;
			device.gl->WaitIdle();
			result.frames.push_back(TakeTriangles());
			if (getenv("DUMP") && f == atoi(getenv("DUMP")) && seed == 2)
			{
				FILE* out = fopen(mode == 1 ? "log1.txt" :
					mode == 2 ? "log2.txt" :
					"log0.txt", "w");
				for (const std::string& line : StubGL::Log())
					fprintf(out, "%s\n", line.substr(0, 120).c_str());
				fclose(out);
			}
			StubGL::Log().clear();
		}
		if (mode == 3)
		{
			device.gl->WaitIdle();
			result.frames.push_back(TakeTriangles());
		}
		result.draws = StubGL::Draws();
		result.cached = device.statCachedSurfaces;
		result.written = device.statWrittenSurfaces;
		result.unstable = device.statUnstableSurfaces;
		device.gl->WaitIdle();
		return result;
	}
}

int main()
{
	int failures = 0;
	size_t triangles = 0;
	struct Case { unsigned seed; int frames, surfaces, chunks; };
	const Case cases[] = { { 1, 12, 300, 6 }, { 2, 20, 800, 6 }, { 3, 10, 2000, 1 }, { 4, 30, 150, 6 }, { 5, 8, 5000, 2 }, { 6, 16, 1200, 1 } };
	for (const Case& c : cases)
	{
		const Result old = Run(c.seed, 0, c.frames, c.surfaces, c.chunks);
		const Result buffers = Run(c.seed, 1, c.frames, c.surfaces, c.chunks);
		const Result threaded = Run(c.seed, 2, c.frames, c.surfaces, c.chunks);
		const Result overlapped = Run(c.seed, 3, c.frames, c.surfaces, c.chunks);
		Triangles all;
		for (const Triangles& t : old.frames)
			all.insert(all.end(), t.begin(), t.end());
		std::sort(all.begin(), all.end());
		if (overlapped.frames.size() != 1 || overlapped.frames[0] != all)
		{
			failures++;
			std::printf("seed %u: the GL thread working beside the next frame drew %zu triangles, the old way %zu (or others)\n", c.seed,
				overlapped.frames.empty() ? (size_t)0 : overlapped.frames[0].size(), all.size());
		}
		for (int f = 0; f < c.frames; f++)
		{
			triangles += old.frames[f].size();
			for (int which = 0; which < 2; which++)
			{
				const Triangles& other = which == 0 ? buffers.frames[f] : threaded.frames[f];
				if (other != old.frames[f])
				{
					failures++;
					size_t i = 0;
					while (i < other.size() && i < old.frames[f].size() && other[i] == old.frames[f][i])
						i++;
					std::printf("seed %u frame %d (%s): %zu triangles, the old way %zu; first difference at %zu:\n  old:   %s\n  other: %s\n", c.seed, f,
						which == 0 ? "vertex buffers" : "GL thread", other.size(), old.frames[f].size(), i,
						i < old.frames[f].size() ? old.frames[f][i].substr(0, 160).c_str() : "(end)", i < other.size() ? other[i].substr(0, 160).c_str() : "(end)");
					if (failures > 6)
						std::_Exit(1);
				}
			}
		}
		std::printf("seed %u: %d frames of %d surfaces: draws %d / %d / %d; from the buffers %d (written %d, unstable %d)\n", c.seed, c.frames, c.surfaces,
			old.draws, buffers.draws, threaded.draws, buffers.cached, buffers.written, buffers.unstable);
	}
	std::printf("%s: %zu triangles a run compared\n", failures ? "FAILED" : "ok", triangles);
	std::fflush(stdout);
	// (the renderers' GL threads still wait on their semaphores, which the static destructors would pull away)
	std::_Exit(failures ? 1 : 0);
}
