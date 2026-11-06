#pragma once

// A small pool of worker threads on the Vita's other two user cores, for work that is pure arithmetic on data the main
// thread prepared (the skinning, normals and vertex light of the visible meshes: KW::VitaPrepareMeshes). Run() hands out
// the indices 0..count-1 to the workers and to the calling thread, and returns when every one is done. The jobs must not
// allocate, throw, or touch the engine. render.cfg mesh_threads: 2 = the workers (default), 1 = everything on the main thread
// (to compare), 0 = no prepass at all.

#ifdef __vita__
#include <psp2/kernel/cpu.h>
#include <psp2/kernel/threadmgr.h>
#include <atomic>
#include "VitaConfig.h"

namespace VitaJobs
{
	typedef void (*Fn)(void* context, int index);

	inline int Mode() { static const int mode = VitaConfigInt("mesh_threads", 2); return mode; }

	struct Shared
	{
		Fn fn = nullptr;
		void* context = nullptr;
		std::atomic<int> count{ 0 };
		std::atomic<int> next{ 0 };
		std::atomic<int> done{ 0 };
		std::atomic<int> inside{ 0 };   // workers between taking their first index and giving up
	};
	inline Shared shared;
	enum { Workers = 2 };
	inline SceUID semaphores[Workers] = { -1, -1 };
	inline bool started = false;
	inline bool failed = false;

	inline void Work()
	{
		for (;;)
		{
			const int i = shared.next.fetch_add(1);
			if (i >= shared.count.load())
				break;
			shared.fn(shared.context, i);
			shared.done.fetch_add(1);
		}
	}

	inline int WorkerMain(SceSize, void* argument)
	{
		const int id = *(const int*)argument;
		for (;;)
		{
			if (sceKernelWaitSema(semaphores[id], 1, nullptr) < 0)
				return 0;
			shared.inside.fetch_add(1);
			Work();
			shared.inside.fetch_sub(1);
		}
		return 0;
	}

	inline bool Start()
	{
		if (started || failed)
			return started;
		const int priority = std::clamp(VitaConfigInt("engine_priority", 96), 64, 191);
		const int cores[Workers] = { SCE_KERNEL_CPU_MASK_USER_1, SCE_KERNEL_CPU_MASK_USER_2 };
		for (int i = 0; i < Workers; i++)
		{
			semaphores[i] = sceKernelCreateSema("meshjobs", 0, 0, Workers * 4, nullptr);
			SceUID thread = semaphores[i] >= 0 ? sceKernelCreateThread("meshjobs", WorkerMain, priority, 64 * 1024, 0, cores[i], nullptr) : -1;
			int id = i;
			if (thread < 0 || sceKernelStartThread(thread, sizeof(id), &id) < 0)
			{
				failed = true;   // no workers: Run does the work itself (the threads already started just wait)
				return false;
			}
		}
		started = true;
		return true;
	}

	inline void Run(Fn fn, void* context, int count)
	{
		if (count <= 0)
			return;
		if (Mode() < 2 || count == 1 || !Start())
		{
			for (int i = 0; i < count; i++)
				fn(context, i);
			return;
		}

		// A worker woken late by the last run must not take an index of this one: while the run is set up, every index it
		// could get is past any count. Then wait for the workers still in the last run's Work().
		shared.next.store(1 << 30);
		while (shared.inside.load() != 0)
		{
		}
		shared.fn = fn;
		shared.context = context;
		shared.done.store(0);
		shared.count.store(count);
		shared.next.store(0);
		for (int i = 0; i < Workers; i++)
			sceKernelSignalSema(semaphores[i], 1);
		Work();
		while (shared.done.load() < count)
		{
		}
	}
}
#endif
