// The on-screen frame counter of the Vita build (top left corner), apply_fixes.sh #86.
//
// Modes (render.cfg fps_counter=, the mode at start; default 0; the older key overlay= counts when fps_counter is not there):
//   0  off
//   1  frames per second, the slowest frame of the last half second, the average frame time
//   2  the same and where the time goes: engine (level tick = scripts, physics), picture (bsp info, visibility walk, drawing
//      by step), meshes/particles/light maps, procedural textures (water), uploads, surfaces and draw calls, heap, map and position
// A tap with two fingers on the REAR touch pad goes to the next mode (off -> FPS -> full -> off), only when render.cfg asks for a
// counter (fps_counter 1 or 2): with 0 there is none at all.
//
// The numbers are averages over half a second, from sums that never reset (VitaTimers::total, VitaStats::total*): the 120-frame
// log lines keep working as before. Drawing costs ~0.3 ms (a few hundred glyph tiles, batched), and nothing at all when off.

#include "Precomp.h"
#include "VitaConfig.h"
#include "VitaTimers.h"
#include "VitaStats.h"
#include "Engine.h"
#include "KW.h"
#include "Render/RenderSubsystem.h"
#include "Packages/Engine/UCanvas.h"
#include "Packages/Engine/UViewport.h"
#include "Packages/Engine/UConsole.h"
#include "Packages/Engine/Resources/Level/UModel.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Engine/Actors/Pawn/UPlayerPawn.h"
#include "Packages/Engine/Resources/Level/ULevel.h"
#include "Packages/Engine/Resources/UFont.h"
#include "Package/Package.h"
#include "Utils/Logger.h"
#include <cstdlib>
#include <psp2/touch.h>
#include <psp2/kernel/processmgr.h>
#include <malloc.h>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

namespace
{
	int mode = -1;   // -1: not read from render.cfg yet
	bool rearTouch = false;   // the rear pad may switch the counter: only when render.cfg's fps_counter is not 0
	bool touchStarted = false;
	bool twoFingersDown = false;

	// The half second being measured
	double windowStart = 0.0;     // ms
	double lastFrame = 0.0;       // ms, the last call
	double worstFrame = 0.0;      // the slowest frame of the window
	int windowFrames = 0;
	double timersAtStart[VitaTimers::Count] = {};
	double engineAtStart = 0.0, pictureAtStart = 0.0, presentAtStart = 0.0, uploadAtStart = 0.0;
	unsigned uploadsAtStart = 0;

	bool benchLog = false;   // VITA_BENCH=1 (env.txt, vita/tools/vitarun.py): every finished window into the log too

	// What is shown (the last finished window)
	std::vector<std::string> lines;
	float fps = 0.0f;

	double NowMs() { return sceKernelGetProcessTimeWide() / 1000.0; }

	// Two fingers put on the rear touch pad: the next mode
	void PollRearTouch()
	{
		// A bench run keeps its mode: a console lying on its back touches the pad (07 Nov: the VitaBench lines stopped mid-run)
		if (benchLog)
			return;
		if (!touchStarted)
		{
			touchStarted = true;
			sceTouchSetSamplingState(SCE_TOUCH_PORT_BACK, SCE_TOUCH_SAMPLING_STATE_START);
		}
		SceTouchData touch = {};
		if (sceTouchPeek(SCE_TOUCH_PORT_BACK, &touch, 1) <= 0)
			return;
		const bool two = touch.reportNum >= 2;
		if (two && !twoFingersDown)
			mode = (mode + 1) % 3;
		if (two)
			twoFingersDown = true;
		else if (touch.reportNum == 0)
			twoFingersDown = false;   // both lifted: the next tap counts
	}

	std::string Format(const char* format, ...) __attribute__((format(printf, 1, 2)));
	std::string Format(const char* format, ...)
	{
		char text[256];
		va_list args;
		va_start(args, format);
		vsnprintf(text, sizeof(text), format, args);
		va_end(args);
		return text;
	}

	void StartWindow(double now)
	{
		windowStart = now;
		worstFrame = 0.0;
		windowFrames = 0;
		for (int i = 0; i < VitaTimers::Count; i++)
			timersAtStart[i] = VitaTimers::total[i];
		engineAtStart = VitaStats::totalEngineMs;
		pictureAtStart = VitaStats::totalPictureMs;
		presentAtStart = VitaStats::totalPresentMs;
		uploadAtStart = VitaStats::totalUploadMs;
		uploadsAtStart = VitaStats::totalUploads;
	}

