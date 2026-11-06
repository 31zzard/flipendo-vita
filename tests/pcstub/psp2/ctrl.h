#pragma once
// PC stand-in (vita/tests): the pad, scripted by the test
#include <cstdint>
enum { SCE_CTRL_UP = 0x10, SCE_CTRL_DOWN = 0x40, SCE_CTRL_CIRCLE = 0x2000, SCE_CTRL_CROSS = 0x4000, SCE_CTRL_MODE_ANALOG = 1 };
typedef struct SceCtrlData { uint64_t timeStamp; unsigned int buttons; unsigned char lx, ly, rx, ry; uint8_t reserved[16]; } SceCtrlData;
int sceCtrlSetSamplingMode(int mode);
int sceCtrlPeekBufferPositive(int port, SceCtrlData* pad, int count);
