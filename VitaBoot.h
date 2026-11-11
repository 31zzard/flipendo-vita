#pragma once

// Where the time of starting the game and of loading a level goes: "Boot: <step>: at X s, +N ms (card: M MB in K ms)" lines in the
// log, from marks that apply_fixes.sh (#76) puts into GameApp, Engine, LoadMap, LoadFromSaveFile and the package manager. Each line
// says how long it was since the last mark and how much of that was reading from the card.

#ifdef __vita__
#include <psp2/kernel/processmgr.h>
#include <cstdint>
#include <cstdio>
#include <malloc.h>
#include <psp2/kernel/sysmem.h>
#include <string>
#include "Utils/Logger.h"

void VitaFileCounters(uint64_t& bytes, uint64_t& micros);   // Utils/File.cpp

inline void VitaBootMark(const std::string& what)
{
	static uint64_t lastTime = 0, lastBytes = 0, lastMicros = 0;
	const uint64_t now = sceKernelGetProcessTimeWide();
	uint64_t bytes = 0, micros = 0;
	VitaFileCounters(bytes, micros);
	char text[300];
	struct mallinfo info = mallinfo();
	SceKernelFreeMemorySizeInfo freeMem = {};
	freeMem.size = sizeof(freeMem);
	sceKernelGetFreeMemorySize(&freeMem);
	snprintf(text, sizeof(text), ": at %.2f s, +%.0f ms (card: %.1f MB in %.0f ms; heap %.1f MB; system free: main %.1f, cdram %.1f, phycont %.1f MB)",
		now / 1000000.0, (now - lastTime) / 1000.0, (bytes - lastBytes) / 1048576.0, (micros - lastMicros) / 1000.0, info.uordblks / 1048576.0,
		freeMem.size_user / 1048576.0, freeMem.size_cdram / 1048576.0, freeMem.size_phycont / 1048576.0);
	LogMessage("Boot: " + what + text);
	lastTime = now;
	lastBytes = bytes;
	lastMicros = micros;
}

// A step that is timed by itself (a package opened, a font made): logged when it took long
struct VitaBootScope
{
	std::string what;
	uint64_t start;
	explicit VitaBootScope(std::string name) : what(std::move(name)), start(sceKernelGetProcessTimeWide()) {}
	~VitaBootScope()
	{
		const double ms = (sceKernelGetProcessTimeWide() - start) / 1000.0;
		if (ms >= 20.0)
		{
			char text[64];
			snprintf(text, sizeof(text), ": %.0f ms", ms);
			LogMessage("Boot: " + what + text);
		}
	}
};
#define VITA_BOOT_MARK(what) VitaBootMark(what)
#define VITA_BOOT_SCOPE(var, what) VitaBootScope var(what)
#else
#define VITA_BOOT_MARK(what)
#define VITA_BOOT_SCOPE(var, what)
#endif
