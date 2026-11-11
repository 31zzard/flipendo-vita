// Actor shadows on the Vita (render.cfg shadow_skip, apply_fixes.sh #84).
//
// KW::UpdateActorShadows calls ActorShadow.Update (a script event) on every shadow under the screen, every frame: 27 shadows
// cost 2.6-3.6 ms a frame in Lev_Tut1's hall (~130 us each: the event, BonePos of the owner's first bone, GetRenderExtent).
// The event is needed every frame even for a shadow that does not move: ActorShadow.Tick detaches the decal on a frame without
// it (bUpdated). And when the owner has not moved, Update does nothing else (Engine.ActorShadow):
//
//     if( Owner == none || Owner.bDeleteMe || Owner.Style == STY_Translucent ) return;
//     bUpdated = true;
//     Opacity = Owner.Opacity;
//     Loc = Owner.BonePos( Owner.BoneName(0) ); ...
//     if( VSize(OldOwnerLocation - Loc) <= MoveThreshold && (!bOriented || OldOwnerRotation == Owner.Rotation) ) return;
//
// So for an owner whose Location and Rotation are the same as at the last real Update, this does those two lines itself. The
// first bone can move with the animation while the actor stands still (an idle sway): the real Update still runs every
// shadow_skip + 1 frames (default 3 skipped, every 4th real) and catches it. shadow_skip=0: every frame, as before.
//
// The owner moving costs more (07 Nov, Lev2_Fire1: 15 Update events a frame at ~210 us for snails and tentacles that crawl,
// of which only ~5 got past the MoveThreshold test to AttachDecal). So when the shadow's Update is Engine.ActorShadow's own
// (not overridden), that early return is answered here exactly as the script does it: Owner.BonePos(Owner.BoneName(0)) + 1 in
// Z against OldOwnerLocation and MoveThreshold, and with bOriented OldOwnerRotation against the owner's Rotation. Inside the
// threshold: bUpdated and Opacity, nothing else (no counter needed: the bone's sway is in the test). Outside: the event.

#include "Precomp.h"
#include "VitaConfig.h"
#include "VitaProbes.h"
#include "Utils/Logger.h"
#include "KWActor.h"
#include "KW.h"
#include "Anim/KWAnimation.h"
#include "KWMove.h"
#include "KWCheck.h"
#include "Math/coords.h"
#include "Packages/Engine/Resources/Textures/UTexture.h"
#include "Packages/Engine/Resources/Mesh/USkeletalMesh.h"
#include "VM/ScriptCall.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Engine/Actors/UDecal.h"
#include "Packages/Core/UClass.h"
#include "Engine.h"
#include "Math/rotator.h"
#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace
{
	int MaxSkip() { static const int n = std::clamp(VitaConfigInt("shadow_skip", 3), 0, 30); return n; }

	struct Entry
	{
		UActor* owner = nullptr;
		vec3 location;
		int yaw = 0, pitch = 0, roll = 0;
		int skipped = 0;
	};
}

namespace KW { vec3 VitaRenderExtent(UActor* a); } // KWCollision.cpp (apply_fixes #160)

