// Script functions done natively on the Vita, each exactly as its UnrealScript does it (apply_fixes.sh #193).
//
// Engine.GameReplicationInfo.Timer (SetTimer(0.2, true) in its PostBeginPlay) runs a few times a second in every level and cost
// ~820 us a call (~250 us a frame) in the script VM: two 32-step loops over PRIArray and AllActors(PlayerReplicationInfo).
// Its code (@script GameReplicationInfo Timer on the console; the same as the UT-era Engine source):
//
//     if( Level.NetMode == NM_Client ) { ... the countdown ... }     (not here: the script does that case)
//     for (i=0; i<32; i++) PRIArray[i] = None;
//     i = 0;
//     foreach AllActors(class'PlayerReplicationInfo', PRI) PRIArray[i++] = PRI;
//     UpdateTimer = 0;
//     for (i=0; i<32; i++) if (PRIArray[i] != None) FragAcc += PRIArray[i].Score;   (float to int: truncated)
//     SumFrags = FragAcc;
//     if( Level.Game != None ) NumPlayers = Level.Game.NumPlayers;
//
// Only for an actor whose Timer is that function (class not overriding it, no state), with fewer PRIs than PRIArray holds
// (more would make the script go past the array); everything else goes to the script. render.cfg gri_timer=0: always the script.

#include "Precomp.h"
#include "VitaConfig.h"
#include "Engine.h"
#include "VM/ScriptCall.h"
#include "Packages/Core/UClass.h"
#include "Packages/Core/Properties/UProperty.h"
#include "Packages/Engine/Actors/UActor.h"
#include "Packages/Engine/Actors/Info/ULevelInfo.h"
#include "Packages/Engine/Actors/Info/UGameInfo.h"
#include "Packages/Engine/Resources/Level/ULevel.h"
#include "Utils/Logger.h"
#include <cstring>
#include <unordered_map>
#include <vector>

namespace
{
	struct GRIClass
	{
		bool exact = false;
		UProperty* priArray = nullptr;
		PropertyDataOffset updateTimer, sumFrags, numPlayers;
	};

	UFunction* OwnFunction(UClass* cls, const char* name)
	{
		for (UClass* c = cls; c; c = static_cast<UClass*>(c->BaseStruct))
			if (UFunction* f = c->GetFunction(NameString(name)))
				return f;
		return nullptr;
	}

	bool IsFloatProperty(UProperty* p) { return p && p->ElementSize() == sizeof(float); }
}

