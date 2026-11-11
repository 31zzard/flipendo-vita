// The engine log (--logfile) written on its own thread (apply_fixes.sh #148).
//
// A write to the memory card blocks for tens of milliseconds: the profile of 07 Nov (Lev2_Fire1) charged 5-6% of the engine
// thread to the log callback, which wrote out its buffer once a second (#33) for only ~7 lines a second. Now the engine thread
// only appends the line to a string; the 'logwriter' thread (low priority, any core) writes what has gathered every 250 ms.
// A FATAL line and the end of the game are written at once on the calling thread (Flush). A hung engine thread no longer
// keeps its last lines in memory: the writer goes on without it (the empty flipendo.log of a game that hung while starting).
//
// The writer is a kernel thread: it waits only on SceKernelLwMutex (no pthread waits there, vita/CLAUDE.md).

#pragma once

#include <psp2/io/fcntl.h>
#include <psp2/kernel/threadmgr.h>
#include <string>

namespace VitaLogWriter
{
	inline SceUID fd = -1;
	inline SceKernelLwMutexWork pendingLock;   // the text not yet written
	inline SceKernelLwMutexWork writeLock;     // one writer at a time (the thread or Flush), so the order stays
	inline std::string pending;

	inline void Flush()
	{
		if (fd < 0)
			return;
		sceKernelLockLwMutex(&writeLock, 1, nullptr);
		std::string text;
		sceKernelLockLwMutex(&pendingLock, 1, nullptr);
		text.swap(pending);
		sceKernelUnlockLwMutex(&pendingLock, 1);
		const char* p = text.data();
		size_t left = text.size();
		while (left > 0)
		{
			int n = sceIoWrite(fd, p, left);
			if (n <= 0)
				break;
			p += n;
			left -= n;
		}
		sceKernelUnlockLwMutex(&writeLock, 1);
	}

	inline int Main(SceSize, void*)
	{
		while (true)
		{
			sceKernelDelayThread(250 * 1000);
			Flush();
		}
		return 0;
	}

	// true: the file is open and the thread runs (else the caller keeps its own way of writing)
	inline bool Open(const std::string& path)
	{
		fd = sceIoOpen(path.c_str(), SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0666);
		if (fd < 0)
			return false;
		sceKernelCreateLwMutex(&pendingLock, "logpending", 0, 0, nullptr);
		sceKernelCreateLwMutex(&writeLock, "logwrite", 0, 0, nullptr);
		pending.reserve(64 * 1024);
		SceUID id = sceKernelCreateThread("logwriter", Main, 191, 64 * 1024, 0, SCE_KERNEL_CPU_MASK_USER_ALL, nullptr);
		if (id < 0 || sceKernelStartThread(id, 0, nullptr) < 0)
		{
			sceIoClose(fd);
			fd = -1;
			return false;
		}
		return true;
	}

	inline void Append(const std::string& line, bool now)
	{
		sceKernelLockLwMutex(&pendingLock, 1, nullptr);
		pending += line;
		sceKernelUnlockLwMutex(&pendingLock, 1);
		if (now)
			Flush();
	}
}
