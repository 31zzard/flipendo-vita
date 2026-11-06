// PC test of vita/VitaMeshLight4.h against a copy of KW::MeshLighting::Light (src/knowwonder/KWMeshLight.cpp).
// g++ -std=gnu++20 -O2 -I<engine>/SurrealEngine -I<flipendo>/src/knowwonder -Ivita vita/tests/meshlighttest.cpp
#include "Precomp.h"
#include "VitaMeshLight4.h"
#include <cstdio>
#include <random>

namespace KW
{
	// copy of MeshLighting::Light
	vec3 MeshLighting::Light(const vec3& location, const vec3& normal) const
	{
		enum { LD_Point, LD_Plane, LD_Ambient };
		vec3 result = Ambient;
		vec3 view = location - ViewLocation;
		float viewSqr = dot(view, view);
		for (int i = 0; i < NumLights; i++)
		{
			const MeshLightInfo& light = Lights[i];
			vec3 L = light.Location - location;
			float distSqr = dot(L, L);
			float dist = std::sqrt(distSqr);
			float cosine;
			if (light.Source == LD_Ambient) { cosine = 1.0f; L = normal * dist; }
			else if (light.Source == LD_Plane) { cosine = dot(normal, light.Direction); L = light.Direction * dist; }
			else { cosine = dist > 0.0f ? dot(L, normal) / dist : 0.0f; }
			if (ScaleGlowCurve) cosine = (cosine + 1.0f) * (cosine + 1.0f) - 1.5f;
			float amount = std::max(Diffuse * cosine, 0.0f);
			if (Specular > 0.0f)
			{
				vec3 reflected = L - normal * (2.0f * dot(L, normal));
				float rv = dot(reflected, view);
				if (rv > 0.0f && distSqr * viewSqr > 0.0f)
				{
					float highlight = rv * (rv / (distSqr * viewSqr)) - SpecularCutoff;
					if (highlight > 0.0f) amount += Specular * highlight;
				}
			}
			if (amount > 0.0f)
			{
				float falloff = std::min((light.Radius - dist) * light.InvFalloff, 1.0f);
				result += light.Color * (falloff * amount);
				if (light.Dark) result = vec3(std::max(result.x, 0.0f), std::max(result.y, 0.0f), std::max(result.z, 0.0f));
			}
		}
		auto clampChannel = [](float v) { uint32_t bits; memcpy(&bits, &v, sizeof(bits)); return bits >= 0x3F800000 ? 1.0f : v; };
		return vec3(clampChannel(result.x), clampChannel(result.y), clampChannel(result.z));
	}
}

int main()
{
	std::mt19937 rng(99);
	std::uniform_real_distribution<float> U(-1.0f, 1.0f);
	double maxErr = 0.0;
	long values = 0, bad = 0;
	for (int t = 0; t < 20000; t++)
	{
		KW::MeshLighting m;
		m.Ambient = vec3(0.1f + 0.1f * U(rng), 0.1f, 0.05f);
		m.Diffuse = 1.0f + U(rng);
		m.Specular = (rng() % 2) ? 0.5f + 0.5f * U(rng) : 0.0f;
		m.SpecularCutoff = 0.3f + 0.2f * U(rng);
		m.ScaleGlowCurve = rng() % 4 == 0;
		m.ViewLocation = vec3(U(rng) * 500, U(rng) * 500, U(rng) * 200);
		m.NumLights = rng() % 6;
		for (int l = 0; l < m.NumLights; l++)
		{
			KW::MeshLightInfo& li = m.Lights[l];
			li.Location = vec3(U(rng) * 300, U(rng) * 300, U(rng) * 300);
			li.Direction = normalize(vec3(U(rng), U(rng), U(rng)));
			li.Source = rng() % 3;
			li.Radius = 100.0f + 400.0f * (U(rng) + 1.0f);
			li.InvFalloff = 1.0f / std::max(li.Radius * (0.3f + 0.3f * (U(rng) + 1.0f)), 1.0f);
			li.Dark = rng() % 7 == 0;
			li.Color = vec3(U(rng) + 1.0f, U(rng) + 1.0f, U(rng) + 1.0f) * (li.Dark ? -0.5f : 0.5f);
		}
		vec3 locs[11], normals[11], out[11];
		for (int i = 0; i < 11; i++)
		{
			locs[i] = vec3(U(rng) * 300, U(rng) * 300, U(rng) * 300);
			if (m.NumLights && rng() % 20 == 0) locs[i] = m.Lights[0].Location;   // a vertex at a light
			normals[i] = (rng() % 15 == 0) ? vec3(0.0f) : normalize(vec3(U(rng), U(rng), U(rng)));
		}
		KW::VitaLightVertices(m, locs, normals, out, 11);
		for (int i = 0; i < 11; i++)
		{
			vec3 ref = m.Light(locs[i], normals[i]);
			for (int c = 0; c < 3; c++)
			{
				double e = std::abs((double)(&ref.x)[c] - (&out[i].x)[c]);
				maxErr = std::max(maxErr, e);
				values++;
				if (e > 1e-4) bad++;
			}
		}
	}
	printf("%ld values, max difference %.3g, over 1e-4: %ld\n", values, maxErr, bad);
}
