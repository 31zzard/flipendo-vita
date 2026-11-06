#pragma once

// apply_fixes.sh #91: a script function's (or state's) local variables made and dropped with one memset when every one of them is
// a plain value. Frame::InitVariables constructed each property through two virtual calls per element (ConstructArray ->
// ConstructElement, ElementPitch -> ElementAlignment/ElementSize) and DeinitVariables destroyed them the same way, on every script
// call: UProperty::ConstructArray/DestructArray/ElementPitch were ~5% of the engine thread in the profile of 06 Nov 08:33.
// For int, float, byte, bool, name, object/class and pointer properties, and structs made only of those (vector, rotator...),
// construction is all zero bytes (T() value-initialised; NameString() is { 0, 0 }; a bool is a cleared bit) and destruction does
// nothing; anything else (strings, dynamic arrays, maps, fixed arrays) keeps the per-property way.

#include "Packages/Core/UStruct.h"
#include "Packages/Core/Properties/UProperty.h"
#include "Packages/Core/Properties/UIntProperty.h"
#include "Packages/Core/Properties/UFloatProperty.h"
#include "Packages/Core/Properties/UByteProperty.h"
#include "Packages/Core/Properties/UBoolProperty.h"
#include "Packages/Core/Properties/UNameProperty.h"
#include "Packages/Core/Properties/UObjectProperty.h"
#include "Packages/Core/Properties/UPointerProperty.h"
#include "Packages/Core/Properties/UStructProperty.h"

inline bool VitaPropertyTrivial(UProperty* prop, int depth = 0)
{
	if (dynamic_cast<UIntProperty*>(prop) || dynamic_cast<UFloatProperty*>(prop) || dynamic_cast<UByteProperty*>(prop) ||
		dynamic_cast<UBoolProperty*>(prop) || dynamic_cast<UNameProperty*>(prop) || dynamic_cast<UObjectProperty*>(prop) ||
		dynamic_cast<UPointerProperty*>(prop))
		return true;
	if (auto sp = dynamic_cast<UStructProperty*>(prop))
	{
		if (!sp->Struct || depth > 8)
			return false;
		for (UProperty* member : sp->Struct->Properties)
			if (!VitaPropertyTrivial(member, depth + 1))
				return false;
		return true;
	}
	return false;
}

inline bool VitaLocalsTrivial(UStruct* layout)
{
	if (layout->VitaTrivialLocals < 0)
	{
		bool trivial = true;
		for (UProperty* prop : layout->Properties)
		{
			if (!VitaPropertyTrivial(prop))
			{
				trivial = false;
				break;
			}
		}
		layout->VitaTrivialLocals = trivial ? 1 : 0;
	}
	return layout->VitaTrivialLocals == 1;
}