// true: the event is not needed this time (what it would do is done here)
bool VitaShadowSkip(UActor* actor, UActor* shadow)
{
	if (MaxSkip() <= 0)
		return false;

	static ULevel* level = nullptr;
	static std::unordered_map<UActor*, Entry> entries;
	if (engine->Level != level)
	{
		level = engine->Level;
		entries.clear();
	}

	static UClass* shadowClass = nullptr;
	static PropertyDataOffset bUpdated;
	static bool hasUpdated = false;
	if (shadow->Class != shadowClass)
	{
		shadowClass = shadow->Class;
		hasUpdated = shadow->HasProperty("bUpdated");
		if (hasUpdated)
			bUpdated = shadow->GetPropertyDataOffset("bUpdated");
	}
	if (!hasUpdated)
		return false;

	// Update's own early return: it leaves the shadow alone (and it detaches): let the script do it
	if (shadow->Owner() != actor || (int)actor->Style() == 3 /* STY_Translucent */)
		return false;

	// Engine.ActorShadow's Update itself: its MoveThreshold test made here (exact)
	static UClass* exactClass = nullptr;
	static bool exact = false;
	static PropertyDataOffset oldLocation, oldRotation, moveThreshold, bOriented, shadowSizeFactor, maxShadowDist;
	static const bool shadowNative = VitaConfigInt("shadow_native", 1) != 0;   // the whole Update natively (else only its early return)
	if (shadow->Class != exactClass)
	{
		exactClass = shadow->Class;
		exact = false;
		UClass* base = shadow->Class;
		while (base && base->Name != NameString("ActorShadow"))
			base = static_cast<UClass*>(base->BaseStruct);
		if (base && base->GetFunction(NameString("Update")) && FindEventFunction(shadow, NameString("Update")) == base->GetFunction(NameString("Update")) &&
			shadow->HasProperty("OldOwnerLocation") && shadow->HasProperty("OldOwnerRotation") && shadow->HasProperty("MoveThreshold") && shadow->HasProperty("bOriented"))
		{
			oldLocation = shadow->GetPropertyDataOffset("OldOwnerLocation");
			oldRotation = shadow->GetPropertyDataOffset("OldOwnerRotation");
			moveThreshold = shadow->GetPropertyDataOffset("MoveThreshold");
			bOriented = shadow->GetPropertyDataOffset("bOriented");
			shadowSizeFactor = shadow->HasProperty("ShadowSizeFactor") ? shadow->GetPropertyDataOffset("ShadowSizeFactor") : PropertyDataOffset();
			maxShadowDist = shadow->HasProperty("MaxShadowDist") ? shadow->GetPropertyDataOffset("MaxShadowDist") : PropertyDataOffset();
			exact = true;
		}
	}
	{
		// once per (class, reason): why a shadow's Update goes to the script
		static std::unordered_map<std::string, bool> told;
		const char* why = !exact ? "Update overridden or properties missing" : (!shadow->GetStateName().IsNone() ? "in a state" : nullptr);
		if (why && !told[shadow->Class->Name.ToString() + why])
		{
			told[shadow->Class->Name.ToString() + why] = true;
			LogMessage("VitaShadows: " + shadow->Class->Name.ToString() + " (state " + shadow->GetStateName().ToString() + "): script Update: " + why);
		}
	}
	if (exact && !shadow->GetStateName().IsNone())
		return false;   // a state could hold its own Update
	if (exact)
	{
		if (actor->bDeleteMe())
			return false;
		// Owner.BonePos(Owner.BoneName(0)) (KWAttach.cpp NBonePos, KWAnimState.cpp NBoneName)
		vec3 loc = actor->Location();
		VITA_LAP_START;
		if (USkeletalMesh* mesh = UObject::TryCast<USkeletalMesh>(actor->Mesh()))
		{
			NameString first = mesh->RefSkeleton.empty() ? NameString() : mesh->RefSkeleton[0].Name;
			vec3 bone, x, y, z;
			if (KW::GetBoneCoords(actor, mesh, KW::BoneIndex(mesh, first), bone, x, y, z))
				loc = bone;
		}
		VITA_LAP(ShadowBone);
		loc.z += 1.0f;
		const vec3 d = shadow->Value<vec3>(oldLocation) - loc;
		bool moved = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z) > shadow->Value<float>(moveThreshold);
		if (!moved && shadow->BoolValue(bOriented))
		{
			const Rotator& a = shadow->Value<Rotator>(oldRotation);
			const Rotator b = actor->Rotation();
			moved = a.Yaw != b.Yaw || a.Pitch != b.Pitch || a.Roll != b.Roll;
		}
		if (moved && (!shadowNative || !shadow->Texture() || !shadowSizeFactor.DataOffset || !maxShadowDist.DataOffset))
		{
			static bool told = false;
			if (!told)
			{
				told = true;
				LogMessage(std::string("VitaShadows: script Update: native ") + (shadowNative ? "on" : "off") + ", texture " + (shadow->Texture() ? "yes" : "none") +
					", ShadowSizeFactor at " + std::to_string(shadowSizeFactor.DataOffset) + ", MaxShadowDist at " + std::to_string(maxShadowDist.DataOffset));
			}
			return false;   // the script's own Update
		}
		shadow->BoolValue(bUpdated) = true;
		KW::Opacity(shadow) = KW::Opacity(actor);
		if (!moved)
			return true;

		// The rest of Update (L is None here), each step the native the script calls:
		//     DetachDecal(); ShadowDir = vec(0,0,-1); Extent = Owner.GetRenderExtent();
		//     DrawScale = float(Max(int(Extent.X), int(Extent.Y))) * ShadowSizeFactor / float(Max(Texture.USize, Texture.VSize));
		//     SetLocation(Loc); SetRotation(rotator(-ShadowDir)); AttachDecal(MaxShadowDist, vector(Owner.Rotation));
		//     OldOwnerLocation = Loc; OldOwnerRotation = Owner.Rotation;
		UDecal* decal = static_cast<UDecal*>(shadow);
		decal->DetachDecal();
		const vec3 shadowDir(0.0f, 0.0f, -1.0f);
		const vec3 extent = KW::VitaRenderExtent(actor);
		UTexture* texture = shadow->Texture();
		shadow->DrawScale() = (float)std::max((int)extent.x, (int)extent.y) * shadow->Value<float>(shadowSizeFactor) /
			(float)std::max((int)texture->USize(), (int)texture->VSize());
		KW::FarMoveActor(shadow, loc, false, false);
		KW::CheckResult hit;
		KW::MoveActor(shadow, vec3(0.0f), Rotator::FromVector(-shadowDir), hit);
		decal->AttachDecal(shadow->Value<float>(maxShadowDist), Coords::Rotation(actor->Rotation()).XAxis);
		shadow->Value<vec3>(oldLocation) = loc;
		shadow->Value<Rotator>(oldRotation) = actor->Rotation();
		VITA_LAP(ShadowMoved);
		return true;
	}

	Entry& e = entries[shadow];
	const vec3 loc = actor->Location();
	const Rotator rot = actor->Rotation();
	const bool same = e.owner == actor && e.location.x == loc.x && e.location.y == loc.y && e.location.z == loc.z && e.yaw == rot.Yaw && e.pitch == rot.Pitch && e.roll == rot.Roll &&
		e.skipped < MaxSkip();
	if (!same)
	{
		e.owner = actor;
		e.location = loc;
		e.yaw = rot.Yaw;
		e.pitch = rot.Pitch;
		e.roll = rot.Roll;
		e.skipped = 0;
		return false;
	}
	e.skipped++;
	shadow->BoolValue(bUpdated) = true;
	KW::Opacity(shadow) = KW::Opacity(actor);
	return true;
}

