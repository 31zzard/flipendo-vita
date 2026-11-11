// VitaLightGrid against the full loop: the lights within radius of a point, in the snapshot's order, must be the same.
// g++ -std=gnu++20 -O2 -I<engine>/SurrealEngine -I.. lightgridtest.cpp -o /tmp/lightgridtest
#include "Math/vec.h"
#include "../VitaLightGrid.h"
#include <cstdio>
#include <random>

int main()
{
	std::mt19937 rng(1234);
	std::uniform_real_distribution<float> pos(-6000.0f, 6000.0f), rad(50.0f, 2500.0f), small(-40.0f, 40.0f);
	long checks = 0, bad = 0;
	for (int level = 0; level < 20; level++)
	{
		const int n = 100 + level * 40;
		std::vector<UActor*> lights(n);
		std::vector<vec3> loc(n);
		std::vector<float> radius(n);
		for (int i = 0; i < n; i++)
		{
			lights[i] = (UActor*)(uintptr_t)(0x1000 + i * 16);
			loc[i] = vec3(pos(rng), pos(rng), pos(rng) * 0.2f);
			radius[i] = rad(rng);
		}
		VitaLightGrid grid;
		for (int frame = 0; frame < 200; frame++)
		{
			// some lights move, sometimes the list changes
			for (int m = 0; m < (frame % 7) + (frame % 40 == 3 ? 90 : 0); m++)
			{
				int i = (int)(rng() % lights.size());
				loc[i] += vec3(small(rng), small(rng), small(rng));
				if (rng() % 5 == 0)
					radius[i] = rad(rng);
			}
			if (frame % 13 == 5 || frame % 31 == 0)   // a light comes (a spell's), anywhere in the list
			{
				int i = (int)(rng() % (lights.size() + 1));
				static uintptr_t next = 0x900000;
				lights.insert(lights.begin() + i, (UActor*)(next += 16));
				loc.insert(loc.begin() + i, vec3(pos(rng), pos(rng), pos(rng) * 0.2f));
				radius.insert(radius.begin() + i, rng() % 9 == 0 ? 40000.0f : rad(rng));
			}
			if (frame % 50 == 49 || frame % 13 == 7)
			{
				int i = (int)(rng() % lights.size());
				lights.erase(lights.begin() + i);
				loc.erase(loc.begin() + i);
				radius.erase(radius.begin() + i);
			}
			grid.Update(lights, loc, radius);
			for (int q = 0; q < 50; q++)
			{
				vec3 p(pos(rng), pos(rng), pos(rng) * 0.2f);
				std::vector<uint32_t> want, got;
				for (uint32_t i = 0; i < lights.size(); i++)
				{
					vec3 d = loc[i] - p;
					if (dot(d, d) < radius[i] * radius[i])
						want.push_back(i);
				}
				for (uint32_t i : grid.Query(p))
				{
					vec3 d = loc[i] - p;
					if (dot(d, d) < radius[i] * radius[i])
						got.push_back(i);
				}
				checks++;
				if (want != got)
					bad++;
			}
		}
	}
	printf("%ld queries, %ld different from the full loop\n", checks, bad);
	return bad != 0;
}
