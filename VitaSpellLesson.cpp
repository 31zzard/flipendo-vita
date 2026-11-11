// Spell lessons on the Vita (HPBase.SpellLearnTrigger, docs/re/hp1/spells.md "Spell lesson flow").
//
// On the PC the spell's shape is traced with the mouse; with a stick most shapes are close to impossible. The lesson's
// Draw state moves the wand every Tick by the mouse (SmoothMouseX/Y) and the keys (asidemove/aformove), and while
// AltFire is held it stores the point (WandX + 0.5, 0.5 - WandY) for the judge (CompareGesture: how near the points
// are to the template and how much of the template they cover; the order does not count). Two easier ways, both
// working through the script's own variables, so the judge, the sounds and the particles are the game's:
//
// - Touch (render.cfg spell_touch=1): a finger on the front touch screen IS the wand. The wand goes where the finger
//   is (the template shows on the screen exactly where it will be judged), the finger down is AltFire held, lifting it
//   ends the drawing as releasing the button does.
// - Rails (spell_assist=1, for the sticks): while the cast button is held the wand stays on the template's line. Either
//   stick moves it along the line: pushed roughly the line's way it goes forward, pushed against it back; a push across
//   the line (a corner) goes forward. Full stick goes over the whole shape in spell_speed percent of the lesson's time
//   (60). spell_assist=0: the original stick drawing.
// - spell_time (percent, 100): the lesson's DrawTime (the countdown) made longer once per lesson.
//
// Tick of the Draw state is wrapped (HP1::Mods::WrapScriptFunction) from VitaTickSpellLesson, called by HP1::TickMods.

#include "Precomp.h"
#include "VitaConfig.h"
#include "KW.h"
#include "KWParticleFX.h"
#include "mods/HP1Mods.h"
#include "Packages/Core/UObject.h"
#include "Packages/Core/UClass.h"
#include "Packages/Core/UFunction.h"
#include "Packages/Engine/Actors/Pawn/UPlayerPawn.h"
#include "Packages/Engine/UViewport.h"
#include "Package/PackageManager.h"
#include "VM/Frame.h"
#include "Utils/Logger.h"
#include "Engine.h"

#include <psp2/ctrl.h>
#include <psp2/touch.h>
#include <algorithm>
#include <cmath>
#include <vector>

namespace
{
	UClass* LessonClass = nullptr;
	UFunction* DrawTick = nullptr;

	// The lesson being drawn (one Draw state): what was set up for it
	UObject* CurrentLesson = nullptr;
	UObject* TimeScaledLesson = nullptr;
	float RailPos = -1.0f;        // where the wand is on the template's line (length along it), -1: not on it yet
	bool TouchForcedFire = false; // bAltFire set by the finger
	bool LoggedOnce = false;
	unsigned TickCount = 0;        // VitaTickSpellLesson's frames
	unsigned DrawTickFrame = 0;    // the frame Draw's Tick last ran in

	bool TouchOn() { static const bool on = VitaConfigInt("spell_touch", 1) != 0; return on; }
	bool AssistOn() { static const bool on = VitaConfigInt("spell_assist", 1) != 0; return on; }
	float SpeedPercent() { static const float p = (float)std::clamp(VitaConfigInt("spell_speed", 60), 10, 400); return p; }
	float TimePercent() { static const float p = (float)std::clamp(VitaConfigInt("spell_time", 100), 50, 400); return p; }

	template<typename T> T* Prop(UObject* obj, const char* name)
	{
		return obj && obj->HasProperty(name) ? static_cast<T*>(obj->GetProperty(name)) : nullptr;
	}

	struct Vec2 { float x, y; };

	// The template's line in gesture space (0..1, y down)
	struct Rail
	{
		std::vector<Vec2> points;
		std::vector<float> start;   // length along the line where each segment starts
		float length = 0.0f;

		explicit Rail(UObject* gesture)
		{
			if (!gesture)
				return;
			TypedScriptArray<vec3> src = KW::GesturePoints(gesture);
			for (size_t i = 0; i < src.size(); i++)
			{
				Vec2 p = { src[i].x, src[i].y };
				if (!points.empty() && std::abs(points.back().x - p.x) < 1e-5f && std::abs(points.back().y - p.y) < 1e-5f)
					continue;
				points.push_back(p);
			}
			for (size_t i = 0; i + 1 < points.size(); i++)
			{
				start.push_back(length);
				length += std::hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y);
			}
		}

		bool Usable() const { return points.size() >= 2 && length > 1e-4f; }

