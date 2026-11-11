// The lights that can reach a point, without looking at every light of the level (apply_fixes.sh #177, #196).
//
// KW::SetupMeshLighting tested every light of the frame's light snapshot against each mesh (distance below the light's radius):
// in Lev3_Intro's Great Hall (candles) ~140 us a mesh, 2.3 ms a frame on the main thread. VitaLightGrid answers with the
// indexes of the lights whose sphere touches the grid cell of the point, in ascending order: the caller makes its own exact test
// on those, in the snapshot's order, so it finds the same lights in the same order.
//
// A light goes into every cell (Cell units) its sphere's box touches, under a slot of its own that stays while the light is in
// the snapshot. A light whose location or radius differs from what its cells were made with is 'loose' and checked by every
// query; past MaxLoose such lights, the moved ones are put into the cells of where they are now.
// #196: when the list of lights changes (a spell's light comes and goes: Lev2_HogFront's 75 ms frames at every cast, the whole
// grid of the outdoor lights made again twice), only the lights that came or went are put in or taken out.

#pragma once

#include "Math/vec.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

class UActor;

struct VitaLightGrid
{
	static constexpr float Cell = 512.0f;
	static constexpr size_t MaxLoose = 64;
	static constexpr int MaxCellsPerLight = 4096;   // a light with a bigger box is always loose

	struct Slot
	{
		UActor* light = nullptr;
		vec3 location = vec3(0.0f);   // what its cells were made with
		float radius = 0.0f;
		bool inCells = false;         // false: too big or not finite, always loose
		int x0 = 0, x1 = -1, y0 = 0, y1 = -1, z0 = 0, z1 = -1;
	};

	std::vector<UActor*> lights;     // the snapshot of the last Update
	std::vector<Slot> slots;
	std::vector<uint32_t> freeSlots;
	std::unordered_map<UActor*, uint32_t> slotOf;
	std::vector<int32_t> indexOfSlot;   // the slot's light's index in the snapshot, -1: none
	std::vector<uint32_t> slotOfIndex;  // the snapshot index's slot (~0u: a light listed twice, loose)
	std::unordered_map<uint64_t, std::vector<uint32_t>> cells;   // slots
	std::vector<uint32_t> loose;     // snapshot indexes checked by every query (ascending)
	std::vector<uint32_t> result;

	static int CellOf(float v) { return (int)std::floor(v * (1.0f / Cell)); }
	static uint64_t Key(int x, int y, int z) { return ((uint64_t)(uint32_t)(x + 0x100000) << 42) ^ ((uint64_t)(uint32_t)(y + 0x100000) << 21) ^ (uint64_t)(uint32_t)(z + 0x100000); }

	void Place(uint32_t slot, const vec3& p, float r)
	{
		Slot& s = slots[slot];
		s.location = p;
		s.radius = r;
		s.inCells = false;
		if (!(r >= 0.0f) || !std::isfinite(r) || !std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z))
			return;
		const int x0 = CellOf(p.x - r), x1 = CellOf(p.x + r);
		const int y0 = CellOf(p.y - r), y1 = CellOf(p.y + r);
		const int z0 = CellOf(p.z - r), z1 = CellOf(p.z + r);
		if ((int64_t)(x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > MaxCellsPerLight)
			return;
		s.inCells = true;
		s.x0 = x0; s.x1 = x1; s.y0 = y0; s.y1 = y1; s.z0 = z0; s.z1 = z1;
		for (int z = z0; z <= z1; z++)
			for (int y = y0; y <= y1; y++)
				for (int x = x0; x <= x1; x++)
					cells[Key(x, y, z)].push_back(slot);
	}

