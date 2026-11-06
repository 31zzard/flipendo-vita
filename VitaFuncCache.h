#pragma once

// apply_fixes.sh #93: which script function a virtual call or an event runs, remembered. Frame's VirtualFunction and
// FindEventFunction (CallEvent) looked it up on every call: for each class from the object's up to Object, a std::map search for
// the current state and one in its functions, then the same for the classes' own functions (Harry: ~7 classes, up to ~14
// searches a call). The answer depends only on the class, the state's name and the function's name while the classes' and
// states' function tables stay as they are; they change only when a class or state is loaded (UClass::Load, UState::Load) or
// a mod wraps a function (HP1::WrapScriptFunction): each of those clears the cache (VitaFuncCacheClear).

#include "Packages/Core/UClass.h"
#include "Packages/Core/UState.h"
#include "Packages/Core/UFunction.h"
#include <unordered_map>
#include <cstdint>

struct VitaFuncKey
{
	const void* cls;
	int state;
	int func;
	bool operator==(const VitaFuncKey& o) const { return cls == o.cls && state == o.state && func == o.func; }
};

struct VitaFuncKeyHash
{
	size_t operator()(const VitaFuncKey& k) const
	{
		uint32_t h = (uint32_t)(uintptr_t)k.cls * 2654435761u;
		h ^= (uint32_t)k.state * 0x85ebca6bu + 0x9e3779b9u + (h << 6) + (h >> 2);
		h ^= (uint32_t)k.func * 0xc2b2ae35u + 0x9e3779b9u + (h << 6) + (h >> 2);
		return h;
	}
};

inline std::unordered_map<VitaFuncKey, UFunction*, VitaFuncKeyHash>& VitaFuncCacheMap()
{
	static std::unordered_map<VitaFuncKey, UFunction*, VitaFuncKeyHash> map;
	return map;
}

inline void VitaFuncCacheClear() { VitaFuncCacheMap().clear(); }

// The engine's own search: states first (over the class chain), then the classes' functions. nullptr when there is none.
inline UFunction* VitaFindFunctionSlow(UClass* contextClass, const NameString& stateName, const NameString& name)
{
	if (!stateName.IsNone())
	{
		for (UClass* cls = contextClass; cls != nullptr; cls = static_cast<UClass*>(cls->BaseStruct))
		{
			if (UState* state = cls->GetState(stateName))
				if (UFunction* func = state->GetFunction(name))
					return func;
		}
	}
	for (UClass* cls = contextClass; cls != nullptr; cls = static_cast<UClass*>(cls->BaseStruct))
		if (UFunction* func = cls->GetFunction(name))
			return func;
	return nullptr;
}

inline UFunction* VitaFindFunction(UClass* contextClass, const NameString& stateName, const NameString& name)
{
	const VitaFuncKey key{ contextClass, stateName.GetCompareIndex(), name.GetCompareIndex() };
	auto& map = VitaFuncCacheMap();
	auto it = map.find(key);
	if (it != map.end())
		return it->second;
	UFunction* func = VitaFindFunctionSlow(contextClass, stateName, name);
	if (func) // a miss is not kept: the engine throws or skips it, and a class loaded later might have it
		map.emplace(key, func);
	return func;
}
