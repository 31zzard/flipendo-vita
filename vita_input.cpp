// Vita input for the SDL2 window.
//
//   left stick     walk (the arrow keys); in the menus and while a spell lesson is drawn it is a second right stick
//   right stick    mouse cursor in the menus, camera in the game, the wand in a spell lesson
//   cross, R       left mouse button (select in the menus, cast the spell in the game)
//   circle, L      right mouse button (jump)
//   front touch    in the menus (title menu, pause menu): the finger is the mouse, touching = left button held
//   d-pad, square, triangle, start, select: keys, see GameControllerButtonToInputKey in sdl2_display_window.cpp
//
// The engine's menus follow the *absolute* mouse position (Engine::OnWindowMouseMove). On a Vita that position
// comes from the touch screen (SDL turns touches into mouse motion) or from the right stick here.
//
// These functions are called from sdl2_display_window.cpp through small hooks added by apply_fixes.sh.

#include "sdl2_display_window.h"
#include "VitaConfig.h"
#include <psp2/touch.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>

// Set by the engine every frame (Engine::TickWindow, apply_fixes.sh #217): a UWindow menu shows its mouse (title and pause menus).
// HP1 keeps the cursor 'locked' there too, so CursorLocked can't tell.
bool VitaMenuMouse = false;
// Set by VitaTickSpellLesson: a spell lesson's Draw state is running (the wand follows the mouse)
bool VitaWandDrawing = false;

namespace
{
	double cursorX = 480.0;   // the cursor, in window pixels
	double cursorY = 272.0;
	bool started = false;
	Uint32 lastTicks = 0;
	double rawRemainderX = 0.0;
	double rawRemainderY = 0.0;
	SDL_GameController* pad = nullptr;

	int leftHeld = 0;    // how many buttons hold the left mouse button down (cross, R and a finger in the menus)
	int rightHeld = 0;   // ... the right mouse button (circle and L)
	bool stickKeyDown[4] = {};   // up, down, left, right, pressed by the left stick
	bool touchHeld = false;      // a finger on the front screen holds the left mouse button (menus)

	// pixels per second at full stick, and mouse counts per second at full stick (camera)
	const double CursorSpeed = 520.0;

	// Measured 2026-11-11 (bench cam_speed, Lev_Tut1): 900 counts a second turned the camera ~126 degrees a second at the
	// options page's highest Mouse Sensitivity (10) and ~38 at the default (3): too slow. 2700 (3x) was too fast
	// for the user; 1350 (1.5x) gives ~57 / 95 / 190 degrees a second at 3 / 5 / 10. render.cfg camera_speed (percent of 1350,
	// 25..400) for players who want it otherwise.
	double CameraSpeed()
	{
		static const double speed = 1350.0 * std::clamp(VitaConfigInt("camera_speed", 100), 25, 400) / 100.0;
		return speed;
	}

	// The camera's response: a little tilt turns slowly (aiming), full tilt turns at CameraSpeed
	double CameraCurve(double v)
	{
		return v * std::sqrt(std::abs(v));
	}
	const double WalkThreshold = 0.35;

	SDL2DisplayWindow* FirstWindow()
	{
		auto& windows = SDL2DisplayWindow::WindowList;
		return windows.empty() ? nullptr : windows.begin()->second;
	}

	SDL_GameController* GetPad()
	{
		if (pad && SDL_GameControllerGetAttached(pad))
			return pad;

		pad = nullptr;
		for (int i = 0; i < SDL_NumJoysticks(); i++)
		{
			if (SDL_IsGameController(i))
			{
				pad = SDL_GameControllerOpen(i);
				if (pad)
					break;
			}
		}
		return pad;
	}

	// -1..1 with a dead zone
	double Axis(SDL_GameController* controller, SDL_GameControllerAxis axis)
	{
		const int deadZone = 6000;
		int value = SDL_GameControllerGetAxis(controller, axis);
		if (std::abs(value) < deadZone)
			return 0.0;
		return (value > 0 ? value - deadZone : value + deadZone) / (32767.0 - deadZone);
	}

