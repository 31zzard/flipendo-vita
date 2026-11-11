#pragma once

// The water simulation of UWaterTexture::UpdateWater and the refraction of UWetTexture::UpdateFrame on the Vita (apply_fixes.sh
// #87). Log of 06 Nov 06:51 (Lev2_Fire1): one new picture of WetWater (256x256) cost 19-32 ms on the engine thread, scalar VFP.
// The same arithmetic, four pixels at a time with NEON: a WaterPixel is four floats (Pressure, Velocity, XGradient, YGradient),
// so vld4q gives four pixels as four vectors. The order of the operations is the engine's, so the numbers are the same (NEON
// flushes denormals to zero, which the engine thread does anyway: flush_to_zero). The first and last column wrap around: scalar.
// Compared with the engine's own loops on the Vita: the log line 'water check' (VitaWaterCheck in apply_fixes.sh #87) once per texture.

#include <cstdint>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <unordered_map>
#include <vector>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define VITA_WATER_NEON 1
#endif

namespace VitaWater
{
	struct Pixel { float Pressure, Velocity, XGradient, YGradient; };

	inline void StepScalar(const Pixel* srcline, const Pixel* up, const Pixel* down, Pixel* dest, int x, int xleft, int xright)
	{
		float velocity = srcline[x].Velocity;
		float pressure = srcline[x].Pressure;
		const float pressureLeft = srcline[xleft].Pressure;
		const float pressureRight = srcline[xright].Pressure;
		const float pressureUp = up[x].Pressure;
		const float pressureDown = down[x].Pressure;
		velocity += (-2.0f * pressure + pressureRight + pressureLeft) * 0.25f;
		velocity += (-2.0f * pressure + pressureUp + pressureDown) * 0.25f;
		pressure += velocity;
		velocity -= 0.005f * pressure;
		velocity *= 1.0f - 0.002f;
		pressure *= 0.999f;
		dest[x].Pressure = pressure;
		dest[x].Velocity = velocity;
		dest[x].XGradient = (pressureRight - pressureLeft) * 0.5f;
		dest[x].YGradient = (pressureDown - pressureUp) * 0.5f;
	}

	// One step of the whole picture: cur -> next (both width * height)
	inline void Step(const Pixel* cur, Pixel* next, int width, int height)
	{
		for (int y = 0; y < height; y++)
		{
			const Pixel* srcline = cur + (size_t)y * width;
			const Pixel* up = cur + (size_t)(y - 1 >= 0 ? y - 1 : height - 1) * width;
			const Pixel* down = cur + (size_t)(y + 1 < height ? y + 1 : 0) * width;
			Pixel* dest = next + (size_t)y * width;
			if (width < 3)
			{
				for (int x = 0; x < width; x++)
					StepScalar(srcline, up, down, dest, x, x - 1 >= 0 ? x - 1 : width - 1, x + 1 < width ? x + 1 : 0);
				continue;
			}
			StepScalar(srcline, up, down, dest, 0, width - 1, 1);
			int x = 1;
#ifdef VITA_WATER_NEON
			const float32x4_t quarter = vdupq_n_f32(0.25f), half = vdupq_n_f32(0.5f), minusTwo = vdupq_n_f32(-2.0f);
			const float32x4_t spring = vdupq_n_f32(0.005f), damp = vdupq_n_f32(1.0f - 0.002f), pdamp = vdupq_n_f32(0.999f);
			for (; x + 4 <= width - 1; x += 4)
			{
				const float32x4x4_t c = vld4q_f32((const float*)(srcline + x));
				const float32x4_t pl = vld4q_f32((const float*)(srcline + x - 1)).val[0];
				const float32x4_t pr = vld4q_f32((const float*)(srcline + x + 1)).val[0];
				const float32x4_t pu = vld4q_f32((const float*)(up + x)).val[0];
				const float32x4_t pd = vld4q_f32((const float*)(down + x)).val[0];
				float32x4_t pressure = c.val[0];
				float32x4_t velocity = c.val[1];
				const float32x4_t twoP = vmulq_f32(minusTwo, pressure);
				velocity = vaddq_f32(velocity, vmulq_f32(vaddq_f32(vaddq_f32(twoP, pr), pl), quarter));
				velocity = vaddq_f32(velocity, vmulq_f32(vaddq_f32(vaddq_f32(twoP, pu), pd), quarter));
				pressure = vaddq_f32(pressure, velocity);
				velocity = vsubq_f32(velocity, vmulq_f32(spring, pressure));
				velocity = vmulq_f32(velocity, damp);
				pressure = vmulq_f32(pressure, pdamp);
				float32x4x4_t out;
				out.val[0] = pressure;
				out.val[1] = velocity;
				out.val[2] = vmulq_f32(vsubq_f32(pr, pl), half);
				out.val[3] = vmulq_f32(vsubq_f32(pd, pu), half);
				vst4q_f32((float*)(dest + x), out);
			}
#endif
			for (; x < width - 1; x++)
				StepScalar(srcline, up, down, dest, x, x - 1, x + 1);
			StepScalar(srcline, up, down, dest, width - 1, width - 2, 0);
		}
	}