// true: the Timer event was done here
bool VitaGRITimer(UActor* actor)
{
	static const bool on = VitaConfigInt("gri_timer", 1) != 0;
	if (!on)
		return false;

	static std::unordered_map<UClass*, GRIClass> classes;
	auto it = classes.find(actor->Class);
	if (it == classes.end())
	{
		GRIClass info;
		UClass* base = actor->Class;
		while (base && base->Name != NameString("GameReplicationInfo"))
			base = static_cast<UClass*>(base->BaseStruct);
		UFunction* timer = base ? base->GetFunction(NameString("Timer")) : nullptr;
		if (timer && OwnFunction(actor->Class, "Timer") == timer && actor->HasProperty("PRIArray") && actor->HasProperty("UpdateTimer") &&
			actor->HasProperty("SumFrags") && actor->HasProperty("NumPlayers"))
		{
			info.priArray = actor->GetMemberProperty(NameString("PRIArray"));
			info.updateTimer = actor->GetPropertyDataOffset("UpdateTimer");
			info.sumFrags = actor->GetPropertyDataOffset("SumFrags");
			info.numPlayers = actor->GetPropertyDataOffset("NumPlayers");
			info.exact = info.priArray && info.priArray->ElementSize() == sizeof(UObject*);
		}
		it = classes.emplace(actor->Class, info).first;
	}
	const GRIClass& info = it->second;
	if (!info.exact || !actor->GetStateName().IsNone() || !actor->IsEventEnabled(EventName::Timer))
		return false;

	ULevelInfo* level = UObject::TryCast<ULevelInfo>(actor->Level());
	if (!level || level->NetMode() == 3 /* NM_Client */ || !engine->Level)
		return false;

	// gri_timer_check=1: the script first, its results kept, then the native way over them, compared
	static const bool check = VitaConfigInt("gri_timer_check", 0) != 0;
	std::vector<UObject*> scriptArray;
	float scriptUpdate = 0.0f;
	int scriptSum = 0, scriptPlayers = 0;
	if (check)
	{
		CallEvent(actor, EventName::Timer);
		void* data = actor->GetProperty(info.priArray);
		for (int i = 0; i < info.priArray->ArrayDimension; i++)
			scriptArray.push_back(*static_cast<UObject**>(info.priArray->GetElement(data, i)));
		scriptUpdate = actor->Value<float>(info.updateTimer);
		scriptSum = actor->Value<int>(info.sumFrags);
		scriptPlayers = actor->Value<int>(info.numPlayers);
	}

	// the PRIs in AllActors' order (Level.Actors, IsA by name)
	static std::vector<UObject*> pris;
	pris.clear();
	static const NameString priName("PlayerReplicationInfo");
	for (UActor* a : engine->Level->Actors)
		if (a && a->IsA(priName))
			pris.push_back(a);
	const int dim = info.priArray->ArrayDimension;
	if (dim != 32 || (int)pris.size() >= dim)
		return false;
	// everything read is checked before anything is written (else the script does it all)
	static std::vector<float*> scores;
	scores.clear();
	for (UObject* pri : pris)
	{
		UProperty* score = pri->GetMemberProperty(NameString("Score"));
		if (!IsFloatProperty(score))
			return false;
		scores.push_back(static_cast<float*>(pri->GetProperty(score)));
	}
	UObject* game = level->Game();
	if (game && !game->HasProperty("NumPlayers"))
		return false;

	void* arrayData = actor->GetProperty(info.priArray);
	for (int i = 0; i < dim; i++)
		*static_cast<UObject**>(info.priArray->GetElement(arrayData, i)) = (i < (int)pris.size()) ? pris[i] : nullptr;
	actor->Value<float>(info.updateTimer) = 0.0f;
	int fragAcc = 0;
	for (float* score : scores)
		fragAcc += (int)*score;
	actor->Value<int>(info.sumFrags) = fragAcc;
	if (game)
		actor->Value<int>(info.numPlayers) = game->Value<int>(game->GetPropertyDataOffset("NumPlayers"));
	if (check)
	{
		static unsigned checked = 0, wrong = 0;
		bool same = scriptUpdate == actor->Value<float>(info.updateTimer) && scriptSum == actor->Value<int>(info.sumFrags) &&
			scriptPlayers == actor->Value<int>(info.numPlayers);
		void* data = actor->GetProperty(info.priArray);
		for (int i = 0; i < info.priArray->ArrayDimension; i++)
			same = same && scriptArray[i] == *static_cast<UObject**>(info.priArray->GetElement(data, i));
		checked++;
		if (!same)
			wrong++;
		if (checked % 50 == 0 || !same)
			LogMessage("VitaGRITimer: " + std::to_string(checked) + " timers compared with the script, " + std::to_string(wrong) + " differ");
	}
	return true;
}

