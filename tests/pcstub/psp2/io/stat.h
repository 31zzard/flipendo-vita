#pragma once
// PC stand-in (vita/tests)
#include <sys/stat.h>
typedef struct SceIoStat { int st_mode; } SceIoStat;
inline int sceIoGetstat(const char* path, SceIoStat* st) { struct stat s; if (stat(path, &s) != 0) return -1; st->st_mode = s.st_mode; return 0; }
