#pragma once
// PC stand-in (vita/tests)
#include <cstdint>
#include <cstddef>
enum { SCE_DISPLAY_PIXELFORMAT_A8B8G8R8 = 0, SCE_DISPLAY_SETBUF_NEXTFRAME = 1 };
typedef struct SceDisplayFrameBuf { size_t size; void* base; unsigned int pitch, pixelformat, width, height; } SceDisplayFrameBuf;
int sceDisplaySetFrameBuf(const SceDisplayFrameBuf* frame, int sync);
int sceDisplayWaitVblankStart(void);