// ---------------------------------------------------------------------------------------------------------------------------
// The menu book's UWindow scripts, natively (apply_fixes.sh #195). The pause menu's pages are painted every frame by UWindow
// scripts at ~2.4 us a statement: the options page ~33 ms a frame, the folio page ~290 ms (3 fps). The folio's description
// (a UWindowWrappedTextArea) walks its whole ring buffer in Paint, ~375 WrapClipText calls on empty lines, twice a frame.
// Each function below does exactly what its script does (@script on the console; the same as the UT-era UWindow source):
//
//   Canvas.SetPos / SetOrigin / SetClip (X, Y):        CurX = X; CurY = Y   (OrgX/OrgY, ClipX/ClipY)
//   UWindowWindow.TextSize(C, Text, out W, out H):     C.SetPos(0, 0); C.TextSize(Text, W, H); W = W / Root.GUIScale; H = H / Root.GUIScale
//   UWindowWindow.ClipText(C, X, Y, S, optional bCheckHotKey):
//       OrgX = C.OrgX; OrgY = C.OrgY; ClipX = C.ClipX; ClipY = C.ClipY;
//       C.SetOrigin(OrgX + ClippingRegion.X * Root.GUIScale, OrgY + ClippingRegion.Y * Root.GUIScale);
//       C.SetClip(ClippingRegion.W * Root.GUIScale, ClippingRegion.H * Root.GUIScale);
//       C.SetPos((X - ClippingRegion.X) * Root.GUIScale, (Y - ClippingRegion.Y) * Root.GUIScale);
//       C.DrawTextClipped(S, bCheckHotKey); C.SetClip(ClipX, ClipY); C.SetOrigin(OrgX, OrgY);
//   UWindowWindow.DrawStretchedTextureSegment(C, X, Y, W, H, tX, tY, tW, tH, Tex): the same frame around
//       C.DrawTileClipped(Tex, W * Root.GUIScale, H * Root.GUIScale, tX, tY, tW, tH)
//   UWindowWindow.WrapClipText(C, X, Y, S, optional bCheckHotKey, Length, PaddingLength, bNoDraw), only for S == "" (other text:
//       the script). Its loop then runs once: Out = "" (Left(S, Length) or S), no space or CR, C.SetPos(0, 0), Temp = "",
//       TextSize(C, "", W, H); with PaddingLength > 0 (Padding = Mid("", ..) = "") TextSize(C, "", pW, pH) and the wrap test
//       W + X + pW > WinWidth && X > 0, else W + X > WinWidth && X > 0 (a wrap: X = 0, Y += H, NumLines++); unless bNoDraw
//       ClipText(C, X, Y, "", bCheckHotKey); Out = "" ends it: NumLines (1, or 2 after a wrap). With Y >= WinHeight the loop
//       does not run at all: 1.
//
// A call goes native only when the object's own function is the one named here (a subclass overriding it gets the script), the
// functions it calls resolve to the ones named here (Canvas subclasses, overridden TextSize/ClipText: the script), the objects
// it reads are there (Root None: the script, which logs Accessed None) and every argument has the type the script expects.
// render.cfg uwindow_natives=0: always the script. uwindow_check=1: the native way first (its results kept aside, the canvas put
// back), then the script, compared ('VitaUWindow: N calls compared with the script, M differ'); the script's results are kept
// and ClipText's text is drawn twice in that mode.

#include "VitaScriptNatives.h"
#include "VM/Frame.h"
#include "VM/NativeFunc.h"
#include "Package/PackageManager.h"
#include "Packages/Engine/UCanvas.h"
#include "Packages/Core/Properties/UStructProperty.h"
#include "Packages/Core/UFunction.h"

namespace
{
	struct UWindowNatives
	{
		bool ready = false, usable = false;
		UClass* canvas = nullptr;
		UFunction* setPos = nullptr, * setOrigin = nullptr, * setClip = nullptr;   // Canvas' script functions
		UFunction* nativeTextSize = nullptr, * drawTextClipped = nullptr, * drawTileClipped = nullptr;   // Canvas' natives
		UClass* window = nullptr;
		UFunction* textSize = nullptr, * clipText = nullptr, * wrapClipText = nullptr, * drawSegment = nullptr;   // UWindowWindow's
		PropertyDataOffset root, winWidth, winHeight, guiScale;
		size_t regionOffset = ~(size_t)0;   // ClippingRegion (X, Y, W, H ints)
		size_t regionX = 0, regionY = 0, regionW = 0, regionH = 0;
		UClass* okCanvasClass = nullptr;     // a canvas class whose SetPos/SetOrigin/SetClip were found to be Canvas' own
		UClass* okWindowClass[8] = {};       // window classes whose TextSize/ClipText were found to be UWindowWindow's own
		UClass* badWindowClass[8] = {};
	} uw;

	UFunction* OwnFunctionOf(UClass* cls, const char* name)
	{
		auto it = cls->Functions.find(NameString(name));
		return it != cls->Functions.end() ? it->second : nullptr;
	}

	bool IsNativeFunc(UFunction* f) { return f && AllFlags(f->FuncFlags, FunctionFlags::Native) && f->NativeFuncIndex != 0 && f->NativeFuncIndex < NativeFunctions::NativeByIndex.size() && NativeFunctions::NativeByIndex[f->NativeFuncIndex]; }

