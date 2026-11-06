#define private public
#include "Precomp.h"
#include "Render/BspClipper.h"
#undef private
#include <cstdio>
#include <random>
#include <cmath>

static bool Triangles(BspClipper& c, const vec3* v, uint32_t count, bool solid)
{
	// the original CheckSurface body
	BspClipper::ShadedVertex buffer[3];
	BspClipper::ShadedVertex* t[3] = { &buffer[0], &buffer[1], &buffer[2] };
	bool result = false;
	t[0]->position = c.WorldToProjection * vec4(v[0], 1.0f); t[0]->clipDistance = dot(c.PortalPlane, vec4(v[0], 1.0f));
	t[1]->position = c.WorldToProjection * vec4(v[1], 1.0f); t[1]->clipDistance = dot(c.PortalPlane, vec4(v[1], 1.0f));
	for (uint32_t i = 2; i < count; i++)
	{
		t[2]->position = c.WorldToProjection * vec4(v[i], 1.0f); t[2]->clipDistance = dot(c.PortalPlane, vec4(v[i], 1.0f));
		result |= c.DrawTriangle(t, solid, false);
		std::swap(t[1], t[2]);
	}
	return result;
}

int main()
{
	std::mt19937 rng(1234);
	std::uniform_real_distribution<float> U(-1.0f, 1.0f);
	mat4 proj = mat4::frustum(-1.0f, 1.0f, -0.53f, 0.53f, 1.0f, 32768.0f, handedness::left, clipzrange::zero_positive_w);
	long surfaces = 0, mismatchVisible = 0, linesDiff = 0, lines = 0, pixelsA = 0, pixelsB = 0;
	for (int scene = 0; scene < 300; scene++)
	{
		BspClipper a, b;
		Array<PortalSpan> none;
		a.Setup(proj, none, vec4(0.0f));
		b.Setup(proj, none, vec4(0.0f));
		for (int s = 0; s < 400; s++)
		{
			// a convex polygon: points on an ellipse in a random plane, some crossing the near plane and the screen edges
			int n = 3 + rng() % 10;
			vec3 centre(U(rng) * 1500.0f, U(rng) * 800.0f, 50.0f + (U(rng) + 1.0f) * 2000.0f);
			if (rng() % 10 == 0) centre.z = U(rng) * 60.0f;
			vec3 ax = normalize(vec3(U(rng), U(rng), U(rng))), tmp = normalize(vec3(U(rng), U(rng), U(rng)));
			vec3 ay = normalize(cross(ax, tmp));
			float rx = 20.0f + (U(rng) + 1.0f) * 400.0f, ry = 20.0f + (U(rng) + 1.0f) * 400.0f;
			vec3 pts[16];
			float phase = U(rng) * 3.14159f;
			for (int i = 0; i < n; i++)
			{
				float t = phase + 6.2831853f * i / n;
				pts[i] = centre + ax * (std::cos(t) * rx) + ay * (std::sin(t) * ry);
			}
			bool solid = rng() % 8 != 0;
			bool va = Triangles(a, pts, n, solid);
			bool vb = b.VitaCheckPolygon(pts, n, solid);
			surfaces++;
			if (va != vb) mismatchVisible++;
		}
		for (int y = 0; y < a.ViewportHeight; y++)
		{
			auto& la = a.Viewport[y]; auto& lb = b.Viewport[y];
			lines++;
			bool same = la.size() == lb.size();
			for (size_t i = 0; same && i < la.size(); i++) same = la[i].x0 == lb[i].x0 && la[i].x1 == lb[i].x1;
			if (!same) linesDiff++;
			for (size_t i = 0; i + 1 < la.size(); i++) pixelsA += la[i + 1].x0 - la[i].x1;
			for (size_t i = 0; i + 1 < lb.size(); i++) pixelsB += lb[i + 1].x0 - lb[i].x1;
		}
	}
	printf("surfaces %ld, visible answer differs %ld (%.2f%%)\n", surfaces, mismatchVisible, 100.0 * mismatchVisible / surfaces);
	printf("screen lines %ld, lines whose coverage differs %ld (%.2f%%); open pixels left: triangles %ld, polygon %ld\n", lines, linesDiff, 100.0 * linesDiff / lines, pixelsA, pixelsB);
}
