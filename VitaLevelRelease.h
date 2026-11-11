#pragma once
// apply_fixes.sh #146: the level the player leaves is let go (most of it).
// The engine never freed a level: PackageManager::LoadMap makes a new Package for every map load, UnloadMap only closes its streams,
// and GC::Collect can't run (only the packages are roots: it frees the viewport, the console...). Every level change kept ~20 MB:
// EntryHall_Hub <-> Grandstaircase_hub ran the 256 MB heap out on the 3rd or 4th door (the user's "crash between locations").
//
// What it does now, at the end of UnloadMap (render.cfg level_release=0: the old way):
//  - finds the old map package's objects that nothing outside that package reaches through a property (the collector's mark,
//    started from every other object instead of the roots: what the engine's own objects point at stays);
//  - those actors give their properties back (strings, arrays, the block itself): the block becomes one shared copy of the class's
//    defaults, so a stale native pointer to one still reads sane values;
//  - those BSP models give back their nodes, surfaces, points, polygons...;
//  - the old ULevel gives back its actor list, collision hash and light system (lightmaps) whatever reaches it.
// No object itself is freed: its address is never handed out again, so the caches kept by pointer (by actor, by level, by texture)
// can never mistake a new object for an old one. The caches kept by actor empty themselves (VitaLevelEpoch.h).
#include "GC/GC.h"
#include "Package/Package.h"
#include "Packages/Core/UClass.h"
#include "Packages/Core/UField.h"
#include "Packages/Core/Properties/UProperty.h"
#include "Packages/Core/Properties/UObjectProperty.h"
#include "Packages/Core/Properties/UBoolProperty.h"
#include "Packages/Core/Properties/UStructProperty.h"
#include "Packages/Core/Properties/UArrayProperty.h"
#include "Packages/Core/Properties/UFixedArrayProperty.h"
#include "Packages/Core/UStruct.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Engine/Resources/Level/ULevel.h"
#include "Packages/Engine/Resources/Level/UModel.h"
#include "Packages/Engine/Resources/Level/UPolys.h"
#include "Utils/AlignedAlloc.h"
#include "Utils/Logger.h"
#include "VitaConfig.h"
#include "VitaLevelEpoch.h"
#include <malloc.h>
#include <algorithm>
#include <map>
#include <new>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace VitaLevelRelease
{
	template<class T> inline void Free(T& c) { T().swap(c); }

	// One copy of a class's defaults, shared by all the let-go actors of that class (never freed: a few hundred classes at most)
	inline void* SharedBlock(UClass* cls)
	{
		static std::unordered_map<UClass*, void*> blocks;
		auto it = blocks.find(cls);
		if (it != blocks.end())
			return it->second;
		void* data = AlignedAlloc(cls->StructAlignment, cls->StructSize);
		for (UProperty* prop : cls->Properties)
		{
			prop->CopyConstructArray(static_cast<uint8_t*>(data) + prop->DataOffset.DataOffset, cls->PropertyData.Ptr(prop));
			// a let-go actor is a destroyed one: the natives that check skip it
			if (prop->Name == NameString("bDeleteMe"))
				if (UBoolProperty* b = dynamic_cast<UBoolProperty*>(prop))
					b->SetBool(static_cast<uint8_t*>(data) + prop->DataOffset.DataOffset, true);
		}
		blocks[cls] = data;
		return data;
	}

	inline size_t HollowActor(UActor* actor)
	{
		PropertyDataBlock& block = actor->PropertyData;
		UClass* cls = block.Class;
		if (!block.Data || !cls || block.Size != cls->StructSize || cls->PropertyData.Size != cls->StructSize)
			return 0;
		void* shared = SharedBlock(cls);
		if (block.Data == shared)
			return 0;
		for (UProperty* prop : cls->Properties)
			prop->DestructArray(block.Ptr(prop));
		AlignedFree(block.Data);
		block.Data = shared;
		return cls->StructSize;
	}

	inline size_t HollowModel(UModel* model, bool withPolys)
	{
		size_t bytes = model->Vectors.size() * sizeof(vec3) + model->Points.size() * sizeof(vec3) + model->Nodes.size() * sizeof(BspNode) +
			model->Surfaces.size() * sizeof(BspSurface) + model->Vertices.size() * sizeof(BspVert) + model->LightMap.size() * sizeof(LightMapIndex) +
			model->LightBits.size() + model->Leaves.size() * sizeof(ConvexVolumeLeaf) + model->LeafHulls.size() * 4 + model->Bounds.size() * sizeof(BBox);
		Free(model->Vectors); Free(model->Points); Free(model->Nodes); Free(model->Surfaces); Free(model->Vertices);
		Free(model->Zones); Free(model->LightMap); Free(model->LightBits); Free(model->Bounds); Free(model->LeafHulls);
		Free(model->Leaves); Free(model->Lights);
		if (withPolys && model->Polys)
		{
			for (Poly& p : model->Polys->Polys)
				bytes += p.Vertices.size() * sizeof(vec3) + sizeof(Poly);
			Free(model->Polys->Polys);
		}
		return bytes;
	}

	inline void HollowLevel(ULevel* level)
	{
		Free(level->Actors);
		Free(level->ReachSpecs);
		level->TravelInfo.clear();
		level->Collision.~CollisionSystem();
		new (&level->Collision) CollisionSystem();
		level->Light.~LightSystem();
		new (&level->Light) LightSystem();
	}

	inline size_t HeapInUse() { struct mallinfo info = mallinfo(); return (size_t)info.uordblks; }

	// The references to the old level's actors from everything outside it become None: UE1 does the same with the references to
	// a destroyed actor, and the level's actors are all destroyed with it. Without this a single reference keeps the whole level
	// (through LevelInfo, the navigation lists...): Entry's BaseCam, BaseCamTarget and GameReplicationInfo.PRIArray kept the old
	// LevelInfo; HP_Scripted's ScriptedTextures (NotifyActor) kept EntryHall's CeremonySTextures.
	struct RefCleaner
	{
		Package* pkg;
		size_t cleared = 0;
		std::string names;
		UObject* owner = nullptr;

		bool IsOldActor(UObject* obj) const { return obj && obj->package == pkg && dynamic_cast<UActor*>(obj); }

		void Element(UProperty* prop, void* data, int depth)
		{
			if (auto op = dynamic_cast<UObjectProperty*>(prop))
			{
				(void)op;
				UObject*& slot = *static_cast<UObject**>(data);
				if (IsOldActor(slot))
				{
					if (names.size() < 800)
						names += " " + owner->Name.ToString() + "." + prop->Name.ToString();
					slot = nullptr;
					cleared++;
				}
			}
			else if (depth > 8)
				return;
			else if (auto sp = dynamic_cast<UStructProperty*>(prop))
			{
				if (sp->Struct)
					for (UProperty* member : sp->Struct->Properties)
						Property(member, static_cast<uint8_t*>(data) + member->DataOffset.DataOffset, depth + 1);
			}
			else if (auto ap = dynamic_cast<UArrayProperty*>(prop))
			{
				ScriptArray* array = static_cast<ScriptArray*>(data);
				if (ap->Inner)
					for (size_t i = 0, n = array->GetSize(); i < n; i++)
						Element(ap->Inner, array->GetItem(i), depth + 1);
			}
			else if (auto fp = dynamic_cast<UFixedArrayProperty*>(prop))
			{
				if (fp->Inner)
					for (int i = 0; i < fp->Count; i++)
						Element(fp->Inner, static_cast<uint8_t*>(data) + i * fp->Inner->ElementPitch(), depth + 1);
			}
		}

		void Property(UProperty* prop, void* data, int depth)
		{
			if (prop->ValueType != ExpressionValueType::ValueObject && prop->ValueType != ExpressionValueType::ValueStruct &&
				prop->ValueType != ExpressionValueType::ValueArray)
				return;
			for (int i = 0; i < prop->ArrayDimension; i++)
				Element(prop, prop->GetElement(data, i), depth);
		}

		void Run()
		{
			for (GCObject* o : GC::GetObjects())
			{
				UObject* obj = dynamic_cast<UObject*>(o);
				if (!obj || obj->package == pkg || !obj->Class || !obj->PropertyData.Data || dynamic_cast<UField*>(obj) ||
					obj->PropertyData.Size < obj->Class->StructSize)
					continue;
				owner = obj;
				for (UProperty* prop : obj->Class->Properties)
					Property(prop, obj->PropertyData.Ptr(prop), 0);
			}
			if (cleared)
				LogMessage("LevelRelease: references to the old level's actors cleared:" + names);
		}
	};

	// pkg: the map package being left; level: its ULevel (may be in pkg or not); entryPkg: the Entry level's package (unused now:
	// RefCleaner clears every outside reference). Engine thread, between maps.
	inline void Release(Package* pkg, ULevel* level, Package* entryPkg)
	{
		if (!pkg || !VitaConfigInt("level_release", 1))
			return;
		const size_t heapBefore = HeapInUse();

		auto inOld = [pkg](GCObject* o) {
			if (o == static_cast<GCObject*>(pkg))
				return true;
			UObject* obj = dynamic_cast<UObject*>(o);
			return obj && obj->package == pkg;
		};
		(void)entryPkg;
		RefCleaner cleaner{ pkg };
		cleaner.Run();
		// the mark starts from every object but the old level's
		auto inside = [&](GCObject* o) { return inOld(o); };
		std::vector<UObject*> dead;
		std::map<std::string, int> reachedByClass;
		size_t reached = 0;
		GC::VitaFindUnreached(inside, [&](GCObject* o, bool isReached) {
			UObject* obj = dynamic_cast<UObject*>(o);
			if (!obj || !inOld(o))
				return;
			if (!isReached)
				dead.push_back(obj);
			else
			{
				reached++;
				if (obj->Class)
					reachedByClass[obj->Class->Name.ToString()]++;
			}
		});

		if (reached && VitaConfigInt("level_release_why", 0))
		{
			// which objects outside keep the old level's objects (the first link of each chain)
			std::map<std::string, int> keepers;
			for (GCObject* o : GC::GetObjects())
			{
				if (inside(o))
					continue;
				UObject* from = dynamic_cast<UObject*>(o);
				GC::VitaDirectRefs(o, [&](GCObject* ref) {
					UObject* to = dynamic_cast<UObject*>(ref);
					if (!to || !inOld(ref))
						return;
					std::string key = from ? (from->Class ? from->Class->Name.ToString() : std::string("?")) + " " + from->Name.ToString() +
						" (" + (from->package ? from->package->GetPackageName().ToString() : std::string("-")) + ")" : std::string("(a package)");
					keepers[key + " -> " + (to->Class ? to->Class->Name.ToString() : std::string("?")) + " " + to->Name.ToString()]++;
				});
			}
			std::string why = "LevelRelease: kept by:";
			int n = 0;
			for (auto& it : keepers)
			{
				if (++n > 40)
					break;
				why += " [" + it.first + (it.second > 1 ? " x" + std::to_string(it.second) : std::string()) + "]";
			}
			LogMessage(why);
		}

		std::unordered_set<UObject*> deadSet(dead.begin(), dead.end());
		size_t actors = 0, actorBytes = 0, models = 0, modelBytes = 0, shellBytes = 0;
		std::vector<UActor*> hollowed;
		for (UObject* obj : dead)
		{
			if (dynamic_cast<UField*>(obj))
				continue;
			if (UActor* actor = dynamic_cast<UActor*>(obj))
			{
				size_t b = HollowActor(actor);
				actors += b != 0;
				actorBytes += b;
				if (b)
					hollowed.push_back(actor);
			}
			else if (UModel* model = dynamic_cast<UModel*>(obj))
			{
				// its polygons go with it when nothing else reaches them either (UModel::Polys is a native pointer, not marked)
				modelBytes += HollowModel(model, model->Polys && deadSet.count(model->Polys));
				models++;
			}
		}
		if (level && level->package == pkg)
		{
			// the level's own model and lists go whatever reaches the level (nothing ticks or draws an old level)
			if (level->Model && !deadSet.count(level->Model))
			{
				modelBytes += HollowModel(level->Model, true);
				models++;
			}
			HollowLevel(level);
		}

		// The hollowed actors themselves are freed (their property block is the shared one: not theirs to free). Nothing outside
		// reaches them (RefCleaner, the mark); the caches kept by actor empty themselves (the epoch below).
		size_t freed = 0;
		if (VitaConfigInt("level_free_actors", 1) && !hollowed.empty())
		{
			std::vector<GCObject*> gone;
			std::unordered_set<UObject*> goneSet;
			for (UActor* actor : hollowed)
			{
				shellBytes += (((GCAllocation*)static_cast<GCObject*>(actor)) - 1)->memsize;
				actor->PropertyData.Data = nullptr;
				actor->PropertyData.Size = 0;
				gone.push_back(actor);
				goneSet.insert(actor);
			}
			// the models nothing reaches (a mover's, a brush's, the level's own) and their polygons
			for (UObject* obj : dead)
			{
				UModel* model = dynamic_cast<UModel*>(obj);
				if (!model)
					continue;
				if (model->Polys && deadSet.count(model->Polys) && !goneSet.count(model->Polys))
				{
					gone.push_back(model->Polys);
					goneSet.insert(model->Polys);
				}
				gone.push_back(model);
				goneSet.insert(model);
				shellBytes += (((GCAllocation*)static_cast<GCObject*>(model)) - 1)->memsize;
			}
			if (level && goneSet.count(level->Model))
				level->Model = nullptr;
			pkg->VitaForgetExports([&](UObject* obj) { return goneSet.count(obj) != 0; });
			pkg->VitaForgetTables();
			GC::VitaFree(gone);
			freed = gone.size();
		}
		vitaLevelEpoch++;

		std::vector<std::pair<int, std::string>> top;
		for (auto& it : reachedByClass)
			top.push_back({ it.second, it.first });
		std::sort(top.rbegin(), top.rend());
		std::string text = "LevelRelease: " + pkg->GetPackageName().ToString() + ": " + std::to_string(dead.size()) + " objects let go (" +
			std::to_string(actors) + " actors " + std::to_string(actorBytes / 1024) + " KB, " + std::to_string(models) + " models " +
			std::to_string(modelBytes / 1024) + " KB; " + std::to_string(freed) + " actors and models freed: " + std::to_string(shellBytes / 1024) + " KB), " + std::to_string(reached) + " still reached from outside (" + std::to_string(cleaner.cleared) + " references cleared):";
		for (size_t i = 0; i < top.size() && i < 12; i++)
			text += " " + top[i].second + " x" + std::to_string(top[i].first);
		const size_t heapAfter = HeapInUse();
		text += "; heap " + std::to_string(heapBefore / (1024 * 1024)) + " -> " + std::to_string(heapAfter / (1024 * 1024)) + " MB";
		LogMessage(text);
	}
}