	void Unplace(uint32_t slot)
	{
		Slot& s = slots[slot];
		if (!s.inCells)
			return;
		s.inCells = false;
		for (int z = s.z0; z <= s.z1; z++)
			for (int y = s.y0; y <= s.y1; y++)
				for (int x = s.x0; x <= s.x1; x++)
				{
					auto it = cells.find(Key(x, y, z));
					if (it == cells.end())
						continue;
					std::vector<uint32_t>& list = it->second;
					auto at = std::find(list.begin(), list.end(), slot);
					if (at != list.end())
					{
						*at = list.back();
						list.pop_back();
					}
					if (list.empty())
						cells.erase(it);
				}
	}

	bool Moved(uint32_t slot, const vec3& a, float r) const
	{
		const Slot& s = slots[slot];
		return !s.inCells || a.x != s.location.x || a.y != s.location.y || a.z != s.location.z || r != s.radius;
	}

	// Once a frame, after the snapshot is made
	void Update(const std::vector<UActor*>& snapLights, const std::vector<vec3>& snapLocations, const std::vector<float>& snapRadii)
	{
		if (snapLights != lights)
		{
			// the lights that went are taken out, the new ones put in; the others keep their slots and cells
			std::fill(indexOfSlot.begin(), indexOfSlot.end(), -1);
			slotOfIndex.assign(snapLights.size(), ~0u);
			for (uint32_t i = 0; i < (uint32_t)snapLights.size(); i++)
			{
				auto [it, added] = slotOf.try_emplace(snapLights[i], 0u);
				if (added)
				{
					uint32_t slot;
					if (!freeSlots.empty())
					{
						slot = freeSlots.back();
						freeSlots.pop_back();
					}
					else
					{
						slot = (uint32_t)slots.size();
						slots.emplace_back();
						indexOfSlot.push_back(-1);
					}
					it->second = slot;
					slots[slot].light = snapLights[i];
					Place(slot, snapLocations[i], snapRadii[i]);
				}
				const uint32_t slot = it->second;
				if (indexOfSlot[slot] >= 0)
					continue;   // listed twice: this one stays loose
				indexOfSlot[slot] = (int32_t)i;
				slotOfIndex[i] = slot;
			}
			for (uint32_t slot = 0; slot < (uint32_t)slots.size(); slot++)
			{
				if (indexOfSlot[slot] >= 0 || !slots[slot].light)
					continue;
				Unplace(slot);
				slotOf.erase(slots[slot].light);
				slots[slot].light = nullptr;
				freeSlots.push_back(slot);
			}
			lights = snapLights;
		}

		// lights that differ from their cells are loose; too many: the moved ones are put where they are now
		loose.clear();
		for (uint32_t i = 0; i < (uint32_t)lights.size(); i++)
			if (slotOfIndex[i] == ~0u || Moved(slotOfIndex[i], snapLocations[i], snapRadii[i]))
				loose.push_back(i);
		if (loose.size() > MaxLoose)
		{
			std::vector<uint32_t> still;
			for (uint32_t i : loose)
			{
				const uint32_t slot = slotOfIndex[i];
				if (slot == ~0u)
				{
					still.push_back(i);
					continue;
				}
				Unplace(slot);
				Place(slot, snapLocations[i], snapRadii[i]);
				if (!slots[slot].inCells)
					still.push_back(i);
			}
			loose.swap(still);
		}
	}

	// The indexes (ascending) of the lights that may reach point p: a superset of those with |light - p| < radius
	const std::vector<uint32_t>& Query(const vec3& p)
	{
		result.clear();
		if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z))
		{
			for (uint32_t i = 0; i < (uint32_t)lights.size(); i++)
				result.push_back(i);
			return result;
		}
		auto it = cells.find(Key(CellOf(p.x), CellOf(p.y), CellOf(p.z)));
		if (it != cells.end())
			for (uint32_t slot : it->second)
				if (indexOfSlot[slot] >= 0)
					result.push_back((uint32_t)indexOfSlot[slot]);
		result.insert(result.end(), loose.begin(), loose.end());
		std::sort(result.begin(), result.end());
		result.erase(std::unique(result.begin(), result.end()), result.end());
		return result;
	}
};
