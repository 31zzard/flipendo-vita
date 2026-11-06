#pragma once
// PC stand-in (vita/tests): the process clock in microseconds
#include <chrono>
#include <cstdint>
inline uint64_t sceKernelGetProcessTimeWide()
{
	return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