		size_t SegmentAt(float s) const
		{
			size_t i = std::upper_bound(start.begin(), start.end(), s) - start.begin();
			return i == 0 ? 0 : std::min(i - 1, start.size() - 1);
		}

		Vec2 At(float s) const
		{
			size_t i = SegmentAt(s);
			float segLen = (i + 1 < start.size() ? start[i + 1] : length) - start[i];
			float t = segLen > 0.0f ? std::clamp((s - start[i]) / segLen, 0.0f, 1.0f) : 0.0f;
			return { points[i].x + (points[i + 1].x - points[i].x) * t, points[i].y + (points[i + 1].y - points[i].y) * t };
		}

		Vec2 Tangent(size_t i) const
		{
			float dx = points[i + 1].x - points[i].x, dy = points[i + 1].y - points[i].y;
			float len = std::hypot(dx, dy);
			return len > 0.0f ? Vec2{ dx / len, dy / len } : Vec2{ 1.0f, 0.0f };
		}

		// Length along the line of the point of the line nearest to p
		float Nearest(Vec2 p) const
		{
			float best = 1e30f, bestS = 0.0f;
			for (size_t i = 0; i + 1 < points.size(); i++)
			{
				float dx = points[i + 1].x - points[i].x, dy = points[i + 1].y - points[i].y;
				float len2 = dx * dx + dy * dy;
				float t = len2 > 0.0f ? std::clamp(((p.x - points[i].x) * dx + (p.y - points[i].y) * dy) / len2, 0.0f, 1.0f) : 0.0f;
				float qx = points[i].x + dx * t - p.x, qy = points[i].y + dy * t - p.y;
				float d = qx * qx + qy * qy;
				if (d < best)
				{
					best = d;
					bestS = start[i] + std::sqrt(len2) * t;
				}
			}
			return bestS;
		}
	};

	// A stick, -1..1 with a dead zone (Vita sticks rest near 128)
	float StickAxis(unsigned char v)
	{
		float a = (v - 127.5f) / 127.5f;
		const float dead = 0.2f;
		if (std::abs(a) < dead)
			return 0.0f;
		return (a > 0 ? a - dead : a + dead) / (1.0f - dead);
	}

	void CallOriginal(UFunction* original, UObject* self, ExpressionValue* args)
	{
		size_t count = 0;
		for (UProperty* prop : original->Properties)
		{
			if (!AllFlags(prop->PropFlags, PropertyFlags::Parm))
				continue;
			if (args[count].GetType() == ExpressionValueType::Nothing)
				break;
			count++;
		}
		Frame::Call(original, self, ArrayView<ExpressionValue>(args, count));
	}

	void NDrawTick(UObject* self, ExpressionValue* args)
	{
		UPlayerPawn* player = UObject::TryCast<UPlayerPawn>(KW::ObjectProperty(self, "Player"));
		float* wandX = Prop<float>(self, "WandX");
		float* wandY = Prop<float>(self, "WandY");
		float* fovRatio = Prop<float>(self, "FOVRatio");
		float* drawTime = Prop<float>(self, "DrawTime");
		float* timeDrawn = Prop<float>(self, "TimeDrawn");
		float* sideMove = Prop<float>(player, "asidemove");
		float* forMove = Prop<float>(player, "aformove");
		DrawTickFrame = TickCount;
		if (!player || !wandX || !wandY || !fovRatio || !drawTime || !timeDrawn || *fovRatio <= 0.0f)
		{
			CallOriginal(DrawTick, self, args);
			return;
		}

		if (self != CurrentLesson || *timeDrawn == 0.0f)
		{
			// A new drawing (each level of the lesson is a new Draw)
			CurrentLesson = self;
			RailPos = -1.0f;
			TouchForcedFire = false;
			if (self != TimeScaledLesson && TimePercent() != 100.0f)
			{
				TimeScaledLesson = self;
				*drawTime *= TimePercent() / 100.0f;
			}
			if (!LoggedOnce)
			{
				LoggedOnce = true;
				LogMessage("Spell lesson: touch " + std::string(TouchOn() ? "on" : "off") + ", stick rails " + (AssistOn() ? "on" : "off") +
					", speed " + std::to_string((int)SpeedPercent()) + "%, time " + std::to_string((int)TimePercent()) + "%");
			}
		}

		const float deltaTime = args[0].ToFloat();
		const float W = 960.0f, H = 544.0f;
		const float projZ = std::tan(radians(engine->CameraFovAngle) * 0.5f);
		bool driven = false;   // the wand placed here: the script must not move it again

		// The finger: the wand where it is on the screen
		if (TouchOn())
		{
			SceTouchData touch = {};
			if (sceTouchPeek(SCE_TOUCH_PORT_FRONT, &touch, 1) > 0 && touch.reportNum > 0)
			{
				float sx = touch.report[0].x * 0.5f;   // the front panel is 1920 x 1088
				float sy = touch.report[0].y * 0.5f;
				*wandX = std::clamp((sx - W * 0.5f) / (W * 0.5f) * projZ / *fovRatio, -1.0f, 1.0f);
				*wandY = std::clamp(-(sy - H * 0.5f) / (W * 0.5f) * projZ / *fovRatio, -1.0f, 1.0f);
				if (player->bAltFire() == 0)
				{
					player->bAltFire() = 1;
					TouchForcedFire = true;
				}
				driven = true;
			}
			else if (TouchForcedFire)
			{
				// The finger lifted: the drawing ends as when the button is released
				player->bAltFire() = 0;
				TouchForcedFire = false;
			}
		}

		// The sticks with the cast button held: along the template's line
		if (!driven && AssistOn() && player->bAltFire() != 0)
		{
			Rail rail(KW::ObjectProperty(self, "SpellGesture"));
			if (rail.Usable())
			{
				Vec2 here = { *wandX + 0.5f, 0.5f - *wandY };
				if (RailPos < 0.0f)
					RailPos = rail.Nearest(here);

				SceCtrlData ctrl = {};
				sceCtrlPeekBufferPositive(0, &ctrl, 1);
				Vec2 stick = { StickAxis(ctrl.rx), StickAxis(ctrl.ry) };
				if (stick.x == 0.0f && stick.y == 0.0f)
					stick = { StickAxis(ctrl.lx), StickAxis(ctrl.ly) };
				float push = std::min(std::hypot(stick.x, stick.y), 1.0f);
				if (push > 0.0f)
				{
					Vec2 t = rail.Tangent(rail.SegmentAt(RailPos));
					float along = (stick.x * t.x + stick.y * t.y) / std::hypot(stick.x, stick.y);
					float dir = std::abs(along) >= 0.5f ? (along > 0.0f ? 1.0f : -1.0f) : 1.0f;
					float speed = rail.length / std::max(*drawTime * SpeedPercent() / 100.0f, 0.1f);
					RailPos = std::clamp(RailPos + dir * push * speed * deltaTime, 0.0f, rail.length);
				}
				Vec2 p = rail.At(RailPos);
				*wandX = p.x - 0.5f;
				*wandY = 0.5f - p.y;
				driven = true;
			}
		}

		if (!driven)
		{
			if (player->bAltFire() == 0)
				RailPos = -1.0f;
			CallOriginal(DrawTick, self, args);
			return;
		}

		// The script stores the point and moves the wand's actors; no mouse or key movement on top
		float saved[4] = { player->SmoothMouseX(), player->SmoothMouseY(), sideMove ? *sideMove : 0.0f, forMove ? *forMove : 0.0f };
		player->SmoothMouseX() = 0.0f;
		player->SmoothMouseY() = 0.0f;
		if (sideMove) *sideMove = 0.0f;
		if (forMove) *forMove = 0.0f;
		CallOriginal(DrawTick, self, args);
		player->SmoothMouseX() = saved[0];
		player->SmoothMouseY() = saved[1];
		if (sideMove) *sideMove = saved[2];
		if (forMove) *forMove = saved[3];
	}
}

extern bool VitaWandDrawing;   // vita_input.cpp: the sticks move the wand (the mouse) while a lesson's Draw state runs

// Called by HP1::TickMods every frame (apply_fixes.sh #81)
void VitaTickSpellLesson()
{
	VitaWandDrawing = TickCount - DrawTickFrame <= 1 && DrawTickFrame != 0;
	if (!TouchOn() && !AssistOn() && TimePercent() == 100.0f)
		return;
	UClass* cls = engine->packages->FindClass("HPBase.SpellLearnTrigger");
	if (cls && cls != LessonClass)
	{
		LessonClass = cls;
		DrawTick = HP1::Mods::WrapScriptFunction(cls, "Draw", "Tick", &NDrawTick);
		LogMessage(std::string("Spell lesson: Draw.Tick ") + (DrawTick ? "wrapped" : "not found"));
	}
	TickCount++;
	if (TouchForcedFire && TickCount - DrawTickFrame > 1)
	{
		// Draw is over (judged, skipped, the level left) with the finger still down: give the button back. The lesson
		// itself may be gone: only the player the viewport has is touched.
		if (engine->viewport && engine->viewport->Actor())
			engine->viewport->Actor()->bAltFire() = 0;
		TouchForcedFire = false;
	}
}
