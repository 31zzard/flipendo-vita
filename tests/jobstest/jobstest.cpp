// PC stress test of vita/VitaJobs.h with std::thread stand-ins for the sceKernel calls (psp2/ here).
// g++ -std=gnu++20 -O2 -D__vita__ -Ivita/tests/jobstest -Ivita vita/tests/jobstest/jobstest.cpp -pthread
#include "VitaJobs.h"
#include <cstdio>
#include <random>
#include <atomic>
static std::atomic<int> hits[4096];
static void Job(void* ctx, int i)
{
	hits[i].fetch_add(1);
	volatile int spin = (i * 7919) % 300;   // uneven job lengths
	for (volatile int k = 0; k < spin; k++) {}
}
int main()
{
	std::mt19937 rng(5);
	long runs = 0, bad = 0;
	for (int r = 0; r < 60000; r++)
	{
		int count = 1 + rng() % 40;
		for (int i = 0; i < count; i++) hits[i] = 0;
		VitaJobs::Run(Job, nullptr, count);
		for (int i = 0; i < count; i++) if (hits[i].load() != 1) bad++;
		runs++;
	}
	printf("runs %ld, jobs not run exactly once when Run returned: %ld; workers started: %d\n", runs, bad, (int)VitaJobs::started);
}