	// The same step without NEON (the engine's loop as it is), for the check
	inline void StepAllScalar(const Pixel* cur, Pixel* next, int width, int height)
	{
		for (int y = 0; y < height; y++)
		{
			const Pixel* srcline = cur + (size_t)y * width;
			const Pixel* up = cur + (size_t)(y - 1 >= 0 ? y - 1 : height - 1) * width;
			const Pixel* down = cur + (size_t)(y + 1 < height ? y + 1 : 0) * width;
			for (int x = 0; x < width; x++)
				StepScalar(srcline, up, down, next + (size_t)y * width, x, x - 1 >= 0 ? x - 1 : width - 1, x + 1 < width ? x + 1 : 0);
		}
	}

	// UWetTexture: each pixel takes the source pixel displaced along x by the water's x gradient
	inline void Refract(const Pixel* water, const uint8_t* src, uint8_t* dst, int width, int height)
	{
		const float fwidth = (float)width;
		for (int y = 0; y < height; y++)
		{
			const Pixel* waterline = water + (size_t)y * width;
			const uint8_t* srcline = src + (size_t)y * width;
			uint8_t* destline = dst + (size_t)y * width;
			int x = 0;
#ifdef VITA_WATER_NEON
			const float32x4_t vhalf = vdupq_n_f32(0.5f), vwidth = vdupq_n_f32(fwidth);
			const int32x4_t zero = vdupq_n_s32(0), last = vdupq_n_s32(width - 1);
			int32x4_t xs = { 0, 1, 2, 3 };
			const int32x4_t four = vdupq_n_s32(4);
			for (; x + 4 <= width; x += 4)
			{
				const float32x4_t g = vld4q_f32((const float*)(waterline + x)).val[2];
				const int32x4_t water = vcvtq_s32_f32(vmulq_f32(vmulq_f32(vhalf, g), vwidth));   // (int)(0.5f * g * width): truncated
				int32x4_t sx = vaddq_s32(xs, water);
				sx = vminq_s32(vmaxq_s32(sx, zero), last);
				int32_t idx[4];
				vst1q_s32(idx, sx);
				destline[x + 0] = srcline[idx[0]];
				destline[x + 1] = srcline[idx[1]];
				destline[x + 2] = srcline[idx[2]];
				destline[x + 3] = srcline[idx[3]];
				xs = vaddq_s32(xs, four);
			}
#endif
			for (; x < width; x++)
			{
				const int water = (int)(0.5f * waterline[x].XGradient * fwidth);
				destline[x] = srcline[std::clamp(x + water, 0, width - 1)];
			}
		}
	}

	// ---- #88: the planar state. Log of 06 Nov 07:19: NEON on the four-float pixels changed nothing (WetWater still ~22 ms a
	// picture): the step is bound by memory (two 1 MB arrays of 16 byte pixels, gradients written and read back). Here a water
	// texture keeps only Pressure (two pictures) and Velocity (one, updated in place: each pixel reads only its own) as plain float
	// arrays; the gradients the picture needs are worked out from the old pressure when it is drawn. Same arithmetic, same order.
	struct State
	{
		std::vector<float> P[2];
		std::vector<float> V;
		int cur = 0;
		int width = 0, height = 0;
	};
	inline std::unordered_map<const void*, State> states;   // by texture (engine thread only)

	// The texture the water thread works on now (VitaWaterJobs.h), its state and the picture it writes into: StateFor and the
	// UpdateFrame patches look here first. Set only by the water thread; nullptr when it is idle.
	inline std::atomic<const void*> jobTexture{ nullptr };
	inline State* jobState = nullptr;
	inline uint8_t* jobPixels = nullptr;
	inline bool OnJob(const void* texture) { return texture && jobTexture.load(std::memory_order_acquire) == texture; }
	inline uint8_t* Output(const void* texture, uint8_t* pixels) { return OnJob(texture) ? jobPixels : pixels; }

	inline State& StateFor(const void* texture, int width, int height)
	{
		if (OnJob(texture))
			return *jobState;
		State& s = states[texture];
		if (s.width != width || s.height != height)
		{
			const size_t n = (size_t)width * height;
			s.P[0].assign(n, 0.0f);
			s.P[1].assign(n, 0.0f);
			s.V.assign(n, 0.0f);
			s.cur = 0;
			s.width = width;
			s.height = height;
		}
		return s;
	}

