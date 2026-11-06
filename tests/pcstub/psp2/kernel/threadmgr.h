#pragma once
// PC stand-in (vita/tests): the kernel's semaphores and threads with std::thread, enough for VitaGLQueue.h and VitaJobs.h
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

typedef int SceUID;
typedef unsigned int SceSize;
typedef int (*SceKernelThreadEntry)(SceSize args, void* argp);

namespace StubKernel
{
	struct Sema { std::mutex m; std::condition_variable cv; int count = 0; };
	struct Thread { SceKernelThreadEntry entry; };
	inline std::mutex& Lock() { static std::mutex m; return m; }
	inline std::map<int, std::unique_ptr<Sema>>& Semas() { static std::map<int, std::unique_ptr<Sema>> s; return s; }
	inline std::map<int, Thread>& Threads() { static std::map<int, Thread> t; return t; }
	inline int& Next() { static int n = 1; return n; }
	inline Sema* Get(SceUID id)
	{
		std::lock_guard<std::mutex> lock(Lock());
		auto it = Semas().find(id);
		return it == Semas().end() ? nullptr : it->second.get();
	}
}

inline SceUID sceKernelCreateSema(const char*, unsigned, int initial, int, void*)
{
	std::lock_guard<std::mutex> lock(StubKernel::Lock());
	const int id = StubKernel::Next()++;
	StubKernel::Semas()[id] = std::make_unique<StubKernel::Sema>();
	StubKernel::Semas()[id]->count = initial;
	return id;
}
inline int sceKernelWaitSema(SceUID id, int need, unsigned*)
{
	StubKernel::Sema* s = StubKernel::Get(id);
	if (!s)
		return -1;
	std::unique_lock<std::mutex> lock(s->m);
	s->cv.wait(lock, [&]() { return s->count >= need; });
	s->count -= need;
	return 0;
}
inline int sceKernelSignalSema(SceUID id, int add)
{
	StubKernel::Sema* s = StubKernel::Get(id);
	if (!s)
		return -1;
	{
		std::lock_guard<std::mutex> lock(s->m);
		s->count += add;
	}
	s->cv.notify_all();
	return 0;
}
inline SceUID sceKernelCreateThread(const char*, SceKernelThreadEntry entry, int, int, unsigned, int, void*)
{
	std::lock_guard<std::mutex> lock(StubKernel::Lock());
	const int id = StubKernel::Next()++;
	StubKernel::Threads()[id] = { entry };
	return id;
}
inline int sceKernelStartThread(SceUID id, SceSize size, const void* argp)
{
	SceKernelThreadEntry entry;
	{
		std::lock_guard<std::mutex> lock(StubKernel::Lock());
		entry = StubKernel::Threads()[id].entry;
	}
	std::vector<uint8_t> args((const uint8_t*)argp, (const uint8_t*)argp + size);
	std::thread([entry, args]() mutable { entry((SceSize)args.size(), args.data()); }).detach();
	return 0;
}
