// Entry point of the Vita apps: Harry Potter and the Philosopher's Stone (flipendo.vpk) and Chamber of Secrets (flipendo2.vpk,
// ~/flipendo2, VITA_HP2). Like the Android port's SDL_main, it starts the engine through GameApp with fixed arguments: the game
// folder, the log file and the renderer are given here. (HP2's own front end, New Game / Load Game, runs inside the engine:
// HP2::RunFrontEnd -> flipendo2's VitaHP2FrontEnd.cpp.)
//
// Folder layout on the memory card (VITA_DATA_ROOT: ux0:data/flipendo/, HP2 ux0:data/flipendo2/):
//   hp1/ (hp2/)             the installed PC game (System, Maps, Textures, Sounds, Music, ...)
//                           (HP1: game/ as before still works when there is no hp1/)
//   fonts/NotoSans-Regular.ttf
//   SurrealEngine.pk3       the engine's resources (a zip of src/engine/Resources)
//   flipendo.log            the engine's log (the previous run is overwritten)
//   vita-main.log           this file's own log: written before the engine starts

#include "Precomp.h"
#include "GameApp.h"
#include "VitaConfig.h"
#include <algorithm>

#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/power.h>

#ifdef VITA_PROFILE
void VitaProfileEngineThread(void* stackAddress);
int VitaProfileStart();
#endif

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <vitaGL.h>

extern "C"
{
	// Memory for malloc/new, in bytes. The Vita has 512 MB in all; the GPU memory, vitaGL and the system take their
	// own. Lower it if the app fails to start, raise it if the engine runs out of memory (std::bad_alloc in the log):
	// cmake -DVITA_HEAP_MB=224 .. (in the build folder), then make.
#ifndef VITA_HEAP_MB
#define VITA_HEAP_MB 192
#endif
	int _newlib_heap_size_user = VITA_HEAP_MB * 1024 * 1024;
}

namespace
{
	const char* const Root = VITA_DATA_ROOT;
	std::string gameFolder;   // the game's folder the engine thread starts

	bool FolderExists(const std::string& path)
	{
		SceIoStat stat = {};
		return sceIoGetstat(path.c_str(), &stat) >= 0;
	}

	void Log(const char* text)
	{
		FILE* file = fopen(VITA_DATA_ROOT "/vita-main.log", "a");
		if (file)
		{
			fputs(text, file);
			fputc('\n', file);
			fclose(file);
		}
	}

	std::string TrimLine(const char* line)
	{
		std::string t = line;
		while (!t.empty() && (t.back() == '\n' || t.back() == '\r' || t.back() == ' ' || t.back() == '\t'))
			t.pop_back();
		size_t start = 0;
		while (start < t.size() && (t[start] == ' ' || t[start] == '\t'))
			start++;
		return t.substr(start);
	}

	void ReadEnvFile(const std::string& path)
	{
		FILE* file = fopen(path.c_str(), "r");
		if (!file)
			return;
		char line[4096];
		while (fgets(line, sizeof(line), file))
		{
			std::string t = TrimLine(line);
			size_t eq = t.find('=');
			if (t.empty() || t[0] == '#' || eq == std::string::npos || eq == 0)
				continue;
			setenv(t.substr(0, eq).c_str(), t.substr(eq + 1).c_str(), 1);
			Log(("env: " + t).c_str());
		}
		fclose(file);
	}

	Array<std::string> ReadArgsFile(const std::string& path)
	{
		Array<std::string> result;
		FILE* file = fopen(path.c_str(), "r");
		if (!file)
			return result;
		char line[1024];
		while (fgets(line, sizeof(line), file))
		{
			std::string t = TrimLine(line);
			if (t.empty() || t[0] == '#')
				continue;
			result.push_back(t);
			Log(("arg: " + t).c_str());
		}
		fclose(file);
		return result;
	}

	bool CopyFile(const std::string& from, const std::string& to)
	{
		FILE* in = fopen(from.c_str(), "rb");
		if (!in)
			return false;
		FILE* out = fopen(to.c_str(), "wb");
		bool ok = out != nullptr;
		static char buffer[64 * 1024];
		size_t n;
		while (ok && (n = fread(buffer, 1, sizeof(buffer), in)) > 0)
			ok = fwrite(buffer, 1, n, out) == n;
		fclose(in);
		if (out && fclose(out) != 0)
			ok = false;
		if (!ok)
			std::remove(to.c_str());
		return ok;
	}

