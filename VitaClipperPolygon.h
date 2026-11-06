#pragma once

// BspClipper::CheckSurface for a whole polygon (clipper_polygons=1 in render.cfg). The original splits a BSP surface (a convex
// polygon, ~5.4 points on average in HP1's halls) into a fan of triangles and draws every triangle's spans line by line, so a line
// that crosses two or three triangles of the fan is searched (DrawSpan walks the line's list of open gaps) two or three times.
// Here the polygon is clipped once against the same six planes, and each line gets one span: from its leftmost to its rightmost
// edge, with the same sampling (line centres, x rounded as DrawClippedTriangle does). Included by BspClipper.cpp only.

#ifdef __vita__
#include <algorithm>
#include <cfloat>

bool BspClipper::VitaCheckPolygon(const vec3* vertices, uint32_t count, bool solid)
{
	struct ClipVertex
	{
		vec4 position;
		float clipDistance;
	};
	enum { MaxVertices = 48 };
	ClipVertex bufferA[MaxVertices], bufferB[MaxVertices];

	int n = (int)count;
	if (VitaStrip)
	{
		// A strip's clipper (parallel_vis): wholly on the outer side of one edge of its wedge, it is not in its columns
		bool outLeft = true, outRight = true;
		for (int i = 0; i < n && (outLeft || outRight); i++)
		{
			const vec4 p(vertices[i], 1.0f);
			outLeft = outLeft && dot(VitaStripLeft, p) < 0.0f;
			outRight = outRight && dot(VitaStripRight, p) < 0.0f;
		}
		if (outLeft || outRight)
		{
			numTris += n - 2;
			return false;
		}
	}
	for (int i = 0; i < n; i++)
	{
		bufferA[i].position = WorldToProjection * vec4(vertices[i], 1.0f);
		bufferA[i].clipDistance = dot(PortalPlane, vec4(vertices[i], 1.0f));
	}
	numTris += n - 2;   // as many as the fan would have had, so the log stays comparable

	// The six half spaces of ClipEdge: -w <= x <= w, -w <= y <= w, z >= -w, and the portal plane
	auto distance = [](const ClipVertex& v, int plane) -> float
	{
		switch (plane)
		{
		case 0: return v.position.x + v.position.w;
		case 1: return v.position.w - v.position.x;
		case 2: return v.position.y + v.position.w;
		case 3: return v.position.w - v.position.y;
		case 4: return v.position.z + v.position.w;
		default: return v.clipDistance;
		}
	};

	ClipVertex* input = bufferA;
	ClipVertex* output = bufferB;
	for (int plane = 0; plane < 6; plane++)
	{
		bool inside = true;
		for (int i = 0; i < n; i++)
		{
			if (distance(input[i], plane) < 0.0f)
			{
				inside = false;
				break;
			}
		}
		if (inside)
			continue;

		int m = 0;
		for (int i = 0; i < n && m + 2 <= MaxVertices; i++)
		{
			const ClipVertex& a = input[i];
			const ClipVertex& b = input[(i + 1) % n];
			const float da = distance(a, plane);
			const float db = distance(b, plane);
			if (da >= 0.0f)
				output[m++] = a;
			if ((da >= 0.0f) != (db >= 0.0f))
			{
				const float t = da / (da - db);
				ClipVertex& v = output[m++];
				v.position = a.position + (b.position - a.position) * t;
				v.clipDistance = a.clipDistance + (b.clipDistance - a.clipDistance) * t;
			}
		}
		std::swap(input, output);
		n = m;
		if (n < 3)
			return false;
	}

	// To the clipper's screen
	const float halfWidth = ViewportWidth * 0.5f;
	const float halfHeight = ViewportHeight * 0.5f;
	float sx[MaxVertices], sy[MaxVertices];
	float minY = FLT_MAX, maxY = -FLT_MAX;
	float minX = FLT_MAX, maxX = -FLT_MAX;
	for (int i = 0; i < n; i++)
	{
		const vec4& p = input[i].position;
		const float rw = 1.0f / p.w;
		sx[i] = halfWidth * (1.0f + p.x * rw);
		sy[i] = halfHeight * (1.0f - p.y * rw);
		minY = std::min(minY, sy[i]);
		maxY = std::max(maxY, sy[i]);
		minX = std::min(minX, sx[i]);
		maxX = std::max(maxX, sx[i]);
	}
	// A strip's clipper (parallel_vis): a polygon wholly in its filled columns closes nothing and shows nothing there. Its spans run
	// from (int)(leftmost + 0.5) to (int)(rightmost + 0.5) at most.
	if ((int)(maxX + 0.5f) <= VitaKeepX0 || (int)(minX + 0.5f) >= VitaKeepX1)
		return false;

	const int top = std::max((int)(minY + 0.5f), 0);
	const int bottom = std::min((int)(maxY + 0.5f), ViewportHeight);
	if (top >= bottom)
		return false;

	if ((int)VitaLineMin.size() < ViewportHeight)
	{
		VitaLineMin.resize(ViewportHeight);
		VitaLineMax.resize(ViewportHeight);
	}
	float* lineMin = VitaLineMin.data();
	float* lineMax = VitaLineMax.data();
	for (int y = top; y < bottom; y++)
	{
		lineMin[y] = FLT_MAX;
		lineMax[y] = -FLT_MAX;
	}

	// Every edge marks the lines whose centre it crosses
	for (int i = 0; i < n; i++)
	{
		float x0 = sx[i], y0 = sy[i];
		float x1 = sx[(i + 1) % n], y1 = sy[(i + 1) % n];
		if (y0 == y1)
			continue;
		if (y1 < y0)
		{
			std::swap(x0, x1);
			std::swap(y0, y1);
		}
		const int ys = std::max((int)(y0 + 0.5f), top);
		const int ye = std::min((int)(y1 + 0.5f), bottom);
		if (ys >= ye)
			continue;
		const float step = (x1 - x0) / (y1 - y0);
		float x = x0 + step * (ys + 0.5f - y0) + 0.5f;
		for (int y = ys; y < ye; y++)
		{
			lineMin[y] = std::min(lineMin[y], x);
			lineMax[y] = std::max(lineMax[y], x);
			x += step;
		}
	}

	const int16_t clipRight = (int16_t)ViewportWidth;
	const int16_t keepLeft = (int16_t)std::min(VitaKeepX0, ViewportWidth);    // a strip's open columns (else 0..width)
	const int16_t keepRight = (int16_t)std::min(VitaKeepX1, ViewportWidth);
	bool result = false;
	for (int y = top; y < bottom; y++)
	{
		if (lineMin[y] > lineMax[y])
			continue;
		const int16_t x0 = std::clamp((int16_t)lineMin[y], keepLeft, clipRight);
		const int16_t x1 = std::clamp((int16_t)lineMax[y], (int16_t)0, keepRight);
		if (x0 < x1)
			result |= DrawSpan((int16_t)y, x0, x1, solid);
	}
	return result;
}
// vis_threads (vita/VitaParallelVis.inc): a clipper for the columns x0..x1 of the screen only, the rest filled. Called after Setup
void BspClipper::VitaKeepColumns(int x0, int x1)
{
	for (int y = 0; y < ViewportHeight; y++)
	{
		DrawSpan((int16_t)y, 0, (int16_t)x0, true);
		DrawSpan((int16_t)y, (int16_t)x1, (int16_t)ViewportWidth, true);
	}
	VitaKeepX0 = x0;
	VitaKeepX1 = x1;

	// The wedge of the columns, two pixels wider each side: screen x = W/2 (1 + X/W') is in [x0 - 2, x1 + 2] when
	// X - a W' >= 0 and b W' - X >= 0 (X, W' the projected x and w). Both are linear in the world point: their coefficients are
	// the projections of the unit vectors and the origin.
	const float a = 2.0f * (x0 - 2) / ViewportWidth - 1.0f;
	const float b = 2.0f * (x1 + 2) / ViewportWidth - 1.0f;
	const vec4 o = WorldToProjection * vec4(0.0f, 0.0f, 0.0f, 1.0f);
	const vec4 ex = WorldToProjection * vec4(1.0f, 0.0f, 0.0f, 0.0f);
	const vec4 ey = WorldToProjection * vec4(0.0f, 1.0f, 0.0f, 0.0f);
	const vec4 ez = WorldToProjection * vec4(0.0f, 0.0f, 1.0f, 0.0f);
	VitaStripLeft = vec4(ex.x - a * ex.w, ey.x - a * ey.w, ez.x - a * ez.w, o.x - a * o.w);
	VitaStripRight = vec4(b * ex.w - ex.x, b * ey.w - ey.x, b * ez.w - ez.x, b * o.w - o.x);
	VitaStrip = x0 > 0 || x1 < ViewportWidth;
}

// The box's corner farthest along each plane's normal is below it: the whole box is outside the strip's wedge
bool BspClipper::VitaOutsideStrip(const BBox& box) const
{
	for (const vec4* plane : { &VitaStripLeft, &VitaStripRight })
	{
		const vec4& p = *plane;
		const float d = p.x * (p.x >= 0.0f ? box.max.x : box.min.x) + p.y * (p.y >= 0.0f ? box.max.y : box.min.y) +
			p.z * (p.z >= 0.0f ? box.max.z : box.min.z) + p.w;
		if (d < 0.0f)
			return true;
	}
	return false;
}
#endif
