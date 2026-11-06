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

#include "Precomp.h"
#include "VitaConfig.h"
#include "KWActor.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Core/UClass.h"
#include "Engine.h"
#include "Math/rotator.h"
#include <algorithm>
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