	// the class named so in cls' chain (classes already loaded: nothing is looked up in the packages, which would load them)
	UClass* BaseNamed(UClass* cls, const char* name)
	{
		const NameString wanted(name);
		for (UClass* c = cls; c; c = static_cast<UClass*>(c->BaseStruct))
			if (c->Name == wanted)
				return c;
		return nullptr;
	}

	// Made on the first call of a UWindowWindow function on a window whose Root is set (the menus are up by then)
	void InitUWindow(UObject* window)
	{
		uw.window = BaseNamed(window->Class, "UWindowWindow");
		UObject* root = nullptr;
		if (uw.window)
			for (UProperty* p : uw.window->Properties)
				if (p->Name == NameString("Root") && p->ElementSize() == sizeof(UObject*))
					root = *static_cast<UObject**>(window->GetProperty(p));
		uw.canvas = engine->canvas ? BaseNamed(engine->canvas->Class, "Canvas") : nullptr;
		UClass* rootClass = root ? BaseNamed(root->Class, "UWindowRootWindow") : nullptr;
		if (!uw.canvas || !uw.window || !rootClass)
			return;   // not yet: asked again at the next call
		uw.ready = true;
		uw.setPos = OwnFunctionOf(uw.canvas, "SetPos");
		uw.setOrigin = OwnFunctionOf(uw.canvas, "SetOrigin");
		uw.setClip = OwnFunctionOf(uw.canvas, "SetClip");
		uw.nativeTextSize = OwnFunctionOf(uw.canvas, "TextSize");
		uw.drawTextClipped = OwnFunctionOf(uw.canvas, "DrawTextClipped");
		uw.drawTileClipped = OwnFunctionOf(uw.canvas, "DrawTileClipped");
		uw.textSize = OwnFunctionOf(uw.window, "TextSize");
		uw.clipText = OwnFunctionOf(uw.window, "ClipText");
		uw.wrapClipText = OwnFunctionOf(uw.window, "WrapClipText");
		uw.drawSegment = OwnFunctionOf(uw.window, "DrawStretchedTextureSegment");
		if (!uw.setPos || !uw.setOrigin || !uw.setClip || !IsNativeFunc(uw.nativeTextSize) || !IsNativeFunc(uw.drawTextClipped) ||
			!IsNativeFunc(uw.drawTileClipped) || !uw.textSize || !uw.clipText || !uw.wrapClipText || !uw.drawSegment)
			return;
		UProperty* region = nullptr, * rootProp = nullptr, * width = nullptr, * height = nullptr, * scale = nullptr;
		for (UProperty* p : uw.window->Properties)   // UWindowWindow's own properties (its base, UObject's, have none of these names)
		{
			if (p->Name == NameString("ClippingRegion")) region = p;
			else if (p->Name == NameString("Root")) rootProp = p;
			else if (p->Name == NameString("WinWidth")) width = p;
			else if (p->Name == NameString("WinHeight")) height = p;
		}
		for (UProperty* p : rootClass->Properties)
			if (p->Name == NameString("GUIScale")) scale = p;
		UStructProperty* regionStruct = dynamic_cast<UStructProperty*>(region);
		if (!regionStruct || !regionStruct->Struct || !rootProp || rootProp->ElementSize() != sizeof(UObject*) || !width || !height || !scale ||
			width->ElementSize() != sizeof(float) || height->ElementSize() != sizeof(float) || scale->ElementSize() != sizeof(float))
			return;
		int found = 0;
		for (UProperty* p : regionStruct->Struct->Properties)
		{
			if (p->ElementSize() != sizeof(int32_t))
				return;
			if (p->Name == NameString("X")) { uw.regionX = p->DataOffset.DataOffset; found |= 1; }
			else if (p->Name == NameString("Y")) { uw.regionY = p->DataOffset.DataOffset; found |= 2; }
			else if (p->Name == NameString("W")) { uw.regionW = p->DataOffset.DataOffset; found |= 4; }
			else if (p->Name == NameString("H")) { uw.regionH = p->DataOffset.DataOffset; found |= 8; }
		}
		if (found != 15)
			return;
		uw.regionOffset = region->DataOffset.DataOffset;
		uw.root = rootProp->DataOffset;
		uw.winWidth = width->DataOffset;
		uw.winHeight = height->DataOffset;
		uw.guiScale = scale->DataOffset;
		uw.usable = true;
	}

