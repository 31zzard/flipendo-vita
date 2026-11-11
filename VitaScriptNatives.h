#pragma once
// Script functions done natively on the Vita (VitaScriptNatives.cpp, apply_fixes.sh #193/#195)

class UObject;
class UFunction;
class ExpressionValue;
template<typename T> class ArrayView;

// a script function's native twin: false = not here (the script runs), true = done, result set
typedef bool (*VitaScriptNativeFn)(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result);

// the native twin of this (resolved, non-native) script function: 1 (fn set), 0 none, -1 not known yet (ask at its next call)
int VitaFindScriptNative(UFunction* func, UObject* instance, VitaScriptNativeFn& fn);
// runs it (uwindow_check=1: compared with the script); false: let the script run
bool VitaRunScriptNative(VitaScriptNativeFn fn, UFunction* func, UObject* instance, const ArrayView<ExpressionValue>& args, ExpressionValue& result);