	inline void StepPixel(const float* row, const float* up, const float* down, float* out, float* vel, int x, int xl, int xr)
	{
		float velocity = vel[x];
		float pressure = row[x];
		const float pressureLeft = row[xl], pressureRight = row[xr], pressureUp = up[x], pressureDown = down[x];
		velocity += (-2.0f * pressure + pressureRight + pressureLeft) * 0.25f;
		velocity += (-2.0f * pressure + pressureUp + pressureDown) * 0.25f;
		pressure += velocity;
		velocity -= 0.005f * pressure;
		velocity *= 1.0f - 0.002f;
		pressure *= 0.999f;
		out[x] = pressure;
		vel[x] = velocity;
	}

	// P[cur] -> P[cur ^ 1], V in place; cur flips. P[cur ^ 1] is then the old pressure the gradients come from.
	inline void StepPlanar(State& s)
	{
		const int width = s.width, height = s.height;
		const float* src = s.P[s.cur].data();
		float* dst = s.P[s.cur ^ 1].data();
		float* V = s.V.data();
		for (int y = 0; y < height; y++)
		{
			const float* row = src + (size_t)y * width;
			const float* up = src + (size_t)(y - 1 >= 0 ? y - 1 : height - 1) * width;
			const float* down = src + (size_t)(y + 1 < height ? y + 1 : 0) * width;
			float* out = dst + (size_t)y * width;
			float* vel = V + (size_t)y * width;
			if (width < 3)
			{
				for (int x = 0; x < width; x++)
					StepPixel(row, up, down, out, vel, x, x - 1 >= 0 ? x - 1 : width - 1, x + 1 < width ? x + 1 : 0);
				continue;
			}
			StepPixel(row, up, down, out, vel, 0, width - 1, 1);
			int x = 1;
#ifdef VITA_WATER_NEON
			const float32x4_t quarter = vdupq_n_f32(0.25f), minusTwo = vdupq_n_f32(-2.0f);
			const float32x4_t spring = vdupq_n_f32(0.005f), damp = vdupq_n_f32(1.0f - 0.002f), pdamp = vdupq_n_f32(0.999f);
			for (; x + 4 <= width - 1; x += 4)
			{
				float32x4_t pressure = vld1q_f32(row + x);
				const float32x4_t pl = vld1q_f32(row + x - 1), pr = vld1q_f32(row + x + 1);
				const float32x4_t pu = vld1q_f32(up + x), pd = vld1q_f32(down + x);
				float32x4_t velocity = vld1q_f32(vel + x);
				const float32x4_t twoP = vmulq_f32(minusTwo, pressure);
				velocity = vaddq_f32(velocity, vmulq_f32(vaddq_f32(vaddq_f32(twoP, pr), pl), quarter));
				velocity = vaddq_f32(velocity, vmulq_f32(vaddq_f32(vaddq_f32(twoP, pu), pd), quarter));
				pressure = vaddq_f32(pressure, velocity);
				velocity = vsubq_f32(velocity, vmulq_f32(spring, pressure));
				velocity = vmulq_f32(velocity, damp);
				pressure = vmulq_f32(pressure, pdamp);
				vst1q_f32(out + x, pressure);
				vst1q_f32(vel + x, velocity);
			}
#endif
			for (; x < width - 1; x++)
				StepPixel(row, up, down, out, vel, x, x - 1, x + 1);
			StepPixel(row, up, down, out, vel, width - 1, width - 2, 0);
		}
		s.cur ^= 1;
	}

	// UWetTexture: XGradient = (right - left) * 0.5 of the old pressure; the source pixel displaced by (int)(0.5 * XGradient * width)
	inline void RefractPlanar(const State& s, const uint8_t* src, uint8_t* dst)
	{
		const int width = s.width, height = s.height;
		const float* old = s.P[s.cur ^ 1].data();
		const float fwidth = (float)width;
		for (int y = 0; y < height; y++)
		{
			const float* row = old + (size_t)y * width;
			const uint8_t* srcline = src + (size_t)y * width;
			uint8_t* destline = dst + (size_t)y * width;
			auto one = [&](int x)
			{
				const float g = (row[x + 1 < width ? x + 1 : 0] - row[x - 1 >= 0 ? x - 1 : width - 1]) * 0.5f;
				const int water = (int)(0.5f * g * fwidth);
				destline[x] = srcline[std::clamp(x + water, 0, width - 1)];
			};
			if (width < 3)
			{
				for (int x = 0; x < width; x++)
					one(x);
				continue;
			}
			one(0);
			int x = 1;
#ifdef VITA_WATER_NEON
			const float32x4_t vhalf = vdupq_n_f32(0.5f), vwidth = vdupq_n_f32(fwidth);
			const int32x4_t zero = vdupq_n_s32(0), last = vdupq_n_s32(width - 1), four = vdupq_n_s32(4);
			int32x4_t xs = { 1, 2, 3, 4 };
			for (; x + 4 <= width - 1; x += 4)
			{
				const float32x4_t g = vmulq_f32(vsubq_f32(vld1q_f32(row + x + 1), vld1q_f32(row + x - 1)), vhalf);
				const int32x4_t water = vcvtq_s32_f32(vmulq_f32(vmulq_f32(vhalf, g), vwidth));
				int32x4_t sx = vminq_s32(vmaxq_s32(vaddq_s32(xs, water), zero), last);
				int32_t idx[4];
				vst1q_s32(idx, sx);
				destline[x + 0] = srcline[idx[0]];
				destline[x + 1] = srcline[idx[1]];
				destline[x + 2] = srcline[idx[2]];
				destline[x + 3] = srcline[idx[3]];
				xs = vaddq_s32(xs, four);
			}
#endif
			for (; x < width; x++)
				one(x);
		}
	}

