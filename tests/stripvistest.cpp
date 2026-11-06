// PC test of the visibility walk on three strips (vita/VitaParallelVis.inc): random trees with nested bounds, polygons on their nodes
// (some not occluding, some portals) and actors whose boxes may reach past their node's box. One walk with one clipper (the old way)
// against three walks with a clipper per strip (each skipping what its strip finds hidden, testing the actors of what it skips) whose
// answers are put together. Every answer must be the same; the only allowed difference is "visible" where the one clipper said hidden.
//   E=../../src/engine/SurrealEngine
//   g++ -std=gnu++20 -O2 -D__vita__ -I$E -I.. stripvistest.cpp $E/Render/BspClipper.cpp $E/Math/mat.cpp $E/Math/FrustumPlanes.cpp \
//       -o stripvistest && ./stripvistest
#include <chrono>
#define private public
#include "Precomp.h"
#include "Render/BspClipper.h"
#include "Math/bbox.h"
#undef private
#include <cstdio>
#include <random>
#include <cmath>
#include <set>

namespace
{
	struct Poly { std::vector<vec3> points; bool solid; bool portal; };
	struct Node
	{
		BBox bound;
		std::vector<Poly> polys;
		std::vector<BBox> actors;
		int front = -1, back = -1;
	};

	std::mt19937 rng;
	float U() { return std::uniform_real_distribution<float>(-1.0f, 1.0f)(rng); }

	Poly MakePoly(const vec3& centre, float size)
	{
		Poly p;
		const int n = 3 + rng() % 8;
		vec3 ax = normalize(vec3(U(), U(), U()) + vec3(0.001f, 0, 0)), tmp = normalize(vec3(U(), U(), U()) + vec3(0, 0.001f, 0));
		vec3 ay = normalize(cross(ax, tmp));
		const float rx = size * (0.2f + 0.8f * (U() + 1.0f) * 0.5f), ry = size * (0.2f + 0.8f * (U() + 1.0f) * 0.5f);
		const float phase = U() * 3.14159f;
		for (int i = 0; i < n; i++)
		{
			const float t = phase + 6.2831853f * i / n;
			p.points.push_back(centre + ax * (std::cos(t) * rx) + ay * (std::sin(t) * ry));
		}
		p.solid = rng() % 8 != 0;
		p.portal = rng() % 40 == 0;
		return p;
	}

	int Build(std::vector<Node>& nodes, const vec3& centre, float size, int depth)
	{
		const int index = (int)nodes.size();
		nodes.emplace_back();
		const int polys = depth == 0 ? 1 + rng() % 3 : rng() % 3;
		for (int i = 0; i < polys; i++)
			nodes[index].polys.push_back(MakePoly(centre + vec3(U(), U(), U()) * size * 0.5f, size * 0.5f));
		const int actors = rng() % 4 == 0 ? 1 + rng() % 3 : 0;
		for (int i = 0; i < actors; i++)
		{
			const vec3 c = centre + vec3(U(), U(), U()) * size * 0.8f;   // may reach past the node's box
			const vec3 e(10 + (U() + 1) * 60, 10 + (U() + 1) * 60, 10 + (U() + 1) * 90);
			nodes[index].actors.push_back(BBox(c - e, c + e));
		}
		if (depth > 0)
		{
			const vec3 axis = rng() % 3 == 0 ? vec3(1, 0, 0) : rng() % 2 ? vec3(0, 1, 0) : vec3(0, 0, 1);
			const int a = Build(nodes, centre + axis * size * 0.5f, size * 0.55f, depth - 1);
			const int b = Build(nodes, centre - axis * size * 0.5f, size * 0.55f, depth - 1);
			nodes[index].front = a;
			nodes[index].back = b;
		}
		// the bound: its polygons and its children's bounds
		bool any = false;
		BBox box;
		auto add = [&](const vec3& p)
		{
			if (!any) { box = BBox(p, p); any = true; return; }
			box.min = vec3(std::min(box.min.x, p.x), std::min(box.min.y, p.y), std::min(box.min.z, p.z));
			box.max = vec3(std::max(box.max.x, p.x), std::max(box.max.y, p.y), std::max(box.max.z, p.z));
		};
		for (const Poly& p : nodes[index].polys)
			for (const vec3& v : p.points)
				add(v);
		for (int child : { nodes[index].front, nodes[index].back })
			if (child >= 0)
			{
				add(nodes[child].bound.min);
				add(nodes[child].bound.max);
			}
		nodes[index].bound = box;
		return index;
	}