	Point CursorPoint(SDL2DisplayWindow* window)
	{
		double uiscale = window->GetDpiScale();
		return Point(cursorX / uiscale, cursorY / uiscale);
	}

	// The front touch screen in the menus. SDL turns no touch into mouse clicks here, so buttons and sliders of the title and pause
	// menus did not react to a finger. While a UWindow menu shows its mouse (VitaMenuMouse) the finger
	// moves the cursor and holds the left mouse button: a tap clicks, a drag drags a slider, lifting releases it (the options
	// page's sliders take their value at that release). In the game the touch is left to the spell lessons.
	// render.cfg menu_touch=0 turns it off.
	void TouchInMenus(SDL2DisplayWindow* window, int width, int height)
	{
		static const bool on = VitaConfigInt("menu_touch", 1) != 0;
		static bool sampling = false;
		if (!on)
			return;
		if (!sampling)
		{
			sceTouchSetSamplingState(SCE_TOUCH_PORT_FRONT, SCE_TOUCH_SAMPLING_STATE_START);
			sampling = true;
		}

		SceTouchData touch = {};
		bool finger = VitaMenuMouse && sceTouchPeek(SCE_TOUCH_PORT_FRONT, &touch, 1) > 0 && touch.reportNum > 0;
		if (finger)
		{
			cursorX = std::clamp(touch.report[0].x * 0.5, 0.0, (double)(width - 1));   // the front panel is 1920 x 1088
			cursorY = std::clamp(touch.report[0].y * 0.5, 0.0, (double)(height - 1));
			window->WindowHost->OnWindowMouseMove(CursorPoint(window));
			if (!touchHeld)
			{
				touchHeld = true;
				if (leftHeld++ == 0)
					window->WindowHost->OnWindowMouseDown(CursorPoint(window), InputKey::LeftMouse);
			}
		}
		else if (touchHeld)
		{
			touchHeld = false;
			if (leftHeld > 0 && --leftHeld == 0)
				window->WindowHost->OnWindowMouseUp(CursorPoint(window), InputKey::LeftMouse);
		}
	}

	// The left stick presses the arrow keys: forward, back, left, right
	// (walking false: the stick is the mouse now; keys it holds are let go)
	void WalkWithLeftStick(SDL2DisplayWindow* window, SDL_GameController* controller, bool walking)
	{
		static const InputKey keys[4] = { InputKey::Up, InputKey::Down, InputKey::Left, InputKey::Right };

		double lx = walking ? Axis(controller, SDL_CONTROLLER_AXIS_LEFTX) : 0.0;
		double ly = walking ? Axis(controller, SDL_CONTROLLER_AXIS_LEFTY) : 0.0;
		bool want[4] = { ly < -WalkThreshold, ly > WalkThreshold, lx < -WalkThreshold, lx > WalkThreshold };

		for (int i = 0; i < 4; i++)
		{
			if (want[i] == stickKeyDown[i])
				continue;
			stickKeyDown[i] = want[i];
			if (want[i])
				window->WindowHost->OnWindowKeyDown(keys[i]);
			else
				window->WindowHost->OnWindowKeyUp(keys[i]);
		}
	}
}