	// UWaterTexture's picture: normalize(-gx, 0.2, -gy).y * 255 + 128, gradients of the old pressure
	inline void ShadePlanar(const State& s, uint8_t* dst)
	{
		const int width = s.width, height = s.height;
		const float* old = s.P[s.cur ^ 1].data();
		for (int y = 0; y < height; y++)
		{
			const float* row = old + (size_t)y * width;
			const float* up = old + (size_t)(y - 1 >= 0 ? y - 1 : height - 1) * width;
			const float* down = old + (size_t)(y + 1 < height ? y + 1 : 0) * width;
			uint8_t* destline = dst + (size_t)y * width;
			auto one = [&](int x)
			{
				const float gx = (row[x + 1 < width ? x + 1 : 0] - row[x - 1 >= 0 ? x - 1 : width - 1]) * 0.5f;
				const float gy = (down[x] - up[x]) * 0.5f;
				const float ny = 0.2f / std::sqrt(gx * gx + 0.04f + gy * gy);
				destline[x] = (uint8_t)std::clamp(ny * 255.0f + 128.0f, 0.0f, 255.0f);
			};
			int x = 0;
#ifdef VITA_WATER_NEON
			// 8 pixels at a time; 1/sqrt by vrsqrte + two Newton steps (relative error ~1e-6: the byte differs from the scalar
			// one only when ny * 255 + 128 lands within that of a whole number). #123: the scalar sqrt + divide was ~half of
			// WaterDE2's 19 ms a picture.
			if (width >= 10)
			{
				one(0);
				x = 1;
				const float32x4_t vhalf = vdupq_n_f32(0.5f), c004 = vdupq_n_f32(0.04f), c02 = vdupq_n_f32(0.2f);
				const float32x4_t c255 = vdupq_n_f32(255.0f), c128 = vdupq_n_f32(128.0f), zero = vdupq_n_f32(0.0f);
				for (; x + 8 <= width - 1; x += 8)
				{
					uint16x4_t half16[2];
					for (int k = 0; k < 2; k++)
					{
						const int xx = x + k * 4;
						const float32x4_t gx = vmulq_f32(vsubq_f32(vld1q_f32(row + xx + 1), vld1q_f32(row + xx - 1)), vhalf);
						const float32x4_t gy = vmulq_f32(vsubq_f32(vld1q_f32(down + xx), vld1q_f32(up + xx)), vhalf);
						const float32x4_t d = vaddq_f32(vaddq_f32(vmulq_f32(gx, gx), c004), vmulq_f32(gy, gy));
						float32x4_t r = vrsqrteq_f32(d);
						r = vmulq_f32(r, vrsqrtsq_f32(vmulq_f32(d, r), r));
						r = vmulq_f32(r, vrsqrtsq_f32(vmulq_f32(d, r), r));
						float32x4_t v = vaddq_f32(vmulq_f32(vmulq_f32(c02, r), c255), c128);
						v = vminq_f32(vmaxq_f32(v, zero), c255);
						half16[k] = vmovn_u32(vcvtq_u32_f32(v));
					}
					vst1_u8(destline + x, vmovn_u16(vcombine_u16(half16[0], half16[1])));
				}
			}
#endif
			for (; x < width; x++)
				one(x);
		}
	}

	// The check: the same step through the engine's own four-float loop; the largest difference of pressure and velocity
	inline float CheckPlanar(const State& before, const State& after)
	{
		const size_t n = (size_t)before.width * before.height;
		std::vector<Pixel> a(n), b(n);
		for (size_t i = 0; i < n; i++)
		{
			a[i].Pressure = before.P[before.cur][i];
			a[i].Velocity = before.V[i];
		}
		StepAllScalar(a.data(), b.data(), before.width, before.height);
		float d = 0.0f;
		for (size_t i = 0; i < n; i++)
			d = std::max({ d, std::abs(b[i].Pressure - after.P[after.cur][i]), std::abs(b[i].Velocity - after.V[i]) });
		return d;
	}
}