	struct Answers
	{
		std::vector<uint8_t> visited;                 // by node
		std::vector<std::vector<uint8_t>> polys;      // by node and polygon
		std::vector<std::vector<uint8_t>> actors;     // by node and actor
		std::set<std::tuple<int, int, int>> portalPixels;   // (node * 64 + polygon, y, x)
	};

	void Prepare(Answers& a, const std::vector<Node>& nodes)
	{
		a.visited.assign(nodes.size(), 0);
		a.polys.resize(nodes.size());
		a.actors.resize(nodes.size());
		for (size_t i = 0; i < nodes.size(); i++)
		{
			a.polys[i].assign(nodes[i].polys.size(), 0);
			a.actors[i].assign(nodes[i].actors.size(), 0);
		}
		a.portalPixels.clear();
	}

	// The walk: a node's box, its actors, the front, its polygons, the back. skipActors: test the actors of what is skipped
	void Walk(const std::vector<Node>& nodes, BspClipper& c, Answers& a, int n, bool strip)
	{
		const Node& node = nodes[n];
		if (!c.IsAABBVisible(node.bound))
		{
			if (strip)
			{
				// the strip's answers for the actors of the skipped subtree: its clipper as it is now
				std::vector<int> stack = { n };
				while (!stack.empty())
				{
					const int m = stack.back();
					stack.pop_back();
					for (size_t k = 0; k < nodes[m].actors.size(); k++)
						a.actors[m][k] = c.IsAABBVisible(nodes[m].actors[k]);
					if (nodes[m].front >= 0) stack.push_back(nodes[m].front);
					if (nodes[m].back >= 0) stack.push_back(nodes[m].back);
				}
			}
			return;
		}
		a.visited[n] = 1;
		for (size_t k = 0; k < node.actors.size(); k++)
			a.actors[n][k] = c.IsAABBVisible(node.actors[k]);
		if (node.front >= 0)
			Walk(nodes, c, a, node.front, strip);
		for (size_t p = 0; p < node.polys.size(); p++)
		{
			const Poly& poly = node.polys[p];
			if (poly.portal)
			{
				Array<PortalSpan> spans = c.CheckPortal(poly.points.data(), (uint32_t)poly.points.size());
				a.polys[n][p] = !spans.empty();
				static const bool timing = getenv("TIMING") != nullptr;   // TIMING=1: the portal pixels are not kept (std::set is most of the time)
				for (const PortalSpan& s : spans)
					for (int x = s.x0; x < s.x1 && !timing; x++)
						a.portalPixels.insert({ n * 64 + (int)p, (int)s.y, x });
			}
			else
			{
				a.polys[n][p] = c.CheckSurface(poly.points.data(), (uint32_t)poly.points.size(), poly.solid);
			}
		}
		if (node.back >= 0)
			Walk(nodes, c, a, node.back, strip);
	}
}