	void FinishWindow(double now)
	{
		using namespace VitaTimers;
		const double n = std::max(1, windowFrames);
		auto t = [&](Section s) { return (total[s] - timersAtStart[s]) / n; };
		fps = (float)(windowFrames * 1000.0 / std::max(1.0, now - windowStart));
		const double avgFrame = (now - windowStart) / n;
		const double minFps = worstFrame > 0.0 ? 1000.0 / worstFrame : 0.0;

		lines.clear();
		lines.push_back(Format("FPS %.1f  min %.0f  %.1f ms", fps, minFps, avgFrame));
		if (mode < 2)
			return;

		const double engineMs = (VitaStats::totalEngineMs - engineAtStart) / n;
		const double pictureMs = (VitaStats::totalPictureMs - pictureAtStart) / n;
		const double presentMs = (VitaStats::totalPresentMs - presentAtStart) / n;
		const double drawGame = t(DrawGame), bsp = t(BspInfo), vis = t(Process), nodes = t(DrawNodes);
		lines.push_back(Format("engine %.1f  picture %.1f  present %.1f", engineMs, pictureMs, presentMs));
		lines.push_back(Format("tick %.1f (part %.1f)  console %.1f  audio %.1f", t(LevelTick), t(ParticleTick), t(ConsoleTick), t(Audio)));
		lines.push_back(Format("bsp %.1f  vis %.1f  draw %.1f  hud %.1f", bsp, vis, nodes, std::max(0.0, drawGame - bsp - vis - nodes)));
		lines.push_back(Format("draw: sky/mirror %.1f  surf %.1f  actors %.1f  transl %.1f", t(DrawPortals), t(DrawOpaque), t(DrawActors), t(DrawTranslucent)));
		lines.push_back(Format("mesh %.1f  particles %.1f  lightmaps %.1f  water/proc %.1f", t(Mesh), t(Particles), t(Lightmaps), t(TexUpdate)));
		lines.push_back(Format("uploads %.1f/f %.1f ms  surf %u  dc %u  tris %u",
			(VitaStats::totalUploads - uploadsAtStart) / n, (VitaStats::totalUploadMs - uploadAtStart) / n,
			VitaStats::lastSurfaces, VitaStats::lastDraws, VitaStats::lastPolygons));
		struct mallinfo info = mallinfo();
		std::string where;
		if (engine->Level && engine->Level->package)
			where = engine->Level->package->GetPackageName().ToString();
		UPlayerPawn* player = engine->viewport ? engine->viewport->Actor() : nullptr;
		if (player)
		{
			const vec3 p = player->Location();
			where += Format("  %.0f %.0f %.0f", p.x, p.y, p.z);
		}
		where += Format("  cam %.0f %.0f %.0f yaw %d pitch %d", engine->CameraLocation.x, engine->CameraLocation.y, engine->CameraLocation.z,
			engine->CameraRotation.Yaw & 0xffff, engine->CameraRotation.Pitch & 0xffff);
		lines.push_back(Format("heap %u MB  ", (unsigned)(info.uordblks / (1024 * 1024))) + where);
		if (benchLog)
		{
			std::string all = "VitaBench:";
			for (const std::string& l : lines)
				all += " | " + l;
			LogMessage(all);
		}
	}
}

// RenderSubsystem::PostRender, after the HUD, the menus and the mods' overlays (the engine thread)
void VitaDrawOverlay()
{
	if (mode < 0)
	{
		mode = std::clamp(VitaConfigInt("fps_counter", VitaConfigInt("overlay", 0)), 0, 2);
		const char* bench = getenv("VITA_BENCH");
		benchLog = bench && *bench && *bench != '0';
		rearTouch = mode != 0;   // fps_counter=0: off for good, the rear pad can't switch it on
		if (benchLog)
			mode = 2;   // the full set of numbers, on the screen and in the log
	}
	const int oldMode = mode;
	if (rearTouch)
		PollRearTouch();

	const double now = NowMs();
	if (mode == 0)
	{
		lastFrame = 0.0;
		return;
	}
	if (lastFrame == 0.0 || mode != oldMode)
	{
		// (again) on: start measuring from here
		lastFrame = now;
		StartWindow(now);
		lines.clear();
		return;
	}
	worstFrame = std::max(worstFrame, now - lastFrame);
	lastFrame = now;
	windowFrames++;
	if (now - windowStart >= 500.0)
	{
		FinishWindow(now);
		StartWindow(now);
	}
	if (lines.empty() || benchLog)   // a bench run logs the numbers and draws nothing: the text costs time itself (~600 glyph tiles)
		return;

	UFont* font = UObject::TryCast<UFont>(KW::ObjectProperty(engine->console, "LocalSmallFont"));
	if (!font && engine->canvas)
		font = engine->canvas->SmallFont();
	if (!font && engine->canvas)
		font = engine->canvas->Font();
	if (!font)
		return;

	RenderSubsystem* render = engine->render.get();
	const vec4 shadow(0.0f, 0.0f, 0.0f, 1.0f);
	const vec4 white(1.0f, 1.0f, 1.0f, 1.0f);
	const vec4 fpsColor = fps >= 28.0f ? vec4(0.4f, 1.0f, 0.4f, 1.0f) : fps >= 20.0f ? vec4(1.0f, 0.9f, 0.3f, 1.0f) : vec4(1.0f, 0.4f, 0.4f, 1.0f);
	float y = 4.0f;
	for (size_t i = 0; i < lines.size(); i++)
	{
		float curXL = 0.0f, curYL = 0.0f;
		float x = 7.0f, sy = y + 1.0f;
		render->DrawText(font, shadow, 0.0f, 0.0f, x, sy, curXL, curYL, false, lines[i], PF_NoSmooth | PF_Masked, false);
		x = 6.0f;
		float ly = y;
		render->DrawText(font, i == 0 ? fpsColor : white, 0.0f, 0.0f, x, ly, curXL, curYL, false, lines[i], PF_NoSmooth | PF_Masked, false);
		y += std::max(curYL, 8.0f);
	}
}
