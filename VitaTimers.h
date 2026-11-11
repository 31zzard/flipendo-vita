#pragma once

// Section timers: how long the engine spends in its main parts, in milliseconds, summed over the frames. The renderer
// (VitaRenderDevice.cpp) prints the average per frame to the log every 120 frames and starts again.
// Used through apply_fixes.sh, which adds VITA_TIMER(...) lines to the engine; does nothing on other platforms.

#ifdef __vita__
#include <psp2/kernel/processmgr.h>
#include <malloc.h>
#include "VitaConfig.h"
#include "Utils/Logger.h"
#include <cstdio>
#include <string>
#include <unordered_map>

namespace VitaTimers
{
	enum Section
	{
		LevelTick,     // Level->Tick: UnrealScript of every actor, physics, collision
		ConsoleTick,   // the console's Tick event: the menu / HUD scripts
		Audio,         // UpdateAudio
		DrawGame,      // render->DrawGame: everything below, the renderer's own calls and the HUD
		BspInfo,       //   finding every actor in the level's BSP
		Process,       //   walking the BSP: what is visible
		DrawNodes,     //   drawing what Process found (calls the renderer)
		Mesh,          //     meshes: vertex animation, lighting, transforms (inside DrawNodes)
		Particles,     //     particle systems (inside DrawNodes)
		Lightmaps,     //     building lightmaps (inside DrawNodes)
		ParticleTick,  // simulating the particle systems (inside LevelTick)
		SoundLoad,     // decoding a sound the first time it plays (inside LevelTick or Audio)
		// VisibleFrame::Draw of the main view, its four steps (inside DrawNodes; the sky/mirror frames' own steps are in DrawPortals)
		DrawPortals,   //     sky zones, mirrors, warp zones: their own visibility walk and drawing, then the seals
		DrawOpaque,    //     the opaque BSP surfaces
		DrawActors,    //     the opaque actors: meshes (and their prepass), sprites, brushes
		DrawTranslucent, //   translucent and modulated surfaces and actors, particles
		DrawBrushes,   //     (inside DrawActors) movers and other brush actors (VisibleBrush::Draw), #99
		Hud,           // (inside DrawGame) RenderSubsystem::PostRender: the HUD and the console's PostRender scripts, menus, overlays (#103)
		Overlays,      // (inside DrawGame) PreRender, RenderOverlays and EndFlash
		LightBegin,    // (inside DrawGame) LightSystem::BeginFrame: the light list and tree of the frame (#107)
		Coronas,       // (inside DrawGame) VisibleFrame::DrawCoronas of the main view
		Unlock,        // (inside DrawGame) RenderDevice::Unlock: the last batch flushed, the frame handed to the GL thread
		Input,         // (#110, engine part) UpdateInput and HP1::BeginModsFrame
		Mods,          // HP1::TickMods
		ViewFlash,     // the ViewFlash event and CalcView (camera scripts)
		LoopRest,      // the clock, localtime, dxRootWindow
		EntryTick,     // the entry level's tick (#125: every entry_tick_rate frames)
		TexUpdate,     // procedural textures (water, wet, fire, ice) worked out again (UTexture::Update), wherever they are drawn
		Count
	};

	inline double ms[Count] = {};
	inline int calls[Count] = {};   // how many times each section ran (LevelTick = the number of game frames)
	inline double total[Count] = {};   // the same, never reset (the on-screen counter, VitaOverlay.cpp, takes its own differences)
	inline unsigned totalCalls[Count] = {};

	inline double Now() { return sceKernelGetProcessTimeWide() / 1000.0; }

	// The procedural textures worked out in the log period, by texture (UTexture::Update; main thread only): which water costs
	struct TexTime
	{
		std::string name;
		double ms = 0.0;
		unsigned updates = 0;   // UpdateFrame calls that made a new picture
	};
	inline std::unordered_map<const void*, TexTime> texTimes;

	// The clock is a system call, two per timed section: render.cfg's section_timers=0 turns the timing off (the counting of frames stays)
	inline bool enabled = true;
	inline unsigned frameNumber = 0;   // the number of frames drawn (the caches of the meshes go by it)

	// a span measured by hand (start = Now() earlier) into a section
	inline void Add(Section s, double start)
	{
		calls[s]++;
		totalCalls[s]++;
		if (enabled)
		{
			const double t = Now() - start;
			ms[s] += t;
			total[s] += t;
		}
	}

	// render.cfg heap_probe=1 (a leak hunt, slow): the heap's growth inside each section (mallinfo before and after), logged as
	// 'heap growth by section' (KB per log period; nested sections count in their parents too)
	inline int heapProbe = -1;
	inline long long heapGrowth[Count] = {};
	inline long long HeapInUse() { struct mallinfo info = mallinfo(); return (long long)info.uordblks; }

	struct Scope
	{
		Section section;
		double start;
		long long heapStart = 0;
		explicit Scope(Section s) : section(s), start(enabled ? Now() : 0.0)
		{
			calls[s]++;
			totalCalls[s]++;
			if (s == DrawGame)
				frameNumber++;
			if (heapProbe < 0)
				heapProbe = VitaConfigInt("heap_probe", 0) != 0 ? 1 : 0;
			if (heapProbe)
				heapStart = HeapInUse();
		}
		~Scope()
		{
			if (enabled)
			{
				const double t = Now() - start;
				ms[section] += t;
				total[section] += t;
			}
			if (heapProbe)
			{
				const long long grew = HeapInUse() - heapStart;
				heapGrowth[section] += grew;
				if (grew > 1024 * 1024 && (section == LevelTick || section == ConsoleTick || section == DrawGame || section == Audio))
				{
					char text[96];
					snprintf(text, sizeof(text), "heap_probe: section %d grew %lld KB in one call (frame %u)", (int)section, grew / 1024, frameNumber);
					LogMessage(text);
				}
			}
		}
	};
}

#define VITA_TIMER(name) VitaTimers::Scope vitaTimer_##name(VitaTimers::name)
#else
#define VITA_TIMER(name)
#endif
