#!/usr/bin/env python3
# Makes the Vita's bubble icon and LiveArea pictures from Flipendo's branding (images/branding), in plain Python
# (no Pillow on this machine). The Vita wants 8 bit palette PNGs:
#   sce_sys/icon0.png                         128 x 128   the bubble on the home screen
#   sce_sys/livearea/contents/bg.png          840 x 500   the LiveArea background
#   sce_sys/livearea/contents/startup.png     280 x 158   the "start" gate
# Usage: python3 -I make_livearea.py <repo root> <output folder (vita/sce_sys)> [--hp2]
#   --hp2: Chamber of Secrets (~/flipendo2/sce_sys): a green sky and a gold "II"
#   --from <folder>: the three pictures made elsewhere as full colour PNGs of those sizes (icon0.png, bg.png, startup.png;
#   make_livearea_cover.ps1 makes them from the game's cover and icon): only turned into palette PNGs

import os
import struct
import sys
import zlib
import math
import random


def read_png(path):
	with open(path, 'rb') as f:
		data = f.read()
	assert data[:8] == b'\x89PNG\r\n\x1a\n', path
	pos = 8
	idat = b''
	while pos < len(data):
		length, kind = struct.unpack('>I4s', data[pos:pos + 8])
		body = data[pos + 8:pos + 8 + length]
		pos += 12 + length
		if kind == b'IHDR':
			w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
			assert depth == 8 and ctype in (2, 6) and interlace == 0, (path, depth, ctype, interlace)
		elif kind == b'IDAT':
			idat += body
		elif kind == b'IEND':
			break
	bpp = 4 if ctype == 6 else 3
	raw = zlib.decompress(idat)
	stride = w * bpp
	prev = bytearray(stride)
	pixels = []
	i = 0
	for y in range(h):
		ftype = raw[i]
		line = bytearray(raw[i + 1:i + 1 + stride])
		i += 1 + stride
		for x in range(stride):
			a = line[x - bpp] if x >= bpp else 0
			b = prev[x]
			c = prev[x - bpp] if x >= bpp else 0
			if ftype == 1:
				line[x] = (line[x] + a) & 255
			elif ftype == 2:
				line[x] = (line[x] + b) & 255
			elif ftype == 3:
				line[x] = (line[x] + ((a + b) >> 1)) & 255
			elif ftype == 4:
				p = a + b - c
				pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
				pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
				line[x] = (line[x] + pr) & 255
		prev = line
		for x in range(w):
			px = line[x * bpp:x * bpp + bpp]
			pixels.append((px[0], px[1], px[2], px[3] if bpp == 4 else 255))
	return w, h, pixels


def resize(img, nw, nh):
	"""Area average (the sources are larger), premultiplied alpha"""
	w, h, px = img
	out = []
	sx, sy = w / nw, h / nh
	for y in range(nh):
		y0, y1 = int(y * sy), max(int((y + 1) * sy), int(y * sy) + 1)
		for x in range(nw):
			x0, x1 = int(x * sx), max(int((x + 1) * sx), int(x * sx) + 1)
			r = g = b = a = 0
			n = 0
			for yy in range(y0, min(y1, h)):
				row = yy * w
				for xx in range(x0, min(x1, w)):
					pr, pg, pb, pa = px[row + xx]
					r += pr * pa
					g += pg * pa
					b += pb * pa
					a += pa
					n += 1
			if a:
				out.append((r / a, g / a, b / a, a / n))
			else:
				out.append((0.0, 0.0, 0.0, 0.0))
	return nw, nh, out


def canvas(w, h, fill):
	return [list(fill(x, y)) for y in range(h) for x in range(w)], w, h


def paste(dst, img, ox, oy):
	pixels, dw, dh = dst
	w, h, px = img
	for y in range(h):
		for x in range(w):
			tx, ty = ox + x, oy + y
			if not (0 <= tx < dw and 0 <= ty < dh):
				continue
			r, g, b, a = px[y * w + x]
			t = a / 255.0
			d = pixels[ty * dw + tx]
			d[0] = d[0] * (1 - t) + r * t
			d[1] = d[1] * (1 - t) + g * t
			d[2] = d[2] * (1 - t) + b * t