// Engine.ActorShadow's Tick event natively (render.cfg shadow_tick, default 1; 07 Nov: 52 shadows in Lev2_Fire1 cost 1.1 ms a
// frame in the event for this script):
//
//     function Tick( float DeltaTime )
//         if( !bUpdated ) { DetachDecal(); OldOwnerLocation = vec(0,0,0); }
//         bUpdated = false;
//
// Only for a class whose Tick is that function (not overridden, no state). true: done, the event is not called.
bool VitaShadowTick(UActor* actor)
{
	static const bool on = VitaConfigInt("shadow_tick", 1) != 0;
	if (!on)
		return false;

	struct ClassInfo { bool exact = false; PropertyDataOffset bUpdated, oldLocation; };
	static std::unordered_map<UClass*, ClassInfo> classes;
	auto it = classes.find(actor->Class);
	if (it == classes.end())
	{
		ClassInfo info;
		UClass* base = actor->Class;
		while (base && base->Name != NameString("ActorShadow"))
			base = static_cast<UClass*>(base->BaseStruct);
		UFunction* tick = base ? base->GetFunction(NameString("Tick")) : nullptr;
		if (tick && UObject::TryCast<UDecal>(actor) && actor->HasProperty("bUpdated") && actor->HasProperty("OldOwnerLocation"))
		{
			// the class's own Tick, as FindEventFunction would find it without a state
			UFunction* found = nullptr;
			for (UClass* cls = actor->Class; cls && !found; cls = static_cast<UClass*>(cls->BaseStruct))
				found = cls->GetFunction(NameString("Tick"));
			if (found == tick)
			{
				info.exact = true;
				info.bUpdated = actor->GetPropertyDataOffset("bUpdated");
				info.oldLocation = actor->GetPropertyDataOffset("OldOwnerLocation");
			}
		}
		it = classes.emplace(actor->Class, info).first;
	}
	const ClassInfo& info = it->second;
	if (!info.exact || !actor->GetStateName().IsNone())
		return false;

	if (!actor->BoolValue(info.bUpdated))
	{
		static_cast<UDecal*>(actor)->DetachDecal();
		actor->Value<vec3>(info.oldLocation) = vec3(0.0f);
	}
	actor->BoolValue(info.bUpdated) = false;
	return true;
}
