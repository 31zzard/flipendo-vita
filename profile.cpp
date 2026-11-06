// A sampling profiler for the Vita, for finding out where the engine spends its time. Only built with
// cmake -DVITA_PROFILE=ON (see CMakeLists.txt), and slow: the engine's code is compiled with
// -finstrument-functions, which calls the two hooks below at the start and the end of every function.
//
// The hooks only remember the function that is running now. A second thread looks at that every millisecond
// and counts. Every 25 seconds the counts are appended to ux0:data/flipendo/profile.txt; resolve_profile.py
// (on the PC) turns the addresses into function names.

#ifdef VITA_PROFILE

#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace
{
	volatile uintptr_t current = 0;   // the function that runs now (or the place it was called from)
	uintptr_t stackLo = 0;            // only the engine thread is looked at: its stack lies between these
	uintptr_t stackHi = 0;

	const int Slots = 32768;
	uint32_t keys[Slots];
	uint32_t counts[Slots];
	uint32_t total = 0;
}

extern "C"
{
	// Its address tells where the program was loaded (the load address changes from run to run)
	__attribute__((noinline, no_instrument_function)) void VitaProfileMarker()
	{
		asm volatile("");
	}

	__attribute__((no_instrument_function)) void __cyg_profile_func_enter(void* fn, void* caller)
	{
		uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
		if (sp >= stackLo && sp < stackHi)
			current = (uintptr_t)fn;
	}

	__attribute__((no_instrument_function)) void __cyg_profile_func_exit(void* fn, void* caller)
	{
		uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
		if (sp >= stackLo && sp < stackHi)
			current = (uintptr_t)caller;
	}
}

__attribute__((no_instrument_function)) void VitaProfileEngineThread(void* stackAddress)
{
	uintptr_t top = (uintptr_t)stackAddress;
	stackLo = top - 16 * 1024 * 1024;
	stackHi = top + 4096;
}

__attribute__((no_instrument_function)) static void Dump()
{
	std::vector<std::pair<uint32_t, uint32_t>> found;   // (count, address)
	for (int i = 0; i < Slots; i++)
	{
		if (counts[i])
			found.push_back({ counts[i], keys[i] });
	}
	std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.first > b.first; });

	FILE* file = fopen("ux0:data/flipendo/profile.txt", "a");
	if (file)
	{
		fprintf(file, "dump marker=0x%08x samples=%u\n", (unsigned)((uintptr_t)&VitaProfileMarker & ~1u), (unsigned)total);
		for (size_t i = 0; i < found.size() && i < 120; i++)
			fprintf(file, "0x%08x %u\n", found[i].second, found[i].first);
		fclose(file);
	}

	for (int i = 0; i < Slots; i++)
		counts[i] = 0;
	total = 0;
}

__attribute__((no_instrument_function)) static int SamplerThread(SceSize, void*)
{
	uint64_t nextDump = sceKernelGetProcessTimeWide() + 25ull * 1000 * 1000;
	for (;;)
	{
		sceKernelDelayThread(1000);

		uint32_t address = (uint32_t)(current & ~1u);
		if (address)
		{
			uint32_t slot = ((address >> 1) * 2654435761u) >> 17;   // 15 bits
			while (counts[slot] && keys[slot] != address)
				slot = (slot + 1) & (Slots - 1);
			keys[slot] = address;
			counts[slot]++;
			total++;
		}

		if (sceKernelGetProcessTimeWide() >= nextDump)
		{
			Dump();
			nextDump += 25ull * 1000 * 1000;
		}
	}
	return 0;
}

// Starts the sampler. Returns the thread id, or a negative error code. (User threads may have priorities from
// 0x40, the highest, to 0xBF, so the engine thread runs a little lower in the profiling build: see vita_main.cpp.)
__attribute__((no_instrument_function)) int VitaProfileStart()
{
	std::remove("ux0:data/flipendo/profile.txt");

	const int priorities[] = { 0x40, 0x10000100 };
	SceUID thread = -1;
	for (int priority : priorities)
	{
		thread = sceKernelCreateThread("profiler", SamplerThread, priority, 64 * 1024, 0, 0, nullptr);
		if (thread >= 0)
		{
			sceKernelStartThread(thread, 0, nullptr);
			return thread;
		}
	}
	return thread;
}

#endif // VITA_PROFILE
