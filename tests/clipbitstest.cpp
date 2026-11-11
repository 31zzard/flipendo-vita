// VitaClipBits (vita/VitaClipBits.h) against BspClipper's span lists (the code of Render/BspClipper.cpp, copied here as it is):
// random DrawSpan / IsVisible / collected portal spans on random lines must give the same answers.
// g++ -std=gnu++20 -O2 -I.. clipbitstest.cpp -o /tmp/clipbitstest && /tmp/clipbitstest
#include "../VitaClipBits.h"
#include <algorithm>
#include <cstdio>
#include <random>
#include <vector>

struct ClipSpan { int16_t x0, x1; };
struct Piece { int y; int16_t x0, x1; bool operator==(const Piece& o) const { return y == o.y && x0 == o.x0 && x1 == o.x1; } };

struct OldClipper
{
	int width, height;
	std::vector<std::vector<ClipSpan>> Viewport;
	bool CollectSpans = false;
	std::vector<Piece> VisibleSpans;

	void Setup(int w, int h)
	{
		width = w; height = h;
		Viewport.assign(h, {});
		for (auto& line : Viewport)
		{
			line.push_back({ (int16_t)0x8000, 0 });
			line.push_back({ (int16_t)w, (int16_t)0x7fff });
		}
	}
	bool IsVisible(int16_t y, int16_t x0, int16_t x1)
	{
		auto& line = Viewport[y];
		for (size_t pos = 0; pos < line.size(); pos++)
		{
			int16_t left = line[pos].x1;
			if (left >= x1)
				break;
			int16_t right = line[pos + 1].x0;
			left = std::max(left, x0);
			right = std::min(right, x1);
			if (left < right)
				return true;
		}
		return false;
	}
	bool DrawSpan(int16_t y, int16_t x0, int16_t x1, bool solid)
	{
		if (x1 <= x0)
			return false;
		if (!solid)
			return IsVisible(y, x0, x1);
		auto& line = Viewport[y];
		bool collect = CollectSpans;
		bool visible = false;
		for (size_t pos = 0; pos < line.size(); pos++)
		{
			ClipSpan& span = line[pos];
			ClipSpan& nextspan = line[pos + 1];
			int16_t left = span.x1;
			if (left >= x1)
				break;
			int16_t right = nextspan.x0;
			left = std::max(left, x0);
			right = std::min(right, x1);
			if (left < right)
			{
				visible = true;
				if (collect)
					VisibleSpans.push_back({ y, left, right });
				if (left == span.x1)
				{
					span.x1 = right;
					if (span.x1 == nextspan.x0)
					{
						span.x1 = nextspan.x1;
						line.erase(line.begin() + pos + 1);
						pos--;
					}
				}
				else if (right == nextspan.x0)
				{
					nextspan.x0 = left;
					if (span.x1 == nextspan.x0)
					{
						span.x1 = nextspan.x1;
						line.erase(line.begin() + pos + 1);
						pos--;
					}
				}
				else
				{
					pos++;
					line.insert(line.begin() + pos, ClipSpan{ left, right });
				}
			}
		}
		return visible;
	}
};

struct NewClipper
{
	VitaClipBits b;
	bool CollectSpans = false;
	std::vector<Piece> VisibleSpans;
	void Setup(int w, int h) { b.Resize(w, h); b.Clear(); }
	bool IsVisible(int16_t y, int16_t x0, int16_t x1) { return b.IsVisible(y, x0, x1); }
	bool DrawSpan(int16_t y, int16_t x0, int16_t x1, bool solid)
	{
		if (x1 <= x0)
			return false;
		if (!solid)
			return b.IsVisible(y, x0, x1);
		if (CollectSpans)
		{
			const int c0 = std::max<int>(x0, 0), c1 = std::min<int>(x1, b.width);
			if (c0 < c1)
				b.OpenRuns(y, c0, c1, [&](int a, int e) { VisibleSpans.push_back({ y, (int16_t)a, (int16_t)e }); });
		}
		return b.Fill(y, x0, x1);
	}
};

int main()
{
	std::mt19937 rng(42);
	long ops = 0, bad = 0;
	for (int round = 0; round < 400; round++)
	{
		const int width = 8 + (int)(rng() % 500), height = 1 + (int)(rng() % 6);
		OldClipper o;
		NewClipper n;
		o.Setup(width, height);
		n.Setup(width, height);
		for (int i = 0; i < 4000; i++)
		{
			const int16_t y = (int16_t)(rng() % height);
			const int span = (int)(rng() % 4 == 0 ? rng() % (width + 40) : rng() % 24);
			const int16_t x0 = (int16_t)((int)(rng() % (width + 40)) - 20);
			const int16_t x1 = (int16_t)(x0 + span - (rng() % 8 == 0 ? 10 : 0));
			const int kind = (int)(rng() % 4);
			bool a, c;
			if (kind == 0)
			{
				a = o.IsVisible(y, x0, x1);
				c = n.IsVisible(y, x0, x1);
			}
			else
			{
				const bool solid = kind != 1;
				const bool collect = kind == 3;
				o.CollectSpans = n.CollectSpans = collect;
				o.VisibleSpans.clear();
				n.VisibleSpans.clear();
				a = o.DrawSpan(y, x0, x1, solid);
				c = n.DrawSpan(y, x0, x1, solid);
				if (o.VisibleSpans != n.VisibleSpans)
					bad++;
			}
			ops++;
			if (a != c)
				bad++;
		}
		// every pixel of every line the same
		for (int y = 0; y < height; y++)
			for (int x = -3; x < width + 3; x++)
				if (o.IsVisible(y, x, x + 1) != n.IsVisible(y, x, x + 1))
					bad++;
	}
	printf("%ld operations, %ld differences\n", ops, bad);
	return bad != 0;
}