int main()
{
	mat4 proj = mat4::frustum(-1.0f, 1.0f, -0.53f, 0.53f, 1.0f, 32768.0f, handedness::left, clipzrange::zero_positive_w);
	long nodesSeen = 0, polysSeen = 0, actorsSeen = 0, portalPixels = 0;
	long missing = 0, extra = 0;
	long missingKind[5] = {};
	double serialMs = 0, slowestStripMs = 0, stripsMs = 0;   // NOKEEP=1: strips without their open-column limits (as before #82)
	auto now = [] { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); };
	const int scenes = getenv("SCENES") ? atoi(getenv("SCENES")) : 400;
	for (int scene = 0; scene < scenes; scene++)
	{
		rng.seed(scene + 1);
		std::vector<Node> nodes;
		Build(nodes, vec3(U() * 300, U() * 200, 2500.0f + U() * 1500.0f), 2500.0f, 9);

		// every other scene is a portal's frame: only the spans of a random polygon are open (as a sky or mirror's frame starts)
		Array<PortalSpan> none;
		if (scene % 2)
		{
			BspClipper p;
			p.Setup(proj, none, vec4(0.0f));
			Poly window = MakePoly(vec3(U() * 300, U() * 200, 1500.0f), 1500.0f);
			none = p.CheckPortal(window.points.data(), (uint32_t)window.points.size());
			std::sort(none.begin(), none.end(), [](const PortalSpan& a, const PortalSpan& b) { return a.y != b.y ? a.y < b.y : a.x0 < b.x0; });
		}
		BspClipper one;
		one.Setup(proj, none, vec4(0.0f));
		Answers serial;
		Prepare(serial, nodes);
		double t0 = now();
		Walk(nodes, one, serial, 0, false);
		serialMs += now() - t0;
		double slowest = 0;

		// three strips with random borders, and the answers put together
		const int width = one.ViewportWidth;
		int b1 = 16 + rng() % (width / 2), b2 = b1 + 16 + rng() % (width - b1 - 32);
		if (getenv("ONESTRIP")) { b1 = width; b2 = width; }
		if (getenv("THIRDS")) { b1 = width / 3; b2 = width * 2 / 3; }   // as the Vita starts (it then moves them by the strips' times)
		const int x0[3] = { 0, b1, b2 }, x1[3] = { b1, b2, width };
		Answers joined;
		Prepare(joined, nodes);
		for (int i = 0; i < 3; i++)
		{
			if (x0[i] >= x1[i])
				continue;
			BspClipper c;
			c.Setup(proj, none, vec4(0.0f));
			c.VitaKeepColumns(x0[i], x1[i]);
			if (getenv("NOKEEP")) { c.VitaKeepX0 = 0; c.VitaKeepX1 = 0x7fff; c.VitaStrip = false; }
			Answers s;
			Prepare(s, nodes);
			double ts = now();
			Walk(nodes, c, s, 0, true);
			const double ms = now() - ts;
			stripsMs += ms;
			slowest = std::max(slowest, ms);
			for (size_t n = 0; n < nodes.size(); n++)
			{
				joined.visited[n] |= s.visited[n];
				for (size_t p = 0; p < s.polys[n].size(); p++) joined.polys[n][p] |= s.polys[n][p];
				for (size_t k = 0; k < s.actors[n].size(); k++) joined.actors[n][k] |= s.actors[n][k];
			}
			joined.portalPixels.insert(s.portalPixels.begin(), s.portalPixels.end());
		}

		slowestStripMs += slowest;

		// The main walk only looks at what it reaches: nodes it visits, their polygons and actors
		for (size_t n = 0; n < nodes.size(); n++)
		{
			auto compare = [&](uint8_t a, uint8_t b, int kind) { if (a && !b) { missing++; missingKind[kind]++; } if (b && !a) extra++; };
			compare(serial.visited[n], joined.visited[n], 0);
			nodesSeen++;
			if (!serial.visited[n] && !joined.visited[n])
				continue;
			for (size_t p = 0; p < nodes[n].polys.size(); p++) { compare(serial.polys[n][p], joined.polys[n][p], nodes[n].polys[p].portal ? 2 : 1); polysSeen++; }
			for (size_t k = 0; k < nodes[n].actors.size(); k++) { compare(serial.actors[n][k], joined.actors[n][k], 3); actorsSeen++; }
		}
		for (const auto& px : serial.portalPixels)
			if (!joined.portalPixels.count(px)) { missing++; missingKind[4]++; }
		for (const auto& px : joined.portalPixels)
			if (!serial.portalPixels.count(px)) extra++;
		portalPixels += (long)serial.portalPixels.size();
	}
	std::printf("%ld nodes, %ld polygons, %ld actors, %ld portal pixels compared: %ld answers missing (hidden by mistake), %ld extra (visible by mistake)\n",
		nodesSeen, polysSeen, actorsSeen, portalPixels, missing, extra);
	std::printf("missing by kind: nodes %ld, polygons %ld, portals %ld, actors %ld, portal pixels %ld\n", missingKind[0], missingKind[1], missingKind[2], missingKind[3], missingKind[4]);
	std::printf("time: one clipper %.1f ms, the strips %.1f ms in all, the slowest strip of each scene %.1f ms in all\n", serialMs, stripsMs, slowestStripMs);
	return missing ? 1 : 0;
}