	bool Settings(int& check)
	{
		static const bool on = VitaConfigInt("uwindow_natives", 1) != 0;
		static const int checkMode = VitaConfigInt("uwindow_check", 0);
		check = checkMode;
		return on;
	}

	// C's SetPos/SetOrigin/SetClip are Canvas' own
	bool CanvasOK(UObject* c)
	{
		if (!c)
			return false;
		if (c->Class == uw.okCanvasClass)
			return true;
		if (FindEventFunction(c, NameString("SetPos")) != uw.setPos || FindEventFunction(c, NameString("SetOrigin")) != uw.setOrigin ||
			FindEventFunction(c, NameString("SetClip")) != uw.setClip || !UObject::TryCast<UCanvas>(c) ||
			FindEventFunction(c, NameString("TextSize")) != uw.nativeTextSize || FindEventFunction(c, NameString("DrawTextClipped")) != uw.drawTextClipped ||
			FindEventFunction(c, NameString("DrawTileClipped")) != uw.drawTileClipped)
			return false;
		if (!c->GetStateName().IsNone())
			return false;
		uw.okCanvasClass = c->Class;
		return true;
	}

	// The window's TextSize and ClipText are UWindowWindow's (WrapClipText calls them)
	bool WindowCallsOK(UObject* w)
	{
		for (UClass* c : uw.okWindowClass)
			if (c == w->Class)
				return true;
		for (UClass* c : uw.badWindowClass)
			if (c == w->Class)
				return false;
		const bool ok = w->GetStateName().IsNone() && FindEventFunction(w, NameString("TextSize")) == uw.textSize &&
			FindEventFunction(w, NameString("ClipText")) == uw.clipText;
		if (!w->GetStateName().IsNone())
			return ok;   // not remembered: a state can change
		UClass** list = ok ? uw.okWindowClass : uw.badWindowClass;
		for (int i = 0; i < 8; i++)
			if (!list[i] || i == 7)
			{
				list[i] = w->Class;
				break;
			}
		return ok;
	}

	struct WindowFrame
	{
		float scale;
		int32_t x, y, w, h;
	};

	// Root.GUIScale and ClippingRegion; false when Root is None
	bool ReadWindow(UObject* w, WindowFrame& f)
	{
		UObject* root = w->Value<UObject*>(uw.root);
		if (!root || !root->IsA(NameString("UWindowRootWindow")))
			return false;
		f.scale = root->Value<float>(uw.guiScale);
		const uint8_t* region = static_cast<const uint8_t*>(w->PropertyData.Ptr(uw.regionOffset));
		std::memcpy(&f.x, region + uw.regionX, 4);
		std::memcpy(&f.y, region + uw.regionY, 4);
		std::memcpy(&f.w, region + uw.regionW, 4);
		std::memcpy(&f.h, region + uw.regionH, 4);
		return true;
	}

	bool IsFloat(const ExpressionValue& v) { return v.GetType() == ExpressionValueType::ValueFloat; }
	bool IsString(const ExpressionValue& v) { return v.GetType() == ExpressionValueType::ValueString; }
	bool IsObjectOrNone(const ExpressionValue& v) { return v.GetType() == ExpressionValueType::ValueObject; }
	// an optional argument: missing / Nothing = its default; else it must have the type
	bool OptBool(const ArrayView<ExpressionValue>& args, size_t i, bool& out)
	{
		out = false;
		if (i >= args.size() || args[i].GetType() == ExpressionValueType::Nothing)
			return true;
		if (args[i].GetType() != ExpressionValueType::ValueBool)
			return false;
		out = args[i].ToBool();
		return true;
	}
	bool OptInt(const ArrayView<ExpressionValue>& args, size_t i, int32_t& out)
	{
		out = 0;
		if (i >= args.size() || args[i].GetType() == ExpressionValueType::Nothing)
			return true;
		if (args[i].GetType() != ExpressionValueType::ValueInt)
			return false;
		out = args[i].ToInt();
		return true;
	}

