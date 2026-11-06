#pragma once
// PC stand-in (vita/tests)
#include <cstdlib>
typedef int SceUID;
typedef unsigned int SceSize;
#define SCE_KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW 0x09408060
inline void*& StubBlockBase() { static void* p = nullptr; return p; }
inline SceUID sceKernelAllocMemBlock(const char*, int, SceSize size, void*) { StubBlockBase() = std::calloc(1, size); return 1; }
inline int sceKernelGetMemBlockBase(SceUID, void** base) { *base = StubBlockBase(); return 0; }
