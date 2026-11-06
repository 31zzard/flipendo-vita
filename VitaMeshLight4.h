#pragma once

// KW::MeshLighting::Light for four vertices at once (NEON on the Vita). The probes showed the light of a mesh's vertices at
// ~330 us a mesh (5-6 ms a frame in big halls): a square root and one or two divisions per light per vertex, one vertex at a time.
// Each vertex still adds its lights in the same order (a bDarkLight's clamp depends on it); only the square root and the
// reciprocals are the NEON estimates refined by two Newton steps (relative error ~1e-6). Elsewhere (the PC test) the same code
// runs on plain arrays with exact maths. Included by KWSkeletal.cpp (and vita/tests/meshlighttest.cpp).

#include "KWMeshLight.h"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define VITA_LIGHT4_NEON 1
#endif

namespace KW
{
	namespace VitaLight4
	{
#ifdef VITA_LIGHT4_NEON
		typedef float32x4_t F4;
		typedef uint32x4_t M4;
		inline F4 Set(float v) { return vdupq_n_f32(v); }
		inline F4 Add(F4 a, F4 b) { return vaddq_f32(a, b); }
		inline F4 Sub(F4 a, F4 b) { return vsubq_f32(a, b); }
		inline F4 Mul(F4 a, F4 b) { return vmulq_f32(a, b); }
		inline F4 Min(F4 a, F4 b) { return vminq_f32(a, b); }
		inline F4 Max(F4 a, F4 b) { return vmaxq_f32(a, b); }
		inline M4 Greater(F4 a, F4 b) { return vcgtq_f32(a, b); }
		inline M4 And(M4 a, M4 b) { return vandq_u32(a, b); }
		inline F4 Select(M4 m, F4 a, F4 b) { return vbslq_f32(m, a, b); }
		inline F4 Rsqrt(F4 x)
		{
			F4 e = vrsqrteq_f32(x);
			e = vmulq_f32(e, vrsqrtsq_f32(vmulq_f32(x, e), e));
			e = vmulq_f32(e, vrsqrtsq_f32(vmulq_f32(x, e), e));
			return e;
		}
		inline F4 Recip(F4 x)
		{
			F4 e = vrecpeq_f32(x);
			e = vmulq_f32(e, vrecpsq_f32(x, e));
			e = vmulq_f32(e, vrecpsq_f32(x, e));
			return e;
		}
		// MeshLighting::Light's last step: a channel whose bits are at or above 1.0f's as an unsigned number (also any negative) is 1
		inline F4 ClampChannel(F4 v) { return vbslq_f32(vcgeq_u32(vreinterpretq_u32_f32(v), vdupq_n_u32(0x3F800000u)), vdupq_n_f32(1.0f), v); }
		struct V3 { F4 x, y, z; };
		inline V3 Load(const vec3* p) { float32x4x3_t v = vld3q_f32(&p->x); return { v.val[0], v.val[1], v.val[2] }; }
		inline void Store(vec3* p, const V3& v) { float32x4x3_t o; o.val[0] = v.x; o.val[1] = v.y; o.val[2] = v.z; vst3q_f32(&p->x, o); }
#else
		struct F4 { float v[4]; };
		struct M4 { bool v[4]; };
		inline F4 Set(float x) { return { { x, x, x, x } }; }
		template<typename Op> inline F4 Each(F4 a, F4 b, Op op) { F4 r; for (int i = 0; i < 4; i++) r.v[i] = op(a.v[i], b.v[i]); return r; }
		inline F4 Add(F4 a, F4 b) { return Each(a, b, [](float x, float y) { return x + y; }); }
		inline F4 Sub(F4 a, F4 b) { return Each(a, b, [](float x, float y) { return x - y; }); }
		inline F4 Mul(F4 a, F4 b) { return Each(a, b, [](float x, float y) { return x * y; }); }
		inline F4 Min(F4 a, F4 b) { return Each(a, b, [](float x, float y) { return std::min(x, y); }); }
		inline F4 Max(F4 a, F4 b) { return Each(a, b, [](float x, float y) { return std::max(x, y); }); }
		inline M4 Greater(F4 a, F4 b) { M4 r; for (int i = 0; i < 4; i++) r.v[i] = a.v[i] > b.v[i]; return r; }
		inline M4 And(M4 a, M4 b) { M4 r; for (int i = 0; i < 4; i++) r.v[i] = a.v[i] && b.v[i]; return r; }
		inline F4 Select(M4 m, F4 a, F4 b) { F4 r; for (int i = 0; i < 4; i++) r.v[i] = m.v[i] ? a.v[i] : b.v[i]; return r; }
		inline F4 Rsqrt(F4 x) { F4 r; for (int i = 0; i < 4; i++) r.v[i] = 1.0f / std::sqrt(x.v[i]); return r; }
		inline F4 Recip(F4 x) { F4 r; for (int i = 0; i < 4; i++) r.v[i] = 1.0f / x.v[i]; return r; }
		inline F4 ClampChannel(F4 x) { F4 r; for (int i = 0; i < 4; i++) { uint32_t b; std::memcpy(&b, &x.v[i], 4); r.v[i] = b >= 0x3F800000u ? 1.0f : x.v[i]; } return r; }
		struct V3 { F4 x, y, z; };
		inline V3 Load(const vec3* p) { V3 r; for (int i = 0; i < 4; i++) { r.x.v[i] = p[i].x; r.y.v[i] = p[i].y; r.z.v[i] = p[i].z; } return r; }
		inline void Store(vec3* p, const V3& v) { for (int i = 0; i < 4; i++) p[i] = vec3(v.x.v[i], v.y.v[i], v.z.v[i]); }
#endif
		inline F4 Dot(const V3& a, const V3& b) { return Add(Add(Mul(a.x, b.x), Mul(a.y, b.y)), Mul(a.z, b.z)); }
		inline V3 Scale(const V3& a, F4 s) { return { Mul(a.x, s), Mul(a.y, s), Mul(a.z, s) }; }
		inline V3 Splat(const vec3& v) { return { Set(v.x), Set(v.y), Set(v.z) }; }
	}