// Called once per frame, after the SDL events were handled
void VitaPollPad()
{
	// A bench run (VITA_BENCH=1 in env.txt, vita/tools/vitarun.py) takes no input from the sticks: a stick that drifts or is
	// touched would move the camera and change what is measured. The scenario's own input (HP1_KEYS, HP1_MOUSE) still works.
	static int benchRun = -1;
	if (benchRun < 0)
	{
		const char* bench = getenv("VITA_BENCH");
		benchRun = (bench && *bench && *bench != '0') ? 1 : 0;
	}
	if (benchRun)
		return;

	SDL2DisplayWindow* window = FirstWindow();
	if (!window || !window->WindowHost)
		return;

	int width = 960, height = 544;
	SDL_GetWindowSize(window->Handle.window, &width, &height);

	if (!started)
	{
		// The first time: put the cursor in the middle (it would sit at the top left corner otherwise)
		started = true;
		cursorX = width * 0.5;
		cursorY = height * 0.5;
		lastTicks = SDL_GetTicks();
		window->WindowHost->OnWindowMouseMove(CursorPoint(window));
		return;
	}

	Uint32 now = SDL_GetTicks();
	double dt = std::min((now - lastTicks) / 1000.0, 0.1);
	lastTicks = now;

	TouchInMenus(window, width, height);

	SDL_GameController* controller = GetPad();
	if (!controller)
		return;

	// In the menus and while a spell lesson is drawn the left stick does what the right one does (the right one wins when both are
	// pushed); otherwise it walks
	const bool leftIsMouse = VitaMenuMouse || VitaWandDrawing;
	WalkWithLeftStick(window, controller, !leftIsMouse);

	double rx = Axis(controller, SDL_CONTROLLER_AXIS_RIGHTX);
	double ry = Axis(controller, SDL_CONTROLLER_AXIS_RIGHTY);
	if (rx == 0.0 && ry == 0.0 && leftIsMouse)
	{
		rx = Axis(controller, SDL_CONTROLLER_AXIS_LEFTX);
		ry = Axis(controller, SDL_CONTROLLER_AXIS_LEFTY);
	}
	if (rx == 0.0 && ry == 0.0)
		return;

	// The cursor: always, so the menus follow the stick whatever the engine thinks about locking the cursor
	cursorX = std::clamp(cursorX + rx * CursorSpeed * dt, 0.0, (double)(width - 1));
	cursorY = std::clamp(cursorY + ry * CursorSpeed * dt, 0.0, (double)(height - 1));
	window->WindowHost->OnWindowMouseMove(CursorPoint(window));

	// The camera: relative movement, when the engine has locked the cursor (in the game)
	if (window->CursorLocked)
	{
		rawRemainderX += CameraCurve(rx) * CameraSpeed() * dt;
		rawRemainderY += CameraCurve(ry) * CameraSpeed() * dt;
		int dx = (int)rawRemainderX;
		int dy = (int)rawRemainderY;
		rawRemainderX -= dx;
		rawRemainderY -= dy;
		if (dx != 0 || dy != 0)
			window->WindowHost->OnWindowRawMouseMove(dx, dy);
	}
}

// Whether the pad holds a key down that it presents as a mouse button or an arrow key. SDL's keyboard state knows nothing of them,
// and a game that asks for a held key (HP2's Actor.GetCurrentKeyState: the cast lets Harry walk only while a mouse button is down,
// docs/re/hp2/gameplay.md) must see them held. Called from SDL2DisplayWindow::GetKeyState (apply_fixes.sh #79).
bool VitaKeyHeld(InputKey key)
{
	switch (key)
	{
	case InputKey::LeftMouse: return leftHeld > 0;
	case InputKey::RightMouse: return rightHeld > 0;
	case InputKey::Up: return stickKeyDown[0];
	case InputKey::Down: return stickKeyDown[1];
	case InputKey::Left: return stickKeyDown[2];
	case InputKey::Right: return stickKeyDown[3];
	default: return false;
	}
}

// The touch screen moved the mouse: keep the stick's cursor where the finger is
void VitaPadCursorMoved(int x, int y)
{
	cursorX = x;
	cursorY = y;
	started = true;
}

// Cross and R are the left mouse button, circle and L the right one. (Their keys are switched off in
// GameControllerButtonToInputKey, so nothing else happens when they are pressed.)
void VitaPadButton(SDL2DisplayWindow* window, int button, bool down)
{
	if (!window || !window->WindowHost)
		return;

	int* held = nullptr;
	InputKey key = InputKey::None;
	switch (button)
	{
	case SDL_CONTROLLER_BUTTON_A:
	case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
		held = &leftHeld;
		key = InputKey::LeftMouse;
		break;
	case SDL_CONTROLLER_BUTTON_B:
	case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
		held = &rightHeld;
		key = InputKey::RightMouse;
		break;
	default:
		return;
	}

	if (down)
	{
		if ((*held)++ == 0)
			window->WindowHost->OnWindowMouseDown(CursorPoint(window), key);
	}
	else if (*held > 0 && --(*held) == 0)
	{
		window->WindowHost->OnWindowMouseUp(CursorPoint(window), key);
	}
}
