#pragma once
// PC stand-ins for the Vita's thread and semaphore calls (test only)
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
typedef int SceUID; typedef unsigned int SceSize;
struct StubSema { std::mutex m; std::condition_variable cv; int count = 0; };
inline std::vector<StubSema*> stubSemas = [] { std::vector<StubSema*> v; v.reserve(64); return v; }();
inline std::vector<int (*)(SceSize, void*)> stubThreads = [] { std::vector<int (*)(SceSize, void*)> v; v.reserve(64); return v; }();
inline SceUID sceKernelCreateSema(const char*, int, int init, int, void*) { auto* s = new StubSema; s->count = init; stubSemas.push_back(s); return (SceUID)stubSemas.size() - 1; }
inline int sceKernelWaitSema(SceUID id, int n, void*) { auto* s = stubSemas[id]; std::unique_lock l(s->m); s->cv.wait(l, [&] { return s->count >= n; }); s->count -= n; return 0; }
inline int sceKernelSignalSema(SceUID id, int n) { auto* s = stubSemas[id]; { std::lock_guard l(s->m); s->count += n; } s->cv.notify_all(); return 0; }
inline SceUID sceKernelCreateThread(const char*, int (*fn)(SceSize, void*), int, int, int, int, void*) { stubThreads.push_back(fn); return (SceUID)stubThreads.size() - 1; }
inline int sceKernelStartThread(SceUID id, SceSize size, const void* arg) { std::vector<char> copy((const char*)arg, (const char*)arg + size); auto fn = stubThreads[id]; auto* heap = new std::vector<char>(copy); std::thread([fn, heap]() { fn((SceSize)heap->size(), heap->data()); }).detach(); return 0; }