	// Files the VPK brings along (app0:data/, VITA_BUNDLED_FILES in flipendo-vita.cmake): copied to the card folder at the
	// first start, so that only the game itself has to be copied by hand
	void InstallBundledFiles()
	{
		const struct { const char* name; const char* dest; } files[] = {
			{ "SurrealEngine.pk3", "SurrealEngine.pk3" },
			{ "NotoSans-Regular.ttf", "fonts/NotoSans-Regular.ttf" },
			{ "render.cfg", "render.cfg" },
		};
		for (const auto& f : files)
		{
			const std::string from = std::string("app0:data/") + f.name;
			const std::string to = std::string(Root) + "/" + f.dest;
			if (FolderExists(to) || !FolderExists(from))
				continue;
			if (std::string(f.dest).find('/') != std::string::npos)
				sceIoMkdir((std::string(Root) + "/fonts").c_str(), 0777);
			Log(((CopyFile(from, to) ? "installed " : "could not install ") + to).c_str());
		}
	}

	// The engine runs UnrealScript on a recursive interpreter. The system's main thread has a small stack,
	// so the engine gets a thread of its own with a large one.
	int EngineThread(SceSize, void*)
	{
		int code = 1;

		// Flush-to-zero for the floating point unit: numbers that are too small to be normal (a velocity or a
		// fade that decays towards zero) count as 0 instead of making every operation with them slow.
		// (flush_to_zero=0 in render.cfg turns it off)
		if (VitaConfigInt("flush_to_zero", 1))
		{
			unsigned int fpscr;
			__asm__ volatile("vmrs %0, fpscr" : "=r"(fpscr));
			fpscr |= (1u << 24);
			__asm__ volatile("vmsr fpscr, %0" : : "r"(fpscr));
		}
#ifdef VITA_PROFILE
		VitaProfileEngineThread(&code);
#endif
		try
		{
			setenv("HOME", Root, 1);

			// Automated runs (vita/tools/vitarun.py puts these files there and takes them away afterwards):
			//   env.txt   NAME=VALUE a line: environment variables for the engine (the HP1_* debug tools: HP1_EXEC, HP1_GOTO,
			//             HP1_CAMERA, ... docs/debug-tools.md; VITA_BENCH=1 logs the on-screen counter's numbers every half second)
			//   args.txt  one more engine argument a line (--level=Lev_Tut1, --slot=5, ...)
			ReadEnvFile(std::string(Root) + "/env.txt");
			Array<std::string> extraArgs = ReadArgsFile(std::string(Root) + "/args.txt");

			Array<std::string> args;
			args.push_back("--autolaunch");
			args.push_back("--skip-splash");
#ifndef VITA_HP2
			args.push_back("--skip-intro");   // HP1's New Game storybook
#endif
			args.push_back("--fps=30");
			args.push_back(std::string("--logfile=") + Root + "/flipendo.log");
			for (const std::string& a : extraArgs)
				args.push_back(a);
			args.push_back(gameFolder);
			args.push_back("--renderer=opengl");

			GameApp app;
			code = app.main(std::move(args));
		}
		catch (const std::exception& e)
		{
			Log(e.what());
		}
		catch (...)
		{
			Log("unknown exception");
		}
		return code;
	}
}

// HP1's own debug mode (HPConsole.bDebugMode: the title menu's Level Select, Language, Credits and Version buttons), set on the
// console when the engine makes it (apply_fixes.sh #198). On in a build made with 'bash build.sh debug' (cmake VITA_GAME_DEBUG),
// off in 'bash build.sh release' (the one to publish). The player's switch: render.cfg debug_mode=0/1 overrides either (the older
// key game_debug still counts when debug_mode is not there).
#ifndef VITA_GAME_DEBUG
#define VITA_GAME_DEBUG 0
#endif
bool VitaGameDebug()
{
	static const bool on = VitaConfigInt("debug_mode", VitaConfigInt("game_debug", VITA_GAME_DEBUG)) != 0;
	return on;
}

