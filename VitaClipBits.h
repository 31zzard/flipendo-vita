// The clipper's screen as one bit per pixel (render.cfg clipper_bits, apply_fixes.sh #208).
//
// BspClipper kept, per line of its screen, a list of covered runs (ClipSpan x0..x1, with a sentinel left of 0 and one from the
// width on): IsVisible walked the list for an open gap meeting x0..x1, DrawSpan walked it, filled the gaps it met and merged the
// runs (inserting into an Array). Here a line is a row of 32-bit words, a set bit a covered pixel; the pixels from the width on
// are set (the right sentinel), x < 0 is never open (the left one). The same answers:
//   IsVisible(y, x0, x1): some pixel x0 <= x < x1 is open;
//   DrawSpan(y, x0, x1, solid): nothing when x1 <= x0; not solid: IsVisible; solid: true when some pixel was open, every pixel
//     of x0..x1 covered afterwards, and with collect the open runs met, left to right, each cut to x0..x1 (the old gaps met:
//     its runs never touch, so a gap is a whole open run).
// vita/tests/clipbitstest.cpp checks them against the old span code on random lines.

#pragma once

#include <cstdint>
#include <cstring>
#include <vector>

struct VitaClipBits
{
	int width = 0, height = 0, words = 0;   // words: 32-bit words a line
	std::vector<uint32_t> bits;
	std::vector<uint32_t> openLine;   // a line open from 0 to the width, covered from there (the right sentinel)

	void Resize(int w, int h)
	{
		width = w;
		height = h;
		words = (w + 31) / 32 + 1;   // one more word: x up to the width rounded up is always inside a line
		bits.assign((size_t)words * h, 0u);
		openLine.assign(words, 0u);
		for (int x = width; x < words * 32; x++)
			openLine[x >> 5] |= 1u << (x & 31);
	}

	// every line open from 0 to the width
	void Clear()
	{
		for (int y = 0; y < height; y++)
			std::memcpy(&bits[(size_t)y * words], openLine.data(), (size_t)words * 4);
	}

	// the bits x0..x1-1 of a word (0 <= x0 < x1 <= 32)
	static uint32_t Mask(int x0, int x1)
	{
		const uint32_t hi = x1 >= 32 ? 0xffffffffu : ((1u << x1) - 1u);
		return hi & ~((1u << x0) - 1u);
	}

	bool IsVisible(int y, int x0, int x1) const
	{
		if (x0 < 0)
			x0 = 0;
		if (x1 > width)
			x1 = width;
		if (x0 >= x1)
			return false;
		const uint32_t* line = &bits[(size_t)y * words];
		const int w0 = x0 >> 5, w1 = (x1 - 1) >> 5;
		if (w0 == w1)
			return (~line[w0] & Mask(x0 & 31, ((x1 - 1) & 31) + 1)) != 0;
		if (~line[w0] & Mask(x0 & 31, 32))
			return true;
		for (int w = w0 + 1; w < w1; w++)
			if (~line[w])
				return true;
		return (~line[w1] & Mask(0, ((x1 - 1) & 31) + 1)) != 0;
	}

	// the open runs of x0..x1 (clamped), left to right, given to collect(x0, x1)
	template<typename Collect>
	void OpenRuns(int y, int x0, int x1, Collect collect) const
	{
		const uint32_t* line = &bits[(size_t)y * words];
		int x = x0;
		while (x < x1)
		{
			// skip covered pixels
			while (x < x1)
			{
				const uint32_t open = ~line[x >> 5] >> (x & 31);
				if (open)
				{
					x += __builtin_ctz(open);
					break;
				}
				x = (x | 31) + 1;
			}
			if (x >= x1)
				break;
			const int start = x;
			// the open run
			while (x < x1)
			{
				const uint32_t covered = line[x >> 5] >> (x & 31);
				if (covered)
				{
					x += __builtin_ctz(covered);
					break;
				}
				x = (x | 31) + 1;
			}
			if (x > x1)
				x = x1;
			collect(start, x);
		}
	}

	// solid: true when some pixel of x0..x1 was open; every pixel of it covered afterwards
	bool Fill(int y, int x0, int x1)
	{
		if (x0 < 0)
			x0 = 0;
		if (x1 > width)
			x1 = width;
		if (x0 >= x1)
			return false;
		uint32_t* line = &bits[(size_t)y * words];
		const int w0 = x0 >> 5, w1 = (x1 - 1) >> 5;
		uint32_t open = 0;
		if (w0 == w1)
		{
			const uint32_t m = Mask(x0 & 31, ((x1 - 1) & 31) + 1);
			open = ~line[w0] & m;
			line[w0] |= m;
			return open != 0;
		}
		uint32_t m = Mask(x0 & 31, 32);
		open |= ~line[w0] & m;
		line[w0] |= m;
		for (int w = w0 + 1; w < w1; w++)
		{
			open |= ~line[w];
			line[w] = 0xffffffffu;
		}
		m = Mask(0, ((x1 - 1) & 31) + 1);
		open |= ~line[w1] & m;
		line[w1] |= m;
		return open != 0;
	}
};