HP2 = False


def purple(w, h, seed):
	"""Deep purple like the icon's disc, lighter in the middle, a few blue sparkles (HP2: deep green)"""
	cx, cy = w * 0.5, h * 0.45
	maxd = math.hypot(w * 0.6, h * 0.6)
	inner, outer = ((18, 86, 52), (3, 22, 12)) if HP2 else ((52, 22, 110), (14, 6, 40))

	def fill(x, y):
		t = min(math.hypot(x - cx, y - cy) / maxd, 1.0)
		t = t * t * (3 - 2 * t)
		return tuple(inner[i] * (1 - t) + outer[i] * t for i in range(3))
	dst = canvas(w, h, fill)
	rnd = random.Random(seed)
	pixels = dst[0]
	for _ in range(int(w * h / 2500)):
		sx, sy = rnd.uniform(0, w), rnd.uniform(0, h)
		size = rnd.uniform(0.8, 2.6)
		bright = rnd.uniform(0.35, 1.0)
		for y in range(int(sy - size * 3), int(sy + size * 3) + 1):
			for x in range(int(sx - size * 3), int(sx + size * 3) + 1):
				if 0 <= x < w and 0 <= y < h:
					d = math.hypot(x - sx, y - sy) / size
					k = bright * math.exp(-d * d)
					if k > 0.01:
						p = pixels[y * w + x]
						for i, c in enumerate((120, 220, 255)):
							p[i] = p[i] * (1 - k) + c * k
	return dst


def badge(dst, ox, oy, size):
	"""A gold Roman "II" (two bars between a top and a bottom bar), outlined in dark green, size pixels high"""
	pixels, dw, dh = dst
	bar, gap, serif = size * 0.17, size * 0.2, size * 0.13
	width = bar * 2 + gap + serif * 2
	shapes = [(ox, oy, width, serif), (ox, oy + size - serif, width, serif),
	          (ox + serif, oy, bar, size), (ox + serif + bar + gap, oy, bar, size)]
	edge = max(size * 0.05, 1.0)

	def inside(x, y, grow):
		return any(sx - grow <= x < sx + sw + grow and sy - grow <= y < sy + sh + grow for sx, sy, sw, sh in shapes)
	for y in range(int(oy - edge) - 1, int(oy + size + edge) + 2):
		for x in range(int(ox - edge) - 1, int(ox + width + edge) + 2):
			if not (0 <= x < dw and 0 <= y < dh):
				continue
			p = pixels[y * dw + x]
			if inside(x + 0.5, y + 0.5, 0):
				t = (y - oy) / size
				p[0], p[1], p[2] = 250 - 40 * t, 214 - 50 * t, 120 - 60 * t
			elif inside(x + 0.5, y + 0.5, edge):
				p[0], p[1], p[2] = 10, 30, 16