	// A Canvas native called as the script calls it (Frame::Call's frameless native path)
	void CallNative(UFunction* f, UObject* self, ExpressionValue* a)
	{
		try
		{
			NativeFunctions::NativeByIndex[f->NativeFuncIndex](self, a);
		}
		catch (const std::exception& e)
		{
			LogMessage(std::string("Script error: ") + e.what());
		}
		catch (...)
		{
			LogMessage("Script error: Unknown error");
		}
	}

	void DoTextSize(UCanvas* c, const WindowFrame& f, const std::string& text, float& w, float& h)
	{
		c->CurX() = 0.0f;
		c->CurY() = 0.0f;
		ExpressionValue a[3] = { ExpressionValue::StringValue(text), ExpressionValue::FloatValue(0.0f), ExpressionValue::FloatValue(0.0f) };
		CallNative(uw.nativeTextSize, c, a);
		w = a[1].ToFloat() / f.scale;
		h = a[2].ToFloat() / f.scale;
	}

	// the frame of ClipText and DrawStretchedTextureSegment around one canvas native
	template<typename Draw>
	void InClippingRegion(UCanvas* c, const WindowFrame& f, float x, float y, Draw draw)
	{
		const float orgX = c->OrgX(), orgY = c->OrgY(), clipX = c->ClipX(), clipY = c->ClipY();
		const float ox = (float)f.x * f.scale;
		const float oy = (float)f.y * f.scale;
		c->OrgX() = orgX + ox;
		c->OrgY() = orgY + oy;
		c->ClipX() = (float)f.w * f.scale;
		c->ClipY() = (float)f.h * f.scale;
		const float px = x - (float)f.x;
		const float py = y - (float)f.y;
		c->CurX() = px * f.scale;
		c->CurY() = py * f.scale;
		draw();
		c->ClipX() = clipX;
		c->ClipY() = clipY;
		c->OrgX() = orgX;
		c->OrgY() = orgY;
	}

	void DoClipText(UCanvas* c, const WindowFrame& f, float x, float y, const std::string& s, bool hotKey)
	{
		InClippingRegion(c, f, x, y, [&]
		{
			ExpressionValue a[2] = { ExpressionValue::StringValue(s), ExpressionValue::BoolValue(hotKey) };
			CallNative(uw.drawTextClipped, c, a);
		});
	}

	bool CanvasSetPair(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result, int which)
	{
		UCanvas* c = UObject::TryCast<UCanvas>(self);
		if (!c || args.size() < 2 || !IsFloat(args[0]) || !IsFloat(args[1]))
			return false;
		const float x = args[0].ToFloat(), y = args[1].ToFloat();
		if (which == 0) { c->CurX() = x; c->CurY() = y; }
		else if (which == 1) { c->OrgX() = x; c->OrgY() = y; }
		else { c->ClipX() = x; c->ClipY() = y; }
		result = ExpressionValue::NothingValue();
		return true;
	}
	bool NSetPos(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result) { return CanvasSetPair(self, args, result, 0); }
	bool NSetOrigin(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result) { return CanvasSetPair(self, args, result, 1); }
	bool NSetClip(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result) { return CanvasSetPair(self, args, result, 2); }

	bool NTextSize(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result)
	{
		WindowFrame f;
		if (args.size() < 4 || !IsObjectOrNone(args[0]) || !IsString(args[1]) || !IsFloat(args[2]) || !IsFloat(args[3]))
			return false;
		UObject* c = args[0].ToObject();
		if (!CanvasOK(c) || !ReadWindow(self, f))
			return false;
		float w, h;
		DoTextSize(static_cast<UCanvas*>(c), f, args[1].ToString(), w, h);
		args[2].Store(ExpressionValue::FloatValue(w));
		args[3].Store(ExpressionValue::FloatValue(h));
		result = ExpressionValue::NothingValue();
		return true;
	}

	bool NClipText(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result)
	{
		WindowFrame f;
		bool hotKey;
		if (args.size() < 4 || !IsObjectOrNone(args[0]) || !IsFloat(args[1]) || !IsFloat(args[2]) || !IsString(args[3]) || !OptBool(args, 4, hotKey))
			return false;
		UObject* c = args[0].ToObject();
		if (!CanvasOK(c) || !ReadWindow(self, f))
			return false;
		DoClipText(static_cast<UCanvas*>(c), f, args[1].ToFloat(), args[2].ToFloat(), args[3].ToString(), hotKey);
		result = ExpressionValue::NothingValue();
		return true;
	}

