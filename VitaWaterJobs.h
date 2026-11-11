#pragma once
// The water textures (UWaterTexture: WaveTexture, WetTexture) worked out on a thread of their own (apply_fixes #122).
// HP2's Adv1Willow spent ~22 ms of a 67 ms frame on two water pictures (WaterDE2 ~19 ms each) on the main thread.
// Now UTexture::Update hands the step to the water thread (cores 1 and 2, below the mesh workers' priority) and shows the picture
// it finished before: the water is one picture late, nothing else changes. The thread writes into a picture of its own
// (Job::picture); the main thread copies it into the texture's level 0 (what the renderer reads) when it is done, so the
// renderer never sees half a picture. The water's state (VitaWater::State) is made on the main thread; the thread finds it
// through VitaWater::jobState (it never touches VitaWater::states, which the main thread may change).
// The thread is a kernel thread: no pthread waits, no logging, no allocation in it (UpdateFrame's checks are skipped there).
// render.cfg water_thread=0: the old way (on the main thread).
#ifdef __vita__
#include <psp2/kernel/cpu.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/kernel/processmgr.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>
#include "VitaConfig.h"
#include "VitaWater.h"

namespace VitaWaterJobs
{
	inline bool Enabled() { static const bool on = VitaConfigInt("water_thread", 1) != 0; return on; }

	struct Job
	{
		void* texture = nullptr;
		void (*run)(void* texture) = nullptr;   // the texture's UpdateFrame
		VitaWater::State* state = nullptr;
		std::vector<uint8_t> picture;
		std::atomic<int> status{ 0 };   // 0 idle, 1 queued (the thread owns it), 2 done (the main thread takes it back)
		double ms = 0.0;                // the thread's time for the last picture
		SceUInt64 queuedAt = 0;         // when the main thread queued it
		double waitMs = 0.0;            // from queued to done (the picture's delay)
	};

	enum { MaxJobs = 32 };
	inline Job* slots[MaxJobs] = {};
	inline std::atomic<int> slotCount{ 0 };
	inline std::unordered_map<const void*, std::unique_ptr<Job>> jobs;   // main thread only
	inline SceUID sema = -1;
	inline bool started = false, failed = false;

	inline int ThreadMain(SceSize, void*)
	{
		for (;;)
		{
			if (sceKernelWaitSema(sema, 1, nullptr) < 0)
				return 0;
			const int n = slotCount.load(std::memory_order_acquire);
			for (int i = 0; i < n; i++)
			{
				Job* job = slots[i];
				if (job->status.load(std::memory_order_acquire) != 1)
					continue;
				const SceUInt64 t0 = sceKernelGetProcessTimeWide();
				VitaWater::jobState = job->state;
				VitaWater::jobPixels = job->picture.data();
				VitaWater::jobTexture.store(job->texture, std::memory_order_release);
				job->run(job->texture);
				VitaWater::jobTexture.store(nullptr, std::memory_order_release);
				const SceUInt64 t1 = sceKernelGetProcessTimeWide();
				job->ms = (t1 - t0) / 1000.0;
				job->waitMs = (t1 - job->queuedAt) / 1000.0;
				job->status.store(2, std::memory_order_release);
			}
		}
		return 0;
	}

	inline bool Start()
	{
		if (started || failed)
			return started;
		sema = sceKernelCreateSema("waterjobs", 0, 0, 1 << 20, nullptr);
		// below the mesh workers (engine_priority, 96) and the GL thread by default: it takes what the other cores leave.
		// render.cfg water_thread_priority (64-191), water_thread_cores (1 = core 1, 2 = core 2, 3 = either)
		const int priority = std::clamp(VitaConfigInt("water_thread_priority", 160), 64, 191);
		const int cores = std::clamp(VitaConfigInt("water_thread_cores", 3), 1, 3);
		const int mask = ((cores & 1) ? SCE_KERNEL_CPU_MASK_USER_1 : 0) | ((cores & 2) ? SCE_KERNEL_CPU_MASK_USER_2 : 0);
		SceUID thread = sema >= 0 ? sceKernelCreateThread("waterjobs", ThreadMain, priority, 64 * 1024, 0, mask, nullptr) : -1;
		if (thread < 0 || sceKernelStartThread(thread, 0, nullptr) < 0)
		{
			failed = true;
			return false;
		}
		started = true;
		return true;
	}

	// The job of a water texture, made at its first update (main thread). nullptr: no thread (the old way).
	inline Job* JobFor(void* texture, void (*run)(void*), const uint8_t* level0, size_t bytes, int width, int height)
	{
		auto it = jobs.find(texture);
		if (it != jobs.end())
			return it->second.get();
		if (!Start() || slotCount.load() >= MaxJobs || !level0 || !bytes)
			return nullptr;
		auto job = std::make_unique<Job>();
		job->texture = texture;
		job->run = run;
		job->state = &VitaWater::StateFor(texture, width, height);
		job->picture.assign(level0, level0 + bytes);
		Job* p = job.get();
		jobs[texture] = std::move(job);
		slots[slotCount.load()] = p;
		slotCount.fetch_add(1, std::memory_order_release);
		return p;
	}

	inline void Queue(Job* job)
	{
		job->queuedAt = sceKernelGetProcessTimeWide();
		job->status.store(1, std::memory_order_release);
		sceKernelSignalSema(sema, 1);
	}
}
#endif