	// out[i] = m.Light(locations[i], normals[i])
	inline void VitaLightVertices(const MeshLighting& m, const vec3* locations, const vec3* normals, vec3* out, size_t count)
	{
		using namespace VitaLight4;
		enum { LD_Point, LD_Plane, LD_Ambient };   // KWMeshLight.cpp's ELightSource values
		const F4 zero = Set(0.0f), one = Set(1.0f), tiny = Set(1e-30f);
		const F4 diffuse = Set(m.Diffuse);
		size_t i = 0;
		for (; i + 4 <= count; i += 4)
		{
			const V3 p = Load(locations + i);
			const V3 n = Load(normals + i);
			const V3 view = { Sub(p.x, Set(m.ViewLocation.x)), Sub(p.y, Set(m.ViewLocation.y)), Sub(p.z, Set(m.ViewLocation.z)) };
			const F4 viewSqr = Dot(view, view);
			V3 result = Splat(m.Ambient);
			for (int l = 0; l < m.NumLights; l++)
			{
				const MeshLightInfo& light = m.Lights[l];
				V3 L = { Sub(Set(light.Location.x), p.x), Sub(Set(light.Location.y), p.y), Sub(Set(light.Location.z), p.z) };
				const F4 distSqr = Dot(L, L);
				const F4 invDist = Rsqrt(Max(distSqr, tiny));
				const F4 dist = Mul(distSqr, invDist);   // 0 when the vertex is at the light

				F4 cosine;
				if (light.Source == LD_Ambient)
				{
					cosine = one;
					L = Scale(n, dist);
				}
				else if (light.Source == LD_Plane)
				{
					const V3 dir = Splat(light.Direction);
					cosine = Dot(n, dir);
					L = Scale(dir, dist);
				}
				else
				{
					cosine = Mul(Dot(L, n), invDist);   // L is 0 when dist is 0: the original's 0
				}
				if (m.ScaleGlowCurve)
				{
					const F4 c1 = Add(cosine, one);
					cosine = Sub(Mul(c1, c1), Set(1.5f));
				}

				F4 amount = Max(Mul(diffuse, cosine), zero);
				if (m.Specular > 0.0f)
				{
					const F4 ln2 = Mul(Set(2.0f), Dot(L, n));
					const V3 reflected = { Sub(L.x, Mul(n.x, ln2)), Sub(L.y, Mul(n.y, ln2)), Sub(L.z, Mul(n.z, ln2)) };
					const F4 rv = Dot(reflected, view);
					const F4 denominator = Mul(distSqr, viewSqr);
					const F4 highlight = Sub(Mul(rv, Mul(rv, Recip(Max(denominator, tiny)))), Set(m.SpecularCutoff));
					const M4 use = And(And(Greater(rv, zero), Greater(denominator, zero)), Greater(highlight, zero));
					amount = Select(use, Add(amount, Mul(Set(m.Specular), highlight)), amount);
				}

				const M4 lit = Greater(amount, zero);
				const F4 falloff = Min(Mul(Sub(Set(light.Radius), dist), Set(light.InvFalloff)), one);
				const F4 k = Mul(falloff, amount);
				V3 added = { Add(result.x, Mul(Set(light.Color.x), k)), Add(result.y, Mul(Set(light.Color.y), k)), Add(result.z, Mul(Set(light.Color.z), k)) };
				if (light.Dark)
					added = { Max(added.x, zero), Max(added.y, zero), Max(added.z, zero) };
				result = { Select(lit, added.x, result.x), Select(lit, added.y, result.y), Select(lit, added.z, result.z) };
			}
			result = { ClampChannel(result.x), ClampChannel(result.y), ClampChannel(result.z) };
			Store(out + i, result);
		}
		for (; i < count; i++)
			out[i] = m.Light(locations[i], normals[i]);
	}
}