	bool NDrawSegment(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result)
	{
		WindowFrame f;
		if (args.size() < 10 || !IsObjectOrNone(args[0]) || !IsObjectOrNone(args[9]))
			return false;
		for (size_t i = 1; i <= 8; i++)
			if (!IsFloat(args[i]))
				return false;
		UObject* c = args[0].ToObject();
		if (!CanvasOK(c) || !ReadWindow(self, f))
			return false;
		UCanvas* canvas = static_cast<UCanvas*>(c);
		InClippingRegion(canvas, f, args[1].ToFloat(), args[2].ToFloat(), [&]
		{
			const float w = args[3].ToFloat() * f.scale;
			const float h = args[4].ToFloat() * f.scale;
			ExpressionValue a[7] = { ExpressionValue::ObjectValue(args[9].ToObject()), ExpressionValue::FloatValue(w), ExpressionValue::FloatValue(h),
				ExpressionValue::FloatValue(args[5].ToFloat()), ExpressionValue::FloatValue(args[6].ToFloat()),
				ExpressionValue::FloatValue(args[7].ToFloat()), ExpressionValue::FloatValue(args[8].ToFloat()) };
			CallNative(uw.drawTileClipped, canvas, a);
		});
		result = ExpressionValue::NothingValue();
		return true;
	}

	bool NWrapClipText(UObject* self, const ArrayView<ExpressionValue>& args, ExpressionValue& result)
	{
		WindowFrame f;
		bool hotKey, noDraw;
		int32_t length, paddingLength;
		if (args.size() < 4 || !IsObjectOrNone(args[0]) || !IsFloat(args[1]) || !IsFloat(args[2]) || !IsString(args[3]) || !args[3].ToString().empty() ||
			!OptBool(args, 4, hotKey) || !OptInt(args, 5, length) || !OptInt(args, 6, paddingLength) || !OptBool(args, 7, noDraw))
			return false;
		float x = args[1].ToFloat(), y = args[2].ToFloat();
		int numLines = 1;
		if (!(y < self->Value<float>(uw.winHeight)))
		{
			result = ExpressionValue::IntValue(numLines);
			return true;
		}
		UObject* c = args[0].ToObject();
		if (!CanvasOK(c) || !WindowCallsOK(self) || !ReadWindow(self, f))
			return false;
		UCanvas* canvas = static_cast<UCanvas*>(c);
		const float winWidth = self->Value<float>(uw.winWidth);
		canvas->CurX() = 0.0f;   // C.SetPos(0, 0)
		canvas->CurY() = 0.0f;
		float w, h;
		DoTextSize(canvas, f, std::string(), w, h);
		if (paddingLength > 0)
		{
			float pw, ph;
			DoTextSize(canvas, f, std::string(), pw, ph);
			const float wx = w + x;
			if (wx + pw > winWidth && x > 0.0f)
			{
				x = 0.0f;
				y += h;
				numLines++;
			}
		}
		else if (w + x > winWidth && x > 0.0f)
		{
			x = 0.0f;
			y += h;
			numLines++;
		}
		if (!noDraw)
			DoClipText(canvas, f, x, y, std::string(), hotKey);
		result = ExpressionValue::IntValue(numLines);
		return true;
	}

	struct CanvasState
	{
		UCanvas* c = nullptr;
		float v[6] = {};
		void Save(UObject* o)
		{
			c = UObject::TryCast<UCanvas>(o);
			if (c)
			{
				v[0] = c->CurX(); v[1] = c->CurY(); v[2] = c->OrgX(); v[3] = c->OrgY(); v[4] = c->ClipX(); v[5] = c->ClipY();
			}
		}
		void Restore() const
		{
			if (c)
			{
				c->CurX() = v[0]; c->CurY() = v[1]; c->OrgX() = v[2]; c->OrgY() = v[3]; c->ClipX() = v[4]; c->ClipY() = v[5];
			}
		}
		bool Same(const CanvasState& o) const { return c == o.c && std::memcmp(v, o.v, sizeof(v)) == 0; }
	};
}