def quantize_write(dst, path):
	"""Median cut to 256 colours, Floyd-Steinberg dithering, 8 bit palette PNG"""
	pixels, w, h = dst
	# median cut on 5 bit buckets (weighted by count)
	hist = {}
	for p in pixels:
		key = (int(p[0]) >> 3, int(p[1]) >> 3, int(p[2]) >> 3)
		hist[key] = hist.get(key, 0) + 1
	boxes = [list(hist.items())]
	while len(boxes) < 256:
		best, bi, axis = -1, -1, 0
		for i, box in enumerate(boxes):
			if len(box) < 2:
				continue
			for a in range(3):
				lo = min(c[0][a] for c in box)
				hi = max(c[0][a] for c in box)
				score = (hi - lo) * sum(c[1] for c in box) ** 0.5
				if score > best:
					best, bi, axis = score, i, a
		if bi < 0 or best <= 0:
			break
		box = sorted(boxes.pop(bi), key=lambda c: c[0][axis])
		total = sum(c[1] for c in box)
		acc, cut = 0, 1
		for j, c in enumerate(box):
			acc += c[1]
			if acc >= total / 2:
				cut = max(1, min(j + 1, len(box) - 1))
				break
		boxes += [box[:cut], box[cut:]]
	palette = []
	for box in boxes:
		n = sum(c[1] for c in box)
		palette.append(tuple(int(round(sum(((c[0][a] << 3) + 4) * c[1] for c in box) / n)) for a in range(3)))
	while len(palette) < 256:
		palette.append((0, 0, 0))
	cache = {}

	def nearest(r, g, b):
		key = (int(r) >> 2, int(g) >> 2, int(b) >> 2)
		idx = cache.get(key)
		if idx is None:
			idx = min(range(len(palette)), key=lambda i: (palette[i][0] - r) ** 2 + (palette[i][1] - g) ** 2 + (palette[i][2] - b) ** 2)
			cache[key] = idx
		return idx
	err = [[list(p) for p in pixels[y * w:(y + 1) * w]] for y in range(h)]
	rows = []
	for y in range(h):
		row = bytearray([0])
		for x in range(w):
			r, g, b = (min(max(v, 0.0), 255.0) for v in err[y][x])
			i = nearest(r, g, b)
			row.append(i)
			pr, pg, pb = palette[i]
			e = (r - pr, g - pg, b - pb)
			for dx, dy, f in ((1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)):
				xx, yy = x + dx, y + dy
				if 0 <= xx < w and yy < h:
					q = err[yy][xx]
					q[0] += e[0] * f
					q[1] += e[1] * f
					q[2] += e[2] * f
		rows.append(bytes(row))

	def chunk(kind, body):
		return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
	png = b'\x89PNG\r\n\x1a\n'
	png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0))
	png += chunk(b'PLTE', bytes(c for p in palette for c in p))
	png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
	png += chunk(b'IEND', b'')
	os.makedirs(os.path.dirname(path), exist_ok=True)
	with open(path, 'wb') as f:
		f.write(png)
	print(f'{path}: {w}x{h}, {len(png)} bytes')


def from_folder(src, out):
	"""Full colour PNGs made elsewhere -> the Vita's palette PNGs"""
	for name, rel in (('icon0.png', 'icon0.png'), ('bg.png', os.path.join('livearea', 'contents', 'bg.png')),
					  ('startup.png', os.path.join('livearea', 'contents', 'startup.png'))):
		w, h, px = read_png(os.path.join(src, name))
		dst = canvas(w, h, lambda x, y: (0, 0, 0))
		paste(dst, (w, h, px), 0, 0)
		quantize_write(dst, os.path.join(out, rel))


def main():
	global HP2
	root, out = sys.argv[1], sys.argv[2]
	if '--from' in sys.argv[3:]:
		from_folder(sys.argv[sys.argv.index('--from') + 1], out)
		return
	HP2 = '--hp2' in sys.argv[3:]
	branding = os.path.join(root, 'images', 'branding')
	icon = read_png(os.path.join(branding, 'flipendo-icon.png'))
	logo = read_png(os.path.join(branding, 'flipendo-logo-dark.png'))

	# The bubble: the icon over the colour of its own disc's rim (the Vita masks the bubble to a circle)
	dst = canvas(128, 128, lambda x, y: (6, 40, 22) if HP2 else (24, 10, 62))
	paste(dst, resize(icon, 128, 128), 0, 0)
	if HP2:
		badge(dst, 80, 78, 34)
	quantize_write(dst, os.path.join(out, 'icon0.png'))

	# The LiveArea: the logo on the purple sky
	dst = purple(840, 500, 7)
	lw = 700
	lh = round(logo[1] * lw / logo[0])
	paste(dst, resize(logo, lw, lh), (840 - lw) // 2, 120)
	if HP2:
		badge(dst, 380, 140 + lh, 90)
	quantize_write(dst, os.path.join(out, 'livearea', 'contents', 'bg.png'))

	# The gate: the logo alone
	dst = purple(280, 158, 3)
	lw = 256
	lh = round(logo[1] * lw / logo[0])
	paste(dst, resize(logo, lw, lh), (280 - lw) // 2, (158 - lh) // 2 - (14 if HP2 else 0))
	if HP2:
		badge(dst, 124, (158 + lh) // 2 - 10, 26)
	quantize_write(dst, os.path.join(out, 'livearea', 'contents', 'startup.png'))


if __name__ == '__main__':
	main()