int main(int, char**)
{
	// render.cfg display_buffers: vitaGL's swap chain (3 by default: up to two finished frames wait for the screen, 33 ms each at
	// fps_lock=30; 2 shows a frame one refresh period sooner). Before SDL makes the GL context (vglInit)
	vglSetDisplayBufferCount(std::clamp(VitaConfigInt("display_buffers", 3), 2, 3));

	// Full speed: 444 MHz CPU, 222 MHz GPU
	scePowerSetArmClockFrequency(444);
	scePowerSetBusClockFrequency(222);
	scePowerSetGpuClockFrequency(222);
	scePowerSetGpuXbarClockFrequency(166);

	// What the system really set (it can refuse): logged below once the log file can be written
	const int cpuMhz = scePowerGetArmClockFrequency();
	const int busMhz = scePowerGetBusClockFrequency();
	const int gpuMhz = scePowerGetGpuClockFrequency();

	sceIoMkdir("ux0:data", 0777);
	sceIoMkdir(Root, 0777);
	std::remove(VITA_DATA_ROOT "/vita-main.log");
	Log((std::string("flipendo: main started, build ") + __DATE__ + " " + __TIME__).c_str());
	Log(("clocks: CPU " + std::to_string(cpuMhz) + " MHz, bus " + std::to_string(busMhz) + " MHz, GPU " + std::to_string(gpuMhz) + " MHz").c_str());

	InstallBundledFiles();

	// The game: hp1/ (hp2/), or for HP1 game/ as in the first builds
	gameFolder = std::string(Root) + "/" VITA_GAME_FOLDER;
#ifndef VITA_HP2
	if (!FolderExists(gameFolder + "/System") && FolderExists(std::string(Root) + "/game/System"))
		gameFolder = std::string(Root) + "/game";
#endif
	if (!FolderExists(gameFolder + "/" VITA_GAME_EXE))
		Log(("no " VITA_GAME_EXE " in " + gameFolder + ": copy the PC game to " + Root + "/" VITA_GAME_FOLDER "/").c_str());
	Log(("game: " + gameFolder).c_str());

#ifndef VITA_HP2
	// The save slot page shows Save/SGS <level>.bmp for each slot (FESlotPage.UpdateSlots), DefaultGameSnap.bmp when that is missing
	if (!FolderExists(gameFolder + "/Save/DefaultGameSnap.bmp"))
		Log(("no save slot pictures in " + gameFolder + "/Save: copy the PC game's Save folder (SGS *.bmp) there").c_str());
#endif

	// The engine writes an ini as <name>.new and then puts it in place (vita-atomicini, apply_fixes.sh #214). The app closed
	// between the two steps leaves only the .new: it holds every setting, so it becomes the ini.
	for (const char* ini : { "SE-HP.ini", "SE-User.ini", "SE-Game.ini" })
	{
		std::string path = gameFolder + "/System/" + ini;
		if (!FolderExists(path) && FolderExists(path + ".new") && sceIoRename((path + ".new").c_str(), path.c_str()) >= 0)
			Log(("settings: " + path + " taken from its .new (the app was closed while writing it)").c_str());
	}

	// In the profiling build the engine runs a little below the sampler (priority 0x40 is the highest a user thread may have)
#ifdef VITA_PROFILE
	const int enginePriority = 0x50;
#else
	// The audio thread of OpenAL has priority 0x40, the highest a user thread may have. An engine thread with the same
	// priority is only interrupted by it when the time slice ends: when a frame is heavy (casting a spell) the sound
	// stutters. A little lower (a bigger number) lets the audio thread run whenever it needs to. (engine_priority in
	// render.cfg, 64..191)
	const int enginePriority = std::clamp(VitaConfigInt("engine_priority", 96), 64, 191);
#endif
	SceUID thread = sceKernelCreateThread("flipendo", EngineThread, enginePriority, 16 * 1024 * 1024, 0, 0, nullptr);
	if (thread < 0)
	{
		Log("could not create the engine thread");
		sceKernelExitProcess(1);
		return 1;
	}
	sceKernelStartThread(thread, 0, nullptr);
#ifdef VITA_PROFILE
	{
		int profiler = VitaProfileStart();
		Log(("profiler thread: " + std::to_string(profiler) + (profiler < 0 ? " (could not start)" : "")).c_str());
	}
#endif

	int status = 0;
	sceKernelWaitThreadEnd(thread, &status, nullptr);
	Log("flipendo: the engine stopped");

	sceKernelExitProcess(0);
	return 0;
}