int VitaFindScriptNative(UFunction* func, UObject* instance, VitaScriptNativeFn& fn)
{
	fn = nullptr;
	int check;
	if (!Settings(check) || AllFlags(func->FuncFlags, FunctionFlags::Singular))
		return 0;
	static const NameString names[7] = { NameString("SetPos"), NameString("SetOrigin"), NameString("SetClip"), NameString("TextSize"),
		NameString("ClipText"), NameString("DrawStretchedTextureSegment"), NameString("WrapClipText") };
	int which = -1;
	for (int i = 0; i < 7; i++)
		if (func->Name == names[i])
			which = i;
	if (which < 0)
		return 0;   // never one of these
	if (!uw.ready)
	{
		if (which < 3 || !instance)
			return -1;   // a Canvas function before the first window call: decided later
		InitUWindow(instance);
		if (!uw.ready)
			return -1;
	}
	if (!uw.usable)
		return 0;
	static const int mask = VitaConfigInt("uwindow_mask", 127);   // a bit per function, in this order (finding a wrong one)
	UFunction* funcs[7] = { uw.setPos, uw.setOrigin, uw.setClip, uw.textSize, uw.clipText, uw.drawSegment, uw.wrapClipText };
	VitaScriptNativeFn natives[7] = { &NSetPos, &NSetOrigin, &NSetClip, &NTextSize, &NClipText, &NDrawSegment, &NWrapClipText };
	if (func != funcs[which] || !(mask & (1 << which)))
		return 0;
	fn = natives[which];
	return 1;
}

// true: done natively, result set
bool VitaRunScriptNative(VitaScriptNativeFn fn, UFunction* func, UObject* instance, const ArrayView<ExpressionValue>& args, ExpressionValue& result)
{
	static bool inCheck = false;
	if (inCheck)
		return false;
	int check;
	Settings(check);
	if (!check)
		return fn(instance, args, result);

	// uwindow_check=1: the native way, its results kept aside and everything it changed put back; then the script, compared
	CanvasState before, nativeCanvas, scriptCanvas;
	before.Save(UObject::TryCast<UCanvas>(instance) ? instance : (args.size() ? args[0].ToObject() : nullptr));
	std::vector<float> outsBefore, outsNative, outsScript;
	for (size_t i = 0; i < args.size(); i++)
		if (args[i].GetType() == ExpressionValueType::ValueFloat)
			outsBefore.push_back(args[i].ToFloat());
	ExpressionValue nativeResult;
	if (!fn(instance, args, nativeResult))
		return false;
	nativeCanvas.Save(before.c);
	for (size_t i = 0; i < args.size(); i++)
		if (args[i].GetType() == ExpressionValueType::ValueFloat)
			outsNative.push_back(args[i].ToFloat());
	before.Restore();
	for (size_t i = 0, k = 0; i < args.size(); i++)   // out floats back as they were (the others are values: unchanged)
		if (args[i].GetType() == ExpressionValueType::ValueFloat)
			args[i].Store(ExpressionValue::FloatValue(outsBefore[k++]));
	inCheck = true;
	result = Frame::Call(func, instance, args);
	inCheck = false;
	scriptCanvas.Save(before.c);
	for (size_t i = 0; i < args.size(); i++)
		if (args[i].GetType() == ExpressionValueType::ValueFloat)
			outsScript.push_back(args[i].ToFloat());
	const bool sameResult = nativeResult.GetType() == result.GetType() &&
		(result.GetType() != ExpressionValueType::ValueInt || nativeResult.ToInt() == result.ToInt());
	const bool same = sameResult && nativeCanvas.Same(scriptCanvas) && std::memcmp(outsNative.data(), outsScript.data(), outsNative.size() * sizeof(float)) == 0 &&
		outsNative.size() == outsScript.size();
	static unsigned checked = 0, wrong = 0;
	checked++;
	if (!same)
		wrong++;
	if (checked % 2000 == 0 || (!same && wrong < 50))
		LogMessage("VitaUWindow: " + std::to_string(checked) + " calls compared with the script, " + std::to_string(wrong) + " differ" +
			(same ? std::string() : " (last: " + func->Name.ToString() + ")"));
	return true;
}
