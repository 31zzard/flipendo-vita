// mat4 * vec4 with NEON, bit for bit what mat4::operator*(const vec4&) (Math/mat.cpp, the NOSSE branch) gives on the Vita
// (apply_fixes.sh #213): each lane ((m0 x + m1 y) + m2 z) + m3 w over the columns, every product rounded before its add (the
// A9 has no fused multiply-add: VMLA.F32 rounds the product), denormals flushed as the VFP does with flush_to_zero=1 (the default;
// render.cfg flush_to_zero=0 turns this off). Inline: the operator was an out-of-line call for every corner and vertex the clipper
// projects. render.cfg neon_check=1: every result compared with the operator's (log 'VitaMatNeon: N compared, M differ').
#pragma once
#include "Math/mat.h"
#include "VitaConfig.h"
#include "Utils/Logger.h"
#include <arm_neon.h>
#include <cstring>
#include <string>

inline bool VitaMatNeonOn()
{
	static int on = -1;
	if (on < 0)
		on = VitaConfigInt("flush_to_zero", 1) != 0 && VitaConfigInt("mat_neon", 0) != 0 ? 1 : 0;   // off by default: no faster (#213)
	return on == 1;
}

inline vec4 VitaMulPoint(const mat4& m, float x, float y, float z)
{
	if (!VitaMatNeonOn())
		return m * vec4(x, y, z, 1.0f);
	float32x4_t r = vmulq_n_f32(vld1q_f32(m.matrix), x);
	r = vmlaq_n_f32(r, vld1q_f32(m.matrix + 4), y);
	r = vmlaq_n_f32(r, vld1q_f32(m.matrix + 8), z);
	r = vmlaq_n_f32(r, vld1q_f32(m.matrix + 12), 1.0f);
	vec4 out;
	vst1q_f32(&out.x, r);
	static int check = -1;
	if (check < 0)
		check = VitaConfigInt("neon_check", 0) != 0 ? 1 : 0;
	if (check == 1)
	{
		static unsigned compared = 0, differ = 0;
		const vec4 ref = m * vec4(x, y, z, 1.0f);
		compared++;
		const bool same = std::memcmp(&ref, &out, sizeof(vec4)) == 0;
		if (!same)
			differ++;
		if (compared % 500000 == 0 || (!same && differ <= 5))
			LogMessage("VitaMatNeon: " + std::to_string(compared) + " compared, " + std::to_string(differ) + " differ");
	}
	return out;
}
