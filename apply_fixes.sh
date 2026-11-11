#!/usr/bin/env bash
# Applies the small Vita fixes to the SurrealEngine sources.
# Safe to run twice; the first run keeps a .orig copy of every file it changes.
# Usage: ./apply_fixes.sh [path to src/engine]   (default: ~/flipendo/src/engine)
set -euo pipefail

ENGINE="${1:-$HOME/flipendo/src/engine}/SurrealEngine"
export VITA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where the files to copy into the engine are
[ -d "$ENGINE" ] || { echo "Not found: $ENGINE"; exit 1; }

# The base Vita patch (32 bit NEON, memalign, the fixed game folder) goes in first; the edits below build on it.
CORE_PATCH="$VITA_DIR/patches/0300-vita-core.patch"
if grep -q "__vita__" "$ENGINE/Utils/AlignedAlloc.h"; then   # (the edits below change the same files: no reverse check)
	echo "[skip] 0300-vita-core.patch: already applied"
elif git -C "$ENGINE/.." apply "$CORE_PATCH"; then
	echo "[ok]   0300-vita-core.patch"
else
	echo "[FAIL] 0300-vita-core.patch does not apply"
fi

python3 - "$ENGINE" <<'PY'
import os
import re
import shutil
import sys

root = sys.argv[1]


def edit(rel, pattern, repl, done_marker):
    path = os.path.join(root, rel)
    with open(path, newline='', encoding='utf-8', errors='surrogateescape') as f:
        text = f.read()
    if done_marker in text:
        print(f"[skip] {rel}: already patched")
        return
    new, n = re.subn(pattern, repl, text)
    if n == 0:
        print(f"[FAIL] {rel}: pattern not found, nothing changed")
        return
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    with open(path, 'w', newline='', encoding='utf-8', errors='surrogateescape') as f:
        f.write(new)
    print(f"[ok]   {rel}: {n} change(s)")


# 0. The app's folder on the memory card is VITA_DATA_ROOT (CMake: ux0:data/flipendo for HP1, ux0:data/flipendo2 for HP2).
#    Files patched before 2026-11-06 have the HP1 folder written out: changed to the macro (nothing to do on fresh files).
for rel in ("Utils/File.cpp", "../../knowwonder/KWNativeFont.cpp", "../../knowwonder/KWParticleFX.cpp"):
    path = os.path.join(root, rel)
    with open(path, newline='', encoding='utf-8', errors='surrogateescape') as f:
        text = f.read()
    new = text.replace('"ux0:data/flipendo/', 'VITA_DATA_ROOT "/').replace('ux0:data/flipendo/render.cfg can', 'render.cfg can')
    if new != text:
        with open(path, 'w', newline='', encoding='utf-8', errors='surrogateescape') as f:
            f.write(new)
        print(f"[ok]   {rel}: the card folder is VITA_DATA_ROOT")


# 1. The NEON code uses 64-bit ARM only intrinsics (vsqrtq_f32, vdivq_f32, vmaxvq_u32).
#    The Vita is 32-bit ARMv7: use the generic code there.
edit("Light/LightEffect.cpp",
     r"#elif\s+defined\(USE_NEON\)",
     "#elif defined(USE_NEON) && defined(__aarch64__)",
     "#elif defined(USE_NEON) && defined(__aarch64__)")

# 2. Finding the folder of the executable goes through /proc/self/exe on Linux.
#    On the Vita the game lives in a fixed folder.
edit("Utils/File.cpp",
     r"#else(\s*)#ifndef PROC_EXE_PATH",
     lambda m: '#elif defined(__vita__)\n\treturn std::string(VITA_DATA_ROOT "/");\n#else'
               + m.group(1) + '#ifndef PROC_EXE_PATH',
     'return std::string(VITA_DATA_ROOT "/")')

# 3. KWNativeFont.cpp (Flipendo's own file, in src/knowwonder) finds system fonts with fontconfig on Linux.
#    The Vita has none: use a TrueType font that ships with the port instead.
edit("../../knowwonder/KWNativeFont.cpp",
     r"#elif !defined\(__APPLE__\)(\s*)#include <fontconfig/fontconfig\.h>",
     lambda m: '#elif !defined(__APPLE__) && !defined(__vita__)' + m.group(1) + '#include <fontconfig/fontconfig.h>',
     '!defined(__vita__)')

VITA_FONT = '''#elif defined(__vita__)
	// The Vita has no system font files this code can read: use a font file that ships with the port
	// (NotoSans-Regular.ttf from the engine's Resources/noto folder; it covers Latin and Cyrillic).
	static bool LoadSystemFontFile(const std::string& name, const std::string& language, NativeFontFile& file)
	{
		const std::string filename = VITA_DATA_ROOT "/fonts/NotoSans-Regular.ttf";
		try
		{
			Array<uint8_t> bytes = File::read_all_bytes(filename);
			file.data.assign(bytes.begin(), bytes.end());
		}
		catch (const std::exception&)
		{
			return false;
		}
		LogMessage("CreateNativeFont: " + name + " is " + filename);
		return true;
	}
#else'''

edit("../../knowwonder/KWNativeFont.cpp",
     r"#else(\s*)// fontconfig language tag",
     lambda m: VITA_FONT + m.group(1) + '// fontconfig language tag',
     'NotoSans-Regular.ttf')

# 4. The SDL2 window asks for a desktop OpenGL 3.2 core context. vitaGL is an OpenGL ES 2.0 style implementation.
edit("../SurrealWidgets/src/window/sdl2/sdl2_display_window.cpp",
     r"(\s*)SDL_GL_SetAttribute\(SDL_GL_CONTEXT_MAJOR_VERSION, 3\);\s*SDL_GL_SetAttribute\(SDL_GL_CONTEXT_MINOR_VERSION, 2\);\s*SDL_GL_SetAttribute\(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE\);",
     lambda m: ('\n#ifdef __vita__\n'
                '\t// vitaGL is an OpenGL ES 2.0 style implementation\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);\n'
                '#else\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);\n'
                '\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);\n'
                '#endif'),
     'SDL_GL_CONTEXT_PROFILE_ES')

# 5. The SDL2 backend loads libX11 with dlopen to read the Xft DPI: Linux/X11 only. The Vita has no dlfcn.h.
edit("../SurrealWidgets/src/window/sdl2/sdl2_display_backend.cpp",
     r"#ifndef WIN32(\s*)#include <dlfcn\.h>",
     lambda m: '#if !defined(WIN32) && !defined(__vita__)' + m.group(1) + '#include <dlfcn.h>',
     '#if !defined(WIN32) && !defined(__vita__)')

edit("../SurrealWidgets/src/window/sdl2/sdl2_display_backend.cpp",
     r"#if !defined\(WIN32\) && !defined\(__APPLE__\)(\s*)const char\* driver",
     lambda m: '#if !defined(WIN32) && !defined(__APPLE__) && !defined(__vita__)' + m.group(1) + 'const char* driver',
     '!defined(__APPLE__) && !defined(__vita__)')

# 6. GameWindow::Create picks the window's graphics API from the launcher settings (Vulkan by default).
#    The Vita has only vitaGL (OpenGL ES).
edit("GameWindow.cpp",
     r"(\s*)return std::make_unique<GameWindow>\(windowHost, api\);",
     lambda m: ('\n#ifdef __vita__\n'
                '\tapi = RenderAPI::OpenGL; // vitaGL is the only renderer on the Vita\n'
                '#endif'
                + m.group(1) + 'return std::make_unique<GameWindow>(windowHost, api);'),
     'vitaGL is the only renderer on the Vita')

# 7. Frame::RunExpr, case FinalFunction, first pass: the arguments are read through a VirtualFunctionExpression cast
#    although the expression is a FinalFunctionExpression (the second pass casts it correctly). The two classes
#    only agree on where "Args" lies when a pointer and a NameString are the same size, i.e. on 64-bit. On the
#    32-bit Vita "Args" is somewhere else and the argument list read from it is garbage (crash in PushExpr).
edit("VM/Frame.cpp",
     r"(case ExpressionType::FinalFunction:\s*if \(pass == 0\)\s*\{\s*PushContext\(self\);\s*const auto& args = static_cast<)VirtualFunctionExpression(\*>\(expr\)->Args;)",
     lambda m: m.group(1) + 'FinalFunctionExpression' + m.group(2) + ' // vita: a FinalFunction, not a VirtualFunction (same layout only on 64-bit)',
     '// vita: a FinalFunction, not a VirtualFunction')

# 8. Vita input in the SDL2 window (see vita_input.cpp): the right stick moves the cursor / turns the camera, cross is
#    the left mouse button, and the touch screen's mouse motion always gives the absolute position (the engine locks
#    the cursor in full screen, which would turn every touch into a camera movement).
SDL2WIN = "../SurrealWidgets/src/window/sdl2/sdl2_display_window.cpp"

edit(SDL2WIN,
     r'(#include "sdl2_display_window\.h"[^\n]*\n)',
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-input:decl\n'
                             'void VitaPollPad();\n'
                             'void VitaPadCursorMoved(int x, int y);\n'
                             'void VitaPadButton(SDL2DisplayWindow* window, int button, bool down);\n'
                             '#endif\n'),
     'vita-input:decl')

edit(SDL2WIN,
     r"(void SDL2DisplayWindow::ProcessEvents\(\)\s*\{\s*SDL_Event event;\s*while \(SDL_PollEvent\(&event\) != 0\)\s*\{\s*DispatchEvent\(event\);\s*\})",
     lambda m: m.group(1) + '\n#ifdef __vita__ // vita-input:poll\n\tVitaPollPad();\n#endif',
     'vita-input:poll')

edit(SDL2WIN,
     r"(\tif \(!CursorLocked\)\s*\{)\s*SDL_SetRelativeMouseMode\(SDL_TRUE\);",
     lambda m: m.group(1) + '\n#ifndef __vita__ // vita-input:lock\n\t\tSDL_SetRelativeMouseMode(SDL_TRUE);\n#endif',
     'vita-input:lock')

edit(SDL2WIN,
     r"(\tif \(CursorLocked\)\s*\{)\s*SDL_SetRelativeMouseMode\(SDL_FALSE\);",
     lambda m: m.group(1) + '\n#ifndef __vita__ // vita-input:unlock\n\t\tSDL_SetRelativeMouseMode(SDL_FALSE);\n#endif',
     'vita-input:unlock')

edit(SDL2WIN,
     r"(void SDL2DisplayWindow::OnMouseMotion\(const SDL_MouseMotionEvent& event\)\s*\{)(\s*if \(CursorLocked\)\s*\{\s*WindowHost->OnWindowRawMouseMove\(event\.xrel, event\.yrel\);\s*\}\s*else\s*\{\s*WindowHost->OnWindowMouseMove\(GetMousePos\(event\)\);\s*\})",
     lambda m: (m.group(1) + '\n#ifdef __vita__ // vita-input:motion\n'
                '\t// Touch arrives as mouse motion. The menus need the absolute position even while the engine has\n'
                '\t// "locked" the cursor, so it is always sent; the camera gets the movement as well when locked.\n'
                '\tif (CursorLocked)\n'
                '\t\tWindowHost->OnWindowRawMouseMove(event.xrel, event.yrel);\n'
                '\tWindowHost->OnWindowMouseMove(GetMousePos(event));\n'
                '\tVitaPadCursorMoved(event.x, event.y);\n'
                '#else' + m.group(2) + '\n#endif'),
     'vita-input:motion')

edit(SDL2WIN,
     r"(void SDL2DisplayWindow::OnJoyButtonUp\(const SDL_ControllerButtonEvent& event\)\s*\{\s*WindowHost->OnWindowKeyUp\(GameControllerButtonToInputKey\(\(SDL_GameControllerButton\)event\.button\)\);)",
     lambda m: m.group(1) + '\n#ifdef __vita__ // vita-input:button-up\n\tVitaPadButton(this, event.button, false);\n#endif',
     'vita-input:button-up')

edit(SDL2WIN,
     r"(void SDL2DisplayWindow::OnJoyButtonDown\(const SDL_ControllerButtonEvent& event\)\s*\{\s*WindowHost->OnWindowKeyDown\(GameControllerButtonToInputKey\(\(SDL_GameControllerButton\)event\.button\)\);)",
     lambda m: m.group(1) + '\n#ifdef __vita__ // vita-input:button-down\n\tVitaPadButton(this, event.button, true);\n#endif',
     'vita-input:button-down')

# 9. The pad's buttons: cross and circle, and the shoulder buttons, are mouse buttons now (vita_input.cpp), so their
#    keys are switched off. Cross and start were the Enter key (which the game uses for "look toggle"): start is
#    the menu (Escape) like on Android.
edit(SDL2WIN,
     r"(\t\tcase SDL_CONTROLLER_BUTTON_A:\s+return InputKey::Enter;\s*case SDL_CONTROLLER_BUTTON_B:\s+return InputKey::Backspace;)",
     lambda m: ('#ifdef __vita__ // vita-input:keys-a\n'
                '\t\tcase SDL_CONTROLLER_BUTTON_A:             return InputKey::None; // cross: left mouse button\n'
                '\t\tcase SDL_CONTROLLER_BUTTON_B:             return InputKey::None; // circle: right mouse button\n'
                '#else\n' + m.group(1) + '\n#endif'),
     'vita-input:keys-a')

edit(SDL2WIN,
     r"(\t\tcase SDL_CONTROLLER_BUTTON_START:\s+return InputKey::Enter;)",
     lambda m: ('#ifdef __vita__ // vita-input:keys-start\n'
                '\t\tcase SDL_CONTROLLER_BUTTON_START:         return InputKey::Escape;\n'
                '#else\n' + m.group(1) + '\n#endif'),
     'vita-input:keys-start')

edit(SDL2WIN,
     r"(\t\tcase SDL_CONTROLLER_BUTTON_LEFTSHOULDER:\s+return InputKey::Tab;\s*case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:\s+return InputKey::Tab;)",
     lambda m: ('#ifdef __vita__ // vita-input:keys-shoulder\n'
                '\t\tcase SDL_CONTROLLER_BUTTON_LEFTSHOULDER:  return InputKey::None; // L: right mouse button\n'
                '\t\tcase SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: return InputKey::None; // R: left mouse button\n'
                '#else\n' + m.group(1) + '\n#endif'),
     'vita-input:keys-shoulder')

# 10. Particles: a spell makes hundreds of them and the Vita's processor cannot keep up. ux0:data/flipendo/render.cfg
#     can thin the emission out: "particles=40" emits 40 percent (100 = as the game wants, the default).
PARTICLES = "../../knowwonder/KWParticleFX.cpp"

edit(PARTICLES,
     r"(#include <cmath>\s*#include <unordered_map>)",
     lambda m: m.group(1) + '\n#include <cstdio>   // vita-particles:include',
     'vita-particles:include')

edit(PARTICLES,
     r"(\t\t// IDA Engine\.dll: \?EmitParticles@AParticleFX@@QAEHM@Z[^\n]*\n(?:\t\t// IDA[^\n]*\n)*\t\tint EmitParticles\(UActor\* a, ParticleSystemState& state, float dt\)\s*\{)",
     lambda m: ('\t\t// vita-particles:helper\n'
                '\t\t// The Vita is slow, and a spell makes hundreds of particles: render.cfg can thin them out\n'
                '\t\t// ("particles=40" emits 40 percent of them). Other platforms always emit all of them.\n'
                '\t\tfloat ParticleDensity()\n'
                '\t\t{\n'
                '#ifdef __vita__\n'
                '\t\t\tstatic float density = []\n'
                '\t\t\t{\n'
                '\t\t\t\tfloat value = 1.0f;\n'
                '\t\t\t\tif (FILE* file = fopen(VITA_DATA_ROOT "/render.cfg", "r"))\n'
                '\t\t\t\t{\n'
                '\t\t\t\t\tchar line[256];\n'
                '\t\t\t\t\twhile (fgets(line, sizeof(line), file))\n'
                '\t\t\t\t\t{\n'
                '\t\t\t\t\t\tint percent = 0;\n'
                '\t\t\t\t\t\tif (sscanf(line, " particles = %d", &percent) == 1)\n'
                '\t\t\t\t\t\t\tvalue = std::clamp(percent, 0, 100) / 100.0f;\n'
                '\t\t\t\t\t}\n'
                '\t\t\t\t\tfclose(file);\n'
                '\t\t\t\t}\n'
                '\t\t\t\treturn value;\n'
                '\t\t\t}();\n'
                '\t\t\treturn density;\n'
                '#else\n'
                '\t\t\treturn 1.0f;\n'
                '#endif\n'
                '\t\t}\n\n' + m.group(1)),
     'vita-particles:helper')

edit(PARTICLES,
     r"(\t\t\tcount \+= PFX::EmissionResidue\(a\);)",
     lambda m: '\t\t\tcount *= ParticleDensity(); // vita-particles:use\n' + m.group(1),
     'vita-particles:use')

# 11. The lighting loop of LightEffect.cpp has NEON code for 64 bit ARM only (fused multiply-add, vector sqrt and
#     divide exist only there). The same loop for the Vita's 32 bit NEON, with a reciprocal and a reciprocal
#     square root estimate refined by two Newton steps. This is the loop that lights every lightmap texel.
LIGHTEFFECT = "Light/LightEffect.cpp"

NEON32 = r"""#elif defined(USE_NEON) // vita-neon: 32 bit ARM
	// No vector sqrt/divide/fused multiply-add here: estimates refined with Newton steps (about 23 bits)
	auto recip = [](float32x4_t x)
	{
		float32x4_t r = vrecpeq_f32(x);
		r = vmulq_f32(vrecpsq_f32(x, r), r);
		return vmulq_f32(vrecpsq_f32(x, r), r);
	};
	auto sqrt4 = [](float32x4_t x)
	{
		float32x4_t r = vrsqrteq_f32(x);
		r = vmulq_f32(vrsqrtsq_f32(vmulq_f32(x, r), r), r);
		r = vmulq_f32(vrsqrtsq_f32(vmulq_f32(x, r), r), r);
		return vmulq_f32(x, r);
	};

	float32x4_t vLx0 = vdupq_n_f32(lightLocationX);
	float32x4_t vLy0 = vdupq_n_f32(lightLocationY);
	float32x4_t vLz0 = vdupq_n_f32(lightLocationZ);
	float32x4_t vNx = vdupq_n_f32(Nx);
	float32x4_t vNy = vdupq_n_f32(Ny);
	float32x4_t vNz = vdupq_n_f32(Nz);
	float32x4_t vInvR = vdupq_n_f32(invRadius);
	float32x4_t vInvR2 = vdupq_n_f32(invRadiusSquared);
	float32x4_t one = vdupq_n_f32(1.0f);
	float32x4_t two = vdupq_n_f32(2.0f);
	float32x4_t three = vdupq_n_f32(3.0f);

	int sse_size = size / 4 * 4;
	for (int i = 0; i < sse_size; i += 4)
	{
		float32x4x3_t P = vld3q_f32(locations);
		float32x4_t Lx = vsubq_f32(vLx0, P.val[0]);
		float32x4_t Ly = vsubq_f32(vLy0, P.val[1]);
		float32x4_t Lz = vsubq_f32(vLz0, P.val[2]);

		float32x4_t lensqr = vmlaq_f32(vmlaq_f32(vmulq_f32(Lx, Lx), Ly, Ly), Lz, Lz);
		uint32x4_t inRange = vcltq_f32(vmulq_f32(lensqr, vInvR2), one);

		uint32x2_t anyIn = vpmax_u32(vget_low_u32(inRange), vget_high_u32(inRange));
		if (vget_lane_u32(vpmax_u32(anyIn, anyIn), 0))
		{
			float32x4_t len = sqrt4(lensqr);
			float32x4_t rcpdist = recip(len);

			Lx = vmulq_f32(Lx, rcpdist);
			Ly = vmulq_f32(Ly, rcpdist);
			Lz = vmulq_f32(Lz, rcpdist);

			float32x4_t angle = vmlaq_f32(vmlaq_f32(vmulq_f32(Lx, vNx), Ly, vNy), Lz, vNz);
			angle = vabsq_f32(angle);

			float32x4_t v = vmulq_f32(len, vInvR);
			float32x4_t v2 = vmulq_f32(v, v);
			float32x4_t v3 = vmulq_f32(v2, v);
			float32x4_t num = vsubq_f32(vmlaq_f32(one, two, v3), vmulq_f32(three, v2));
			float32x4_t dist = vminq_f32(vmulq_f32(num, recip(v)), one);

			float32x4_t value = vmulq_f32(vld1q_f32(shadowmap), vmulq_f32(dist, angle));
			value = vreinterpretq_f32_u32(vandq_u32(vreinterpretq_u32_f32(value), inRange));
			vst1q_f32(result, value);
		}
		else
		{
			vst1q_f32(result, vdupq_n_f32(0.0f));
		}

		locations += 3 * 4;
		shadowmap += 4;
		result += 4;
	}
"""

edit(LIGHTEFFECT,
     r"(vst1q_f32\(result, vdupq_n_f32\(0\.0f\)\);\s*\}\s*locations \+= 3 \* 4;\s*shadowmap \+= 4;\s*result \+= 4;\s*\}\n)(#else\n\tint sse_size = 0;\n#endif)",
     lambda m: m.group(1) + NEON32 + m.group(2),
     'vita-neon: 32 bit ARM')

# 12. Section timers (VitaTimers.h): where the engine spends its time, logged by the renderer every 120 frames.
def include_timers(rel, marker):
    edit(rel,
         r'(#include "Precomp\.h"\n)',
         lambda m: m.group(1) + '#include "VitaTimers.h" // ' + marker + '\n',
         marker)

# the main loop
include_timers("Engine.cpp", "vita-timers:include")
edit("Engine.cpp",
     r"(\t+)Level->Tick\((\w+), m_GamePaused\);\n",
     lambda m: m.group(1) + "{ VITA_TIMER(LevelTick); Level->Tick(" + m.group(2) + ", m_GamePaused); } // vita-timers:level\n",
     "vita-timers:level")
edit("Engine.cpp",
     r"(\t+)CallEvent\(console, EventName::Tick, \{ ExpressionValue::FloatValue\((\w+)\) \}\);\n",
     lambda m: m.group(1) + "{ VITA_TIMER(ConsoleTick); CallEvent(console, EventName::Tick, { ExpressionValue::FloatValue(" + m.group(2) + ") }); } // vita-timers:console\n",
     "vita-timers:console")
edit("Engine.cpp",
     r"\t\tUpdateAudio\(\);\n(\n\t\tviewport->SetViewportRect)",
     lambda m: "\t\t{ VITA_TIMER(Audio); UpdateAudio(); } // vita-timers:audio\n" + m.group(1),
     "vita-timers:audio")
edit("Engine.cpp",
     r"\t\trender->DrawGame\(levelElapsed\);\n",
     lambda m: "\t\t{ VITA_TIMER(DrawGame); render->DrawGame(levelElapsed); } // vita-timers:draw\n",
     "vita-timers:draw")

# the scene
include_timers("Render/RenderScene.cpp", "vita-timers:include")
edit("Render/RenderScene.cpp",
     r"(\tfor \(UActor\* actor : engine->Level->Actors\)\n\t\{\n\t\tif \(actor\)\n\t\t\tactor->UpdateBspInfo\(\);\n\t\})",
     lambda m: "\t{ // vita-timers:bspinfo\n\t\tVITA_TIMER(BspInfo);\n" + m.group(1) + "\n\t}",
     "vita-timers:bspinfo")
edit("Render/RenderScene.cpp",
     r"\tMainFrame\.Process\(engine->CameraLocation, worldToView, Coords::Rotation\(engine->CameraRotation\)\);\n\tMainFrame\.Draw\(\);\n",
     lambda m: ("\t{ VITA_TIMER(Process); MainFrame.Process(engine->CameraLocation, worldToView, Coords::Rotation(engine->CameraRotation)); } // vita-timers:process\n"
                "\t{ VITA_TIMER(DrawNodes); MainFrame.Draw(); }\n"),
     "vita-timers:process")

# meshes, particles, lightmaps
include_timers("Render/VisibleMesh.cpp", "vita-timers:include")
edit("Render/VisibleMesh.cpp",
     r"(bool VisibleMesh::DrawMesh\(VisibleFrame\* frame, UActor\* actor, bool wireframe, bool translucentPass\)\n\{\n)",
     lambda m: m.group(1) + "\tVITA_TIMER(Mesh); // vita-timers:mesh\n",
     "vita-timers:mesh")

include_timers("../../knowwonder/KWParticleRender.cpp", "vita-timers:include")
edit("../../knowwonder/KWParticleRender.cpp",
     r"(\tvoid DrawParticleSystem\(VisibleFrame\* frame, UActor\* actor\)\n\t\{\n)",
     lambda m: m.group(1) + "\t\tVITA_TIMER(Particles); // vita-timers:particles\n",
     "vita-timers:particles")

include_timers("Light/LightSystem_Light.cpp", "vita-timers:include")
edit("Light/LightSystem_Light.cpp",
     r"(TextureInfo LightSystem::GetLightmap\([^\n]*\)\n\{\n)",
     lambda m: m.group(1) + "\tVITA_TIMER(Lightmaps); // vita-timers:lightmaps\n",
     "vita-timers:lightmaps")

# 13. The engine never frees the objects of a level it has left (GC::Collect() is commented out in UnloadMap): the
#     second level ran the Vita out of memory ("FATAL: std::bad_alloc" at the change from Lev_Tut1 to Lev_Tut1b).
#     The engine's collector can NOT be used as it is: only the packages are registered as roots, so it frees the
#     engine's own objects too (the viewport, the console...) and the first LoadMap crashed in LoadEntryMap. It stays
#     in the code for later, off ("gc=1" in render.cfg turns it on: do not).
edit("Engine.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-config:include\n',
     'vita-config:include')

edit("Engine.cpp",
     r"\t// GC::Collect\(\);\n\}",
     lambda m: ('\tif (VitaConfigInt("gc", 0)) // vita-gc (off by default: see apply_fixes.sh)\n'
                '\t{\n'
                '\t\tGCStats before = GC::GetStats();\n'
                '\t\tGC::Collect();\n'
                '\t\tGCStats after = GC::GetStats();\n'
                '\t\tLogMessage("GC after unloading the map: " + std::to_string(before.numObjects) + " -> " + std::to_string(after.numObjects) +\n'
                '\t\t\t" objects, " + std::to_string(before.memoryUsage / (1024 * 1024)) + " -> " + std::to_string(after.memoryUsage / (1024 * 1024)) + " MB");\n'
                '\t}\n'
                '}'),
     'vita-gc')

# 13b. A tree patched by the first version of 13 has "gc" on by default: switch it off.
edit("Engine.cpp",
     r'VitaConfigInt\("gc", 1\)\) // vita-gc\n',
     lambda m: 'VitaConfigInt("gc", 0)) // vita-gc (off by default: see apply_fixes.sh)\n',
     'vita-gc (off by default')

# 14. Sounds: the engine keeps every sound as floats (4 bytes a sample) and OpenAL keeps a second copy as floats
#     again. Giving OpenAL 16 bit samples halves that copy. (The float samples stay: the lip sync reads them.)
AUDIO = "Audio/OpenAL/OpenALAudioDevice.cpp"  # SurrealEngine c41d349e moved the OpenAL code here

edit(AUDIO,
     r"\tALenum format = AL_FORMAT_MONO_FLOAT32;\n\tif \(sound->channels == 2\)\n\t\tformat = AL_FORMAT_STEREO_FLOAT32;\n\n\tALuint id;\n\talGenBuffers\(1, &id\);\n\talBufferData\(id, format, sound->samples\.data\(\), \(ALsizei\)\(sound->samples\.size\(\) \* sizeof\(sound->samples\[0\]\)\), sound->frequency\);\n",
     lambda m: ('#ifdef __vita__ // vita-audio16\n'
                '\t\tALenum format = AL_FORMAT_MONO16;\n'
                '\t\tif (sound->channels == 2)\n'
                '\t\t\tformat = AL_FORMAT_STEREO16;\n'
                '\n'
                '\t\tALuint id;\n'
                '\t\talGenBuffers(1, &id);\n'
                '\t\t{\n'
                '\t\t\tstd::vector<int16_t> pcm(sound->samples.size());\n'
                '\t\t\tfor (size_t i = 0; i < pcm.size(); i++)\n'
                '\t\t\t{\n'
                '\t\t\t\tfloat v = sound->samples[i];\n'
                '\t\t\t\tv = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);\n'
                '\t\t\t\tpcm[i] = (int16_t)(v * 32767.0f);\n'
                '\t\t\t}\n'
                '\t\t\talBufferData(id, format, pcm.data(), (ALsizei)(pcm.size() * sizeof(int16_t)), sound->frequency);\n'
                '\t\t\tVitaStats::soundCount++;\n'
                '\t\t\tVitaStats::soundSamples += sound->samples.size();\n'
                '\t\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-audio16')

edit(AUDIO,
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaStats.h" // vita-audiostats\n',
     'vita-audiostats')

# 15. Lightmaps: the renderer frees the float data of a lightmap after uploading it (16 bytes a texel); the engine has to
#     make it again when it rebuilds the lightmap.
edit("Light/LightSystem_Light.cpp",
     r"(\t\tvec4\* dest = \(vec4\*\)lmmip\.Data\.data\(\);\n)",
     lambda m: ('\t\tif (lmmip.Data.size() < (size_t)lmmip.Width * lmmip.Height * sizeof(vec4)) // vita-lightmem: freed after the upload\n'
                '\t\t\tlmmip.Data.resize((size_t)lmmip.Width * lmmip.Height * sizeof(vec4));\n' + m.group(1)),
     'vita-lightmem')

edit("Light/LightSystem_Fog.cpp",
     r"(\t\tUpdateFogmapTexture\(\(uint32_t\*\)fogtexture->Mip\.Data\.data\(\), model, coords, lightmapIndex, zoneActor\);\n)",
     lambda m: ('\t\tif (fogtexture->Mip.Data.size() < (size_t)fogtexture->Mip.Width * fogtexture->Mip.Height * sizeof(vec4)) // vita-lightmem: freed after the upload\n'
                '\t\t\tfogtexture->Mip.Data.resize((size_t)fogtexture->Mip.Width * fogtexture->Mip.Height * sizeof(vec4));\n' + m.group(1)),
     'vita-lightmem')

# 16. Meshes far away: "mesh_distance=3000" in render.cfg leaves out meshes (characters, objects) farther than that from the
#     camera: no vertex animation, no lighting, no drawing. 0 (the default) draws all, as the game does.
edit("Render/VisibleMesh.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-meshinc\n#include "VitaStats.h"\n',
     'vita-meshinc')

edit("Render/VisibleMesh.cpp",
     r"(bool VisibleMesh::DrawMesh\(VisibleFrame\* frame, UActor\* actor, bool wireframe, bool translucentPass\)\n\{\n(?:\tVITA_TIMER\(Mesh\);[^\n]*\n)?\tUMesh\* mesh = actor->Mesh\(\);\n\tif \(!mesh\)\n\t\treturn false;\n)",
     lambda m: m.group(1) + ('\n\tif (VitaMeshDistance() > 0.0f) // vita-meshdist\n'
                             '\t{\n'
                             '\t\tvec3 toActor = actor->Location() - engine->CameraLocation;\n'
                             '\t\tif (dot(toActor, toActor) > VitaMeshDistance() * VitaMeshDistance())\n'
                             '\t\t{\n'
                             '\t\t\tVitaStats::meshesSkipped++;\n'
                             '\t\t\treturn false;\n'
                             '\t\t}\n'
                             '\t}\n'),
     'vita-meshdist')

# 17. Textures: UTexture::Load keeps the mip data three times (UncompressedMipmaps, CompressedMipmaps and a copy of the
#     one in use, UsedMipmaps). Only UsedMipmaps is read by the game (the others are for saving packages), so on the
#     Vita the used one is swapped in and the others are emptied. That is most of the texture memory.
UTEXTURE = "Packages/Engine/Resources/Textures/UTexture.cpp"

edit(UTEXTURE,
     r"\t\tUsedMipmaps = CompressedMipmaps;\n",
     lambda m: ('#ifdef __vita__ // vita-texmem\n'
                '\t\tUsedMipmaps.swap(CompressedMipmaps);\n'
                '\t\tCompressedMipmaps.clear();\n'
                '\t\tCompressedMipmaps.shrink_to_fit();\n'
                '\t\tUncompressedMipmaps.clear();\n'
                '\t\tUncompressedMipmaps.shrink_to_fit();\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-texmem')

edit(UTEXTURE,
     r"\t\tUsedMipmaps = UncompressedMipmaps;\n",
     lambda m: ('#ifdef __vita__ // vita-texmem2\n'
                '\t\tUsedMipmaps.swap(UncompressedMipmaps);\n'
                '\t\tUncompressedMipmaps.clear();\n'
                '\t\tUncompressedMipmaps.shrink_to_fit();\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-texmem2')

# 18. Sounds: the file's bytes (wav/mp3) are only needed to decode the sound (GetSound does that once) and to save a package.
edit("Packages/Engine/Resources/USound.cpp",
     r"(\tengine->audiodev->GetDevice\(\)->AddSound\(this\);\n)(\})",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-sounddata\n'
                             '\t// decoded and buffered: the original bytes are not needed any more\n'
                             '\tData.clear();\n'
                             '\tData.shrink_to_fit();\n'
                             '#endif\n') + m.group(2),
     'vita-sounddata')

# 19. Out of memory. PropertyDataBlock::Init takes an object's memory from AlignedAlloc (memalign here), which returns null when
#     the heap is full, and the next line writes to it: a crash in UPropertyT<int>::CopyConstructElement at the change
#     of level. Throwing like operator new does makes it a normal "FATAL: std::bad_alloc" in the log.
edit("Utils/AlignedAlloc.h",
     r"\treturn memalign\(alignment, size\);\n",
     lambda m: ('\t{ // vita-oom\n'
                '\t\tvoid* block = memalign(alignment, size);\n'
                '\t\tif (!block)\n'
                '\t\t\tthrow std::bad_alloc();\n'
                '\t\treturn block;\n'
                '\t}\n'),
     'vita-oom')

edit("Utils/AlignedAlloc.h",
     r"(#include <cstdlib>\n)",
     lambda m: m.group(1) + '#include <new> // vita-oom-include\n',
     'vita-oom-include')

# the heap at the start of every map load, to see how much a level needs
edit("Engine.cpp",
     r"(void Engine::LoadMap\(const UnrealURL& url, const std::map<std::string, std::string>& travelInfo\)\n\{\n)",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-loadlog\n'
                             '\t{\n'
                             '\t\tstruct mallinfo info = mallinfo();\n'
                             '\t\tLogMessage("LoadMap: heap " + std::to_string((size_t)info.uordblks / (1024 * 1024)) + " MB in use of " + std::to_string((size_t)info.arena / (1024 * 1024)) + " MB taken from the system");\n'
                             '\t}\n'
                             '#endif\n'),
     'vita-loadlog')

# 20. The visibility clipper rasterizes the level's walls in software on a fixed virtual screen of 2048x1080, four times the
#     pixels of the Vita's screen: the 'process' step took 20-30 ms in big halls. "clipper_scale=50" (the default)
#     in render.cfg makes it 1024x540 (the screen's own size), 25 makes it 512x270, 100 is the original.
edit("Render/BspClipper.h",
     r"(\tconst int ViewportWidth = 2048;\n\tconst int ViewportHeight = 1080;\n)",
     lambda m: ('#ifdef __vita__ // vita-clipper\n'
                '\tconst int ViewportWidth = VitaClipperWidth();\n'
                '\tconst int ViewportHeight = VitaClipperHeight();\n'
                '#else\n' + m.group(1) + '#endif\n'),
     'vita-clipper')

edit("Render/BspClipper.h",
     r"(#pragma once\n)",
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-clipperinc\n',
     'vita-clipperinc')

# 21. The light tree (LightActorTree.cpp/.h): BeginFrame rebuilt it from scratch every frame, and the build read two script
#     properties of every light on every level of the tree: 'LightActorTree::Subdivide' was 5-7 percent of all the time. The
#     replacement files (in this folder) read them once, and keep the tree while no light moved. Same results (compared with
#     the original on 15000 random queries).
def replace_file(rel, source, marker):
    path = os.path.join(root, rel)
    with open(path, newline='', encoding='utf-8', errors='surrogateescape') as f:
        text = f.read()
    if marker in text:
        print(f"[skip] {rel}: already replaced")
        return
    with open(os.path.join(os.environ["VITA_DIR"], source), newline='', encoding='utf-8', errors='surrogateescape') as f:
        new = f.read()
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    with open(path, 'w', newline='', encoding='utf-8', errors='surrogateescape') as f:
        f.write(new)
    print(f"[ok]   {rel}: replaced by {source}")

replace_file("Light/LightActorTree.h", "LightActorTree.h", "vita-lighttree")
replace_file("Light/LightActorTree.cpp", "LightActorTree.cpp", "vita-lighttree")

# 22. Files: a package is read with thousands of tiny reads at scattered places, and every fseek is a slow system call on the
#     Vita: FileImpl::seek was two thirds of the time of loading a level. A read-only file keeps a block of 32 KB in memory.
VITA_FILEIMPL = r'''// vita-fileread3 (the first version was vita-fileread, the second vita-fileread2): reading a package is thousands of reads at scattered
// places. A read-only file reads straight from the card with read() (no stdio in between), keeps a block in memory and seeking only
// changes a number. A scattered read costs a block of 8 KB (the card's time is mostly the wait for each read); a read that continues
// where the last block ended is part of a scan, and the next block is twice as large, up to 256 KB. A file that has had many scattered
// reads is read into memory whole in one go (up to 20 MB, if the heap has room): that is the fastest way to read it, and the copy is
// given back when the level has loaded (VitaFileReleaseCaches). A file that is written (a save) is written in blocks of 256 KB.
// The log shows what was read and how fast (VitaFileStatsText).
#include <unistd.h>
#include <malloc.h>
#include <mutex>
#include <psp2/kernel/processmgr.h>
extern "C" int _newlib_heap_size_user;

class FileImpl : public File
{
public:
	static inline uint64_t statBytes = 0, statReads = 0, statMicros = 0;
	static inline uint64_t statSlurps = 0, statSlurpBytes = 0;
	static inline uint64_t statWritten = 0, statWrites = 0, statWriteMicros = 0;
	static inline size_t slurpedNow = 0;
	static inline std::vector<FileImpl*> openFiles;
	static inline std::mutex registryMutex;

	FileImpl(FILE* handle, bool readOnly = false, bool writeBuffered = false) : handle(handle), cached(readOnly), buffered(writeBuffered)
	{
		fd = fileno(handle);
		if (cached)
		{
			setvbuf(handle, nullptr, _IONBF, 0);
			std::lock_guard<std::mutex> lock(registryMutex);
			openFiles.push_back(this);
		}
		if (buffered)
			wbuf.reserve(WriteBlock);
	}

	~FileImpl()
	{
		try
		{
			FlushWrites();
		}
		catch (...)
		{
		}
		if (cached)
		{
			std::lock_guard<std::mutex> lock(registryMutex);
			if (!whole.empty())
				slurpedNow -= whole.size();
			for (size_t i = 0; i < openFiles.size(); i++)
			{
				if (openFiles[i] == this)
				{
					openFiles[i] = openFiles.back();
					openFiles.pop_back();
					break;
				}
			}
		}
		if (handle)
			fclose(handle);
	}

	// What the memory holds for this file (the block and a whole-file copy) is given back; reading goes on from the card.
	void ReleaseMemory()
	{
		if (!whole.empty())
		{
			slurpedNow -= whole.size();
			std::vector<uint8_t>().swap(whole);
		}
		std::vector<uint8_t>().swap(cache);
		cacheLength = 0;
		blockSize = MinBlock;
	}

	int64_t size() override
	{
		if (cached && fileSize >= 0)
			return fileSize;
		FlushWrites();

		auto pos = ftell(handle);
		fseek(handle, 0, SEEK_END);
		auto s = ftell(handle);
		fseek(handle, pos, SEEK_SET);
		if (cached)
			fileSize = s;
		return s;
	}

	void read(void *data, size_t size) override
	{
		if (size == 0)
			return;

		if (!cached)
		{
			FlushWrites();
			size_t result = fread(data, size, 1, handle);
			if (result != 1)
				Exception::Throw("fread failed");
			return;
		}

		uint8_t* out = (uint8_t*)data;
		while (size > 0)
		{
			if (!whole.empty())
			{
				if (position < 0 || position + (int64_t)size > (int64_t)whole.size())
					Exception::Throw("fread failed");
				memcpy(out, whole.data() + position, size);
				position += size;
				return;
			}

			if (position >= cacheStart && position < cacheStart + (int64_t)cacheLength)
			{
				size_t offset = (size_t)(position - cacheStart);
				size_t count = std::min(size, cacheLength - offset);
				memcpy(out, cache.data() + offset, count);
				out += count;
				size -= count;
				position += count;
			}
			else if (size >= MinBlock)
			{
				// a big read goes straight to its destination
				if (DeviceRead(position, out, size) != size)
					Exception::Throw("fread failed");
				position += size;
				return;
			}
			else
			{
				const bool continuing = cacheLength > 0 && position == cacheStart + (int64_t)cacheLength;
				if (!continuing && ++scattered >= SlurpAfter && TryWholeFile())
					continue;
				blockSize = continuing ? std::min(blockSize * 2, MaxBlock) : MinBlock;
				if (cache.size() < blockSize)
					cache.resize(blockSize);
				cacheStart = position;
				cacheLength = DeviceRead(position, cache.data(), blockSize);
				if (cacheLength == 0)
					Exception::Throw("fread failed");
			}
		}
	}

	void write(const void *data, size_t size) override
	{
		if (size == 0)
			return;

		if (!buffered)
		{
			size_t result = fwrite(data, size, 1, handle);
			if (result != 1)
				Exception::Throw("fwrite failed");
			return;
		}

		const uint8_t* in = (const uint8_t*)data;
		while (size > 0)
		{
			size_t count = std::min(size, WriteBlock - wbuf.size());
			wbuf.insert(wbuf.end(), in, in + count);
			in += count;
			size -= count;
			if (wbuf.size() >= WriteBlock)
				FlushWrites();
		}
	}

	void seek(int64_t offset, SeekPoint origin = SeekPoint::begin) override
	{
		if (cached)
		{
			int64_t target = offset;
			if (origin == SeekPoint::current) target = position + offset;
			else if (origin == SeekPoint::end) target = size() + offset;
			if (target < 0)
				Exception::Throw("fseek failed");
			position = target;
			return;
		}

		FlushWrites();
		int moveMethod = SEEK_SET;
		if (origin == SeekPoint::current) moveMethod = SEEK_CUR;
		else if (origin == SeekPoint::end) moveMethod = SEEK_END;
		int result = fseek(handle, offset, moveMethod);
		if (result != 0)
			Exception::Throw("fseek failed");
		if (buffered)
			wbase = ftell(handle);
	}

	uint64_t tell() override
	{
		if (cached)
			return (uint64_t)position;
		if (buffered)
			return (uint64_t)(wbase + (int64_t)wbuf.size());

		auto result = ftell(handle);
		if (result == -1)
			Exception::Throw("ftell failed");
		return result;
	}

	FILE* handle = nullptr;

private:
	static constexpr size_t MinBlock = 8 * 1024;
	static constexpr size_t MaxBlock = 256 * 1024;
	static constexpr size_t WriteBlock = 256 * 1024;
	static constexpr int SlurpAfter = 48;                          // scattered reads before the whole file is read
	static constexpr int64_t SlurpMaxFile = 20 * 1024 * 1024;
	static constexpr size_t SlurpMaxTotal = 40 * 1024 * 1024;

	// One read from the card, straight into its destination.
	size_t DeviceRead(int64_t offset, void* dest, size_t count)
	{
		const uint64_t start = sceKernelGetProcessTimeWide();
		size_t total = 0;
		if (lseek(fd, (off_t)offset, SEEK_SET) != (off_t)-1)
		{
			while (total < count)
			{
				ssize_t got = ::read(fd, (uint8_t*)dest + total, count - total);
				if (got <= 0)
					break;
				total += (size_t)got;
			}
		}
		statMicros += sceKernelGetProcessTimeWide() - start;
		statBytes += total;
		statReads++;
		return total;
	}

	// Many scattered reads: read the file whole (once), if there is room for it in the heap.
	bool TryWholeFile()
	{
		if (wholeTried)
			return false;
		wholeTried = true;
		const int64_t length = size();
		if (length <= 0 || length > SlurpMaxFile)
			return false;
		struct mallinfo info = mallinfo();
		const int64_t free = (int64_t)_newlib_heap_size_user - (int64_t)info.uordblks;
		if (slurpedNow + (size_t)length > SlurpMaxTotal || free < length + 72 * 1024 * 1024)
			return false;
		try
		{
			whole.resize((size_t)length);
		}
		catch (...)
		{
			std::vector<uint8_t>().swap(whole);
			return false;
		}
		if (DeviceRead(0, whole.data(), (size_t)length) != (size_t)length)
		{
			std::vector<uint8_t>().swap(whole);
			return false;
		}
		slurpedNow += (size_t)length;
		statSlurps++;
		statSlurpBytes += (uint64_t)length;
		std::vector<uint8_t>().swap(cache);
		cacheLength = 0;
		return true;
	}

	void FlushWrites()
	{
		if (!buffered || wbuf.empty())
			return;
		const uint64_t start = sceKernelGetProcessTimeWide();
		size_t written = fwrite(wbuf.data(), 1, wbuf.size(), handle);
		statWriteMicros += sceKernelGetProcessTimeWide() - start;
		statWrites++;
		statWritten += written;
		if (written != wbuf.size())
		{
			wbuf.clear();
			Exception::Throw("fwrite failed");
		}
		wbase += (int64_t)wbuf.size();
		wbuf.clear();
	}

	int fd = -1;
	bool cached = false;
	bool buffered = false;
	bool wholeTried = false;
	int scattered = 0;
	std::vector<uint8_t> cache;
	std::vector<uint8_t> whole;
	std::vector<uint8_t> wbuf;
	size_t blockSize = MinBlock;
	int64_t cacheStart = 0;
	size_t cacheLength = 0;
	int64_t position = 0;
	int64_t fileSize = -1;
	int64_t wbase = 0;

	friend void VitaFileReleaseCaches();
};

// After a level has loaded: the memory that the open files hold for reading is given back.
void VitaFileReleaseCaches()
{
	std::lock_guard<std::mutex> lock(FileImpl::registryMutex);
	for (FileImpl* file : FileImpl::openFiles)
		file->ReleaseMemory();
}

// For the log: what was read from the card so far, and how fast.
std::string VitaFileStatsText()
{
	char text[360];
	const double readMB = FileImpl::statBytes / 1048576.0;
	const double readMs = FileImpl::statMicros / 1000.0;
	snprintf(text, sizeof(text), "at %.1f s: files: read %.1f MB in %llu reads, %.0f ms on the card (%.1f MB/s); %llu files read whole (%.1f MB); written %.1f MB in %llu writes, %.0f ms",
		(double)sceKernelGetProcessTimeWide() / 1000000.0, readMB, (unsigned long long)FileImpl::statReads, readMs, readMs > 0.0 ? readMB * 1000.0 / readMs : 0.0,
		(unsigned long long)FileImpl::statSlurps, FileImpl::statSlurpBytes / 1048576.0,
		FileImpl::statWritten / 1048576.0, (unsigned long long)FileImpl::statWrites, FileImpl::statWriteMicros / 1000.0);
	return text;
}
'''

edit("Utils/File.cpp",
     r"(?s)(class FileImpl : public File\n\{\npublic:\n\tFileImpl\(FILE\* handle\) : handle\(handle\)\n.*?\tFILE\* handle = nullptr;\n\};\n)",
     lambda m: '#ifdef __vita__ // vita-fileread\n' + VITA_FILEIMPL + '#else\n' + m.group(1) + '#endif\n',
     'vita-fileread')

edit("Utils/File.cpp",
     r'(\tFILE\* handle = fopen\(filename\.c_str\(\), "rb"\);\n\tif \(handle == nullptr\)\n\t\tException::Throw\("Could not open " \+ filename\);\n\n)\treturn std::make_shared<FileImpl>\(handle\);\n',
     lambda m: m.group(1) + '#ifdef __vita__ // vita-fileread-open\n\treturn std::make_shared<FileImpl>(handle, true);\n#else\n\treturn std::make_shared<FileImpl>(handle);\n#endif\n',
     'vita-fileread-open')

# 23. The skeletal mesh (characters) worked out the material, the texture and its TextureInfo again for every face
#     (hundreds per character): once per material now.
VITA_MESHMAT_OLD = r'''		bool needTranslucentPass = false;
		float opacity = MeshOpacity(actor);
		GouraudVertex vertices[3];
		for (const MeshFace& face : mesh->Faces)
		{
			if (face.MaterialIndex >= mesh->Materials.size())
				continue;
			const MeshMaterial& material = mesh->Materials[face.MaterialIndex];
			if (material.PolyFlags & PF_Invisible)
				continue;

			uint32_t renderflags = material.PolyFlags | polyFlags;
			ApplyOpacityFlags(opacity, renderflags);
			UTexture* tex = (renderflags & PF_Environment) ? engine->render->Mesh.envmap : (material.TextureIndex < engine->render->Mesh.textures.size() ? engine->render->Mesh.textures[material.TextureIndex] : nullptr);
			if (!tex)
				continue;

			bool isTranslucent = (renderflags & (PF_Translucent | PF_Modulated | PF_Highlighted)) != 0;
			if (isTranslucent != translucentPass)
			{
				needTranslucentPass |= isTranslucent;
				continue;
			}

			engine->render->UpdateTexture(tex);
			TextureInfo texinfo;
			engine->render->UpdateTextureInfo(texinfo, tex);

			float width = texinfo.Texture ? (float)texinfo.Texture->UsedMipmaps.front().Width : 256.0f;
			float height = texinfo.Texture ? (float)texinfo.Texture->UsedMipmaps.front().Height : 256.0f;
'''
VITA_MESHMAT_NEW = r'''		bool needTranslucentPass = false;
		float opacity = MeshOpacity(actor);
		GouraudVertex vertices[3];

		// vita-meshmat: the flags, the texture and its TextureInfo are the same for every face of a material, but were worked
		// out again for every face (a character has hundreds). Once per material now.
		struct MaterialCache
		{
			bool ready = false;
			bool skip = false;
			uint32_t renderflags = 0;
			TextureInfo texinfo;
			float width = 256.0f;
			float height = 256.0f;
		};
		static std::vector<MaterialCache> materialCache;
		materialCache.assign(mesh->Materials.size(), MaterialCache());

		for (const MeshFace& face : mesh->Faces)
		{
			if (face.MaterialIndex >= mesh->Materials.size())
				continue;
			MaterialCache& mc = materialCache[face.MaterialIndex];
			if (!mc.ready)
			{
				mc.ready = true;
				const MeshMaterial& material = mesh->Materials[face.MaterialIndex];
				if (material.PolyFlags & PF_Invisible)
				{
					mc.skip = true;
				}
				else
				{
					uint32_t renderflags = material.PolyFlags | polyFlags;
					ApplyOpacityFlags(opacity, renderflags);
					UTexture* tex = (renderflags & PF_Environment) ? engine->render->Mesh.envmap : (material.TextureIndex < engine->render->Mesh.textures.size() ? engine->render->Mesh.textures[material.TextureIndex] : nullptr);
					if (!tex)
					{
						mc.skip = true;
					}
					else
					{
						bool isTranslucent = (renderflags & (PF_Translucent | PF_Modulated | PF_Highlighted)) != 0;
						if (isTranslucent != translucentPass)
						{
							needTranslucentPass |= isTranslucent;
							mc.skip = true;
						}
						else
						{
							engine->render->UpdateTexture(tex);
							engine->render->UpdateTextureInfo(mc.texinfo, tex);
							mc.renderflags = renderflags;
							mc.width = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Width : 256.0f;
							mc.height = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Height : 256.0f;
						}
					}
				}
			}
			if (mc.skip)
				continue;

			const uint32_t renderflags = mc.renderflags;
			TextureInfo& texinfo = mc.texinfo;
			const float width = mc.width;
			const float height = mc.height;

'''
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape(VITA_MESHMAT_OLD),
     lambda m: VITA_MESHMAT_NEW,
     'vita-meshmat')

# 24. Rays. A trace is a walk through the level's BSP with double precision maths, and the profile showed 5 percent of the
#     time in them. Two callers made most of them, every frame: the coronas (the glow of a torch: is a wall in the way?) and
#     the light list of a moving actor. The corona's answer is kept for 0.15 s, the actor's list until it moved 6 units.
edit("Render/VisibleCorona.cpp",
     r"(void VisibleCorona::Draw\(VisibleFrame\* frame\)\n\{\n)\tif \(light->bCorona\(\) && light->Skin\(\) && !engine->Level->Collision\.TraceAnyHit\(light->Location\(\), engine->CameraLocation, nullptr, false, true, true\)\)\n",
     lambda m: ('#ifdef __vita__ // vita-corona\n'
                '#include "Packages/Engine/Actors/Info/ULevelInfo.h"\n'
                '// Is a wall between the light and the camera? Asked again only every 0.15 seconds per light.\n'
                'static bool VitaCoronaBlocked(UActor* light)\n'
                '{\n'
                '\tstruct Entry { float time; bool blocked; };\n'
                '\tstatic std::unordered_map<UActor*, Entry> cache;\n'
                '\tfloat now = engine->LevelInfo ? engine->LevelInfo->TimeSeconds() : 0.0f;\n'
                '\tif (cache.size() > 4096)\n'
                '\t\tcache.clear();\n'
                '\tauto it = cache.find(light);\n'
                '\tif (it != cache.end() && now >= it->second.time && now - it->second.time < 0.15f)\n'
                '\t\treturn it->second.blocked;\n'
                '\tbool blocked = engine->Level->Collision.TraceAnyHit(light->Location(), engine->CameraLocation, nullptr, false, true, true);\n'
                '\tcache[light] = { now, blocked };\n'
                '\treturn blocked;\n'
                '}\n'
                '#endif\n\n' + m.group(1) +
                '#ifdef __vita__\n'
                '\tif (light->bCorona() && light->Skin() && !VitaCoronaBlocked(light))\n'
                '#else\n'
                '\tif (light->bCorona() && light->Skin() && !engine->Level->Collision.TraceAnyHit(light->Location(), engine->CameraLocation, nullptr, false, true, true))\n'
                '#endif\n'),
     'vita-corona')

edit("Light/LightSystem.cpp",
     r"\tif \(!actor->TouchingLights\.NeedsUpdate && actor->TouchingLights\.Location == location\)\n\t\treturn;\n",
     lambda m: ('#ifdef __vita__ // vita-lightlist\n'
                '\t{\n'
                '\t\tvec3 moved = actor->TouchingLights.Location - location;\n'
                '\t\tif (!actor->TouchingLights.NeedsUpdate && dot(moved, moved) < 36.0f) // moved less than 6 units since the list was made\n'
                '\t\t\treturn;\n'
                '\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-lightlist')

# 25. UpdateBspInfo runs for every actor every frame ("bsp info" is a constant 4 ms): it builds the actor's matrices (sines and
#     cosines of the rotation, three matrix products) to find its bounding box and then finds it unchanged. An actor whose
#     position, rotation, scale and model are the same as at the last call is left alone (not skeletal meshes and particle
#     systems: their box changes with the animation). "bspinfo_cache=0" in render.cfg turns it off.
edit("Packages/Engine/Actors/UActor.h",
     r"(\t\tUActor\* Prev = nullptr;\n\t\tUActor\* Next = nullptr;\n)(\t\} BspInfo;\n)",
     lambda m: m.group(1) + ('\n\t\t// vita-bspinfo: what the bounding box was made from\n'
                             '\t\tbool SigValid = false;\n'
                             '\t\tfloat SigLocation[3] = { 0.0f, 0.0f, 0.0f };\n'
                             '\t\tfloat SigPrePivot[3] = { 0.0f, 0.0f, 0.0f };\n'
                             '\t\tfloat SigScale3[3] = { 0.0f, 0.0f, 0.0f };\n'
                             '\t\tint SigRotation[3] = { 0, 0, 0 };\n'
                             '\t\tfloat SigDrawScale = 0.0f;\n'
                             '\t\tconst void* SigMesh = nullptr;\n'
                             '\t\tconst void* SigTexture = nullptr;\n'
                             '\t\tconst void* SigBrush = nullptr;\n'
                             '\t\tint SigDrawType = -1;\n'
                             '\t\tfloat LastDrawn = -1000.0f; // when a mesh actor was last drawn (HP1 has no LastRenderTime property)\n') + m.group(2),
     'vita-bspinfo')

edit("Packages/Engine/Actors/UActor_Render.cpp",
     r'(#include "KW\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-bspinc\n',
     'vita-bspinc')

edit("Packages/Engine/Actors/UActor_Render.cpp",
     r"(void UActor::UpdateBspInfo\(\)\n\{\n)",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-bspinfo-guard\n'
                             '\tif (VitaBspInfoCache())\n'
                             '\t{\n'
                             '\t\tconst int drawType = DrawType();\n'
                             '\t\tbool animated = false; // the box of these changes with the animation\n'
                             '\t\tif (drawType == DT_Mesh && Mesh())\n'
                             '\t\t\tanimated = engine->LaunchInfo.IsKnowWonder() && UObject::TryCast<USkeletalMesh>(Mesh()) != nullptr;\n'
                             '\t\telse if (drawType == 8 && engine->LaunchInfo.IsKnowWonder())\n'
                             '\t\t\tanimated = true;\n'
                             '\t\tif (!animated)\n'
                             '\t\t{\n'
                             '\t\t\tconst vec3 location = Location();\n'
                             '\t\t\tconst vec3 prePivot = PrePivot();\n'
                             '\t\t\tconst Rotator rotation = Rotation();\n'
                             '\t\t\tconst float drawScale = DrawScale();\n'
                             '\t\t\tvec3 moverScale(0.0f);\n'
                             '\t\t\tif (drawType == DT_Brush)\n'
                             '\t\t\t\tif (UMover* mover = UObject::TryCast<UMover>(this))\n'
                             '\t\t\t\t\tmoverScale = mover->MainScale().Scale;\n'
                             '\t\t\tconst void* mesh = Mesh();\n'
                             '\t\t\tconst void* texture = Texture();\n'
                             '\t\t\tconst void* brush = Brush();\n'
                             '\t\t\tbool same = BspInfo.Node && BspInfo.SigValid && BspInfo.SigDrawType == drawType &&\n'
                             '\t\t\t\tBspInfo.SigMesh == mesh && BspInfo.SigTexture == texture && BspInfo.SigBrush == brush &&\n'
                             '\t\t\t\tBspInfo.SigDrawScale == drawScale && BspInfo.SigRotation[0] == rotation.Pitch &&\n'
                             '\t\t\t\tBspInfo.SigRotation[1] == rotation.Yaw && BspInfo.SigRotation[2] == rotation.Roll &&\n'
                             '\t\t\t\tBspInfo.SigLocation[0] == location.x && BspInfo.SigLocation[1] == location.y && BspInfo.SigLocation[2] == location.z &&\n'
                             '\t\t\t\tBspInfo.SigPrePivot[0] == prePivot.x && BspInfo.SigPrePivot[1] == prePivot.y && BspInfo.SigPrePivot[2] == prePivot.z &&\n'
                             '\t\t\t\tBspInfo.SigScale3[0] == moverScale.x && BspInfo.SigScale3[1] == moverScale.y && BspInfo.SigScale3[2] == moverScale.z;\n'
                             '\t\t\tif (same)\n'
                             '\t\t\t\treturn;\n'
                             '\t\t\tBspInfo.SigValid = true;\n'
                             '\t\t\tBspInfo.SigDrawType = drawType;\n'
                             '\t\t\tBspInfo.SigMesh = mesh;\n'
                             '\t\t\tBspInfo.SigTexture = texture;\n'
                             '\t\t\tBspInfo.SigBrush = brush;\n'
                             '\t\t\tBspInfo.SigDrawScale = drawScale;\n'
                             '\t\t\tBspInfo.SigRotation[0] = rotation.Pitch;\n'
                             '\t\t\tBspInfo.SigRotation[1] = rotation.Yaw;\n'
                             '\t\t\tBspInfo.SigRotation[2] = rotation.Roll;\n'
                             '\t\t\tBspInfo.SigLocation[0] = location.x; BspInfo.SigLocation[1] = location.y; BspInfo.SigLocation[2] = location.z;\n'
                             '\t\t\tBspInfo.SigPrePivot[0] = prePivot.x; BspInfo.SigPrePivot[1] = prePivot.y; BspInfo.SigPrePivot[2] = prePivot.z;\n'
                             '\t\t\tBspInfo.SigScale3[0] = moverScale.x; BspInfo.SigScale3[1] = moverScale.y; BspInfo.SigScale3[2] = moverScale.z;\n'
                             '\t\t}\n'
                             '\t}\n'
                             '#endif\n'),
     'vita-bspinfo-guard')

# 26. Far, unseen mesh actors (the characters in other rooms) are ticked every tick_far_rate frames with the time of those
#     frames: the scripts and the physics of every actor of the level ran every frame. Actors without a mesh (the controllers of
#     cutscenes, triggers, lights) and actors that were drawn in the last second are never touched. "tick_far_distance=0" in
#     render.cfg turns it off.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-tickinc\n',
     'vita-tickinc')

edit("Packages/Engine/Resources/Level/ULevel.cpp",
     r"(void ULevel::Tick\(float elapsed, bool gamePaused\)\n\{\n)",
     lambda m: ('#ifdef __vita__ // vita-tickhelper\n'
                'static bool VitaFarAndUnseen(UActor* actor, float now, const vec3& camera, float distance)\n'
                '{\n'
                '\tif (actor->DrawType() != DT_Mesh || !actor->Mesh() || actor->bAlwaysTick())\n'
                '\t\treturn false;\n'
                '\tif (now - actor->BspInfo.LastDrawn < 1.0f)\n'
                '\t\treturn false;\n'
                '\tvec3 d = actor->Location() - camera;\n'
                '\treturn dot(d, d) > distance * distance;\n'
                '}\n'
                '#endif\n\n') + m.group(1),
     'vita-tickhelper')

edit("Packages/Engine/Resources/Level/ULevel.cpp",
     r"\telse\n\t\{\n\t\tfor \(size_t i = 0; i < Actors\.size\(\); i\+\+\)\n\t\t\{\n\t\t\tif \(Actors\[i\]\)\n\t\t\t\tTickActor\(elapsed, Actors\[i\]\);\n\t\t\}\n\t\}\n",
     lambda m: ('\telse\n'
                '\t{\n'
                '#ifdef __vita__ // vita-tickfar\n'
                '\t\tconst float farDistance = VitaTickFarDistance();\n'
                '\t\tconst int farRate = VitaTickFarRate();\n'
                '\t\tstatic int tickFrame = 0;\n'
                '\t\ttickFrame++;\n'
                '\t\tconst float now = engine->LevelInfo ? engine->LevelInfo->TimeSeconds() : 0.0f;\n'
                '\t\tconst vec3 camera = engine->CameraLocation;\n'
                '\t\tfor (size_t i = 0; i < Actors.size(); i++)\n'
                '\t\t{\n'
                '\t\t\tUActor* actor = Actors[i];\n'
                '\t\t\tif (!actor)\n'
                '\t\t\t\tcontinue;\n'
                '\t\t\tif (farDistance > 0.0f && VitaFarAndUnseen(actor, now, camera, farDistance))\n'
                '\t\t\t{\n'
                '\t\t\t\tif (((int)i + tickFrame) % farRate != 0)\n'
                '\t\t\t\t\tcontinue;\n'
                '\t\t\t\tTickActor(elapsed * (float)farRate, actor);\n'
                '\t\t\t}\n'
                '\t\t\telse\n'
                '\t\t\t{\n'
                '\t\t\t\tTickActor(elapsed, actor);\n'
                '\t\t\t}\n'
                '\t\t}\n'
                '#else\n'
                '\t\tfor (size_t i = 0; i < Actors.size(); i++)\n'
                '\t\t{\n'
                '\t\t\tif (Actors[i])\n'
                '\t\t\t\tTickActor(elapsed, Actors[i]);\n'
                '\t\t}\n'
                '#endif\n'
                '\t}\n'),
     'vita-tickfar')

# the renderer's side: a drawn actor remembers when
edit("Render/VisibleMesh.cpp",
     r"(\tengine->render->Stats\.Actors\+\+;\n)(\tengine->Level->Light\.UpdateLightList\(actor\);\n)",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-lastrender\n'
                             '\tactor->BspInfo.LastDrawn = engine->LevelInfo ? engine->LevelInfo->TimeSeconds() : 0.0f;\n'
                             '#endif\n') + m.group(2),
     'vita-lastrender')

# 27. Procedural textures (water, fire) are updated 25 times a second by default; 12 is enough on a 5 inch screen, and each
#     update also means one upload of the picture.
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     r'(#include "UTexture\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-texinc\n',
     'vita-texinc')

edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     r"(\t\tmaxFrameRate = 25\.0f; // Original game wasn't designed for 240 hz monitors!\n)",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-texfps\n'
                             '\tmaxFrameRate = std::min(maxFrameRate, VitaTextureFps());\n'
                             '#endif\n'),
     'vita-texfps')

# 28. The first version of 25-26 read the script property Actor.LastRenderTime, which HP1's Actor class does not have: the
#     engine stopped at the first tick with "FATAL: Property offset out of bounds!". The time is kept in a C++ member now.
edit("Packages/Engine/Actors/UActor.h",
     r"(\t\tint SigDrawType = -1;\n)",
     lambda m: m.group(1) + '\t\tfloat LastDrawn = -1000.0f; // when a mesh actor was last drawn (HP1 has no LastRenderTime property)\n',
     'LastDrawn')

edit("Packages/Engine/Resources/Level/ULevel.cpp",
     r"now - actor->LastRenderTime\(\) < 1\.0f",
     lambda m: 'now - actor->BspInfo.LastDrawn < 1.0f',
     'BspInfo.LastDrawn')

edit("Render/VisibleMesh.cpp",
     r"actor->LastRenderTime\(\) = engine->LevelInfo",
     lambda m: 'actor->BspInfo.LastDrawn = engine->LevelInfo',
     'BspInfo.LastDrawn')

# 29. Two more timers for the log: the particle simulation (a spell makes hundreds of particles) and the decoding of a sound the first
#     time it plays. With the SLOW FRAME lines of the renderer they show what stops the game while a spell is cast.
edit("../../knowwonder/KWParticleFX.cpp",
     r'(#include "KWParticleFX\.h"\n)',
     lambda m: m.group(1) + '#include "VitaTimers.h" // vita-ptinc\n',
     'vita-ptinc')
edit("../../knowwonder/KWParticleFX.cpp",
     r"(\tvoid TickParticleFX\(UActor\* a, float elapsed\)\n\t\{\n)",
     lambda m: m.group(1) + '\t\tVITA_TIMER(ParticleTick); // vita-ptimer\n',
     'vita-ptimer')

edit("Packages/Engine/Resources/USound.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaTimers.h" // vita-sndinc\n',
     'vita-sndinc')
edit("Packages/Engine/Resources/USound.cpp",
     r"(void USound::CheckSoundSamples\(\)\n\{\n\tif \(samples\.size\(\) > 0\)\n\t\treturn;\n)",
     lambda m: m.group(1) + '\n\tVITA_TIMER(SoundLoad); // vita-sndtimer\n',
     'vita-sndtimer')

# 30. Animated lights. Torches (LE_TorchWaver, LE_FireWaver, pulsing and blinking lights) were marked as changed every frame: every
#     lightmap they touch was built again and uploaded again, every frame (in the profile: GetTextureEntry 7-12 percent, building
#     lightmaps, CollectLights). Marked every light_anim_divider-th frame (3) instead; the flicker of the original is 25 Hz anyway.
edit("Light/LightSystem.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-laninc\n',
     'vita-laninc')
edit("Light/LightSystem.cpp",
     r"\t\tif \(needsUpdate\)\n\t\t\tactor->Light\.LastUpdate = FrameCounter;\n",
     lambda m: ('#ifdef __vita__ // vita-lightanim\n'
                '\t\tif (needsUpdate && (VitaLightAnimDivider() <= 1 || FrameCounter % VitaLightAnimDivider() == 0))\n'
                '\t\t\tactor->Light.LastUpdate = FrameCounter;\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-lightanim')

# 31. Rays. While aiming (the cast button held) the game asks for visibility again and again (every actor of the level in turn):
#     CollisionSystem::TraceAnyHit was 7-20 percent of all the time, and most of it was the walk through every cell of the collision grid
#     (a hash lookup per cell and a pass over the actors in it) for rays that ignore actors: nothing but movers can stop those.
#     (a) such a ray tests the (few) movers only, with a box test first; (b) the same ray between the same points is answered from
#     memory for 0.12 s. Switch off with mover_trace=0 / trace_cache=0 in render.cfg.
edit("Collision/TopLevel/CollisionSystem.h",
     r"(\tstd::unordered_map<uint32_t, std::list<UActor\*>> CollisionActors;\n)",
     lambda m: m.group(1) + '\tstd::vector<UActor*> MoverActors; // vita-movers: the movers that are in the grid above\n',
     'vita-movers')

edit("Collision/TopLevel/CollisionTest.h",
     r"(\tULevel\* GetLevel\(\) const \{ return Collision->Level; \}\n)",
     lambda m: ('\tconst std::vector<UActor*>& GetMovers() const { return Collision->MoverActors; } // vita-movers\n' + m.group(1)),
     'vita-movers')

edit("Collision/TopLevel/CollisionSystem.cpp",
     r"(\t\tactor->Collision\.Inserted = true;\n)",
     lambda m: m.group(1) + '\t\tif (UObject::TryCast<UMover>(actor)) // vita-movers\n\t\t\tMoverActors.push_back(actor);\n',
     'vita-movers')

edit("Collision/TopLevel/CollisionSystem.cpp",
     r"(\t\tactor->Collision\.Inserted = false;\n)",
     lambda m: '\t\tMoverActors.erase(std::remove(MoverActors.begin(), MoverActors.end(), actor), MoverActors.end()); // vita-movers-remove\n' + m.group(1),
     'vita-movers-remove')

edit("Collision/TopLevel/CollisionSystem.cpp",
     r"(#include \"VitaConfig\.h\".*\n)?bool CollisionSystem::TraceAnyHit\(vec3 from, vec3 to, UActor\* tracingActor, bool traceActors, bool traceWorld, bool visibilityOnly\)\n\{\n\tTraceTester trace\(this\);\n\treturn trace\.TraceAnyHit\(from, to, tracingActor, traceActors, traceWorld, visibilityOnly\);\n\}\n",
     lambda m: ('#ifdef __vita__ // vita-tracecache\n'
                '#include "VitaConfig.h"\n'
                'bool CollisionSystem::TraceAnyHit(vec3 from, vec3 to, UActor* tracingActor, bool traceActors, bool traceWorld, bool visibilityOnly)\n'
                '{\n'
                '\tTraceTester trace(this);\n'
                '\tif (traceActors || !VitaTraceCache() || !engine->LevelInfo)\n'
                '\t\treturn trace.TraceAnyHit(from, to, tracingActor, traceActors, traceWorld, visibilityOnly);\n'
                '\n'
                '\t// a ray that ignores actors between the same two points as a moment ago: the same answer (a lamp seen from a still camera)\n'
                '\tstruct Entry { float values[6]; UActor* actor; uint32_t flags; float time; bool result; bool used; };\n'
                '\tstatic Entry cache[1024];\n'
                '\tconst float now = engine->LevelInfo->TimeSeconds();\n'
                '\tfloat values[6] = { from.x, from.y, from.z, to.x, to.y, to.z };\n'
                '\tconst uint32_t flags = (traceWorld ? 1u : 0u) | (visibilityOnly ? 2u : 0u);\n'
                '\tuint32_t hash = 2166136261u;\n'
                '\tfor (float value : values)\n'
                '\t{\n'
                '\t\tuint32_t bits;\n'
                '\t\tmemcpy(&bits, &value, 4);\n'
                '\t\thash = (hash ^ bits) * 16777619u;\n'
                '\t}\n'
                '\thash = (hash ^ (uint32_t)(uintptr_t)tracingActor ^ flags) * 16777619u;\n'
                '\tEntry& entry = cache[(hash ^ (hash >> 11)) & 1023u];\n'
                '\tif (entry.used && entry.actor == tracingActor && entry.flags == flags && now >= entry.time && now - entry.time < 0.12f &&\n'
                '\t\tmemcmp(entry.values, values, sizeof(values)) == 0)\n'
                '\t\treturn entry.result;\n'
                '\n'
                '\tbool result = trace.TraceAnyHit(from, to, tracingActor, traceActors, traceWorld, visibilityOnly);\n'
                '\tmemcpy(entry.values, values, sizeof(values));\n'
                '\tentry.actor = tracingActor;\n'
                '\tentry.flags = flags;\n'
                '\tentry.time = now;\n'
                '\tentry.result = result;\n'
                '\tentry.used = true;\n'
                '\treturn result;\n'
                '}\n'
                '#else\n' + 'bool CollisionSystem::TraceAnyHit(vec3 from, vec3 to, UActor* tracingActor, bool traceActors, bool traceWorld, bool visibilityOnly)\n{\n\tTraceTester trace(this);\n\treturn trace.TraceAnyHit(from, to, tracingActor, traceActors, traceWorld, visibilityOnly);\n}\n#endif\n'),
     'vita-tracecache')

edit("Collision/TopLevel/TraceTest.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-tracinc\n',
     'vita-tracinc')

edit("Collision/TopLevel/TraceTest.cpp",
     r"(bool TraceTester::TraceAnyHit\(vec3 from, vec3 to, UActor\* tracingActor, bool traceActors, bool traceWorld, bool visibilityOnly\)\n\{\n)",
     lambda m: ('#ifdef __vita__ // vita-boxtest\n'
                '// Does the segment a-b touch the box (centre, half sizes)? A slab test.\n'
                'static bool VitaSegmentHitsBox(const vec3& a, const vec3& b, const vec3& center, const vec3& extents)\n'
                '{\n'
                '\tconst float start[3] = { a.x, a.y, a.z };\n'
                '\tconst float delta[3] = { b.x - a.x, b.y - a.y, b.z - a.z };\n'
                '\tconst float lo[3] = { center.x - extents.x, center.y - extents.y, center.z - extents.z };\n'
                '\tconst float hi[3] = { center.x + extents.x, center.y + extents.y, center.z + extents.z };\n'
                '\tfloat tmin = 0.0f, tmax = 1.0f;\n'
                '\tfor (int i = 0; i < 3; i++)\n'
                '\t{\n'
                '\t\tif (std::abs(delta[i]) < 1e-6f)\n'
                '\t\t{\n'
                '\t\t\tif (start[i] < lo[i] || start[i] > hi[i])\n'
                '\t\t\t\treturn false;\n'
                '\t\t}\n'
                '\t\telse\n'
                '\t\t{\n'
                '\t\t\tfloat t1 = (lo[i] - start[i]) / delta[i];\n'
                '\t\t\tfloat t2 = (hi[i] - start[i]) / delta[i];\n'
                '\t\t\tif (t1 > t2)\n'
                '\t\t\t\tstd::swap(t1, t2);\n'
                '\t\t\ttmin = std::max(tmin, t1);\n'
                '\t\t\ttmax = std::min(tmax, t2);\n'
                '\t\t\tif (tmin > tmax)\n'
                '\t\t\t\treturn false;\n'
                '\t\t}\n'
                '\t}\n'
                '\treturn true;\n'
                '}\n'
                '#endif\n\n') + m.group(1),
     'vita-boxtest')

edit("Collision/TopLevel/TraceTest.cpp",
     r"(\tint checkCounter = NextCheckCounter\(\);\n\tivec3 start = GetRayStartExtents\(from, to\);\n\tivec3 end = GetRayEndExtents\(from, to\);\n)(\tif \(end\.x - start\.x < 100 && end\.y - start\.y < 100 && end\.z - start\.z < 100\)\n\t\{\n\t\tfor \(int z = start\.z; z < end\.z; z\+\+\)\n\t\t\{\n\t\t\tfor \(int y = start\.y; y < end\.y; y\+\+\)\n\t\t\t\{\n\t\t\t\tfor \(int x = start\.x; x < end\.x; x\+\+\)\n\t\t\t\t\{\n\t\t\t\t\tfor \(UActor\* actor : GetActors\(x, y, z\)\)\n\t\t\t\t\t\{\n\t\t\t\t\t\tif \(actor->Collision\.CheckCounter != checkCounter\)\n\t\t\t\t\t\t\{\n\t\t\t\t\t\t\tactor->Collision\.CheckCounter = checkCounter;\n\t\t\t\t\t\t\tif \(actor != tracingActor && actor->bBlockActors\(\)\)\n\t\t\t\t\t\t\t\{\n\t\t\t\t\t\t\t\tTraceActor\(actor, origin, tmin, direction, tmax, 0\.0, 0\.0, traceActors, traceWorld, visibilityOnly, hits\);\n\t\t\t\t\t\t\t\tif \(!hits\.empty\(\)\)\n\t\t\t\t\t\t\t\t\treturn true;)",
     lambda m: (m.group(1) +
                '#ifdef __vita__ // vita-movertrace\n'
                '\tif (!traceActors && VitaMoverTrace())\n'
                '\t{\n'
                '\t\t// nothing but a mover (a door) can stop a ray that ignores actors: no walk through the grid\n'
                '\t\tif (end.x - start.x < 100 && end.y - start.y < 100 && end.z - start.z < 100)\n'
                '\t\t{\n'
                '\t\t\tfor (UActor* actor : GetMovers())\n'
                '\t\t\t{\n'
                '\t\t\t\tif (actor == tracingActor || !actor->bBlockActors())\n'
                '\t\t\t\t\tcontinue;\n'
                '\t\t\t\tif (!VitaSegmentHitsBox(from, to, actor->Collision.Location, actor->Collision.Extents + vec3(2.0f)))\n'
                '\t\t\t\t\tcontinue;\n'
                '\t\t\t\tTraceActor(actor, origin, tmin, direction, tmax, 0.0, 0.0, traceActors, traceWorld, visibilityOnly, hits);\n'
                '\t\t\t\tif (!hits.empty())\n'
                '\t\t\t\t\treturn true;\n'
                '\t\t\t}\n'
                '\t\t}\n'
                '\t}\n'
                '\telse\n'
                '#endif\n' + m.group(2)),
     'vita-movertrace')

# 32. The file reader reads ahead more when a file is being scanned (up to 256 KB blocks), and goes back to 32 KB for scattered reads.
#     (A tree that has the first version gets the new class here; a fresh tree already got it above.)
edit("Utils/File.cpp",
     r"(?s)(#ifdef __vita__ // vita-fileread\n).*?(#else\nclass FileImpl : public File)",
     lambda m: m.group(1) + VITA_FILEIMPL + m.group(2),
     'vita-fileread2')

# 33. The log: every line was written with std::endl, which is a write to the memory card each time. Lines are buffered and written out
#     once a second (and at once for a FATAL line). A crash loses at most the last second of the log.
edit("GameApp.cpp",
     r'(\t\t\tLogger::Get\(\)->SetCallback\(\[&\]\(const LogMessageLine& line\) \{\n)\t\t\t\tlogfile << "\[" << line\.Time << "\] " << line\.Source << \(line\.Source\.empty\(\) \? "" : ": "\) << line\.Text << std::endl;\n',
     lambda m: (m.group(1) +
                '#ifdef __vita__ // vita-logbuffer\n'
                '\t\t\t\tlogfile << "[" << line.Time << "] " << line.Source << (line.Source.empty() ? "" : ": ") << line.Text << \'\\n\';\n'
                '\t\t\t\tstatic auto lastFlush = std::chrono::steady_clock::now();\n'
                '\t\t\t\tauto now = std::chrono::steady_clock::now();\n'
                '\t\t\t\tif (now - lastFlush > std::chrono::seconds(1) || line.Text.find("FATAL") != std::string::npos)\n'
                '\t\t\t\t{\n'
                '\t\t\t\t\tlogfile.flush();\n'
                '\t\t\t\t\tlastFlush = now;\n'
                '\t\t\t\t}\n'
                '#else\n'
                '\t\t\t\tlogfile << "[" << line.Time << "] " << line.Source << (line.Source.empty() ? "" : ": ") << line.Text << std::endl;\n'
                '#endif\n'),
     'vita-logbuffer')

# 34. Meshes. For every character in view the game skins the vertices, works out the normals and lights every vertex (3-5 lights,
#     a square root and two divisions each): in a hall full of people that is most of the 'meshes' time. The result is kept per actor:
#     the second pass of a frame (translucent faces) uses it, and so does a mesh that is far away and has not moved, for a few frames.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r'(#include "KW\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-skininc\n#include "VitaTimers.h"\n',
     'vita-skininc')

edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"(\tbool DrawSkeletalMesh\(VisibleFrame\* frame, UActor\* actor, UActor\* lightLocationActor, USkeletalMesh\* mesh, bool translucentPass\)\n\t\{\n)",
     lambda m: ('#ifdef __vita__ // vita-skincache\n'
                '\tstruct VitaSkinEntry\n'
                '\t{\n'
                '\t\tunsigned frame = 0;\n'
                '\t\tconst void* mesh = nullptr;\n'
                '\t\tvec3 location = vec3(0.0f);\n'
                '\t\tRotator rotation;\n'
                '\t\tfloat scale = 0.0f;\n'
                '\t\tvec3 unlit = vec3(0.0f);\n'
                '\t\tArray<vec3> verts, normals, lights;\n'
                '\t\tbool valid = false;\n'
                '\t};\n'
                '\tstatic std::unordered_map<UActor*, VitaSkinEntry> VitaSkinCache;\n'
                '\n'
                '\tstruct VitaSkinHit\n'
                '\t{\n'
                '\t\tbool hit = false;\n'
                '\t\tvec3 unlit = vec3(0.0f);\n'
                '\t};\n'
                '\n'
                '\t// Is there a kept result for this actor that is still good: drawn this frame already (the second pass), or (far away, not moved)\n'
                '\t// a few frames ago? A mesh close to the camera is never drawn from an older frame.\n'
                '\tstatic VitaSkinHit VitaSkinLookup(UActor* actor, USkeletalMesh* mesh, Array<vec3>& verts, Array<vec3>& normals, Array<vec3>& lights)\n'
                '\t{\n'
                '\t\tVitaSkinHit result;\n'
                '\t\tif (!VitaSkinCacheOn())\n'
                '\t\t\treturn result;\n'
                '\t\tauto it = VitaSkinCache.find(actor);\n'
                '\t\tif (it == VitaSkinCache.end() || !it->second.valid)\n'
                '\t\t\treturn result;\n'
                '\t\tVitaSkinEntry& e = it->second;\n'
                '\t\tconst vec3 location = actor->Location();\n'
                '\t\tconst Rotator rotation = actor->Rotation();\n'
                '\t\tif (e.mesh != mesh || !(e.location == location) || e.rotation.Pitch != rotation.Pitch || e.rotation.Yaw != rotation.Yaw ||\n'
                '\t\t\te.rotation.Roll != rotation.Roll || e.scale != actor->DrawScale())\n'
                '\t\t\treturn result;\n'
                '\t\tconst unsigned age = VitaTimers::frameNumber - e.frame;\n'
                '\t\tconst vec3 d = location - engine->CameraLocation;\n'
                '\t\tconst float distSqr = dot(d, d);\n'
                '\t\tconst unsigned maxAge = distSqr < 700.0f * 700.0f ? 0u : (distSqr < 1500.0f * 1500.0f ? 1u : VitaSkinFarAge());\n'
                '\t\tif (age > maxAge)\n'
                '\t\t\treturn result;\n'
                '\t\tverts = e.verts;\n'
                '\t\tnormals = e.normals;\n'
                '\t\tlights = e.lights;\n'
                '\t\tresult.hit = true;\n'
                '\t\tresult.unlit = e.unlit;\n'
                '\t\treturn result;\n'
                '\t}\n'
                '\n'
                '\tstatic void VitaSkinStore(UActor* actor, USkeletalMesh* mesh, const Array<vec3>& verts, const Array<vec3>& normals, const Array<vec3>& lights, const vec3& unlit)\n'
                '\t{\n'
                '\t\tif (!VitaSkinCacheOn())\n'
                '\t\t\treturn;\n'
                '\t\tif (VitaSkinCache.size() > 600)\n'
                '\t\t\tVitaSkinCache.clear();   // actors that are gone leave their entries behind\n'
                '\t\tVitaSkinEntry& e = VitaSkinCache[actor];\n'
                '\t\te.frame = VitaTimers::frameNumber;\n'
                '\t\te.mesh = mesh;\n'
                '\t\te.location = actor->Location();\n'
                '\t\te.rotation = actor->Rotation();\n'
                '\t\te.scale = actor->DrawScale();\n'
                '\t\te.unlit = unlit;\n'
                '\t\te.verts = verts;\n'
                '\t\te.normals = normals;\n'
                '\t\te.lights = lights;\n'
                '\t\te.valid = true;\n'
                '\t}\n'
                '#endif\n\n') + m.group(1),
     'vita-skincache')

edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"(\t\tstatic Array<vec3> verts;\n\t\tstatic Array<vec3> normals;\n)\t\tif \(!GetFrame\(actor, mesh, verts\)\)\n\t\t\treturn false;\n",
     lambda m: (m.group(1) +
                '#ifdef __vita__ // vita-skinuse\n'
                '\t\tstatic Array<vec3> vertexLights;\n'
                '\t\tVitaSkinHit skin = VitaSkinLookup(actor, mesh, verts, normals, vertexLights);\n'
                '\t\tif (!skin.hit && !GetFrame(actor, mesh, verts))\n'
                '\t\t\treturn false;\n'
                '#else\n'
                '\t\tif (!GetFrame(actor, mesh, verts))\n'
                '\t\t\treturn false;\n'
                '#endif\n'),
     'vita-skinuse')

edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"(\t\t// bMeshCurvy points them away from the actor's location instead\.\n)\t\tnormals\.clear\(\);\n",
     lambda m: m.group(1) + '#ifdef __vita__ // vita-skinnormals\n\t\tif (!skin.hit)\n\t\t{\n#endif\n\t\tnormals.clear();\n',
     'vita-skinnormals')

edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"(\t\tfor \(vec3& n : normals\)\n\t\t\tn \*= 1\.0f / std::sqrt\(dot\(n, n\) \+ 0\.001f\);\n)",
     lambda m: m.group(1) + '#ifdef __vita__ // vita-skinnormals-end\n\t\t}\n#endif\n',
     'vita-skinnormals-end')

edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"\t\tMeshLighting lighting;\n\t\tSetupMeshLighting\(lighting, actor, lightLocationActor, zoneActor\);\n\t\tstatic Array<vec3> vertexLights;\n\t\tvertexLights\.resize\(verts\.size\(\)\);\n\t\tfor \(size_t i = 0; i < verts\.size\(\); i\+\+\)\n\t\t\tvertexLights\[i\] = lighting\.Light\(verts\[i\], normals\[i\]\);\n",
     lambda m: ('\t\tMeshLighting lighting;\n'
                '#ifdef __vita__ // vita-skinlight\n'
                '\t\tif (skin.hit)\n'
                '\t\t{\n'
                '\t\t\tlighting.Unlit = skin.unlit;\n'
                '\t\t}\n'
                '\t\telse\n'
                '\t\t{\n'
                '\t\t\tSetupMeshLighting(lighting, actor, lightLocationActor, zoneActor);\n'
                '\t\t\tvertexLights.resize(verts.size());\n'
                '\t\t\tfor (size_t i = 0; i < verts.size(); i++)\n'
                '\t\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n'
                '\t\t\tVitaSkinStore(actor, mesh, verts, normals, vertexLights, lighting.Unlit);\n'
                '\t\t}\n'
                '#else\n'
                '\t\tSetupMeshLighting(lighting, actor, lightLocationActor, zoneActor);\n'
                '\t\tstatic Array<vec3> vertexLights;\n'
                '\t\tvertexLights.resize(verts.size());\n'
                '\t\tfor (size_t i = 0; i < verts.size(); i++)\n'
                '\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n'
                '#endif\n'),
     'vita-skinlight')

# 35. At most mesh_light_max lights per mesh (the strongest come first): the cost of lighting a vertex is per light.
edit("../../knowwonder/KWMeshLight.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-inc-maxlights\n',
     'vita-inc-maxlights')
edit("../../knowwonder/KWMeshLight.cpp",
     r"(\t\t\tif \(c\.Fade > 1 && cache\.Lights\.size\(\) < 16\)\n\t\t\t\tcache\.Lights\.push_back\(\{ light, c\.Fade \}\);\n\t\t\}\n)",
     lambda m: m.group(1) + '#ifdef __vita__ // vita-cap-maxlights\n\t\tout.NumLights = std::min(out.NumLights, VitaMeshLightMax());\n#endif\n',
     'vita-cap-maxlights')

# 36. tick_far_visible: an actor that was drawn a moment ago but is very far away is ticked less often as well.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     r"\tif \(now - actor->BspInfo\.LastDrawn < 1\.0f\)\n\t\treturn false;\n\tvec3 d = actor->Location\(\) - camera;\n\treturn dot\(d, d\) > distance \* distance;\n",
     lambda m: ('\tvec3 d = actor->Location() - camera;\n'
                '\tconst float distSqr = dot(d, d);\n'
                '\tif (now - actor->BspInfo.LastDrawn < 1.0f)   // vita-tickvisible: in view: only when it is really far\n'
                '\t\treturn VitaTickFarVisible() > 0.0f && distSqr > VitaTickFarVisible() * VitaTickFarVisible();\n'
                '\treturn distSqr > distance * distance;\n'),
     'vita-tickvisible')

# 37. lightmap=0 / fog=0 in render.cfg: the engine does not build the lightmaps / fog maps at all (it was the renderer that ignored them)
edit("Render/VisibleNode.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-inc-nolight\n',
     'vita-inc-nolight')
edit("Render/VisibleNode.cpp",
     re.escape("\tTextureInfo lightmap;\n\tif ((PolyFlags & PF_Unlit) == 0)\n\t\tlightmap = engine->Level->Light.GetLevelLightmap(surface, zoneActor, model);\n"
               "\tTextureInfo fogmap = engine->Level->Light.GetLevelFogmap(surface, engine->CameraActor->Region().Zone, model);\n"),
     lambda m: ('\tTextureInfo lightmap;\n'
                '\tTextureInfo fogmap;\n'
                '#ifdef __vita__ // vita-build-nolight\n'
                '\tif ((PolyFlags & PF_Unlit) == 0 && VitaLightmapsOn())\n'
                '\t\tlightmap = engine->Level->Light.GetLevelLightmap(surface, zoneActor, model);\n'
                '\tif (VitaFogOn())\n'
                '\t\tfogmap = engine->Level->Light.GetLevelFogmap(surface, engine->CameraActor->Region().Zone, model);\n'
                '#else\n'
                '\tif ((PolyFlags & PF_Unlit) == 0)\n'
                '\t\tlightmap = engine->Level->Light.GetLevelLightmap(surface, zoneActor, model);\n'
                '\tfogmap = engine->Level->Light.GetLevelFogmap(surface, engine->CameraActor->Region().Zone, model);\n'
                '#endif\n'),
     'vita-build-nolight')
edit("Render/VisibleBrush.cpp",
     r'(#include "Precomp\.h"\n)',
     lambda m: m.group(1) + '#include "VitaConfig.h" // vita-nolightinc2\n',
     'vita-nolightinc2')
edit("Render/VisibleBrush.cpp",
     re.escape("\tTextureInfo lightmap;\n\tif ((PolyFlags & PF_Unlit) == 0)\n\t\tlightmap = engine->Level->Light.GetMoverLightmap(mover, poly, zoneActor, model);\n"
               "\tTextureInfo fogmap = engine->Level->Light.GetMoverFogmap(mover, poly, engine->CameraActor->Region().Zone, model);\n"),
     lambda m: ('\tTextureInfo lightmap;\n'
                '\tTextureInfo fogmap;\n'
                '#ifdef __vita__ // vita-nolight2\n'
                '\tif ((PolyFlags & PF_Unlit) == 0 && VitaLightmapsOn())\n'
                '\t\tlightmap = engine->Level->Light.GetMoverLightmap(mover, poly, zoneActor, model);\n'
                '\tif (VitaFogOn())\n'
                '\t\tfogmap = engine->Level->Light.GetMoverFogmap(mover, poly, engine->CameraActor->Region().Zone, model);\n'
                '#else\n'
                '\tif ((PolyFlags & PF_Unlit) == 0)\n'
                '\t\tlightmap = engine->Level->Light.GetMoverLightmap(mover, poly, zoneActor, model);\n'
                '\tfogmap = engine->Level->Light.GetMoverFogmap(mover, poly, engine->CameraActor->Region().Zone, model);\n'
                '#endif\n'),
     'vita-nolight2')

# 38. Loading and saving. (a) The file reader (see the comment in the class): 8 KB blocks for scattered reads, read() instead of stdio,
#     a package with many scattered reads is read whole once, the memory is given back when a level has loaded. (b) A file that is
#     written (a save) is written in blocks of 256 KB: every little write of the level's objects was a write to the card. (c) The log
#     says what was read and how fast. (d) The checksums of two system files at the start are not computed.
edit("Utils/File.cpp",
     r"(?s)(#ifdef __vita__ // vita-fileread\n).*?(#else\nclass FileImpl : public File)",
     lambda m: m.group(1) + VITA_FILEIMPL + m.group(2),
     'vita-fileread3')

edit("Utils/File.cpp",
     r'(\tFILE\* handle = fopen\(filename\.c_str\(\), "wb"\);\n\tif \(handle == nullptr\)\n\t\tException::Throw\("Could not create " \+ filename\);\n\n)\treturn std::make_shared<FileImpl>\(handle\);\n',
     lambda m: (m.group(1) +
                '#ifdef __vita__ // vita-filewrite\n'
                '\treturn std::make_shared<FileImpl>(handle, false, true);\n'
                '#else\n'
                '\treturn std::make_shared<FileImpl>(handle);\n'
                '#endif\n'),
     'vita-filewrite')

edit("Engine.cpp",
     r"(void Engine::LoadMap\(const UnrealURL& url, const std::map<std::string, std::string>& travelInfo\)\n\{\n#ifdef __vita__ // vita-loadlog)",
     lambda m: ('#ifdef __vita__ // vita-fileio-decl\n'
                'std::string VitaFileStatsText();\n'
                'void VitaFileReleaseCaches();\n'
                '#endif\n\n') + m.group(1),
     'vita-fileio-decl')

edit("Engine.cpp",
     r"(\t\}\n)(#endif\n\tClientTravelInfo\.URL\.Clear\(\);\n)",
     lambda m: m.group(1) + '\tLogMessage("LoadMap: " + VitaFileStatsText()); // vita-iostart\n' + m.group(2),
     'vita-iostart')

edit("Engine.cpp",
     r'(\tif \(LevelInfo->Game\(\)\)\n\t\tCallEvent\(LevelInfo->Game\(\), "DetailChange", \{\}\);\n)(\}\n)',
     lambda m: (m.group(1) +
                '#ifdef __vita__ // vita-ioend\n'
                '\tVitaFileReleaseCaches();\n'
                '\tLogMessage("LoadMap done: " + VitaFileStatsText());\n'
                '#endif\n' + m.group(2)),
     'vita-ioend')

edit("Engine.cpp",
     r"(void Engine::LogGamePackageSHA1Sums\(\) const\n\{\n)",
     lambda m: m.group(1) + '#ifdef __vita__ // vita-nosha\n\treturn;   // two whole files are read for four lines in the log\n#endif\n',
     'vita-nosha')

edit("Engine.cpp",
     r"(void Engine::SaveGameToSlot\(int32_t slotNum, const std::string& saveDescription\) const\n\{\n)",
     lambda m: m.group(1) + '#ifdef __vita__ // vita-savelog-start\n\tLogMessage("SaveGame: start, " + VitaFileStatsText());\n#endif\n',
     'vita-savelog-start')
edit("Engine.cpp",
     r'(\t\tpackages->SetIniValue\("user", "SaveGame", "MapName" \+ std::to_string\(slotNum\), Level->package->GetPackageName\(\)\.ToString\(\)\);\n\t\}\n)(\}\n)',
     lambda m: (m.group(1) + '#ifdef __vita__ // vita-savelog-end\n\tLogMessage("SaveGame: done, " + VitaFileStatsText());\n#endif\n' + m.group(2)),
     'vita-savelog-end')

# 39. Lights and lightmaps, every frame, for every visible surface:
#     (a) The dynamic lights that touch a surface were looked up in the light tree for every surface in every frame (CollectLights and
#         TestSphereAABB were 3-6 percent of the time). The list is kept with the surface's lightmap and used again while the tree has not
#         been built again (a light moved, came or went): the same list, as the tree is the same. The lights' own changes (colour,
#         brightness) are still checked every frame, as before.
#     (b) The lightmap and fog map caches are hash maps (they were ordered maps: a search of 11 steps for every surface, every frame).
edit("Light/LightActorTree.h",
     r"(\tArray<UActor\*> CollectedLights;\n)",
     lambda m: m.group(1) + '\tunsigned Version = 0; // vita-lcversion-h: goes up every time the tree is built again\n',
     'vita-lcversion-h')
edit("Light/LightActorTree.cpp",
     r"(\tPrevious\.lights = Lights;\n\tPrevious\.locs = Scratch\.locs;\n)",
     lambda m: '\tVersion++; // vita-lcversion-c\n' + m.group(1),
     'vita-lcversion-c')

edit("Light/LightSystem.h",
     r"(struct LightmapTexture\n\{\n\tTextureFormat Format;\n\tUnrealMipmap Mip;\n\tint LastStaticUpdate = -1;\n\tint LastDynamicUpdate = -1;\n\tArray<vec3> StaticLightColors;\n)",
     lambda m: m.group(1) + ('#ifdef __vita__ // vita-lcfields\n'
                             '\t// the dynamic lights found for this surface, and the light tree they were found in\n'
                             '\tbool DynValid = false;\n'
                             '\tunsigned DynTree = 0;\n'
                             '\tint DynFrame = -1000;\n'
                             '\tstd::vector<UActor*> DynLights;\n'
                             '#endif\n'),
     'vita-lcfields')
edit("Light/LightSystem.h",
     r"\tstd::map<uint64_t, std::unique_ptr<LightmapTexture>> lmtextures;\n\tstd::map<uint64_t, std::pair<int, std::unique_ptr<LightmapTexture>>> fogtextures;\n",
     lambda m: ('#ifdef __vita__ // vita-lmhash\n'
                '\tstd::unordered_map<uint64_t, std::unique_ptr<LightmapTexture>> lmtextures;\n'
                '\tstd::unordered_map<uint64_t, std::pair<int, std::unique_ptr<LightmapTexture>>> fogtextures;\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-lmhash')
edit("Light/LightSystem.h",
     r"(#pragma once\n)",
     lambda m: m.group(1) + '#include <unordered_map> // vita-lmhash-inc\n',
     'vita-lmhash-inc')

edit("Light/LightSystem_Light.cpp",
     r"\t\t// Look at all lights potentially touching the surface\. They go into our dynamic light list:\n\n\t\tLightTree\.CollectLights\(worldLocation, radius\);\n\t\tfor \(UActor\* light : LightTree\.CollectedLights\)\n\t\t\{\n\t\t\tif \(light->Light\.LightmapCheckCounter != checkCounter\)\n\t\t\t\{\n\t\t\t\tlight->Light\.LightmapCheckCounter = checkCounter;\n\t\t\t\tif \(!light->bStatic\(\) && !light->bNoDelete\(\) && light->bSpecialLit\(\) == specialLit\)\n\t\t\t\t\{\n\t\t\t\t\tCheckLight\(light\);\n\t\t\t\t\tlastDynamicUpdate = std::max\(lastDynamicUpdate, light->Light\.LastUpdate\);\n\t\t\t\t\tTempDynLightList\.push_back\(light\);\n\t\t\t\t\}\n\t\t\t\}\n\t\t\}\n\t\}\n",
     lambda m: ('#ifdef __vita__ // vita-lccollect\n'
                '\t\t// Look at all lights potentially touching the surface. They go into our dynamic light list: the list found a moment ago,\n'
                '\t\t// if the light tree is the same one\n'
                '\t\tLightmapTexture* kept = nullptr;\n'
                '\t\t{\n'
                '\t\t\tauto found = lmtextures.find(cacheID);\n'
                '\t\t\tif (found != lmtextures.end())\n'
                '\t\t\t\tkept = found->second.get();\n'
                '\t\t}\n'
                '\t\tif (kept && kept->DynValid && kept->DynTree == LightTree.Version && FrameCounter - kept->DynFrame < 60)\n'
                '\t\t{\n'
                '\t\t\tfor (UActor* light : kept->DynLights)\n'
                '\t\t\t{\n'
                '\t\t\t\tCheckLight(light);\n'
                '\t\t\t\tlastDynamicUpdate = std::max(lastDynamicUpdate, light->Light.LastUpdate);\n'
                '\t\t\t\tTempDynLightList.push_back(light);\n'
                '\t\t\t}\n'
                '\t\t}\n'
                '\t\telse\n'
                '\t\t{\n'
                '\t\t\tLightTree.CollectLights(worldLocation, radius);\n'
                '\t\t\tfor (UActor* light : LightTree.CollectedLights)\n'
                '\t\t\t{\n'
                '\t\t\t\tif (light->Light.LightmapCheckCounter != checkCounter)\n'
                '\t\t\t\t{\n'
                '\t\t\t\t\tlight->Light.LightmapCheckCounter = checkCounter;\n'
                '\t\t\t\t\tif (!light->bStatic() && !light->bNoDelete() && light->bSpecialLit() == specialLit)\n'
                '\t\t\t\t\t{\n'
                '\t\t\t\t\t\tCheckLight(light);\n'
                '\t\t\t\t\t\tlastDynamicUpdate = std::max(lastDynamicUpdate, light->Light.LastUpdate);\n'
                '\t\t\t\t\t\tTempDynLightList.push_back(light);\n'
                '\t\t\t\t\t}\n'
                '\t\t\t\t}\n'
                '\t\t\t}\n'
                '\t\t\tif (kept)\n'
                '\t\t\t{\n'
                '\t\t\t\tkept->DynValid = true;\n'
                '\t\t\t\tkept->DynTree = LightTree.Version;\n'
                '\t\t\t\tkept->DynFrame = FrameCounter;\n'
                '\t\t\t\tkept->DynLights.assign(TempDynLightList.begin(), TempDynLightList.end());\n'
                '\t\t\t}\n'
                '\t\t}\n'
                '\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-lccollect')

# 40. Light maps in big halls (the log's 'lightmaps' part was 17-42 ms a frame with almost no light map uploads):
#     (a) still_lights: KnowWonder's light maps (KW::LightmapIllumination) leave out the flicker of LE_TorchWaver, LE_FireWaver and
#         LE_WateryShimmer, but BeginFrame marked such lights as changed every frame: every surface they touch was built again into
#         the same light map.
#     (b) lightmap_incremental: a flickering / pulsing light rebuilt its surfaces with every one of their static lights. The sum of the
#         steady ones is kept (LightmapTexture::SteadyLightColors) and only the animated ones are added to it. HP1 adds lights with a
#         clamp at full, which is the same in any order; a surface with a bDarkLight (subtracts) is built whole as before.
#     (c) dynamic_light_list: a surface's dynamic lights were looked for in the tree of all the level's lights (hundreds, most of them
#         static), reading bStatic/bNoDelete/bSpecialLit of each one found. The dynamic ones are listed once a frame instead.
#     (d) counters for the log (VitaStats): light map requests, rebuilds, their texels and time, light tree builds.
edit("Packages/Engine/Actors/UActor.h",
     re.escape("\t\tfloat NextFlickerTime = 0.0f;\n\t} Light;\n"),
     lambda m: "\t\tfloat NextFlickerTime = 0.0f;\n\t\tbool VitaAnimated = false; // vita-animflag: its light maps change every frame (flicker, pulse...)\n\t} Light;\n",
     'vita-animflag')

edit("Light/LightSystem.h",
     re.escape("\tstd::vector<UActor*> DynLights;\n#endif\n"),
     lambda m: ("\tstd::vector<UActor*> DynLights;\n"
                "\t// vita-steadyfields: the ambient light plus the surface's static lights that do not animate, and what it was made from\n"
                "\tArray<vec3> SteadyLightColors;\n"
                "\tint SteadyStamp = -1000;\n"
                "\tuintptr_t SteadyAnimatedKey = 0;\n"
                "#endif\n"),
     'vita-steadyfields')
edit("Light/LightSystem.h",
     re.escape("\tLightActorTree LightTree;\n};"),
     lambda m: ("\tLightActorTree LightTree;\n"
                "#ifdef __vita__ // vita-dynmembers\n"
                "\t// the level's dynamic lights (not bStatic, not bNoDelete) this frame: the only ones a light map's dynamic list can hold\n"
                "\tstruct VitaDynamicLight { UActor* Light; vec3 Location; float Radius; };\n"
                "\tstd::vector<VitaDynamicLight> DynamicLights;\n"
                "\tvoid VitaCollectDynamic(const vec3& center, float radius);\n"
                "#endif\n"
                "};"),
     'vita-dynmembers')

edit("Light/LightSystem.cpp",
     re.escape("\tLightTree.Lights.clear();\n"),
     lambda m: "\tLightTree.Lights.clear();\n#ifdef __vita__ // vita-dynclear\n\tDynamicLights.clear();\n#endif\n",
     'vita-dynclear')
edit("Light/LightSystem.cpp",
     re.escape("#ifdef __vita__ // vita-lightanim\n"),
     lambda m: ("#ifdef __vita__ // vita-kwanim\n"
                "\t\t// KnowWonder's light maps leave out the flicker of these effects (KW::LightmapIllumination): a steady light with one of them\n"
                "\t\t// gives the same light map every time\n"
                "\t\tif (needsUpdate && VitaStillLights() && engine->LaunchInfo.IsKnowWonder() && !(lightType > LT_Steady && lightType != LT_BackdropLight) &&\n"
                "\t\t\tlightEffect >= LE_TorchWaver && lightEffect <= LE_WateryShimmer)\n"
                "\t\t\tneedsUpdate = false;\n"
                "\t\tactor->Light.VitaAnimated = needsUpdate;\n"
                "#endif\n" + m.group(0)),
     'vita-kwanim')
edit("Light/LightSystem.cpp",
     re.escape("\t\tLightTree.Lights.push_back(actor);\n\t}\n\tLightTree.CreateTLAS();\n"),
     lambda m: ("\t\tLightTree.Lights.push_back(actor);\n"
                "#ifdef __vita__ // vita-dynfill\n"
                "\t\tif (VitaDynamicLightList() && !actor->bStatic() && !actor->bNoDelete())\n"
                "\t\t\tDynamicLights.push_back({ actor, actor->Location(), actor->WorldLightRadius() });\n"
                "#endif\n"
                "\t}\n\tLightTree.CreateTLAS();\n"
                "#ifdef __vita__\n"
                "\tVitaStats::dynamicLights = DynamicLights.size();\n"
                "#endif\n"),
     'vita-dynfill')
edit("Light/LightSystem.cpp",
     re.escape("void LightSystem::UpdateLightList(UActor* actor)\n"),
     lambda m: ("#ifdef __vita__ // vita-dynfn\n"
                "// What LightTree.CollectLights finds of the dynamic lights (the same test: the surface's sphere against the box of the light's\n"
                "// sphere), into LightTree.CollectedLights\n"
                "void LightSystem::VitaCollectDynamic(const vec3& center, float radius)\n"
                "{\n"
                "\tif (!VitaDynamicLightList())\n"
                "\t{\n"
                "\t\tLightTree.CollectLights(center, radius);\n"
                "\t\treturn;\n"
                "\t}\n"
                "\tLightTree.CollectedLights.clear();\n"
                "\tfor (const VitaDynamicLight& light : DynamicLights)\n"
                "\t{\n"
                "\t\tconst float r = light.Radius + 0.1f;\n"
                "\t\tconst float dx = std::max(std::abs(center.x - light.Location.x) - r, 0.0f);\n"
                "\t\tconst float dy = std::max(std::abs(center.y - light.Location.y) - r, 0.0f);\n"
                "\t\tconst float dz = std::max(std::abs(center.z - light.Location.z) - r, 0.0f);\n"
                "\t\tif (dx * dx + dy * dy + dz * dz <= radius * radius)\n"
                "\t\t\tLightTree.CollectedLights.push_back(light.Light);\n"
                "\t}\n"
                "}\n"
                "#endif\n\n" + m.group(0)),
     'vita-dynfn')
edit("Light/LightSystem.cpp",
     re.escape('#include "VitaConfig.h" // vita-laninc\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-lsstatsinc\n',
     'vita-lsstatsinc')

edit("Light/LightSystem_Light.cpp",
     re.escape('#include "VitaTimers.h" // vita-timers:include\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-statsinc\n#include "VitaConfig.h"\n#include "KWActor.h"\n',
     'vita-statsinc')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t\tLightTree.CollectLights(worldLocation, radius);\n\t\t\tfor (UActor* light : LightTree.CollectedLights)\n\t\t\t{\n\t\t\t\tif (light->Light.LightmapCheckCounter != checkCounter)\n"),
     lambda m: m.group(0).replace("LightTree.CollectLights(worldLocation, radius);", "VitaCollectDynamic(worldLocation, radius); // vita-dynuse"),
     'vita-dynuse')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tVITA_TIMER(Lightmaps); // vita-timers:lightmaps\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-lmcounters\n\tVitaStats::lightmapCalls++;\n#endif\n",
     'vita-lmcounters')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tengine->render->Stats.LightmapsUpdated++;\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-rebuildtime\n\t\tVitaStats::lightmapRebuilds++;\n\t\tconst double vitaRebuildStart = VitaTimers::Now();\n#endif\n",
     'vita-rebuildtime')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tlmtexture->LastStaticUpdate = lastStaticUpdate;\n\t\tlmtexture->LastDynamicUpdate = lastDynamicUpdate;\n\t\tbRealtimeChanged = true;\n"),
     lambda m: ("#ifdef __vita__ // vita-rebuildend\n"
                "\t\tVitaStats::lightmapRebuildMs += VitaTimers::Now() - vitaRebuildStart;\n"
                "\t\tVitaStats::lightmapTexels += (size_t)count;\n"
                "#endif\n" + m.group(0)),
     'vita-rebuildend')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\telse if (lmtexture->LastStaticUpdate != lastStaticUpdate)\n\t\t{\n\t\t\tBuilder.SetAmbientLight(zoneActor);\n\t\t\tBuilder.AddStaticLights(model, lightmapIndex);\n\t\t\tBuilder.SaveStaticLight(lmtexture->StaticLightColors);\n\t\t}\n"),
     lambda m: ("#ifdef __vita__ // vita-steadybuild\n"
                "\t\telse if (lmtexture->LastStaticUpdate != lastStaticUpdate)\n"
                "\t\t{\n"
                "\t\t\t// Some of the surface's lights animate (flicker, pulse): the sum of the others is kept, and only the animated ones are\n"
                "\t\t\t// added to it. HP1 adds lights with a clamp at full (KW::AddLightmapLight): the same in any order, unless one subtracts\n"
                "\t\t\t// (bDarkLight); then all of them, as before\n"
                "\t\t\tint steadyStamp = -100;\n"
                "\t\t\tuintptr_t animatedKey = 0;\n"
                "\t\t\tbool anyAnimated = false, anyDark = false;\n"
                "\t\t\tif (VitaLightmapIncremental() && engine->LaunchInfo.IsKnowWonder() && lmindex.LightActors >= 0)\n"
                "\t\t\t{\n"
                "\t\t\t\tUActor** lightlist = &model->Lights[lmindex.LightActors];\n"
                "\t\t\t\tfor (int i = 0; lightlist[i] != nullptr; i++)\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tUActor* light = lightlist[i];\n"
                "\t\t\t\t\tif (light->Light.VitaAnimated)\n"
                "\t\t\t\t\t{\n"
                "\t\t\t\t\t\tanyAnimated = true;\n"
                "\t\t\t\t\t\tanimatedKey = animatedKey * 31 + (uintptr_t)light;\n"
                "\t\t\t\t\t}\n"
                "\t\t\t\t\telse\n"
                "\t\t\t\t\t\tsteadyStamp = std::max(steadyStamp, light->Light.LastUpdate);\n"
                "\t\t\t\t\tif (KW::bDarkLight(light))\n"
                "\t\t\t\t\t\tanyDark = true;\n"
                "\t\t\t\t}\n"
                "\t\t\t}\n"
                "\t\t\tif (anyAnimated && !anyDark)\n"
                "\t\t\t{\n"
                "\t\t\t\tif (lmtexture->SteadyStamp == steadyStamp && lmtexture->SteadyAnimatedKey == animatedKey &&\n"
                "\t\t\t\t\tlmtexture->SteadyLightColors.size() == (size_t)Builder.Width() * Builder.Height())\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tBuilder.LoadStaticLight(lmtexture->SteadyLightColors);\n"
                "\t\t\t\t\tVitaStats::lightmapIncremental++;\n"
                "\t\t\t\t}\n"
                "\t\t\t\telse\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tBuilder.SetAmbientLight(zoneActor);\n"
                "\t\t\t\t\tBuilder.VitaAddStaticLights(model, lightmapIndex, false);\n"
                "\t\t\t\t\tBuilder.SaveStaticLight(lmtexture->SteadyLightColors);\n"
                "\t\t\t\t\tlmtexture->SteadyStamp = steadyStamp;\n"
                "\t\t\t\t\tlmtexture->SteadyAnimatedKey = animatedKey;\n"
                "\t\t\t\t}\n"
                "\t\t\t\tBuilder.VitaAddStaticLights(model, lightmapIndex, true);\n"
                "\t\t\t}\n"
                "\t\t\telse\n"
                "\t\t\t{\n"
                "\t\t\t\tBuilder.SetAmbientLight(zoneActor);\n"
                "\t\t\t\tBuilder.AddStaticLights(model, lightmapIndex);\n"
                "\t\t\t}\n"
                "\t\t\tBuilder.SaveStaticLight(lmtexture->StaticLightColors);\n"
                "\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-steadybuild')

edit("Light/LightmapBuilder.h",
     re.escape("\tvoid AddStaticLights(UModel* model, int lightMap);\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-builderdecl\n\tvoid VitaAddStaticLights(UModel* model, int lightMap, bool animated); // only the static lights that animate, or only the others\n#endif\n",
     'vita-builderdecl')
edit("Light/LightmapBuilder.cpp",
     re.escape("void LightmapBuilder::AddDynamicLights(UModel* model, int lightMap, const Array<UActor*>& lights)\n"),
     lambda m: ("#ifdef __vita__ // vita-builderdef\n"
                "void LightmapBuilder::VitaAddStaticLights(UModel* model, int lightMap, bool animated)\n"
                "{\n"
                "\tconst LightMapIndex& lmindex = model->LightMap[lightMap];\n"
                "\tif (lmindex.LightActors < 0)\n"
                "\t\treturn;\n"
                "\tUActor** lightlist = &model->Lights[lmindex.LightActors];\n"
                "\tfor (int lightindex = 0; lightlist[lightindex] != nullptr; lightindex++)\n"
                "\t{\n"
                "\t\tUActor* light = lightlist[lightindex];\n"
                "\t\tif (light->Light.VitaAnimated != animated)\n"
                "\t\t\tcontinue;\n"
                "\t\tif (light->LightType() != LT_None && light->LightBrightness() > 0)\n"
                "\t\t{\n"
                "\t\t\tShadow.Load(model, lightMap, lightindex);\n"
                "\t\t\tif (!engine->LaunchInfo.IsKnowWonder() || !KW::LightmapIllumination(light, width * height, WorldLocations(), base, WorldNormal(), Shadow.Pixels(), illuminationmap.data()))\n"
                "\t\t\t\tEffect.Run(light, width, height, WorldLocations(), base, WorldNormal(), Shadow.Pixels(), illuminationmap.data());\n"
                "\t\t\tAddLightContribution(light);\n"
                "\t\t}\n"
                "\t}\n"
                "}\n"
                "#endif\n\n" + m.group(0)),
     'vita-builderdef')

edit("Light/LightActorTree.cpp",
     re.escape("\tVersion++; // vita-lcversion-c\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-tbuildcount\n\tVitaStats::lightTreeBuilds++;\n#endif\n",
     'vita-tbuildcount')
edit("Light/LightActorTree.cpp",
     re.escape('#include "LightActorTree.h"\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-tbinclude\n',
     'vita-tbinclude')


# 41. A count for the log: how many static lights the light map requests look at (the length of the surfaces' light lists)
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t\t\t// Mark the light as visited so the second pass doesn't pick it up\n\t\t\t\tlight->Light.LightmapCheckCounter = checkCounter;\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-listcount\n\t\t\t\tVitaStats::lightmapListLights++;\n#endif\n",
     'vita-listcount')


# 42. Lap timers (VitaProbes.h) along one BSP surface: VisibleNode::Draw and LightSystem::GetLightmap. Each surface asked for its
#     light map at ~130 us even with nothing built again, which the code does not explain; these measure where it goes.
edit("Render/VisibleNode.cpp",
     re.escape('#include "VitaConfig.h" // vita-inc-nolight\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-node\n',
     'vita-probeinc-node')
edit("Render/VisibleNode.cpp",
     re.escape("\tBspSurface& surface = model->Surfaces[Node->Surf];\n"),
     lambda m: m.group(0) + "\tVITA_LAP_START; // vita-nodelaps\n",
     'vita-nodelaps')
edit("Render/VisibleNode.cpp",
     re.escape("\tengine->render->UpdateTextureInfo(texture, surface, tex, ZoneUPanSpeed, ZoneVPanSpeed);\n"),
     lambda m: m.group(0) + "\tVITA_LAP(NodeTexture); // vita-lap-tex\n",
     'vita-lap-tex')
edit("Render/VisibleNode.cpp",
     re.escape("\tint numverts = Node->NumVertices;\n"),
     lambda m: "\tVITA_LAP(NodeExtraTex); // vita-lap-extra\n" + m.group(0),
     'vita-lap-extra')
edit("Render/VisibleNode.cpp",
     re.escape("\tTextureInfo lightmap;\n\tTextureInfo fogmap;\n"),
     lambda m: "\tVITA_LAP(NodeVerts); // vita-lap-verts\n" + m.group(0),
     'vita-lap-verts')
edit("Render/VisibleNode.cpp",
     re.escape("\t\tlightmap = engine->Level->Light.GetLevelLightmap(surface, zoneActor, model);\n\tif (VitaFogOn())\n"),
     lambda m: "\t\tlightmap = engine->Level->Light.GetLevelLightmap(surface, zoneActor, model);\n\tVITA_LAP(NodeLightmap); // vita-lap-lm\n\tif (VitaFogOn())\n",
     'vita-lap-lm')
edit("Render/VisibleNode.cpp",
     re.escape("\t\tfogmap = engine->Level->Light.GetLevelFogmap(surface, engine->CameraActor->Region().Zone, model);\n#else\n"),
     lambda m: "\t\tfogmap = engine->Level->Light.GetLevelFogmap(surface, engine->CameraActor->Region().Zone, model);\n\tVITA_LAP(NodeFogmap); // vita-lap-fog\n#else\n",
     'vita-lap-fog')
edit("Render/VisibleNode.cpp",
     re.escape("\tengine->render->Stats.Surfaces++;\n"),
     lambda m: m.group(0) + "\tVITA_LAP(NodeDevice); // vita-lap-dev\n",
     'vita-lap-dev')
edit("Render/VisibleNode.cpp",
     re.escape("\tdecal.DrawDecals(frame, Node);\n"),
     lambda m: m.group(0) + "\tVITA_LAP(NodeDecals); // vita-lap-decals\n",
     'vita-lap-decals')

edit("Light/LightSystem_Light.cpp",
     re.escape('#include "VitaStats.h" // vita-statsinc\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-light\n',
     'vita-probeinc-light')
edit("Light/LightSystem_Light.cpp",
     re.escape("#ifdef __vita__ // vita-lmcounters\n\tVitaStats::lightmapCalls++;\n#endif\n"),
     lambda m: m.group(0) + "\tVITA_LAP_START; // vita-lmlaps\n",
     'vita-lmlaps')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tint checkCounter = LightmapCheckCounter++;\n"),
     lambda m: "\tVITA_LAP(LmPrologue); // vita-lap-prologue\n" + m.group(0),
     'vita-lap-prologue')
edit("Light/LightSystem_Light.cpp",
     re.escape("#ifdef __vita__ // vita-lccollect\n"),
     lambda m: "\t\tVITA_LAP(LmStatic); // vita-lap-static\n" + m.group(0),
     'vita-lap-static')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t// If anything changed update the lightmap:\n"),
     lambda m: "\tVITA_LAP(LmDynamic); // vita-lap-dynamic\n" + m.group(0),
     'vita-lap-dynamic')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tTextureInfo texinfo;\n\ttexinfo.bRealtimeChanged = bRealtimeChanged;\n"),
     lambda m: "\tVITA_LAP(LmBuild); // vita-lap-build\n" + m.group(0),
     'vita-lap-build')
edit("Light/LightSystem_Light.cpp",
     re.escape("\ttexinfo.VScale = lmindex.VScale;\n\treturn texinfo;\n"),
     lambda m: "\ttexinfo.VScale = lmindex.VScale;\n\tVITA_LAP(LmInfo); // vita-lap-info\n\treturn texinfo;\n",
     'vita-lap-info')


# 43. The light map caches hashed their 64 bit CacheIDs with std::hash, which on the Vita keeps only the low 32 bits: the same for every
#     lightmap of a zone, so all of them shared one bucket (laps: ~65 us per lookup, three per surface). VitaHash64 mixes all 64 bits.
edit("Light/LightSystem.h",
     re.escape("\tstd::unordered_map<uint64_t, std::unique_ptr<LightmapTexture>> lmtextures;\n\tstd::unordered_map<uint64_t, std::pair<int, std::unique_ptr<LightmapTexture>>> fogtextures;\n"),
     lambda m: ("\t// vita-lmhash64: VitaHash64, std::hash keeps only the low 32 bits of the key on the Vita\n"
                "\tstd::unordered_map<uint64_t, std::unique_ptr<LightmapTexture>, VitaHash64> lmtextures;\n"
                "\tstd::unordered_map<uint64_t, std::pair<int, std::unique_ptr<LightmapTexture>>, VitaHash64> fogtextures;\n"),
     'vita-lmhash64')
edit("Light/LightSystem.h",
     re.escape("#include <unordered_map> // vita-lmhash-inc\n"),
     lambda m: m.group(0) + '#include "VitaHash.h" // vita-hash64-inc\n',
     'vita-hash64-inc')


# 44. Slow frames of 80-300 ms come from decoding a sound the first time it plays ('sound decoding' in SLOW FRAME): which sounds.
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\tVITA_TIMER(SoundLoad); // vita-sndtimer\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-decodelog\n\tconst double vitaDecodeStart = VitaTimers::Now();\n#endif\n",
     'vita-decodelog')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\tengine->audiodev->GetDevice()->AddSound(this);\n"),
     lambda m: ("#ifdef __vita__ // vita-decodelog-end\n"
                "\t{\n"
                "\t\tconst double ms = VitaTimers::Now() - vitaDecodeStart;\n"
                "\t\tif (ms > 15.0)\n"
                "\t\t\tLogMessage(\"Sound decoded: \" + Name.ToString() + \" (\" + Format.ToString() + \", \" + std::to_string((int)(duration * 10.0f) / 10.0f).substr(0, 5) +\n"
                "\t\t\t\t\" s, \" + std::to_string(channels) + \" ch, \" + std::to_string(frequency) + \" Hz): \" + std::to_string((int)ms) + \" ms\");\n"
                "\t}\n"
                "#endif\n" + m.group(0)),
     'vita-decodelog-end')


# 45. MP2/MP3 sounds are decoded on a thread of their own (vita/VitaSoundDecode.h, render.cfg sound_thread): GetSound only opens the
#     file (length, rate, channels: GetDuration is unchanged), and USurrealAudioDevice::UpdateSounds starts the sound on the device
#     once its samples are there (a frame or a few later; the lip sync clock starts then). The first play of a line of dialogue cost
#     30-110 ms of the frame, a room's ambience up to 230 ms.
edit("Packages/Engine/Resources/USound.h",
     re.escape("\tAudioLoopInfo loopInfo;\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-sndfields\n"
                             "\tbool vitaPending = false;   // being decoded on the sound thread (VitaSoundDecode.h)\n"
                             "\tbool vitaFailed = false;\n"
                             "\tbool VitaReady();           // decoded and on the device (finishes a decode that is done)\n"
                             "#endif\n"),
     'vita-sndfields')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape('#include "VitaTimers.h" // vita-sndinc\n'),
     lambda m: m.group(0) + '#include "VitaSoundDecode.h" // vita-sdinc\n',
     'vita-sdinc')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\tif (samples.size() > 0)\n\t\treturn;\n\n\tVITA_TIMER(SoundLoad); // vita-sndtimer\n"),
     lambda m: ("\tif (samples.size() > 0)\n\t\treturn;\n"
                "#ifdef __vita__ // vita-sndasync\n"
                "\tif (vitaFailed)\n"
                "\t\treturn;\n"
                "\tif (vitaPending)\n"
                "\t{\n"
                "\t\tArray<float> decoded;\n"
                "\t\tVitaSoundDecode::State state = VitaSoundDecode::Poll(this, decoded);\n"
                "\t\tif (state == VitaSoundDecode::State::Pending)\n"
                "\t\t\treturn;\n"
                "\t\tvitaPending = false;\n"
                "\t\tif (state == VitaSoundDecode::State::Failed || decoded.empty())\n"
                "\t\t{\n"
                "\t\t\tvitaFailed = true;\n"
                "\t\t\tLogMessage(\"Sound decoding failed: \" + Name.ToString());\n"
                "\t\t\treturn;\n"
                "\t\t}\n"
                "\t\tsamples = std::move(decoded);\n"
                "\t\tduration = samples.size() / (float)frequency;\n"
                "\t\tengine->audiodev->GetDevice()->AddSound(this);\n"
                "\t\tData.clear();\n"
                "\t\tData.shrink_to_fit();\n"
                "\t\treturn;\n"
                "\t}\n"
                "#endif\n\n"
                "\tVITA_TIMER(SoundLoad); // vita-sndtimer\n"),
     'vita-sndasync')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\t#define ALIGN(x, a) ((x & ~(a-1)) + a)\n"),
     lambda m: ("#ifdef __vita__ // vita-sndasync-start\n"
                "\tif ((Format == \"mp3\" || Format == \"mp2\") && VitaSoundDecode::Enabled() && source->GetFrequency() > 0 && VitaSoundDecode::EnsureThread())\n"
                "\t{\n"
                "\t\tfrequency = source->GetFrequency();\n"
                "\t\tchannels = source->GetChannels();\n"
                "\t\tloopInfo.Looped = source->bIsLooped;\n"
                "\t\tloopInfo.LoopStart = source->loopStart;\n"
                "\t\tloopInfo.LoopEnd = source->loopEnd;\n"
                "\t\tconst size_t expected = (size_t)source->GetSamples();\n"
                "\t\tduration = VitaSoundDecode::Round4(expected) / (float)frequency;   // what the decode gives, as below\n"
                "\t\tVitaSoundDecode::Start(this, std::move(source), expected);\n"
                "\t\tvitaPending = true;\n"
                "\t\treturn;\n"
                "\t}\n"
                "#endif\n" + m.group(0)),
     'vita-sndasync-start')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("float USound::GetDuration()\n"),
     lambda m: ("#ifdef __vita__ // vita-sndready\n"
                "bool USound::VitaReady()\n"
                "{\n"
                "\tCheckSoundSamples();\n"
                "\treturn !vitaPending;\n"
                "}\n"
                "#endif\n\n" + m.group(0)),
     'vita-sndready')
edit("Packages/Engine/Subsystems/USurrealAudioDevice.cpp",
     re.escape("\t\t\t\tm_Device->PlaySound((int)i, Playing.Sound, Playing.Location, volume * globalVolume, Playing.Radius, Playing.Pitch);\n"),
     lambda m: ("#ifdef __vita__ // vita-sndwait\n"
                "\t\t\t\t// A sound still being decoded on the sound thread starts once it is ready; one that could not be decoded is dropped\n"
                "\t\t\t\tif (!Playing.Sound->VitaReady())\n"
                "\t\t\t\t\tcontinue;\n"
                "\t\t\t\tif (Playing.Sound->vitaFailed || !Playing.Sound->handle)\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tPlayingSounds[i] = {};\n"
                "\t\t\t\t\tcontinue;\n"
                "\t\t\t\t}\n"
                "\t\t\t\tif (engine->LevelInfo)\n"
                "\t\t\t\t\tPlaying.StartTime = engine->LevelInfo->TimeSeconds();   // the lip sync clock starts with the sound\n"
                "#endif\n" + m.group(0)),
     'vita-sndwait')


# 46. The trace cache (vita-tracecache) kept an answer 0.12 s in 1024 places: aiming a spell (baseHarry.ExtendTarget: foreach
#     VisibleActors over every actor of the level, a ray to each, every frame) made level tick ~100 ms with frames of ~160 ms, so
#     nothing was ever found again. A ray that ignores actors only meets the BSP (never changes) and the movers (mover_trace): its
#     answer holds while no mover moved, turned or changed bBlockActors. A signature of the movers is taken once a frame; 8192 places.
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape("\tstruct Entry { float values[6]; UActor* actor; uint32_t flags; float time; bool result; bool used; };\n\tstatic Entry cache[1024];\n"),
     lambda m: ("\t// vita-tracecache2: valid while the movers are where they were (VitaMoverTrace: nothing else but the BSP can stop the ray)\n"
                "\tstruct Entry { float values[6]; UActor* actor; uint32_t flags; float time; uint32_t movers; bool result; bool used; };\n"
                "\tstatic Entry cache[8192];\n"
                "\tstatic unsigned signatureFrame = ~0u;\n"
                "\tstatic uint32_t moverSignature = 0;\n"
                "\tconst bool byMovers = VitaMoverTrace();\n"
                "\tif (byMovers && signatureFrame != VitaTimers::frameNumber)\n"
                "\t{\n"
                "\t\tsignatureFrame = VitaTimers::frameNumber;\n"
                "\t\tuint32_t sig = 2166136261u ^ (uint32_t)(uintptr_t)Level;\n"
                "\t\tauto mix = [&](uint32_t v) { sig = (sig ^ v) * 16777619u; };\n"
                "\t\tfor (UActor* mover : MoverActors)\n"
                "\t\t{\n"
                "\t\t\tconst vec3 l = mover->Location();\n"
                "\t\t\tconst Rotator r = mover->Rotation();\n"
                "\t\t\tuint32_t bits[3];\n"
                "\t\t\tmemcpy(bits, &l, sizeof(bits));\n"
                "\t\t\tmix((uint32_t)(uintptr_t)mover); mix(bits[0]); mix(bits[1]); mix(bits[2]);\n"
                "\t\t\tmix((uint32_t)r.Pitch); mix((uint32_t)r.Yaw); mix((uint32_t)r.Roll); mix(mover->bBlockActors() ? 1u : 0u);\n"
                "\t\t}\n"
                "\t\tmoverSignature = sig;\n"
                "\t}\n"
                "\tVitaStats::traceCalls++;\n"),
     'vita-tracecache2')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape("\tEntry& entry = cache[(hash ^ (hash >> 11)) & 1023u];\n\tif (entry.used && entry.actor == tracingActor && entry.flags == flags && now >= entry.time && now - entry.time < 0.12f &&\n\t\tmemcmp(entry.values, values, sizeof(values)) == 0)\n\t\treturn entry.result;\n"),
     lambda m: ("\tEntry& entry = cache[(hash ^ (hash >> 13)) & 8191u]; // vita-tracecache2-use\n"
                "\tif (entry.used && entry.actor == tracingActor && entry.flags == flags &&\n"
                "\t\t(byMovers ? entry.movers == moverSignature : (now >= entry.time && now - entry.time < 0.12f)) &&\n"
                "\t\tmemcmp(entry.values, values, sizeof(values)) == 0)\n"
                "\t{\n"
                "\t\tVitaStats::traceCacheHits++;\n"
                "\t\treturn entry.result;\n"
                "\t}\n"),
     'vita-tracecache2-use')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape("\tentry.time = now;\n\tentry.result = result;\n"),
     lambda m: "\tentry.time = now;\n\tentry.movers = moverSignature; // vita-tracecache2-store\n\tentry.result = result;\n",
     'vita-tracecache2-store')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape('#ifdef __vita__ // vita-tracecache\n#include "VitaConfig.h"\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-tc2inc\n#include "VitaTimers.h"\n',
     'vita-tc2inc')

# 47. Counters for the log: foreach VisibleActors calls, the actors traced and the time
edit("VM/Iterator.cpp",
     re.escape('#include "Iterator.h"\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-itinc\n#include "VitaTimers.h"\n',
     'vita-itinc')
edit("VM/Iterator.cpp",
     re.escape("\tdouble sqrRadius = Radius * Radius;\n\tfor (auto levelActor : engine->Level->Actors)\n"),
     lambda m: ("#ifdef __vita__ // vita-viscount\n"
                "\tconst double vitaStart = VitaTimers::Now();\n"
                "\tVitaStats::visibleActorsCalls++;\n"
                "#endif\n" + m.group(0)),
     'vita-viscount')
edit("VM/Iterator.cpp",
     re.escape("\t\t\tif ((Radius == 0.0f || dot(d, d) <= sqrRadius) && Caller->FastTrace(levelActor->Location(), Location))\n\t\t\t\tVisibleActors.push_back(levelActor);\n\t\t}\n\t}\n"),
     lambda m: ("\t\t\tif (Radius == 0.0f || dot(d, d) <= sqrRadius)\n"
                "\t\t\t{\n"
                "#ifdef __vita__ // vita-vistraced\n"
                "\t\t\t\tVitaStats::visibleActorsTraced++;\n"
                "#endif\n"
                "\t\t\t\tif (Caller->FastTrace(levelActor->Location(), Location))\n"
                "\t\t\t\t\tVisibleActors.push_back(levelActor);\n"
                "\t\t\t}\n"
                "\t\t}\n"
                "\t}\n"
                "#ifdef __vita__\n"
                "\tVitaStats::visibleActorsMs += VitaTimers::Now() - vitaStart;\n"
                "#endif\n"),
     'vita-vistraced')


# 48. foreach VisibleActors, as HP1's AActor::execVisibleActors (Engine 0x1040E610, docs/re/hp1/spells.md): an actor is visible when
#     the BSP alone does not block it (UModel::FastLineCheck, ported as KW::ModelFastLineCheck; movers don't count). SurrealEngine
#     traced a full ray (BSP polygons in double, plus the movers) to every actor: aiming a spell while walking (ExtendTarget, every
#     frame, ~450 actors) cost 25-40 ms a frame. Gated by IsKnowWonder (HP1 and HP2); a fix for Flipendo itself as well.
edit("VM/Iterator.cpp",
     re.escape('#include "VitaStats.h" // vita-itinc\n'),
     lambda m: m.group(0) + '#include "KWCheck.h" // vita-kwcheckinc\n',
     'vita-kwcheckinc')
edit("VM/Iterator.cpp",
     re.escape("\t\t\t\tif (Caller->FastTrace(levelActor->Location(), Location))\n\t\t\t\t\tVisibleActors.push_back(levelActor);\n"),
     lambda m: ("\t\t\t\t// vita-visfastline: HP1's execVisibleActors looks through the BSP only (UModel::FastLineCheck), movers don't count\n"
                "\t\t\t\tconst bool visible = engine->LaunchInfo.IsKnowWonder() ?\n"
                "\t\t\t\t\tKW::ModelFastLineCheck(engine->Level->Model, levelActor->Location(), Location) :\n"
                "\t\t\t\t\tCaller->FastTrace(levelActor->Location(), Location);\n"
                "\t\t\t\tif (visible)\n"
                "\t\t\t\t\tVisibleActors.push_back(levelActor);\n"),
     'vita-visfastline')


# 49. Probes in VisibleFrame::Process (the log's 'process', 25-30 ms in big halls): the BSP nodes' boxes, the actors, the surfaces into
#     the clipper; and the clipper's triangle and span counts.
edit("Render/VisibleFrame.cpp",
     re.escape('#include "VisibleFrame.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-frame\n',
     'vita-probeinc-frame')
edit("Render/VisibleFrame.cpp",
     re.escape("\tif (node->RenderBound != -1 && !Clipper.IsAABBVisible(engine->Level->Model->Bounds[node->RenderBound]))\n\t{\n\t\treturn;\n\t}\n"),
     lambda m: ("\tbool vitaNodeVisible; // vita-probe-nodebox\n"
                "\t{\n"
                "\t\tVITA_PROBE(ProcNodeBox);\n"
                "\t\tvitaNodeVisible = node->RenderBound == -1 || Clipper.IsAABBVisible(engine->Level->Model->Bounds[node->RenderBound]);\n"
                "\t}\n"
                "\tif (!vitaNodeVisible)\n"
                "\t\treturn;\n"),
     'vita-probe-nodebox')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\t\tVisibleActor visactor;\n\t\t\tvisactor.Process(this, actor);\n"),
     lambda m: "\t\t\tVITA_PROBE(ProcActors); // vita-probe-actors\n" + m.group(0),
     'vita-probe-actors')
edit("Render/VisibleFrame.cpp",
     re.escape("\tif (!Clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0))\n\t\treturn;\n"),
     lambda m: ("\tbool vitaSurfaceVisible; // vita-probe-surface\n"
                "\t{\n"
                "\t\tVITA_PROBE(ProcSurface);\n"
                "\t\tvitaSurfaceVisible = Clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0);\n"
                "\t}\n"
                "\tif (!vitaSurfaceVisible)\n"
                "\t\treturn;\n"),
     'vita-probe-surface')
edit("Render/VisibleFrame.cpp",
     re.escape("\tProcessNode(&engine->Level->Model->Nodes[0]);\n}\n"),
     lambda m: ("\tProcessNode(&engine->Level->Model->Nodes[0]);\n"
                "#ifdef __vita__ // vita-clipcount\n"
                "\tVitaProbes::clipTris += Clipper.numTris;\n"
                "\tVitaProbes::clipSpans += Clipper.numDrawSpans;\n"
                "#endif\n"
                "}\n"),
     'vita-clipcount')


# 50. The visibility clipper draws a BSP surface as one convex polygon (vita/VitaClipperPolygon.h, render.cfg clipper_polygons):
#     probes showed CheckSurface ~30 us per surface, ~20 ms a frame in big halls (680 surfaces, 2300 triangles, 20000 spans).
#     The fan of triangles searched each line's gaps once per triangle crossing it; the polygon searches it once.
edit("Render/BspClipper.h",
     re.escape("\tbool IsVisible(int16_t y, int16_t x0, int16_t x1);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-clippoly-h\n"
                             "\tbool VitaCheckPolygon(const vec3* vertices, uint32_t count, bool solid);\n"
                             "\tArray<float> VitaLineMin, VitaLineMax;   // per line of the clipper's screen: the polygon's leftmost and rightmost x\n"
                             "#endif\n"),
     'vita-clippoly-h')
edit("Render/BspClipper.cpp",
     re.escape('#include "Math/bbox.h"\n'),
     lambda m: m.group(0) + '#include "VitaClipperPolygon.h" // vita-clippoly-inc\n',
     'vita-clippoly-inc')
edit("Render/BspClipper.cpp",
     re.escape("\tif (count < 3)\n\t\treturn false;\n\n\tnumSurfs++;\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-clippoly-use\n"
                             "\tif (VitaClipperPolygons() && count <= 32)\n"
                             "\t\treturn VitaCheckPolygon(vertices, count, solid);\n"
                             "#endif\n"),
     'vita-clippoly-use')


# 51. BspClipper::DrawSpan skipped a gap: when the span closed a gap and merged two covered runs (erase of pos + 1), the loop's pos++
#     stepped over the next gap, so a span crossing several gaps covered only every other one. The screen was left more open than
#     it was (surfaces behind it checked and drawn for nothing). Found comparing the polygon clipper with the triangles on the PC.
edit("Render/BspClipper.cpp",
     re.escape("\t\t\t\tif (span.x1 == nextspan.x0)\n\t\t\t\t{\n\t\t\t\t\tspan.x1 = nextspan.x1;\n\t\t\t\t\tline.erase(line.begin() + pos + 1);\n\t\t\t\t}\n\t\t\t}\n\t\t\telse if (right == nextspan.x0)\n"),
     lambda m: ("\t\t\t\tif (span.x1 == nextspan.x0)\n\t\t\t\t{\n\t\t\t\t\tspan.x1 = nextspan.x1;\n\t\t\t\t\tline.erase(line.begin() + pos + 1);\n"
                "\t\t\t\t\tpos--; // vita-spanmerge: the gap after the merged run is the next to look at (pos++ would skip it)\n"
                "\t\t\t\t}\n\t\t\t}\n\t\t\telse if (right == nextspan.x0)\n"),
     'vita-spanmerge')
edit("Render/BspClipper.cpp",
     re.escape("\t\t\t\tnextspan.x0 = left;\n\t\t\t\tif (span.x1 == nextspan.x0)\n\t\t\t\t{\n\t\t\t\t\tspan.x1 = nextspan.x1;\n\t\t\t\t\tline.erase(line.begin() + pos + 1);\n\t\t\t\t}\n"),
     lambda m: ("\t\t\t\tnextspan.x0 = left;\n\t\t\t\tif (span.x1 == nextspan.x0)\n\t\t\t\t{\n\t\t\t\t\tspan.x1 = nextspan.x1;\n\t\t\t\t\tline.erase(line.begin() + pos + 1);\n"
                "\t\t\t\t\tpos--; // vita-spanmerge2\n"
                "\t\t\t\t}\n"),
     'vita-spanmerge2')


# 52. Probes in the meshes (the log's 'meshes', 13-31 ms in big halls, ~1-2 ms a mesh): the light list, the pose and skinning,
#     the normals, the vertex light and the faces.
edit("Render/VisibleMesh.cpp",
     re.escape('#include "VitaTimers.h" // vita-timers:include\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-mesh\n',
     'vita-probeinc-mesh')
edit("Render/VisibleMesh.cpp",
     re.escape("\tengine->Level->Light.UpdateLightList(actor);\n"),
     lambda m: "\t{ VITA_PROBE(MeshLightList); engine->Level->Light.UpdateLightList(actor); } // vita-probe-lightlist\n",
     'vita-probe-lightlist')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaTimers.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-skel\n',
     'vita-probeinc-skel')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tstatic Array<vec3> vertexLights;\n\t\tVitaSkinHit skin = VitaSkinLookup(actor, mesh, verts, normals, vertexLights);\n\t\tif (!skin.hit && !GetFrame(actor, mesh, verts))\n\t\t\treturn false;\n"),
     lambda m: ("\t\tVITA_LAP_START; // vita-skellaps\n" + m.group(0) + "\t\tVITA_LAP(MeshPose);\n"),
     'vita-skellaps')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("#ifdef __vita__ // vita-skinnormals-end\n\t\t}\n#endif\n"),
     lambda m: m.group(0) + "\t\tVITA_LAP(MeshNormals); // vita-lap-normals\n",
     'vita-lap-normals')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tbool needTranslucentPass = false;\n\t\tfloat opacity = MeshOpacity(actor);\n"),
     lambda m: "\t\tVITA_LAP(MeshLight); // vita-lap-meshlight\n" + m.group(0),
     'vita-lap-meshlight')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tframe->Device->DrawGouraudPolygon(&frame->Frame, texinfo, vertices, 3, renderflags | PF_RenderFog);\n\t\t}\n\t\treturn needTranslucentPass;\n"),
     lambda m: ("\t\t\tframe->Device->DrawGouraudPolygon(&frame->Frame, texinfo, vertices, 3, renderflags | PF_RenderFog);\n\t\t}\n"
                "\t\tVITA_LAP(MeshFaces); // vita-lap-faces\n"
                "\t\treturn needTranslucentPass;\n"),
     'vita-lap-faces')


# 53. Meshes (probes: vertex light ~330 us and faces ~375 us a mesh, 11-12 ms a frame in big halls), render.cfg mesh_fast:
#     (a) the vertex light four vertices at a time with NEON (vita/VitaMeshLight4.h; checked on the PC against MeshLighting::Light:
#         2.4e-6 at most, vita/tests/meshlighttest.cpp);
#     (b) the faces go to the renderer in runs of consecutive faces with the same material and flags (the order is kept):
#         RenderDevice::DrawGouraudTriangles, whose default draws them one by one; the Vita renderer sets its state once a run.
edit("RenderDevice/RenderDevice.h",
     re.escape("\tvirtual void DrawGouraudPolygon(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumPts, uint32_t PolyFlags) = 0;\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-gouraudtris\n"
                             "\t// Triangles (3 vertices each) with the same texture and flags\n"
                             "\tvirtual void DrawGouraudTriangles(SceneNode* Frame, TextureInfo& Info, const GouraudVertex* Pts, int NumTriangles, uint32_t PolyFlags)\n"
                             "\t{\n"
                             "\t\tfor (int i = 0; i < NumTriangles; i++)\n"
                             "\t\t\tDrawGouraudPolygon(Frame, Info, Pts + i * 3, 3, PolyFlags);\n"
                             "\t}\n"
                             "#endif\n"),
     'vita-gouraudtris')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-skel\n'),
     lambda m: m.group(0) + '#include "VitaMeshLight4.h" // vita-light4inc\n',
     'vita-light4inc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tvertexLights.resize(verts.size());\n\t\t\tfor (size_t i = 0; i < verts.size(); i++)\n\t\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n\t\t\tVitaSkinStore("),
     lambda m: ("\t\t\tvertexLights.resize(verts.size());\n"
                "\t\t\tif (VitaMeshFast() && normals.size() >= verts.size()) // vita-light4use\n"
                "\t\t\t\tVitaLightVertices(lighting, verts.data(), normals.data(), vertexLights.data(), verts.size());\n"
                "\t\t\telse\n"
                "\t\t\tfor (size_t i = 0; i < verts.size(); i++)\n\t\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n\t\t\tVitaSkinStore("),
     'vita-light4use')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tbool needTranslucentPass = false;\n\t\tfloat opacity = MeshOpacity(actor);\n\t\tGouraudVertex vertices[3];\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-facerun\n"
                "\t\t// Consecutive faces with the same material and flags are handed over together (mesh_fast)\n"
                "\t\tstatic std::vector<GouraudVertex> runVertices;\n"
                "\t\trunVertices.clear();\n"
                "\t\tTextureInfo* runTexture = nullptr;\n"
                "\t\tuint32_t runFlags = 0;\n"
                "\t\tconst bool faceRuns = VitaMeshFast();\n"
                "\t\tauto flushRun = [&]()\n"
                "\t\t{\n"
                "\t\t\tif (!runVertices.empty())\n"
                "\t\t\t\tframe->Device->DrawGouraudTriangles(&frame->Frame, *runTexture, runVertices.data(), (int)(runVertices.size() / 3), runFlags);\n"
                "\t\t\trunVertices.clear();\n"
                "\t\t};\n"
                "#endif\n"),
     'vita-facerun')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tframe->Device->DrawGouraudPolygon(&frame->Frame, texinfo, vertices, 3, renderflags | PF_RenderFog);\n\t\t}\n\t\tVITA_LAP(MeshFaces); // vita-lap-faces\n"),
     lambda m: ("#ifdef __vita__ // vita-facerun-use\n"
                "\t\t\tif (faceRuns)\n"
                "\t\t\t{\n"
                "\t\t\t\tconst uint32_t flags = renderflags | PF_RenderFog;\n"
                "\t\t\t\tif (runTexture != &texinfo || runFlags != flags)\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tflushRun();\n"
                "\t\t\t\t\trunTexture = &texinfo;\n"
                "\t\t\t\t\trunFlags = flags;\n"
                "\t\t\t\t}\n"
                "\t\t\t\trunVertices.insert(runVertices.end(), vertices, vertices + 3);\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\t}\n"
                "#endif\n"
                "\t\t\tframe->Device->DrawGouraudPolygon(&frame->Frame, texinfo, vertices, 3, renderflags | PF_RenderFog);\n\t\t}\n"
                "#ifdef __vita__\n"
                "\t\tflushRun();\n"
                "#endif\n"
                "\t\tVITA_LAP(MeshFaces); // vita-lap-faces\n"),
     'vita-facerun-use')


# 54. Finer probes in the meshes (#53 changed little): the parts of 'mesh: light' and the renderer's share of 'mesh: faces'
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     r"\t\tlightsys->InitVertexLight\(vertexLight, lightLocationActor, zoneActor[^\n]*\);\n\t\tMeshLighting lighting;\n",
     lambda m: "\t\t// vita-lap-lightinit\n" + m.group(0).replace("MeshLighting lighting;\n", "MeshLighting lighting;\n\t\tVITA_LAP(MeshLightInit);\n"),
     'vita-lap-lightinit')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tSetupMeshLighting(lighting, actor, lightLocationActor, zoneActor);\n\t\t\tvertexLights.resize(verts.size());\n"),
     lambda m: m.group(0) + "\t\t\tVITA_LAP(MeshLightSetup); // vita-lap-lightsetup\n",
     'vita-lap-lightsetup')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n\t\t\tVitaSkinStore(actor, mesh, verts, normals, vertexLights, lighting.Unlit);\n"),
     lambda m: ("\t\t\t\tvertexLights[i] = lighting.Light(verts[i], normals[i]);\n"
                "\t\t\tVITA_LAP(MeshLightVerts); // vita-lap-lightverts\n"
                "\t\t\tVitaSkinStore(actor, mesh, verts, normals, vertexLights, lighting.Unlit);\n"
                "\t\t\tVITA_LAP(MeshLightStore);\n"),
     'vita-lap-lightverts')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\tframe->Device->DrawGouraudTriangles(&frame->Frame, *runTexture, runVertices.data(), (int)(runVertices.size() / 3), runFlags);\n"),
     lambda m: "\t\t\t{\n\t\t\t\tVITA_PROBE(MeshDevice); // vita-probe-meshdev\n" + m.group(0) + "\t\t\t}\n",
     'vita-probe-meshdev')


# 55. The time of actor ticks by class (probes=1): the log's 'level tick' is 13-21 ms in big halls
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape('#include "VitaConfig.h" // vita-tickinc\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-level\n',
     'vita-probeinc-level')
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t// Tick the actor for this turn\n\tactor->Tick(elapsed);\n"),
     lambda m: ("\t// Tick the actor for this turn\n"
                "#ifdef __vita__ // vita-classtime\n"
                "\tif (VitaProbes::enabled)\n"
                "\t{\n"
                "\t\tUClass* cls = actor->Class;\n"
                "\t\tconst uint64_t start = VitaProbes::Now();\n"
                "\t\tactor->Tick(elapsed);\n"
                "\t\tVitaProbes::ClassTime& entry = VitaProbes::classTimes[cls];\n"
                "\t\tif (entry.name.empty())\n"
                "\t\t\tentry.name = cls->Name.ToString();\n"
                "\t\tentry.us += (double)(VitaProbes::Now() - start);\n"
                "\t\tentry.calls++;\n"
                "\t}\n"
                "\telse\n"
                "#endif\n"
                "\tactor->Tick(elapsed);\n"),
     'vita-classtime')

edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-level\n'),
     lambda m: m.group(0) + '#include "Packages/Core/UClass.h" // vita-uclassinc\n',
     'vita-uclassinc')


# 56. KW::SetupMeshLighting walked every light of the level for every mesh (s.Lights, ~715 in Hogwarts' halls), reading
#     bSpecialLit, WorldLightRadius and Location of each to drop the far ones: ~270 us a mesh (probes). BeginFrame keeps those values
#     with the list (once a frame; no script runs between the level's tick and the drawing, so they are the same values).
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\t\tstd::vector<UActor*> Lights;\n\t\t\tstd::unordered_map<UActor*, ActorLightCache> Cache;\n"),
     lambda m: ("\t\t\tstd::vector<UActor*> Lights;\n"
                "#ifdef __vita__ // vita-lightsnap\n"
                "\t\t\tstd::vector<vec3> LightLocations;   // of Lights, read once a frame\n"
                "\t\t\tstd::vector<float> LightRadii;\n"
                "\t\t\tstd::vector<uint8_t> LightSpecialLit;\n"
                "#endif\n"
                "\t\t\tstd::unordered_map<UActor*, ActorLightCache> Cache;\n"),
     'vita-lightsnap')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\t\ts.Lights.clear();\n\t\t\tfor (UActor* light : s.Level->Actors)\n\t\t\t{\n\t\t\t\tif (light && light->LightType() != LT_None && light->LightBrightness() != 0)\n\t\t\t\t\ts.Lights.push_back(light);\n\t\t\t}\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-lightsnap-fill\n"
                "\t\t\ts.LightLocations.resize(s.Lights.size());\n"
                "\t\t\ts.LightRadii.resize(s.Lights.size());\n"
                "\t\t\ts.LightSpecialLit.resize(s.Lights.size());\n"
                "\t\t\tfor (size_t i = 0; i < s.Lights.size(); i++)\n"
                "\t\t\t{\n"
                "\t\t\t\ts.LightLocations[i] = s.Lights[i]->Location();\n"
                "\t\t\t\ts.LightRadii[i] = s.Lights[i]->WorldLightRadius();\n"
                "\t\t\t\ts.LightSpecialLit[i] = s.Lights[i]->bSpecialLit() ? 1 : 0;\n"
                "\t\t\t}\n"
                "#endif\n"),
     'vita-lightsnap-fill')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\tfor (UActor* light : s.Lights)\n\t\t{\n\t\t\tif (light == lightActor || light->bSpecialLit() != specialLit)\n\t\t\t\tcontinue;\n\t\t\tfloat radius = light->WorldLightRadius();\n\t\t\tvec3 L = light->Location() - location;\n"),
     lambda m: ("#ifdef __vita__ // vita-lightsnap-use\n"
                "\t\tfor (size_t li = 0; li < s.Lights.size(); li++)\n"
                "\t\t{\n"
                "\t\t\tUActor* light = s.Lights[li];\n"
                "\t\t\tif (light == lightActor || (s.LightSpecialLit[li] != 0) != specialLit)\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\tfloat radius = s.LightRadii[li];\n"
                "\t\t\tvec3 L = s.LightLocations[li] - location;\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-lightsnap-use')

# 57. A mesh face turned away from the eye is dropped before its texture coordinates, normals, light and fog are worked out (the
#     same test as below, made first; about half the faces of a mesh)
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tbool valid = true;\n\t\t\tvec3 faceNormals[3];\n\t\t\tint faceVerts[3];\n"),
     lambda m: ("#ifdef __vita__ // vita-earlycull\n"
                "\t\t\tif (!(renderflags & PF_TwoSided) && face.Indices[0] < numWedges && face.Indices[1] < numWedges && face.Indices[2] < numWedges)\n"
                "\t\t\t{\n"
                "\t\t\t\tconst int c0 = wedgeVertex(face.Indices[0]), c1 = wedgeVertex(face.Indices[1]), c2 = wedgeVertex(face.Indices[2]);\n"
                "\t\t\t\tif (c0 < (int)verts.size() && c1 < (int)verts.size() && c2 < (int)verts.size())\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tconst vec3 n = cross(verts[c1] - verts[c0], verts[c2] - verts[c0]);\n"
                "\t\t\t\t\tif (dot(n, eye - verts[c0]) <= 0.0f)\n"
                "\t\t\t\t\t\tcontinue;\n"
                "\t\t\t\t}\n"
                "\t\t\t}\n"
                "#endif\n" + m.group(0)),
     'vita-earlycull')


# 58. Static actors are not ticked, as in HP1: ULevel::Tick [HP1 0x103B6DB0] ticks Actors from iFirstDynamicActor (ULevel+0x110) on,
#     and UGameEngine::LoadMap [HP1 0x1039C3D0] sorts Actors as [0], [1], the bStatic ones (Actor+0x28 bit 0), iFirstDynamicActor,
#     the rest (docs/re/engine/level_tick.md). SurrealEngine ticked all ~1200 actors of Hogwarts' first hall a frame, 715 of them
#     Lights (2.8 ms). An owner is still ticked first by the actor it owns (TickActor). render.cfg tick_static=1: as before.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t\t\tUActor* actor = Actors[i];\n\t\t\tif (!actor)\n\t\t\t\tcontinue;\n\t\t\tif (farDistance > 0.0f && VitaFarAndUnseen(actor, now, camera, farDistance))\n"),
     lambda m: ("\t\t\tUActor* actor = Actors[i];\n\t\t\tif (!actor)\n\t\t\t\tcontinue;\n"
                "\t\t\tif (!VitaTickStatic() && actor->bStatic()) // vita-skipstatic: before iFirstDynamicActor in HP1\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\tif (farDistance > 0.0f && VitaFarAndUnseen(actor, now, camera, farDistance))\n"),
     'vita-skipstatic')

# 59. The visible skeletal meshes are posed, skinned and lit before the actors are drawn, the arithmetic on the other cores
#     (vita/VitaMeshPrepass.inc, vita/VitaJobs.h; render.cfg mesh_threads)
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaMeshLight4.h" // vita-light4inc\n'),
     lambda m: m.group(0) + '#include "VitaJobs.h" // vita-jobsinc\n#include "Render/VisibleActor.h"\n',
     'vita-jobsinc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\treturn needTranslucentPass;\n\t}\n}\n"),
     lambda m: ("\t\treturn needTranslucentPass;\n\t}\n"
                "#ifdef __vita__\n#include \"VitaMeshPrepass.inc\" // vita-meshprepass\n#endif\n"
                "}\n"),
     'vita-meshprepass')
edit("Render/VisibleFrame.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-frame\n'),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-prepassdecl\n"
                             "namespace KW { void VitaPrepareMeshes(VisibleFrame* frame); }\n"
                             "#endif\n"),
     'vita-prepassdecl')
edit("Render/VisibleFrame.cpp",
     re.escape("\tDevice->SetSceneNode(&Frame);\n\tfor (VisibleActor& actor : Actors)\n\t\tactor.DrawOpaque(this);\n"),
     lambda m: ("\tDevice->SetSceneNode(&Frame);\n"
                "#ifdef __vita__ // vita-prepasscall\n"
                "\tif (engine->LaunchInfo.IsKnowWonder())\n"
                "\t\tKW::VitaPrepareMeshes(this);\n"
                "#endif\n"
                "\tfor (VisibleActor& actor : Actors)\n\t\tactor.DrawOpaque(this);\n"),
     'vita-prepasscall')

# 60. Probes in the process step: the actor shadows, and each node's surface all told (the walk is the rest)
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tKW::UpdateActorShadows(this);\n"),
     lambda m: "\t{ VITA_PROBE(ProcShadows); KW::UpdateActorShadows(this); } // vita-probe-shadows\n",
     'vita-probe-shadows')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tProcessNodeSurface(polynode, swapFrontAndBack);\n"),
     lambda m: "\t\t{ VITA_PROBE(ProcNodeSurface); ProcessNodeSurface(polynode, swapFrontAndBack); } // vita-probe-nodesurf\n",
     'vita-probe-nodesurf')


# 61. A one-sided BSP surface seen from behind is dropped at the start of ProcessNodeSurface, before its points are copied (the same
#     test the function makes after the copy: the surface's and its material's PolyFlags, the side of the node's plane)
edit("Render/VisibleFrame.cpp",
     re.escape("\tUModel* model = engine->Level->Model;\n\tconst BspSurface& surface = model->Surfaces[node->Surf];\n\n\tint numverts = node->NumVertices;\n"),
     lambda m: ("\tUModel* model = engine->Level->Model;\n\tconst BspSurface& surface = model->Surfaces[node->Surf];\n\n"
                "#ifdef __vita__ // vita-earlyback\n"
                "\t{\n"
                "\t\tuint32_t flags = surface.PolyFlags;\n"
                "\t\tif (surface.Material)\n"
                "\t\t\tflags |= surface.Material->PolyFlags();\n"
                "\t\tif (!(flags & PF_TwoSided) && dot(ViewLocation, vec4(node->PlaneX, node->PlaneY, node->PlaneZ, -node->PlaneW)) < 0.0f)\n"
                "\t\t\treturn;\n"
                "\t}\n"
                "#endif\n\n"
                "\tint numverts = node->NumVertices;\n"),
     'vita-earlyback')


# 62. Probes in the 'bsp info' step (it rose from ~4 to ~6 ms in Lev_Tut1's hall with #58/#59): each actor, and the skeletal box
edit("Render/RenderScene.cpp",
     re.escape("\t\tif (actor)\n\t\t\tactor->UpdateBspInfo();\n"),
     lambda m: "\t\tif (actor)\n\t\t{\n\t\t\tVITA_PROBE(BspActor); // vita-probe-bspactor\n\t\t\tactor->UpdateBspInfo();\n\t\t}\n",
     'vita-probe-bspactor')
edit("Render/RenderScene.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-scene\n',
     'vita-probeinc-scene')
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape("\t\t\t\tbbox = KW::GetRenderBoundingBox(this, skel);\n"),
     lambda m: "\t\t\t{\n\t\t\t\tVITA_PROBE(BspSkelBox); // vita-probe-skelbox\n\t\t\t\tbbox = KW::GetRenderBoundingBox(this, skel);\n\t\t\t}\n",
     'vita-probe-skelbox')
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape('#include "VitaConfig.h" // vita-bspinc\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-probeinc-actrender\n',
     'vita-probeinc-actrender')


# 63. The 'bsp info' step looked at every actor of the level every frame (~1270 in Lev_Tut1, ~3-4 us each, most of it reading the
#     actor's properties). A static actor can't move or turn (UE1's MoveActor/FarMoveActor refuse bStatic) and isn't ticked (#58):
#     once placed in the BSP it is looked at again only every 16th frame, staggered, to catch a script changing how it is drawn.
#     bStatic is const: it is read once and kept with the BSP info.
edit("Packages/Engine/Actors/UActor.h",
     re.escape("\t\tfloat LastDrawn = -1000.0f; // when a mesh actor was last drawn (HP1 has no LastRenderTime property)\n"),
     lambda m: m.group(0) + "\t\tint8_t VitaStatic = -1;     // vita-bspstatic-field: bStatic, read once (-1: not yet)\n",
     'vita-bspstatic-field')
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape("#ifdef __vita__ // vita-bspinfo-guard\n\tif (VitaBspInfoCache())\n\t{\n"),
     lambda m: ("#ifdef __vita__ // vita-bspstatic\n"
                "\tif (VitaBspInfoCache())\n"
                "\t{\n"
                "\t\tif (BspInfo.VitaStatic < 0)\n"
                "\t\t\tBspInfo.VitaStatic = bStatic() ? 1 : 0;\n"
                "\t\tif (BspInfo.VitaStatic == 1 && BspInfo.Node && ((((uint32_t)(uintptr_t)this >> 6) + VitaTimers::frameNumber) & 15) != 0)\n"
                "\t\t\treturn;\n"
                "\t}\n"
                "#endif\n" + m.group(0)),
     'vita-bspstatic')
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-actrender\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-timersinc-actrender\n',
     'vita-timersinc-actrender')


# 64. No probe around each actor's UpdateBspInfo any more (it cost ~1.4 us an actor itself); the skeletal box probe stays
edit("Render/RenderScene.cpp",
     re.escape("\t\tif (actor)\n\t\t{\n\t\t\tVITA_PROBE(BspActor); // vita-probe-bspactor\n\t\t\tactor->UpdateBspInfo();\n\t\t}\n"),
     lambda m: "\t\tif (actor)\n\t\t\tactor->UpdateBspInfo(); // vita-probe-bspactor removed: vita-bspactor-off\n",
     'vita-bspactor-off')


# 65. The end of ULevel::Tick rebuilt the actor array every frame and wrote every actor's Index (a cache miss per actor, ~1270).
#     Only a destroyed actor (a null) moves the others; new ones are appended. Without a null only the new ones get their Index.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\tArray<UActor*> newActorList;\n\tnewActorList.reserve(Actors.size());\n\tfor (UActor* actor : Actors)\n\t{\n\t\tif (actor)\n\t\t{\n\t\t\tactor->Index = (int)newActorList.size();\n\t\t\tnewActorList.push_back(actor);\n\t\t}\n\t}\n\tActors.swap(newActorList);\n"),
     lambda m: ("#ifdef __vita__ // vita-compactactors\n"
                "\tstatic ULevel* indexedLevel = nullptr;\n"
                "\tstatic size_t indexedUpTo = 0;   // Actors[0..indexedUpTo) have their Index and no null came since\n"
                "\tbool hasNull = false;\n"
                "\tfor (UActor* actor : Actors)\n"
                "\t{\n"
                "\t\tif (!actor)\n"
                "\t\t{\n"
                "\t\t\thasNull = true;\n"
                "\t\t\tbreak;\n"
                "\t\t}\n"
                "\t}\n"
                "\tif (!hasNull && indexedLevel == this && indexedUpTo <= Actors.size())\n"
                "\t{\n"
                "\t\tfor (size_t i = indexedUpTo; i < Actors.size(); i++)\n"
                "\t\t\tActors[i]->Index = (int)i;\n"
                "\t\tindexedUpTo = Actors.size();\n"
                "\t}\n"
                "\telse\n"
                "\t{\n"
                + m.group(0).replace("\n\t", "\n\t\t").replace("\tArray<UActor*> newActorList;", "\t\tArray<UActor*> newActorList;", 1) +
                "\t\tindexedLevel = this;\n"
                "\t\tindexedUpTo = Actors.size();\n"
                "\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-compactactors')


# 66. Mesh LOD as HP1's URender::DrawLodMesh [HP1 Render 0x10B0FF00] (docs/re/engine/animation.md "LOD"): the number of vertices a
#     skeletal mesh is drawn with comes from its screen size, Actor.LODBias, Mesh.LODStrength/LODMinVerts and URender's LODAdjust,
#     which rises by 0.1 a frame while the frame rate is under MinDesiredFrameRate (30) [HP1 Render 0x10B1EF80]. Faces whose
#     FaceLevel is above it are not drawn; a wedge whose vertex is at or above it is replaced by CollapseWedgeThus until it isn't.
#     The port drew every mesh in full. render.cfg mesh_lod (HP1 only: HP2's Render.dll is not checked).
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaJobs.h" // vita-jobsinc\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-lodheaders\n#include <unordered_set>\n#include <cmath>\n',
     'vita-lodheaders')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tArray<vec3> verts, normals, lights;\n\t\tbool valid = false;\n\t};\n"),
     lambda m: "\t\tArray<vec3> verts, normals, lights;\n\t\tbool valid = false;\n\t\tint lod = -1; // vita-lodentry: the LODRequest the entry was made for (-1: every vertex)\n\t};\n",
     'vita-lodentry')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\tstatic VitaSkinHit VitaSkinLookup(UActor* actor, USkeletalMesh* mesh, Array<vec3>& verts, Array<vec3>& normals, Array<vec3>& lights)\n"),
     lambda m: "\tstatic VitaSkinHit VitaSkinLookup(UActor* actor, USkeletalMesh* mesh, Array<vec3>& verts, Array<vec3>& normals, Array<vec3>& lights, int lod) // vita-lodlookup\n",
     'vita-lodlookup')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\te.rotation.Roll != rotation.Roll || e.scale != actor->DrawScale())\n\t\t\treturn result;\n"),
     lambda m: "\t\t\te.rotation.Roll != rotation.Roll || e.scale != actor->DrawScale() || e.lod != lod) // vita-lodlookup2\n\t\t\treturn result;\n",
     'vita-lodlookup2')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\tstatic void VitaSkinStore(UActor* actor, USkeletalMesh* mesh, const Array<vec3>& verts, const Array<vec3>& normals, const Array<vec3>& lights, const vec3& unlit)\n"),
     lambda m: "\tstatic void VitaSkinStore(UActor* actor, USkeletalMesh* mesh, const Array<vec3>& verts, const Array<vec3>& normals, const Array<vec3>& lights, const vec3& unlit, int lod) // vita-lodstore\n",
     'vita-lodstore')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\te.valid = true;\n\t}\n"),
     lambda m: "\t\te.valid = true;\n\t\te.lod = lod; // vita-lodstore2\n\t}\n",
     'vita-lodstore2')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\tbool DrawSkeletalMesh(VisibleFrame* frame, UActor* actor, UActor* lightLocationActor, USkeletalMesh* mesh, bool translucentPass)\n\t{\n"),
     lambda m: ('#ifdef __vita__\n#include "VitaMeshLod.inc" // vita-lodinc\n#endif\n\n' + m.group(0)),
     'vita-lodinc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tVitaSkinHit skin = VitaSkinLookup(actor, mesh, verts, normals, vertexLights);\n"),
     lambda m: ("\t\tconst int lod = VitaLodRequest(frame, actor, mesh); // vita-lodcalc\n"
                "\t\tVitaSkinHit skin = VitaSkinLookup(actor, mesh, verts, normals, vertexLights, lod);\n"),
     'vita-lodcalc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tsize_t numWedges = useExtWedges ? mesh->ExtWedges.size() : mesh->Wedges.size();\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-lodwedge\n"
                "\t\t// HP1's LOD: a wedge whose vertex is at or above LODRequest is replaced by CollapseWedgeThus until it isn't\n"
                "\t\tauto lodWedge = [&](int w) -> int { return VitaLodWedge(mesh, w, lod, useExtWedges); };\n"
                "\t\tauto lodFaceSkipped = [&](const MeshFace& face) -> bool { return VitaLodFaceSkipped(mesh, &face - mesh->Faces.data(), lod); };\n"
                "#else\n"
                "\t\tauto lodWedge = [](int w) -> int { return w; };\n"
                "\t\tauto lodFaceSkipped = [](const MeshFace&) -> bool { return false; };\n"
                "#endif\n"),
     'vita-lodwedge')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n\t\t\tif (face.Indices[0] >= numWedges || face.Indices[1] >= numWedges || face.Indices[2] >= numWedges)\n\t\t\t\tcontinue;\n\t\t\tint i0 = wedgeVertex(face.Indices[0]), i1 = wedgeVertex(face.Indices[1]), i2 = wedgeVertex(face.Indices[2]);\n"),
     lambda m: ("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n\t\t\tif (face.Indices[0] >= numWedges || face.Indices[1] >= numWedges || face.Indices[2] >= numWedges)\n\t\t\t\tcontinue;\n"
                "\t\t\tif (lodFaceSkipped(face)) // vita-lodnormals\n\t\t\t\tcontinue;\n"
                "\t\t\tint i0 = wedgeVertex(lodWedge(face.Indices[0])), i1 = wedgeVertex(lodWedge(face.Indices[1])), i2 = wedgeVertex(lodWedge(face.Indices[2]));\n"),
     'vita-lodnormals')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tVitaSkinStore(actor, mesh, verts, normals, vertexLights, lighting.Unlit);\n"),
     lambda m: "\t\t\tVitaSkinStore(actor, mesh, verts, normals, vertexLights, lighting.Unlit, lod); // vita-lodstorecall\n",
     'vita-lodstorecall')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n\t\t\tif (face.MaterialIndex >= mesh->Materials.size())\n\t\t\t\tcontinue;\n"),
     lambda m: ("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n"
                "\t\t\tif (lodFaceSkipped(face)) // vita-lodfaces\n\t\t\t\tcontinue;\n"
                "\t\t\tif (face.MaterialIndex >= mesh->Materials.size())\n\t\t\t\tcontinue;\n"),
     'vita-lodfaces')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\tconst int c0 = wedgeVertex(face.Indices[0]), c1 = wedgeVertex(face.Indices[1]), c2 = wedgeVertex(face.Indices[2]);\n"),
     lambda m: "\t\t\t\tconst int c0 = wedgeVertex(lodWedge(face.Indices[0])), c1 = wedgeVertex(lodWedge(face.Indices[1])), c2 = wedgeVertex(lodWedge(face.Indices[2])); // vita-lodcull\n",
     'vita-lodcull')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\tint w = face.Indices[i];\n\t\t\t\tif (w >= (int)numWedges) { valid = false; break; }\n"),
     lambda m: "\t\t\t\tint w = face.Indices[i];\n\t\t\t\tif (w >= (int)numWedges) { valid = false; break; }\n\t\t\t\tw = lodWedge(w); // vita-lodface-wedge\n",
     'vita-lodface-wedge')


# 67. Frame::Call asks IsEventEnabled(func->Name) on every script call: the state's name and a std::map search for the events
#     disabled in it. Almost no object ever disables an event: with none disabled the answer is known (the probe masks are still
#     checked first, as before).
edit("Packages/Core/UObject.cpp",
     re.escape("\telse\n\t{\n\t\tNameString stateName = GetStateName();\n\t\tauto it = DisabledEvents.find(stateName);\n\t\treturn it == DisabledEvents.end() || it->second.find(name) == it->second.end();\n\t}\n"),
     lambda m: ("\telse\n\t{\n"
                "\t\tif (DisabledEvents.empty()) // vita-noevents1\n\t\t\treturn true;\n"
                "\t\tNameString stateName = GetStateName();\n\t\tauto it = DisabledEvents.find(stateName);\n\t\treturn it == DisabledEvents.end() || it->second.find(name) == it->second.end();\n\t}\n"),
     'vita-noevents1')
edit("Packages/Core/UObject.cpp",
     re.escape("\t\tif (!foundProbe)\n\t\t\treturn false;\n\t}\n\n\tNameString stateName = GetStateName();\n"),
     lambda m: ("\t\tif (!foundProbe)\n\t\t\treturn false;\n\t}\n\n"
                "\tif (DisabledEvents.empty()) // vita-noevents2\n\t\treturn true;\n"
                "\tNameString stateName = GetStateName();\n"),
     'vita-noevents2')


# 68. PropertyDataBlock::Ptr (every script property read: Value, BoolValue, ...) was not inlined: the Exception::Throw in it made
#     it too big, and 1107 call sites called one of 15 out-of-line copies. The throw goes to a cold function; the check stays.
edit("Packages/Core/UObject.h",
     re.escape("inline void* PropertyDataBlock::Ptr(size_t offset)\n{\n\tif (offset < Size)\n\t\treturn static_cast<uint8_t*>(Data) + offset;\n\tException::Throw(\"Property offset out of bounds!\");\n}\n\ninline const void* PropertyDataBlock::Ptr(size_t offset) const\n{\n\tif (offset < Size)\n\t\treturn static_cast<const uint8_t*>(Data) + offset;\n\tException::Throw(\"Property offset out of bounds!\");\n}\n"),
     lambda m: ("#ifdef __vita__ // vita-ptrinline\n"
                "[[noreturn]] __attribute__((noinline, cold)) inline void PropertyOffsetOutOfBounds() { Exception::Throw(\"Property offset out of bounds!\"); }\n"
                "__attribute__((always_inline)) inline void* PropertyDataBlock::Ptr(size_t offset)\n{\n"
                "\tif (__builtin_expect(offset < Size, 1))\n\t\treturn static_cast<uint8_t*>(Data) + offset;\n\tPropertyOffsetOutOfBounds();\n}\n\n"
                "__attribute__((always_inline)) inline const void* PropertyDataBlock::Ptr(size_t offset) const\n{\n"
                "\tif (__builtin_expect(offset < Size, 1))\n\t\treturn static_cast<const uint8_t*>(Data) + offset;\n\tPropertyOffsetOutOfBounds();\n}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-ptrinline')


# 69. ExpressionValue::Deinit (the script VM, every value it drops) wasn't inlined either (774 call sites): the destructors of strings,
#     names, structs and arrays made it big. Those go to a cold function; every other kind has nothing to destroy.
edit("VM/ExpressionValue.h",
     re.escape("\tvoid Deinit()\n\t{\n\t\tif (!VariableProperty)\n\t\t{\n\t\t\tswitch (Type)\n"),
     lambda m: ("#ifdef __vita__ // vita-deinitinline\n"
                "\t__attribute__((always_inline)) void Deinit()\n\t{\n\t\tif (!VariableProperty)\n\t\t{\n"
                "\t\t\tif (__builtin_expect(Type == ExpressionValueType::ValueString || Type == ExpressionValueType::ValueName ||\n"
                "\t\t\t\tType == ExpressionValueType::ValueStruct || Type == ExpressionValueType::ValueArray, 0))\n"
                "\t\t\t\tDeinitSlow();\n"
                "\t\t\tType = ExpressionValueType::Nothing;\n"
                "\t\t}\n\t\telse\n\t\t{\n\t\t\tVariableProperty = nullptr;\n\t\t}\n\t}\n\n"
                "\t__attribute__((noinline)) void DeinitSlow()\n\t{\n"
                "\t\tswitch (Type)\n\t\t{\n\t\tdefault: break;\n"
                "\t\tcase ExpressionValueType::ValueString: PtrString->~basic_string(); break;\n"
                "\t\tcase ExpressionValueType::ValueName: PtrName->~NameString(); break;\n"
                "\t\tcase ExpressionValueType::ValueStruct: GetStructValue()->~StructValue(); break;\n"
                "\t\tcase ExpressionValueType::ValueArray: GetArrayValue()->~ArrayValue(); break;\n"
                "\t\t}\n\t}\n"
                "#else\n"
                "\tvoid Deinit() { DeinitAll(); }\n"
                "#endif\n\n"
                "\tvoid DeinitAll()\n\t{\n\t\tif (!VariableProperty)\n\t\t{\n\t\t\tswitch (Type)\n"),
     'vita-deinitinline')


# 70. The surface cache of the Vita renderer (render.cfg surface_cache, vita/VitaRenderDevice.h): a level surface carries a key, its BSP
#     node (with the side and the mirror flag), so the renderer can keep its vertices in video memory and find them again.
edit("RenderDevice/RenderDevice.h",
     re.escape("\tvec3* Vertices;\n\tuint32_t VertexCount;\n};\n"),
     lambda m: ("\tvec3* Vertices;\n\tuint32_t VertexCount;\n"
                "#ifdef __vita__ // vita-facetkey-h\n"
                "\tuint32_t VitaKey = 0; // a level surface: its BSP node * 4 + side * 2 + mirror + 1 (0: anything else, a mover's polygon)\n"
                "#endif\n};\n"),
     'vita-facetkey-h')
edit("Render/VisibleNode.cpp",
     re.escape("\tfacet.VertexCount = numverts;\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-facetkey-node\n"
                             "\t// (not in HP2: its Lumos surfaces change what is drawn of a surface)\n"
                             "\tif (!engine->LaunchInfo.IsHarryPotter2())\n"
                             "\t\tfacet.VitaKey = (uint32_t)(Node - model->Nodes.data()) * 4 + (Front ? 2 : 0) + (frame->MirrorFlag ? 1 : 0) + 1;\n"
                             "#endif\n"),
     'vita-facetkey-node')

# 71. LightSystem::GetLightmap looked its lightmap up twice in the hash map (lmtextures) for every surface drawn (~360 a frame in big
#     halls). The map entry is now also kept by the lightmap's index (the map's nodes never move; cleared with the map): one look at a
#     vector, and the hash lookup only for a lightmap seen the first time (or another zone's ambient light: a new CacheID).
edit("Light/LightSystem.h",
     re.escape("\tvoid VitaCollectDynamic(const vec3& center, float radius);\n"),
     lambda m: m.group(0) + ("\t// vita-lmdirect-h: lmtextures' entry by lightmap index, with the CacheID it was found for\n"
                             "\tstd::vector<std::pair<uint64_t, std::unique_ptr<LightmapTexture>*>> VitaLmDirect;\n"),
     'vita-lmdirect-h')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tVITA_LAP(LmPrologue); // vita-lap-prologue\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-lmdirect-find\n"
                             "\tstd::unique_ptr<LightmapTexture>* vitaDirect = nullptr;\n"
                             "\tif (!dynamicMover && (size_t)lightmapIndex < VitaLmDirect.size() && VitaLmDirect[lightmapIndex].first == cacheID)\n"
                             "\t\tvitaDirect = VitaLmDirect[lightmapIndex].second;\n"
                             "#endif\n"),
     'vita-lmdirect-find')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t{\n\t\t\tauto found = lmtextures.find(cacheID);\n\t\t\tif (found != lmtextures.end())\n\t\t\t\tkept = found->second.get();\n\t\t}\n"),
     lambda m: ("\t\tif (vitaDirect) // vita-lmdirect-kept\n\t\t\tkept = vitaDirect->get();\n\t\telse\n" + m.group(0)),
     'vita-lmdirect-kept')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tauto& lmtexture = lmtextures[cacheID];\n"),
     lambda m: ("#ifdef __vita__ // vita-lmdirect-use\n"
                "\tstd::unique_ptr<LightmapTexture>& lmtexture = vitaDirect ? *vitaDirect : lmtextures[cacheID];\n"
                "\tif (!vitaDirect && !dynamicMover)\n"
                "\t{\n"
                "\t\tif (VitaLmDirect.size() <= (size_t)lightmapIndex)\n"
                "\t\t\tVitaLmDirect.resize((size_t)lightmapIndex + 1, { 0, nullptr });\n"
                "\t\tVitaLmDirect[lightmapIndex] = { cacheID, &lmtexture };\n"
                "\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-lmdirect-use')
edit("Light/LightSystem.cpp",
     re.escape("\tengine->Level->Light.lmtextures.clear();\n"),
     lambda m: m.group(0) + "\tengine->Level->Light.VitaLmDirect.clear(); // vita-lmdirect-clear\n",
     'vita-lmdirect-clear')


# 72. The visibility walk (VisibleFrame::Process, ~14 ms a frame in big halls) on three cores, render.cfg vis_threads
#     (vita/VitaParallelVis.inc, which explains it): three strips of the clipper's screen walked by the mesh workers and the main
#     thread, then ProcessNode once more on the main thread with VitaReplay set, answering every question to the clipper from them.
edit("Render/BspClipper.h",
     re.escape("\tArray<PortalSpan> CheckPortal(const vec3* vertices, uint32_t count);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pvis-clipper-h\n"
                             "\tvoid VitaKeepColumns(int x0, int x1); // only these columns of the screen stay open (vita/VitaClipperPolygon.h)\n"
                             "\tint VitaWidth() const { return ViewportWidth; }\n"
                             "#endif\n"),
     'vita-pvis-clipper-h')
edit("Render/VisibleFrame.h",
     re.escape("\tvec4 PortalPlane = vec4(0.0f, 0.0f, 0.0f, 1.0f); // what a portal's frame keeps: dot(PortalPlane, p) >= 0\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pvis-frame-pub\n"
                             "\t// vita/VitaParallelVis.inc: the walk answered from the strips, and the answer for the next VisibleActor::Process\n"
                             "\tbool VitaReplay = false;\n"
                             "\tbool VitaReplayFailed = false;\n"
                             "\tint VitaForcedVisible = -1; // -1: ask the clipper\n"
                             "#endif\n"),
     'vita-pvis-frame-pub')
edit("Render/VisibleFrame.h",
     re.escape("\tvoid SortTranslucent();\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pvis-frame-priv\n"
                             "\tbool VitaProcessParallel(const Array<PortalSpan>& portalSpans, const vec4& portalPlane);\n"
                             "\tbool VitaReplayBox(BspNode* node);\n"
                             "\tint VitaReplayActor(BspNode* node, int k, UActor* actor);\n"
                             "\tbool VitaReplaySurface(BspNode* node);\n"
                             "\tArray<PortalSpan> VitaReplayPortal(BspNode* node);\n"
                             "#endif\n"),
     'vita-pvis-frame-priv')
edit("Render/VisibleFrame.cpp",
     re.escape("\tProcessNode(&engine->Level->Model->Nodes[0]);\n#ifdef __vita__ // vita-clipcount\n"),
     lambda m: ("#ifdef __vita__ // vita-pvis-call\n\tif (!VitaProcessParallel(portalSpans, portalPlane))\n#endif\n" + m.group(0)),
     'vita-pvis-call')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tvitaNodeVisible = node->RenderBound == -1 || Clipper.IsAABBVisible(engine->Level->Model->Bounds[node->RenderBound]);\n"),
     lambda m: ("#ifdef __vita__ // vita-pvis-box\n"
                "\t\tif (VitaReplay)\n\t\t\tvitaNodeVisible = VitaReplayBox(node);\n\t\telse\n"
                "#endif\n" + m.group(0)),
     'vita-pvis-box')
edit("Render/VisibleFrame.cpp",
     re.escape("\tfor (UActor* actor = node->ActorList; actor != nullptr; actor = actor->BspInfo.Next)\n"),
     lambda m: ("\tint vitaActorIndex = 0; // vita-pvis-actorloop: the actor's place in the node's list (the strips' answers go by it)\n"
                "\tfor (UActor* actor = node->ActorList; actor != nullptr; actor = actor->BspInfo.Next, vitaActorIndex++)\n"),
     'vita-pvis-actorloop')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\t\tvisactor.Process(this, actor);\n"),
     lambda m: ("#ifdef __vita__ // vita-pvis-actorcall\n"
                "\t\t\tVitaForcedVisible = VitaReplay ? VitaReplayActor(node, vitaActorIndex, actor) : -1;\n"
                "#endif\n" + m.group(0) +
                "#ifdef __vita__\n\t\t\tVitaForcedVisible = -1;\n#endif\n"),
     'vita-pvis-actorcall')
edit("Render/VisibleFrame.cpp",
     re.escape("\tBspVert* v = &model->Vertices[node->VertPool];\n\tif (MirrorFlag)\n"),
     lambda m: ("\tBspVert* v = &model->Vertices[node->VertPool];\n"
                "#ifdef __vita__ // vita-pvis-points: the walk with the strips' answers needs no points\n"
                "\tif (VitaReplay)\n\t{\n\t}\n\telse\n"
                "#endif\n"
                "\tif (MirrorFlag)\n"),
     'vita-pvis-points')
edit("Render/VisibleFrame.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-frame\n'),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pvis-macro\n"
                             "#define VITA_CHECKPORTAL(node, points, count) (VitaReplay ? VitaReplayPortal(node) : Clipper.CheckPortal(points, count))\n"
                             "#else\n"
                             "#define VITA_CHECKPORTAL(node, points, count) Clipper.CheckPortal(points, count)\n"
                             "#endif\n"),
     'vita-pvis-macro')
edit("Render/VisibleFrame.cpp",
     re.escape("Array<PortalSpan> spans = Clipper.CheckPortal(points, numverts);"),
     lambda m: "Array<PortalSpan> spans = VITA_CHECKPORTAL(node, points, numverts);",
     'VITA_CHECKPORTAL(node, points, numverts)')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tvitaSurfaceVisible = Clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0);\n"),
     lambda m: ("#ifdef __vita__ // vita-pvis-surface\n"
                "\t\tif (VitaReplay)\n\t\t\tvitaSurfaceVisible = VitaReplaySurface(node);\n\t\telse\n"
                "#endif\n" + m.group(0)),
     'vita-pvis-surface')
edit("Render/VisibleFrame.cpp",
     r"\Z",
     lambda m: "\n#include \"VitaParallelVis.inc\" // vita-pvis-inc\n",
     'vita-pvis-inc')
edit("Render/VisibleActor.cpp",
     re.escape("\tif (!frame->Clipper.IsAABBVisible(actor->BspInfo.BoundingBox))\n\t\treturn;\n"),
     lambda m: ("#ifdef __vita__ // vita-pvis-actorvis: the walk on three cores knows the answer already (vita/VitaParallelVis.inc)\n"
                "\tif (frame->VitaForcedVisible >= 0 ? frame->VitaForcedVisible == 0 : !frame->Clipper.IsAABBVisible(actor->BspInfo.BoundingBox))\n"
                "\t\treturn;\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-pvis-actorvis')

# 73. A light map request (LightSystem::GetLightmap, ~9.5 us, ~380 a frame in big halls) looked at every light of the surface
#     (CheckLight, their LastUpdate) and its dynamic lights every frame. render.cfg lightmap_skip: BeginFrame checks every light the
#     level's light maps name once (CheckLight) and keeps, by light map, the newest LastUpdate of its lights; a request whose light map
#     is up to date with that and that no dynamic light reaches (the same test as the slow path) is answered from the kept light map.
edit("Light/LightSystem.h",
     re.escape("\tstd::vector<std::pair<uint64_t, std::unique_ptr<LightmapTexture>*>> VitaLmDirect;\n"),
     lambda m: m.group(0) + ("\t// vita-lmskip-h: by light map index of VitaSkipModel, the newest LastUpdate of its lights; and the lights with their light maps\n"
                             "\tUModel* VitaSkipModel = nullptr;\n"
                             "\tstd::vector<int> VitaLmDirty;\n"
                             "\tstruct VitaSkipLight { UActor* Light; int Seen; std::vector<int> Maps; };\n"
                             "\tstd::vector<VitaSkipLight> VitaSkipLights;\n"
                             "\tvoid VitaUpdateLightmapDirty();\n"),
     'vita-lmskip-h')
edit("Light/LightSystem.cpp",
     re.escape("\tLightTree.CreateTLAS();\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-lmskip-frame\n"
                             "\tif (VitaLightmapSkip())\n\t\tVitaUpdateLightmapDirty();\n"
                             "#endif\n"),
     'vita-lmskip-frame')
edit("Light/LightSystem.cpp",
     re.escape("\tengine->Level->Light.VitaLmDirect.clear(); // vita-lmdirect-clear\n"),
     lambda m: m.group(0) + "\tengine->Level->Light.VitaSkipModel = nullptr; // vita-lmskip-clear\n",
     'vita-lmskip-clear')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tvitaDirect = VitaLmDirect[lightmapIndex].second;\n#endif\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-lmskip-fast\n"
                             "\t// lightmap_skip: none of its lights changed since the light map was made, and no dynamic light reaches it (what the code\n"
                             "\t// below finds as its dynamic lights: the list kept for it, or the dynamic lights near it): the light map as it is\n"
                             "\tif (VitaLightmapSkip() && VitaDynamicLightList() && vitaDirect && *vitaDirect && model == VitaSkipModel &&\n"
                             "\t\t(size_t)lightmapIndex < VitaLmDirty.size())\n"
                             "\t{\n"
                             "\t\tLightmapTexture* kept = vitaDirect->get();\n"
                             "\t\tif (VitaLmDirty[lightmapIndex] == kept->LastStaticUpdate && kept->LastDynamicUpdate == -100)\n"
                             "\t\t{\n"
                             "\t\t\tbool noDynamic;\n"
                             "\t\t\tif (kept->DynValid && kept->DynTree == LightTree.Version && FrameCounter - kept->DynFrame < 60)\n"
                             "\t\t\t\tnoDynamic = kept->DynLights.empty();\n"
                             "\t\t\telse\n"
                             "\t\t\t{\n"
                             "\t\t\t\tVitaCollectDynamic(worldLocation, radius);\n"
                             "\t\t\t\tnoDynamic = LightTree.CollectedLights.empty();\n"
                             "\t\t\t}\n"
                             "\t\t\tif (noDynamic)\n"
                             "\t\t\t{\n"
                             "\t\t\t\tVitaStats::lightmapFast++;\n"
                             "\t\t\t\tTextureInfo texinfo;\n"
                             "\t\t\t\ttexinfo.bRealtimeChanged = false;\n"
                             "\t\t\t\ttexinfo.CacheID = cacheID;\n"
                             "\t\t\t\ttexinfo.Format = kept->Format;\n"
                             "\t\t\t\ttexinfo.Mips = &kept->Mip;\n"
                             "\t\t\t\ttexinfo.NumMips = 1;\n"
                             "\t\t\t\ttexinfo.USize = kept->Mip.Width;\n"
                             "\t\t\t\ttexinfo.VSize = kept->Mip.Height;\n"
                             "\t\t\t\ttexinfo.Pan = { lmindex.PanX, lmindex.PanY };\n"
                             "\t\t\t\ttexinfo.UScale = lmindex.UScale;\n"
                             "\t\t\t\ttexinfo.VScale = lmindex.VScale;\n"
                             "\t\t\t\treturn texinfo;\n"
                             "\t\t\t}\n"
                             "\t\t}\n"
                             "\t}\n"
                             "#endif\n"),
     'vita-lmskip-fast')
edit("Light/LightSystem_Light.cpp",
     re.escape("void LightSystem::CheckLight(UActor* light)\n"),
     lambda m: ("#ifdef __vita__ // vita-lmskip-fn\n"
                "// Once a frame (BeginFrame): every light the level's light maps name is checked, and a light whose LastUpdate moved makes its\n"
                "// light maps' newest LastUpdate move. Built again when the level changes\n"
                "void LightSystem::VitaUpdateLightmapDirty()\n"
                "{\n"
                "\tconst double started = VitaTimers::Now();\n"
                "\tUModel* model = engine->Level->Model;\n"
                "\tif (model != VitaSkipModel || VitaLmDirty.size() != model->LightMap.size())\n"
                "\t{\n"
                "\t\tVitaSkipModel = model;\n"
                "\t\tVitaSkipLights.clear();\n"
                "\t\tVitaLmDirty.assign(model->LightMap.size(), -100);\n"
                "\t\tstd::unordered_map<UActor*, int> slots;\n"
                "\t\tfor (size_t i = 0; i < model->LightMap.size(); i++)\n"
                "\t\t{\n"
                "\t\t\tconst LightMapIndex& lmindex = model->LightMap[i];\n"
                "\t\t\tif (lmindex.LightActors < 0)\n\t\t\t\tcontinue;\n"
                "\t\t\tUActor** lightlist = &model->Lights[lmindex.LightActors];\n"
                "\t\t\tfor (int k = 0; lightlist[k] != nullptr; k++)\n"
                "\t\t\t{\n"
                "\t\t\t\tUActor* light = lightlist[k];\n"
                "\t\t\t\tauto found = slots.find(light);\n"
                "\t\t\t\tint slot;\n"
                "\t\t\t\tif (found == slots.end())\n"
                "\t\t\t\t{\n"
                "\t\t\t\t\tslot = (int)VitaSkipLights.size();\n"
                "\t\t\t\t\tslots[light] = slot;\n"
                "\t\t\t\t\tVitaSkipLights.push_back({ light, light->Light.LastUpdate, {} });\n"
                "\t\t\t\t}\n"
                "\t\t\t\telse\n\t\t\t\t\tslot = found->second;\n"
                "\t\t\t\tVitaSkipLights[slot].Maps.push_back((int)i);\n"
                "\t\t\t\tVitaLmDirty[i] = std::max(VitaLmDirty[i], light->Light.LastUpdate);\n"
                "\t\t\t}\n"
                "\t\t}\n"
                "\t}\n"
                "\tfor (VitaSkipLight& skip : VitaSkipLights)\n"
                "\t{\n"
                "\t\tCheckLight(skip.Light);\n"
                "\t\tconst int update = skip.Light->Light.LastUpdate;\n"
                "\t\tif (update != skip.Seen)\n"
                "\t\t{\n"
                "\t\t\tskip.Seen = update;\n"
                "\t\t\tfor (int i : skip.Maps)\n\t\t\t\tVitaLmDirty[i] = std::max(VitaLmDirty[i], update);\n"
                "\t\t}\n"
                "\t}\n"
                "\tVitaStats::lightmapDirtyMs += VitaTimers::Now() - started;\n"
                "}\n"
                "#endif\n\n" + m.group(0)),
     'vita-lmskip-fn')


# 74. BspClipper::IsAABBVisible cut the box's right edge down ((int)max2d.x) while a polygon's spans are rounded to the nearest pixel
#     (+0.5): a polygon inside a box could reach one column past the box, so a box called hidden could still hold a visible pixel.
#     The edge is rounded up: a box's columns always hold its polygons' (the walk on three strips relies on it, see VitaParallelVis.inc;
#     the one-clipper walk only checks a few more boxes)
edit("Render/BspClipper.cpp",
     re.escape("\tint x1 = clamp((int)max2d.x, 0, ViewportWidth);\n"),
     lambda m: ("#ifdef __vita__ // vita-boxedge\n"
                "\tint x1 = clamp((int)(max2d.x + 1.0f), 0, ViewportWidth);\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-boxedge')


# 75. (removed 2026-11-04: Flipendo's own fix of centred canvas text, KW::CenteredTextLineX, does the same since 47801a2)


# 76. Where starting the game and loading a level spend their time: "Boot: ..." lines (vita/VitaBoot.h) at the steps of GameApp::main,
#     the Engine's start, LoadMap and LoadFromSaveFile, and for every package opened and native font made that takes 20 ms or more.
edit("Utils/File.cpp",
     re.escape("// For the log: what was read from the card so far, and how fast.\nstd::string VitaFileStatsText()\n"),
     lambda m: ("// vita-bootcounters: what was read from the card so far (vita/VitaBoot.h)\n"
                "void VitaFileCounters(uint64_t& bytes, uint64_t& micros)\n{\n\tbytes = FileImpl::statBytes;\n\tmicros = FileImpl::statMicros;\n}\n\n" + m.group(0)),
     'vita-bootcounters')
edit("Engine.cpp",
     re.escape('#include "VitaTimers.h" // vita-timers:include\n'),
     lambda m: m.group(0) + '#include "VitaBoot.h" // vita-boot-inc\n',
     'vita-boot-inc')
edit("Engine.cpp",
     re.escape('\tLogMessage("Game: " + LaunchInfo.gameName + " (Version: " + LaunchInfo.gameVersionString + ")");\n'),
     lambda m: '\tVITA_BOOT_MARK("the engine object is made (packages Core and Engine, ini files)"); // vita-boot-run\n' + m.group(0),
     'vita-boot-run')
edit("Engine.cpp",
     re.escape("\tOpenWindow();\n\n\taudiodev->InitDevice();\n\trender = std::make_unique<RenderSubsystem>(window->GetRenderDevice());\n"),
     lambda m: ('\tVITA_BOOT_MARK("settings and key bindings"); // vita-boot-window\n'
                "\tOpenWindow();\n\tVITA_BOOT_MARK(\"window and renderer\");\n\n\taudiodev->InitDevice();\n\tVITA_BOOT_MARK(\"audio device\");\n"
                "\trender = std::make_unique<RenderSubsystem>(window->GetRenderDevice());\n"),
     'vita-boot-window')
edit("Engine.cpp",
     re.escape("\tLoginPlayer();\n\n\t// HP2's -LOADGAME=<n>"),
     lambda m: ('\tVITA_BOOT_MARK("the first map (startup) is loaded"); // vita-boot-login\n'
                "\tLoginPlayer();\n\tVITA_BOOT_MARK(\"the player is logged in\");\n\n\t// HP2's -LOADGAME=<n>"),
     'vita-boot-login')
edit("Engine.cpp",
     re.escape("\tLoadMap(GetDefaultURL(entryMapName));\n\tEntryLevelPackage = LevelPackage;\n"),
     lambda m: m.group(0) + '\tVITA_BOOT_MARK("the entry map is loaded"); // vita-boot-entry\n',
     'vita-boot-entry')
# LoadMap's steps
edit("Engine.cpp",
     re.escape('\tLogMessage("LoadMap: " + VitaFileStatsText()); // vita-iostart\n'),
     lambda m: m.group(0) + '\tVITA_BOOT_MARK("LoadMap " + url.Map + ": start"); // vita-boot-lm0\n',
     'vita-boot-lm0')
edit("Engine.cpp",
     re.escape("\taudiodev->StopSounds();\n\tUnloadMap();\n\n\t// Load map objects\n\n\tLevelPackage = packages->LoadMap(url.Map);\n\n\tGetLevelInfoObject();\n"),
     lambda m: ('\tVITA_BOOT_MARK("LoadMap: fade out, NotifyLevelChange"); // vita-boot-lm1\n'
                "\taudiodev->StopSounds();\n\tUnloadMap();\n\tVITA_BOOT_MARK(\"LoadMap: the old map unloaded\");\n\n\t// Load map objects\n\n"
                "\tLevelPackage = packages->LoadMap(url.Map);\n\tVITA_BOOT_MARK(\"LoadMap: the map package opened\");\n\n\tGetLevelInfoObject();\n"
                "\tVITA_BOOT_MARK(\"LoadMap: LevelInfo loaded\");\n"),
     'vita-boot-lm1')
edit("Engine.cpp",
     re.escape("\tLevelInfo->URL = url;\n\n\tGetLevelObject();\n\n\tLevel->TravelInfo = travelInfo;"),
     lambda m: ('\tVITA_BOOT_MARK("LoadMap: the loading screen drawn"); // vita-boot-lm2\n'
                "\tLevelInfo->URL = url;\n\n\tGetLevelObject();\n\tVITA_BOOT_MARK(\"LoadMap: the level and its actors loaded\");\n\n\tLevel->TravelInfo = travelInfo;"),
     'vita-boot-lm2')
edit("Engine.cpp",
     re.escape("\tLinkActorsToLevel();\n\n\tif (LaunchInfo.IsHarryPotter2() && !StrTools::equals_ignore_case(fs::path(url.Map).stem().string(), \"Entry\"))"),
     lambda m: ("\tLinkActorsToLevel();\n\tVITA_BOOT_MARK(\"LoadMap: actors linked to the level (collision, zones, lights)\"); // vita-boot-lm3\n\n"
                "\tif (LaunchInfo.IsHarryPotter2() && !StrTools::equals_ignore_case(fs::path(url.Map).stem().string(), \"Entry\"))"),
     'vita-boot-lm3')
edit("Engine.cpp",
     re.escape("\t\t\tException::Throw(\"InitGame failed: \" + error);\n"),
     lambda m: m.group(0) + "\t\tVITA_BOOT_MARK(\"LoadMap: InitGame\"); // vita-boot-lm4\n",
     'vita-boot-lm4')
def boot_after_event(event, mark, marker):
    edit("Engine.cpp",
         r"(\t\tfor \(size_t i = 0; i < \w+(?:\(\))?; i\+\+\) \{ if \(Level->Actors\[i\]\) CallEvent\(Level->Actors\[i\], EventName::" + event + r"\); \}\n)",
         lambda m: m.group(1) + "\t\tVITA_BOOT_MARK(\"" + mark + "\"); // " + marker + "\n",
         marker)
boot_after_event("PreBeginPlay", "LoadMap: PreBeginPlay", "vita-bootmark-prebegin")
boot_after_event("BeginPlay", "LoadMap: BeginPlay", "vita-bootmark-begin")
boot_after_event("PostBeginPlay", "LoadMap: PostBeginPlay", "vita-bootmark-postbegin")
boot_after_event("SetInitialState", "LoadMap: SetInitialState", "vita-bootmark-initstate")
edit("Engine.cpp",
     re.escape('\tVitaFileReleaseCaches();\n\tLogMessage("LoadMap done: " + VitaFileStatsText());\n'),
     lambda m: '\tVITA_BOOT_MARK("LoadMap: InitBase, DetailChange (done)"); // vita-boot-lm6\n' + m.group(0),
     'vita-boot-lm6')
# LoadFromSaveFile's steps
edit("Engine.cpp",
     re.escape("\tif (!savefilePackage)\n\t\treturn;\n\n\tif (LaunchInfo.IsKnowWonder()) // HP1 loads a save as a map"),
     lambda m: ('\tVITA_BOOT_MARK("LoadFromSaveFile: the save package opened"); // vita-boot-sv0\n'
                "\tif (!savefilePackage)\n\t\treturn;\n\n\tif (LaunchInfo.IsKnowWonder()) // HP1 loads a save as a map"),
     'vita-boot-sv0')
edit("Engine.cpp",
     re.escape("\tLevelPackage = savefilePackage;\n\n\tGetLevelInfoObject();\n\tif (LaunchInfo.IsKnowWonder())\n\t\tKW::LoadMapLevelInfo(LevelInfo);\n"),
     lambda m: ('\tVITA_BOOT_MARK("LoadFromSaveFile: fade out, old map unloaded"); // vita-boot-sv1\n' + m.group(0) +
                '\tVITA_BOOT_MARK("LoadFromSaveFile: LevelInfo loaded, loading screen drawn");\n'),
     'vita-boot-sv1')
edit("Engine.cpp",
     re.escape("\tLevelInfo->URL = UnrealURL(realMapName);\n\n\tGetLevelObject();\n\n\tLinkActorsToLevel();\n"),
     lambda m: ("\tLevelInfo->URL = UnrealURL(realMapName);\n\n\tGetLevelObject();\n"
                '\tVITA_BOOT_MARK("LoadFromSaveFile: the level and its actors loaded"); // vita-boot-sv2\n'
                "\n\tLinkActorsToLevel();\n\tVITA_BOOT_MARK(\"LoadFromSaveFile: actors linked to the level\");\n"),
     'vita-boot-sv2')
# packages and fonts that take long
edit("Package/PackageManager.cpp",
     re.escape('#include "Utils/Logger.h" // missing data messages\n'),
     lambda m: m.group(0) + '#include "VitaBoot.h" // vita-boot-pkginc\n',
     'vita-boot-pkginc')
edit("Package/PackageManager.cpp",
     re.escape("\tif (it != packageFilenames.end())\n\t{\n\t\tpackage.set(GC::Alloc<Package>(this, name, it->second));\n\t}\n"),
     lambda m: ("\tif (it != packageFilenames.end())\n\t{\n"
                "\t\tVITA_BOOT_SCOPE(vitaBootPackage, \"package \" + name.ToString() + \" opened\"); // vita-boot-pkg\n"
                "\t\tpackage.set(GC::Alloc<Package>(this, name, it->second));\n\t}\n"),
     'vita-boot-pkg')
edit("../../knowwonder/KWNativeFont.cpp",
     re.escape("\t\tauto it = fonts.find(key);\n\t\tif (it != fonts.end())\n\t\t\treturn it->second;\n\n\t\tNativeFontFile file;\n"),
     lambda m: ("\t\tauto it = fonts.find(key);\n\t\tif (it != fonts.end())\n\t\t\treturn it->second;\n"
                "\t\tVITA_BOOT_SCOPE(vitaBootFont, \"native font \" + name + \" \" + std::to_string(height) + \" made\"); // vita-boot-font\n\n"
                "\t\tNativeFontFile file;\n"),
     'vita-boot-font')
edit("../../knowwonder/KWNativeFont.cpp",
     re.escape('#include "KW.h"\n'),
     lambda m: m.group(0) + '#include "VitaBoot.h" // vita-boot-fontinc\n',
     'vita-boot-fontinc')
edit("GameApp.cpp",
     re.escape("\t\t\tEngine engine(info);\n\t\t\tengine.Run();\n"),
     lambda m: ('\t\t\tVITA_BOOT_MARK("the game folder is recognised"); // vita-boot-app\n'
                "\t\t\tEngine engine(info);\n\t\t\tengine.Run();\n"),
     'vita-boot-app')
edit("GameApp.cpp",
     re.escape('#include "Utils/File.h"\n#include <stdexcept>\n'),
     lambda m: '#include "Utils/File.h"\n#include "VitaBoot.h" // vita-boot-appinc\n#include <stdexcept>\n',
     'vita-boot-appinc')


# 77. A sound's float samples stayed on the heap after OpenAL had its own 16 bit copy (13 MB in HP2's first level). Nothing else reads
#     them on the Vita (the lip sync from samples is Deus Ex's; HP2's has its own data): freed once the sound is buffered, and GetSound
#     does not decode it again. And "Failed to buffer sound data" (HP2's Adv1Willow, the heap full) now says OpenAL's error and the heap.
edit("Packages/Engine/Resources/USound.h",
     re.escape("\tbool vitaFailed = false;\n"),
     lambda m: m.group(0) + "\tbool vitaBuffered = false; // vita-sndbuffered: in OpenAL, the samples freed\n\tvoid VitaFreeSamples();\n",
     'vita-sndbuffered')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("void USound::CheckSoundSamples()\n{\n\tif (samples.size() > 0)\n\t\treturn;\n"),
     lambda m: ("void USound::CheckSoundSamples()\n{\n\tif (samples.size() > 0)\n\t\treturn;\n"
                "#ifdef __vita__ // vita-sndbuffered-guard\n\tif (vitaBuffered)\n\t\treturn;\n#endif\n"),
     'vita-sndbuffered-guard')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\t\tengine->audiodev->GetDevice()->AddSound(this);\n\t\tData.clear();\n\t\tData.shrink_to_fit();\n\t\treturn;\n"),
     lambda m: ("\t\tengine->audiodev->GetDevice()->AddSound(this);\n\t\tData.clear();\n\t\tData.shrink_to_fit();\n"
                "\t\tVitaFreeSamples(); // vita-sndfree-async\n\t\treturn;\n"),
     'vita-sndfree-async')
edit("Packages/Engine/Resources/USound.cpp",
     re.escape("\t// decoded and buffered: the original bytes are not needed any more\n\tData.clear();\n\tData.shrink_to_fit();\n#endif\n}\n"),
     lambda m: ("\t// decoded and buffered: the original bytes are not needed any more\n\tData.clear();\n\tData.shrink_to_fit();\n"
                "\tVitaFreeSamples(); // vita-sndfree-sync\n#endif\n}\n\n"
                "#ifdef __vita__\n"
                "// OpenAL has the sound (AddSound made its 16 bit buffer): the float samples go (duration, channels and the loop stay)\n"
                "void USound::VitaFreeSamples()\n{\n"
                "\tif (!handle)\n\t\treturn;\n"
                "\tVitaStats::soundSamples -= std::min(VitaStats::soundSamples, (size_t)samples.size());\n"
                "\tArray<float>().swap(samples);\n"
                "\tvitaBuffered = true;\n}\n#endif\n"),
     'vita-sndfree-sync')
edit(AUDIO,
     re.escape('\t\tException::Throw("Failed to buffer sound data for " + sound->Name.ToString());\n'),
     lambda m: ("#ifdef __vita__ // vita-alerror\n"
                "\t\t{\n\t\t\tstruct mallinfo info = mallinfo();\n"
                "\t\t\tException::Throw(\"Failed to buffer sound data for \" + sound->Name.ToString() + \" (OpenAL error \" + std::to_string((int)alError) +\n"
                "\t\t\t\t(alError == AL_OUT_OF_MEMORY ? \", out of memory\" : \"\") + \"; heap \" + std::to_string((size_t)info.uordblks / (1024 * 1024)) + \" MB in use)\");\n"
                "\t\t}\n#else\n" + m.group(0) + "#endif\n"),
     'vita-alerror')

edit("Packages/Engine/Resources/USound.cpp",
     re.escape('#include "VitaTimers.h" // vita-sndinc\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-sndstatsinc\n',
     'vita-sndstatsinc')
edit(AUDIO,
     re.escape('#include "VitaStats.h" // vita-audiostats\n'),
     lambda m: m.group(0) + '#include <malloc.h> // vita-audiomalloc\n',
     'vita-audiomalloc')


# 78. The Vita's screen is 960x544 whatever the game's ini asks for. The engine sized its window from [WinDrv.WindowsClient]
#     FullscreenViewportX/Y and SDL's vitaGL driver then reported that size as the drawable: HP2's ini (bigger than the screen) had the
#     picture drawn at that size and only a corner of it on the screen. The window is always the screen's size.
edit(SDL2WIN,
     re.escape("\tSDL_SetWindowSize(Handle.window, w, h);\n\tSDL_SetWindowPosition(Handle.window, x, y);\n"),
     lambda m: ("#ifdef __vita__ // vita-screensize\n\tw = 960;\n\th = 544;\n\tx = y = 0;\n#endif\n" + m.group(0)),
     'vita-screensize')
edit(SDL2WIN,
     re.escape("int SDL2DisplayWindow::GetPixelWidth() const\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-screenwidth\n\treturn 960;\n#endif\n",
     'vita-screenwidth')
edit(SDL2WIN,
     re.escape("int SDL2DisplayWindow::GetPixelHeight() const\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-screenheight\n\treturn 544;\n#endif\n",
     'vita-screenheight')


# 79. SDL2DisplayWindow::GetKeyState read SDL's keyboard state only: the pad's mouse buttons (cross/R, circle/L) and the left stick's
#     arrow keys (vita_input.cpp) were never held. HP2's harry.PlayerInput lets Harry walk while casting only when GetCurrentKeyState
#     says a mouse button is down (docs/re/hp2/gameplay.md "Moving and looking while casting"); without it every cast counted as a
#     keyboard cast and the stick's forward/back aimed the spell instead of moving Harry.
edit(SDL2WIN,
     re.escape("bool SDL2DisplayWindow::GetKeyState(InputKey key)\n{\n"),
     lambda m: ("#ifdef __vita__ // vita-keystate-decl\nbool VitaKeyHeld(InputKey key);\n#endif\n\n" + m.group(0) +
                "#ifdef __vita__ // vita-keystate\n\tif (VitaKeyHeld(key))\n\t\treturn true;\n#endif\n"),
     'vita-keystate')


# 80. The cast animation did not play with AdamJD's MagiPacks packages (HarryPotter.u / HPBase.u of the "Widescreen Mod (Improved
#     Movement)"). Flipendo's improved-movement mod (on by default since Flipendo 2fbf840) is written for the retail scripts, where a
#     held spell is the state playeraiming. AdamJD's Harry has no playeraiming (commented out): he casts in PlayerWalking and plays
#     'wave' on HarryAnimChannel (cHarryAnimChannel.stateCasting, AT_Combine). Every tick the mod saw "not aiming" and PutWandBack
#     cleared that channel's 'wave'. Those packages already do what the mod does: the mod stays off when Harry has no playeraiming.
IMPROVED = "../../hp1/mods/ImprovedMovement.cpp"
edit(IMPROVED,
     re.escape("\t\tbool Active()\n\t\t{\n\t\t\treturn IsOn(\"improved-movement\");\n\t\t}\n"),
     lambda m: ("\t\t// Harry's scripts have no playeraiming state (AdamJD's packages cast in PlayerWalking): the mod stays off\n"
                "\t\tbool OwnCasting = false; // vita-improved-own\n\n"
                "\t\tbool Active()\n\t\t{\n\t\t\treturn IsOn(\"improved-movement\") && !OwnCasting;\n\t\t}\n"),
     'vita-improved-own')
edit(IMPROVED,
     re.escape("\t\tif (cls && cls != HarryClass)\n\t\t{\n\t\t\tHarryClass = cls;\n"),
     lambda m: ("\t\tif (cls && cls != HarryClass && !cls->GetState(NameString(\"playeraiming\"))) // vita-improved-check\n"
                "\t\t{\n"
                "\t\t\tHarryClass = cls;\n"
                "\t\t\tOwnCasting = true;\n"
                "\t\t\tLogMessage(\"Improved movement: off, Harry's scripts have no playeraiming state (packages with their own casting)\");\n"
                "\t\t\treturn;\n"
                "\t\t}\n" + m.group(0)),
     'vita-improved-check')
edit(IMPROVED,
     re.escape('#include "Engine.h"\n'),
     lambda m: m.group(0) + '#include "Utils/Logger.h" // vita-improved-log\n',
     'vita-improved-log')


# 81. Spell lessons with the touch screen and stick "rails" (vita/VitaSpellLesson.cpp; render.cfg spell_touch, spell_assist,
#     spell_speed, spell_time): HP1::TickMods lets it wrap SpellLearnTrigger's Draw.Tick once the class is loaded.
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape("\t\tMods::TickImprovedMovement();\n"),
     lambda m: "#ifdef __vita__ // vita-spelllesson\n\t\tVitaTickSpellLesson();\n#endif\n" + m.group(0),
     'vita-spelllesson')
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape("namespace HP1\n{\n\tvoid TickMods(float realElapsed)\n"),
     lambda m: "#ifdef __vita__ // vita-spelllesson-decl\nvoid VitaTickSpellLesson(); // vita/VitaSpellLesson.cpp\n#endif\n\n" + m.group(0),
     'vita-spelllesson-decl')


# 82. The three-core walk (parallel_vis) cost each strip as much as the whole walk (log of 05 Nov 00:11: 8.3 ms a strip): a strip's
#     clipper has two thirds of the screen filled, yet a node box lying in those columns made IsAABBVisible look at every line of
#     its height before answering hidden, and a polygon there drew its spans line by line into filled columns. The strip's open
#     columns (VitaKeepX0..X1, set by VitaKeepColumns) cut both short: a box or polygon outside them is hidden at once, spans are cut
#     to them. The answers are the same (those columns are filled); a full clipper keeps 0..0x7fff.
edit("Render/BspClipper.h",
     re.escape("\tint VitaWidth() const { return ViewportWidth; }\n"),
     lambda m: m.group(0) + ("\tint VitaKeepX0 = 0, VitaKeepX1 = 0x7fff; // vita-keepcols-h: the open columns (a strip's clipper)\n"
                             "\tbool VitaStrip = false;               // a strip: the two world planes through the eye along its columns' edges\n"
                             "\tvec4 VitaStripLeft, VitaStripRight;   // (a point is in the strip's wedge when dot(plane, (p, 1)) >= 0 for both)\n"
                             "\tbool VitaOutsideStrip(const BBox& box) const;\n"),
     'vita-keepcols-h')
edit("Render/BspClipper.cpp",
     re.escape("\tWorldToProjection = world_to_projection;\n\tFrustumClip = FrustumPlanes(world_to_projection);\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-keepcols-reset\n\tVitaKeepX0 = 0;\n\tVitaKeepX1 = 0x7fff;\n\tVitaStrip = false;\n#endif\n",
     'vita-keepcols-reset')
edit("Render/BspClipper.cpp",
     re.escape("\tint x1 = clamp((int)(max2d.x + 1.0f), 0, ViewportWidth);\n#else\n\tint x1 = clamp((int)max2d.x, 0, ViewportWidth);\n#endif\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-keepcols-box\n\tx0 = std::max(x0, VitaKeepX0);\n\tx1 = std::min(x1, VitaKeepX1);\n#endif\n",
     'vita-keepcols-box')

edit("Render/BspClipper.cpp",
     re.escape("bool BspClipper::IsAABBVisible(const BBox& bbox)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-strip-box: wholly outside a strip's wedge, without projecting its corners\n\tif (VitaStrip && VitaOutsideStrip(bbox))\n\t\treturn false;\n#endif\n",
     'vita-strip-box')


# 83. parallel_vis=2 (auto, the default): the walk is timed both ways where the player is (VitaVisWalkDone, VitaParallelVis.inc)
#     and the faster is kept for a while, then measured again. The three-core walk pays only where the strips split the work well.
edit("Render/VisibleFrame.cpp",
     re.escape("\tif (!VitaProcessParallel(portalSpans, portalPlane))\n#endif\n"),
     lambda m: ("\tvoid VitaVisWalkDone(bool parallel); // vita-pvis-auto: the time of the walk, for parallel_vis=2\n"
                "\tconst bool vitaParallel = VitaProcessParallel(portalSpans, portalPlane);\n\tif (!vitaParallel)\n#endif\n"),
     'vita-pvis-auto')
edit("Render/VisibleFrame.cpp",
     re.escape("\tVitaProbes::clipSpans += Clipper.numDrawSpans;\n"),
     lambda m: m.group(0) + "\tVitaVisWalkDone(vitaParallel); // vita-pvis-done\n",
     'vita-pvis-done')


# 84. Actor shadows: ActorShadow.Update only when the owner moved or turned, or every shadow_skip + 1 frames (vita/VitaShadows.cpp)
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('\t\t\tCallEvent(shadow, NameString("Update"), { ExpressionValue::ObjectValue(nullptr) });\n'),
     lambda m: ("#ifdef __vita__ // vita-shadowskip\n\t\t\tif (VitaShadowSkip(actor, shadow))\n\t\t\t\tcontinue;\n#endif\n" + m.group(0)),
     'vita-shadowskip')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape("namespace KW\n{\n\t// Actor shadows"),
     lambda m: "#ifdef __vita__ // vita-shadowskip-decl\nbool VitaShadowSkip(UActor* actor, UActor* shadow); // vita/VitaShadows.cpp\n#endif\n\n" + m.group(0),
     'vita-shadowskip-decl')

# 85. Mesh faces (Lev_Tut1: ~270-390 us a mesh in the face loop). (a) The back-face test was made twice per face: vita-earlycull
#     makes it from the same LOD wedges and vertices, and a face it could not test is invalid below anyway. (b) A vertex's fog
#     (GetVertexFog: every fog ball of the zone, a sphere density each) was worked out for every face it is in (~6): once per
#     vertex per draw now, when the zone has fog balls.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\tif (!(renderflags & PF_TwoSided))\n\t\t\t{\n\t\t\t\tvec3 faceNormal = cross(vertices[1].Point - vertices[0].Point, vertices[2].Point - vertices[0].Point);\n"
               "\t\t\t\tif (dot(faceNormal, eye - vertices[0].Point) <= 0.0f)\n\t\t\t\t\tcontinue;\n\t\t\t}\n"),
     lambda m: "#ifndef __vita__ // vita-cull-once: vita-earlycull made this test\n" + m.group(0) + "#endif\n",
     'vita-cull-once')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\tvertices[i].Fog = vertexLight.GetVertexFog(vertices[i].Point);\n"),
     lambda m: ("#ifdef __vita__ // vita-fogcache\n"
                "\t\t\t\tif (vitaFogBalls)\n\t\t\t\t{\n"
                "\t\t\t\t\tif (vitaFogDone[faceVerts[i]] != vitaFogStamp)\n\t\t\t\t\t{\n"
                "\t\t\t\t\t\tvitaFog[faceVerts[i]] = vertexLight.GetVertexFog(vertices[i].Point);\n"
                "\t\t\t\t\t\tvitaFogDone[faceVerts[i]] = vitaFogStamp;\n\t\t\t\t\t}\n"
                "\t\t\t\t\tvertices[i].Fog = vitaFog[faceVerts[i]];\n\t\t\t\t}\n"
                "\t\t\t\telse\n\t\t\t\t\tvertices[i].Fog = vec4(0.0f);\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-fogcache')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tstatic std::vector<MaterialCache> materialCache;\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-fogcache-decl: a vertex's fog once per draw (stamped, no clearing)\n"
                "\t\tstatic std::vector<vec4> vitaFog;\n\t\tstatic std::vector<uint32_t> vitaFogDone;\n\t\tstatic uint32_t vitaFogStamp = 0;\n"
                "\t\tconst bool vitaFogBalls = vertexLight.NumFogBalls > 0;\n"
                "\t\tif (vitaFogBalls)\n\t\t{\n"
                "\t\t\tif (vitaFog.size() < verts.size())\n\t\t\t{\n\t\t\t\tvitaFog.resize(verts.size());\n\t\t\t\tvitaFogDone.resize(verts.size(), 0);\n\t\t\t}\n"
                "\t\t\tif (++vitaFogStamp == 0)\n\t\t\t{\n\t\t\t\tstd::fill(vitaFogDone.begin(), vitaFogDone.end(), 0u);\n\t\t\t\tvitaFogStamp = 1;\n\t\t\t}\n"
                "\t\t}\n#endif\n"),
     'vita-fogcache-decl')


# 86. The on-screen counter (vita/VitaOverlay.cpp, render.cfg overlay=0/1/2, two fingers on the rear touch pad = next mode), and
#     timers for what 'draw nodes' did not explain (log of 06 Nov: Lev2_Inc_A/B ~30-40 ms of draw nodes outside meshes, particles,
#     light maps and the BSP surface laps, where water was in view): the four steps of the main view's VisibleFrame::Draw and the
#     procedural textures (UTexture::Update, by texture in the log). The water's picture: normalize(-gx, 0.2, -gy).y worked out as
#     0.2 / sqrt(gx*gx + 0.04 + gy*gy) (the same number, one square root and no vector). Cutscene skip: 1/20 s steps on the Vita.
edit("Render/RenderCanvas.cpp",
     re.escape("\tDrawTimedemoStats();\n\t\n\tif (ShowCollisionDebug)"),
     lambda m: ("\tDrawTimedemoStats();\n#ifdef __vita__ // vita-overlay-call\n\tvoid VitaDrawOverlay(); // vita/VitaOverlay.cpp\n\tVitaDrawOverlay();\n#endif\n"
                "\t\n\tif (ShowCollisionDebug)"),
     'vita-overlay-call')
edit("Render/VisibleFrame.cpp",
     re.escape('#include "VitaProbes.h" // vita-probeinc-frame\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-drawsteps-inc\n',
     'vita-drawsteps-inc')
edit("Render/VisibleFrame.cpp",
     re.escape("void VisibleFrame::Draw()\n{\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-drawsteps: the main view's steps timed (a sky/mirror frame is inside DrawPortals)\n"
                "\tif (PortalDepth == 0)\n\t{\n"
                "\t\t{ VITA_TIMER(DrawPortals); DrawPortals(); }\n"
                "\t\t{ VITA_TIMER(DrawOpaque); DrawOpaqueNodes(); }\n"
                "\t\t{ VITA_TIMER(DrawActors); DrawOpaqueActors(); }\n"
                "\t\t{ VITA_TIMER(DrawTranslucent); SortTranslucent(); DrawTranslucent(); }\n"
                "\t\treturn;\n\t}\n#endif\n"),
     'vita-drawsteps:')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape('#include "VitaConfig.h" // vita-texinc\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-textime-inc\n#include "Packages/Core/UClass.h"\n',
     'vita-textime-inc')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape("\tfloat animationSpeed = 1.0f / maxFrameRate;\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-textime: the time of the new pictures, by texture\n"
                "\tconst double vitaTexStart = VitaTimers::Now();\n\tunsigned vitaTexUpdates = 0;\n"
                "\tstruct VitaTexDone\n\t{\n\t\tUTexture* tex; double start; unsigned& updates;\n"
                "\t\t~VitaTexDone()\n\t\t{\n\t\t\tif (!updates)\n\t\t\t\treturn;\n"
                "\t\t\tconst double t = VitaTimers::Now() - start;\n"
                "\t\t\tVitaTimers::ms[VitaTimers::TexUpdate] += t;\n\t\t\tVitaTimers::total[VitaTimers::TexUpdate] += t;\n"
                "\t\t\tVitaTimers::TexTime& e = VitaTimers::texTimes[tex];\n"
                "\t\t\tif (e.name.empty())\n\t\t\t\te.name = tex->Name.ToString() + \" (\" + tex->Class->Name.ToString() + \")\";\n"
                "\t\t\te.ms += t;\n\t\t\te.updates += updates;\n\t\t}\n"
                "\t} vitaTexDone{ this, vitaTexStart, vitaTexUpdates };\n#endif\n"),
     'vita-textime:')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape("\tfor (int iteration = 0; Accumulator() > animationSpeed; iteration++)\n\t{\n\t\tUpdateFrame();\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-textime-count\n\t\tvitaTexUpdates++;\n#endif\n",
     'vita-textime-count')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\t\t\t\tvec3 normal = normalize(vec3(-waterline[x].XGradient, 0.2f, -waterline[x].YGradient));\n"
               "\t\t\t\tdestline[x] = (uint8_t)clamp(std::abs(normal.y) * 255.0f + 128.0f, 0.0f, 255.0f);\n"),
     lambda m: ("#ifdef __vita__ // vita-waternormal: normalize(...).y without the vector (same value)\n"
                "\t\t\t\tconst float gx = waterline[x].XGradient, gy = waterline[x].YGradient;\n"
                "\t\t\t\tconst float ny = 0.2f / std::sqrt(gx * gx + 0.04f + gy * gy);\n"
                "\t\t\t\tdestline[x] = (uint8_t)clamp(ny * 255.0f + 128.0f, 0.0f, 255.0f);\n#else\n" + m.group(0) + "#endif\n"),
     'vita-waternormal')
edit("../../hp1/mods/CutsceneSkip.cpp",
     re.escape("\tstatic constexpr float SimulationStep = 1.0f / 60.0f;\n"),
     lambda m: ("#ifdef __vita__ // vita-skipstep: a 1/60 s step costs a whole level tick (~13 ms): 48 a frame made the skip ~1.1x real time\n"
                "\tstatic constexpr float SimulationStep = 1.0f / 20.0f;   // (normal play on the Vita ticks 1/15-1/20 s anyway)\n#else\n"
                + m.group(0) + "#endif\n"),
     'vita-skipstep')


# 87. Log of 06 Nov 06:51 (Lev2_Fire1, ~10 fps): 'node: fogmap' 26 ms a frame (235 us x 110 surfaces: the zone is a fog zone, every
#     surface's fog map built again and uploaded every frame: 70-140 uploads a frame) and 'node: texture' 24 ms (WetWater, a
#     WetTexture: 19-32 ms per new picture). (a) fog maps built again every fog_rate frames (default 3, staggered by lightmap),
#     uploaded only then; (b) the water step and the wet refraction four pixels at a time with NEON (vita/VitaWater.h, same
#     arithmetic in the same order; 'VitaWater: water check' log lines compare it with the scalar loop now and then); (c) water
#     textures at most water_fps (10) new pictures a second.
edit("Light/LightSystem_Fog.cpp",
     re.escape('#include "FogmapBuilder.h"\n'),
     lambda m: m.group(0) + '#include "VitaConfig.h" // vita-fograte-inc\n',
     'vita-fograte-inc')
edit("Light/LightSystem_Fog.cpp",
     re.escape("\tstd::unique_ptr<LightmapTexture>& fogtexture = fogtex.second;\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-fogrnew\n\tconst bool vitaFogNew = !fogtexture;\n#endif\n",
     'vita-fogrnew')
edit("Light/LightSystem_Fog.cpp",
     re.escape("\tbool firstDrawThisScene = false;\n\tif (fogtex.first != FrameCounter)\n\t{\n\t\tfirstDrawThisScene = true;\n\t\tfogtex.first = FrameCounter;\n\t}\n"),
     lambda m: ("\tbool firstDrawThisScene = false;\n#ifdef __vita__ // vita-fograte: built again every fog_rate frames (staggered)\n"
                "\tstatic const int vitaFogRate = VitaFogRate();\n"
                "\tif (vitaFogNew)\n\t{\n\t\tfirstDrawThisScene = true;\n\t\tfogtex.first = FrameCounter - (lightmapIndex % vitaFogRate);\n\t}\n"
                "\telse if (FrameCounter - fogtex.first >= vitaFogRate || FrameCounter < fogtex.first)\n\t{\n\t\tfirstDrawThisScene = true;\n\t\tfogtex.first = FrameCounter;\n\t}\n"
                "#else\n" + m.group(0)[len("\tbool firstDrawThisScene = false;\n"):] + "#endif\n"),
     'vita-fograte:')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape('#include "UWaterTexture.h"\n'),
     lambda m: m.group(0) + '#include "VitaWater.h" // vita-water-inc\n#include "Utils/Logger.h"\n#include <vector>\n',
     'vita-water-inc')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\tint cur = CurrentWaterDepth;\n\tint next = (cur + 1) % 2;\n\tCurrentWaterDepth = next;\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-water-neon\n\t{\n"
                "\t\tstatic_assert(sizeof(WaterPixel) == sizeof(VitaWater::Pixel), \"WaterPixel\");\n"
                "\t\tconst VitaWater::Pixel* src = (const VitaWater::Pixel*)WaterDepth[cur].data();\n"
                "\t\tVitaWater::Pixel* dst = (VitaWater::Pixel*)WaterDepth[next].data();\n"
                "\t\tstatic unsigned vitaSteps = 0, vitaChecks = 0;\n"
                "\t\tif ((++vitaSteps & 127) == 100 && vitaChecks < 5)\n\t\t{\n"
                "\t\t\tvitaChecks++;\n"
                "\t\t\tstd::vector<VitaWater::Pixel> ref((size_t)width * height);\n"
                "\t\t\tVitaWater::StepAllScalar(src, ref.data(), width, height);\n"
                "\t\t\tVitaWater::Step(src, dst, width, height);\n"
                "\t\t\tfloat maxDiff = 0.0f, maxValue = 0.0f;\n"
                "\t\t\tfor (size_t i = 0; i < ref.size(); i++)\n\t\t\t{\n"
                "\t\t\t\tmaxDiff = std::max({ maxDiff, std::abs(ref[i].Pressure - dst[i].Pressure), std::abs(ref[i].Velocity - dst[i].Velocity),\n"
                "\t\t\t\t\tstd::abs(ref[i].XGradient - dst[i].XGradient), std::abs(ref[i].YGradient - dst[i].YGradient) });\n"
                "\t\t\t\tmaxValue = std::max(maxValue, std::abs(ref[i].Pressure));\n\t\t\t}\n"
                "\t\t\tLogMessage(\"VitaWater: water check \" + Name.ToString() + \" \" + std::to_string(width) + \"x\" + std::to_string(height) +\n"
                "\t\t\t\t\": largest difference \" + std::to_string(maxDiff) + \" (largest pressure \" + std::to_string(maxValue) + \")\");\n\t\t}\n"
                "\t\telse\n\t\t\tVitaWater::Step(src, dst, width, height);\n"
                "\t\treturn;\n\t}\n#endif\n"),
     'vita-water-neon')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape('#include "UWetTexture.h"\n'),
     lambda m: m.group(0) + '#include "VitaWater.h" // vita-wet-inc\n',
     'vita-wet-inc')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape("\t\t\tfor (int y = 0; y < height; y++)\n\t\t\t{\n\t\t\t\tconst WaterPixel* waterline"),
     lambda m: ("#ifdef __vita__ // vita-wet-neon\n"
                "\t\t\tVitaWater::Refract((const VitaWater::Pixel*)WaterDepth[CurrentWaterDepth].data(), srcpixels, pixels, width, height);\n"
                "\t\t\tif (false)\n#endif\n" + m.group(0)),
     'vita-wet-neon')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape("\tmaxFrameRate = std::min(maxFrameRate, VitaTextureFps());\n"),
     lambda m: m.group(0) + "\tif (dynamic_cast<UWaterTexture*>(this)) // vita-waterfps\n\t\tmaxFrameRate = std::min(maxFrameRate, VitaWaterFps());\n",
     'vita-waterfps')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape('#include "VitaConfig.h" // vita-texinc\n'),
     lambda m: m.group(0) + '#include "UWaterTexture.h" // vita-waterfps-inc\n',
     'vita-waterfps-inc')


# 88. Log of 06 Nov 07:19 (Lev2_Fire1 again, 11-23 fps): the NEON water of #87 was exact (water check 0.000000) but still ~22 ms a
#     WetWater picture (memory bound: 16 byte pixels). (a) The water as planar floats (vita/VitaWater.h State: two pressure arrays
#     and one velocity array, gradients from the old pressure when the picture is made): UpdateWater, UWetTexture's refraction and
#     UWaterTexture's picture go through it ('VitaWater: planar check' compares with the engine's loop now and then). (b) Fog maps
#     ('node: fogmap' still 12 ms): built again only when the camera (or a mover's surface) moved since the last build; the fog of a
#     map depends on nothing else (the fog lights' FogInfo is taken once). (c) A fog light whose sphere cannot meet any ray from the
#     eye to the surface (distance from its centre to the segment eye -> the texels' bounding sphere centre > both radii) adds
#     nothing (SphereDensity is 0 for every texel): skipped.
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("void UWaterTexture::UpdateWater()\n{\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-water-planar\n\t{\n"
                "\t\tUnrealMipmap& vitaMip = UsedMipmaps.front();\n"
                "\t\tconst int width = vitaMip.Width, height = vitaMip.Height;\n"
                "\t\tVitaWater::State& st = VitaWater::StateFor(this, width, height);\n"
                "\t\tfloat* P = st.P[st.cur].data();\n"
                "\t\tconst size_t n = (size_t)width * height;\n"
                "\t\tauto drops = Drops();\n"
                "\t\tfor (int i = 0, count = NumDrops(); i < count; i++)\n\t\t{\n"
                "\t\t\tADrop& drop = drops[i];\n"
                "\t\t\tconst size_t at = (size_t)drop.X * 2 + (size_t)drop.Y * 2 * width;\n"
                "\t\t\tif (drop.Type == ADropType::FixedDepth)\n\t\t\t{\n"
                "\t\t\t\tif (at < n)\n\t\t\t\t\tP[at] = ((int)drop.Depth - 128) * (1.0f / 255);\n\t\t\t}\n"
                "\t\t\telse if (drop.Type == ADropType::PhaseSpot)\n\t\t\t{\n"
                "\t\t\t\tdrop.Depth += drop.ByteD;\n"
                "\t\t\t\tif (at < n)\n\t\t\t\t\tP[at] = std::sin(drop.Depth * (3.14f / 128));\n\t\t\t}\n\t\t}\n"
                "\t\tstatic unsigned vitaSteps = 0, vitaChecks = 0;\n"
                "\t\tif ((++vitaSteps & 127) == 100 && vitaChecks < 4)\n\t\t{\n"
                "\t\t\tvitaChecks++;\n"
                "\t\t\tconst VitaWater::State before = st;\n"
                "\t\t\tVitaWater::StepPlanar(st);\n"
                "\t\t\tLogMessage(\"VitaWater: planar check \" + Name.ToString() + \": largest difference \" + std::to_string(VitaWater::CheckPlanar(before, st)));\n\t\t}\n"
                "\t\telse\n\t\t\tVitaWater::StepPlanar(st);\n"
                "\t\treturn;\n\t}\n#endif\n"),
     'vita-water-planar')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\t\tuint8_t* pixels = (uint8_t*)mipmap.Data.data();\n\n\t\tfor (int y = 0; y < height; y++)\n"),
     lambda m: ("\t\tuint8_t* pixels = (uint8_t*)mipmap.Data.data();\n\n"
                "#ifdef __vita__ // vita-shade-planar\n\t\tVitaWater::ShadePlanar(VitaWater::StateFor(this, width, height), pixels);\n\t\tif (false)\n#endif\n"
                "\t\tfor (int y = 0; y < height; y++)\n"),
     'vita-shade-planar')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape("\t\t\tVitaWater::Refract((const VitaWater::Pixel*)WaterDepth[CurrentWaterDepth].data(), srcpixels, pixels, width, height);\n"),
     lambda m: "\t\t\tVitaWater::RefractPlanar(VitaWater::StateFor(this, width, height), srcpixels, pixels); // vita-wet-planar\n",
     'vita-wet-planar')
edit("Light/LightSystem_Fog.cpp",
     re.escape("\tstatic const int vitaFogRate = VitaFogRate();\n\tif (vitaFogNew)\n\t{\n\t\tfirstDrawThisScene = true;\n"),
     lambda m: ("\tstatic const int vitaFogRate = VitaFogRate();\n"
                "\tstruct VitaFogView { vec3 eye; vec3 origin; }; // vita-fogview: the camera and the surface at the last build\n"
                "\tstatic std::unordered_map<uint64_t, VitaFogView, VitaHash64> vitaFogViews;\n"
                "\tVitaFogView& vitaView = vitaFogViews[cacheID];\n"
                "\tconst vec3 vitaEye = engine->CameraLocation;\n"
                "\tconst vec3 de = vitaEye - vitaView.eye, dor = coords.Origin - vitaView.origin;\n"
                "\tconst bool vitaMoved = vitaFogNew || dot(de, de) > 1.0f || dot(dor, dor) > 0.01f;\n"
                "\tif (vitaFogNew)\n\t{\n\t\tfirstDrawThisScene = true;\n"),
     'vita-fogview')
edit("Light/LightSystem_Fog.cpp",
     re.escape("\telse if (FrameCounter - fogtex.first >= vitaFogRate || FrameCounter < fogtex.first)\n"),
     lambda m: "\telse if ((FrameCounter - fogtex.first >= vitaFogRate || FrameCounter < fogtex.first) && vitaMoved) // vita-fogmoved\n",
     'vita-fogmoved')
edit("Light/LightSystem_Fog.cpp",
     re.escape("#else\n\tif (fogtex.first != FrameCounter)\n"),
     lambda m: "\tif (firstDrawThisScene) // vita-fogview-set\n\t{\n\t\tvitaView.eye = vitaEye;\n\t\tvitaView.origin = coords.Origin;\n\t}\n" + m.group(0),
     'vita-fogview-set')
edit("Light/FogmapBuilder.h",
     re.escape("\tArray<vec3> points;\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-fogcull-h: the texels' bounding sphere (radius < 0: not worked out yet)\n\tvec3 vitaCenter;\n\tfloat vitaRadius = -1.0f;\n#endif\n",
     'vita-fogcull-h')
edit("Light/FogmapBuilder.cpp",
     re.escape("\tCalcWorldLocations(mapCoords, lmindex);\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-fogcull-reset\n\tvitaRadius = -1.0f;\n#endif\n",
     'vita-fogcull-reset')
edit("Light/FogmapBuilder.cpp",
     re.escape("\tvec3 fogcolor = light->FogInfo.fogcolor;\n\tfloat brightness = light->FogInfo.brightness;\n"),
     lambda m: ("#ifdef __vita__ // vita-fogcull: no ray from the eye to a texel meets the light's sphere: nothing to add\n"
                "\t{\n\t\tconst size_t n = (size_t)width * height;\n"
                "\t\tif (vitaRadius < 0.0f && n > 0)\n\t\t{\n"
                "\t\t\tvec3 lo = points[0], hi = points[0];\n"
                "\t\t\tfor (size_t i = 1; i < n; i++)\n\t\t\t{\n"
                "\t\t\t\tlo = vec3(std::min(lo.x, points[i].x), std::min(lo.y, points[i].y), std::min(lo.z, points[i].z));\n"
                "\t\t\t\thi = vec3(std::max(hi.x, points[i].x), std::max(hi.y, points[i].y), std::max(hi.z, points[i].z));\n\t\t\t}\n"
                "\t\t\tvitaCenter = (lo + hi) * 0.5f;\n\t\t\tvitaRadius = length(hi - lo) * 0.5f + 1.0f;\n\t\t}\n"
                "\t\tif (vitaRadius >= 0.0f)\n\t\t{\n"
                "\t\t\tconst vec3 seg = vitaCenter - view;\n"
                "\t\t\tconst float segLen2 = dot(seg, seg);\n"
                "\t\t\tfloat t = segLen2 > 0.0f ? dot(light->FogInfo.location - view, seg) / segLen2 : 0.0f;\n"
                "\t\t\tt = std::clamp(t, 0.0f, 1.0f);\n"
                "\t\t\tconst vec3 d = light->FogInfo.location - (view + seg * t);\n"
                "\t\t\tconst float reach = light->FogInfo.radius + vitaRadius;\n"
                "\t\t\tif (dot(d, d) > reach * reach)\n\t\t\t\treturn;\n\t\t}\n\t}\n#endif\n"
                + m.group(0)),
     'vita-fogcull:')


# 89. The level tick by part (laps 'tick: ...', probes=1): 18-23 ms a frame in Lev2_Fire1 (Snail 6-8 ms for 9) with no idea how much
#     is physics, script or animation.
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape('#include "VM/Frame.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-tickparts-inc\n',
     'vita-tickparts-inc')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("void UActor::Tick(float elapsed)\n{\n\tif (engine->LaunchInfo.IsKnowWonder()) // AParticleFX::Tick, AWind::Tick\n\t{\n\t\tKW::TickNativeActor(this, elapsed);\n"),
     lambda m: m.group(0).replace("void UActor::Tick(float elapsed)\n{\n", "void UActor::Tick(float elapsed)\n{\n\tVITA_LAP_START; // vita-tickparts-start\n"),
     'vita-tickparts-start')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\tTickAnimation(elapsed);\n\tif (engine->LaunchInfo.IsDeusEx())\n\t\tTickBlendAnimation(elapsed);\n"),
     lambda m: "\tVITA_LAP(TickNative); // vita-tickparts-anim\n" + m.group(0) + "\tVITA_LAP(TickAnim);\n",
     'vita-tickparts-anim')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\tif (engine->LaunchInfo.IsKnowWonder()) // HP1's ProcessState: the latent action is polled after the Tick event\n"),
     lambda m: "\tVITA_LAP(TickEvent); // vita-tickparts-event\n" + m.group(0),
     'vita-tickparts-event')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\tbool timerFirst = engine->LaunchInfo.IsKnowWonder() && KW::UseKWPhysics(); // HP1's AActor::Tick: Timer, then physics\n\tif (!timerFirst)\n\t\tTickPhysics(elapsed);\n"),
     lambda m: "\tVITA_LAP(TickState); // vita-tickparts-state\n" + m.group(0) + "\tVITA_LAP(TickPhysics);\n",
     'vita-tickparts-state')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\tif (timerFirst && !bDeleteMe())\n\t\tTickPhysics(elapsed);\n"),
     lambda m: "\tVITA_LAP(TickTimer); // vita-tickparts-phys\n" + m.group(0) + "\tVITA_LAP(TickPhysics);\n",
     'vita-tickparts-phys')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\t\tKW::TickRootMotion(this);\n}\n"),
     lambda m: "\t\tKW::TickRootMotion(this);\n\tVITA_LAP(TickRoot); // vita-tickparts-root\n}\n",
     'vita-tickparts-root')


# 90. Log of 06 Nov 07:41 (Lev_Tut2, broom lesson, ~22 fps): level tick 16.5 ms = Tick events 10.1 (25.6 us x 395), physics 3.0,
#     native 1.1, Timer 0.9; by class BroomHoopStage5 5.8 ms for 50, Stage4 1.5, Ring4/5 1.1 each: HPBase.baseProps.Tick bobs every
#     hoop (hidden ones too) with SetLocation every frame. (a) laps inside SetLocation; (b) the touch query after the move is made only
#     when the actor collides with actors: Touch needs bCollideActors() on both sides, so with it false the loop touched nothing.
edit("Packages/Engine/Actors/UActor_Phys.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-setloc-inc\n',
     'vita-setloc-inc')
edit("Packages/Engine/Actors/UActor_Phys.cpp",
     re.escape("bool UActor::SetLocation(const vec3& newLocation)\n{\n\tauto result = CheckLocation(newLocation, CollisionRadius(), CollisionHeight(), bCollideWorld() || bCollideWhenPlacing());\n"),
     lambda m: ("bool UActor::SetLocation(const vec3& newLocation)\n{\n\tVITA_LAP_START; // vita-setloc-laps\n"
                "\tauto result = CheckLocation(newLocation, CollisionRadius(), CollisionHeight(), bCollideWorld() || bCollideWhenPlacing());\n\tVITA_LAP(SetLocCheck);\n"),
     'vita-setloc-laps')
edit("Packages/Engine/Actors/UActor_Phys.cpp",
     re.escape("\tLocation() = result.second;\n\tXLevel()->Collision.AddToCollision(this);\n\n\tif (Level()->bBegunPlay())\n\t{\n\t\t// Send touch notifications for anything at the new location\n\t\tfor (UActor* actor"),
     lambda m: ("\tLocation() = result.second;\n\tXLevel()->Collision.AddToCollision(this);\n\tVITA_LAP(SetLocRelink); // vita-setloc-relink\n\n"
                "\tif (Level()->bBegunPlay())\n\t{\n\t\t// Send touch notifications for anything at the new location\n"
                "#ifdef __vita__ // vita-setloc-notouch: Touch needs bCollideActors() on this actor: without it the query finds nothing to touch\n"
                "\t\tif (bCollideActors())\n#endif\n"
                "\t\tfor (UActor* actor"),
     'vita-setloc-relink')
edit("Packages/Engine/Actors/UActor_Phys.cpp",
     re.escape("\t\t\t\tif (actor && !IsOverlapping(actor))\n\t\t\t\t\tUnTouch(actor);\n\t\t\t}\n\t\t}\n\t}\n\n\treturn true;\n}\n"),
     lambda m: m.group(0)[:-len("\n\treturn true;\n}\n")] + "\n\tVITA_LAP(SetLocTouch); // vita-setloc-touch\n\treturn true;\n}\n",
     'vita-setloc-touch')


# 91. The script VM, from the profile of 06 Nov 08:33 (Lev_Tut2, broom lesson; instrumented, so small functions look bigger):
#     Frame::Call/Run/RunExpr, ExpressionValue, UProperty::ConstructArray/DestructArray/ElementPitch ~25-30% of the engine thread.
#     (a) a frame's locals made with one memset and dropped with nothing when they are all plain values (vita/VitaTrivialLocals.h;
#     the flag is worked out once per function/state, UStruct::VitaTrivialLocals); (b) Frame::Call made an ExpressionValue for every
#     property of the function (locals too) twice, to store the args and to copy out params: only for params and the return value now.
edit("Packages/Core/UStruct.h",
     re.escape("\tbool IsNativeFunc = false;\n"),
     lambda m: m.group(0) + "\tint8_t VitaTrivialLocals = -1; // vita-trivial-field: every property a plain value (1), not (0), unknown (-1)\n",
     'vita-trivial-field')
edit("VM/Frame.cpp",
     re.escape('#include "Frame.h"\n'),
     lambda m: m.group(0) + '#include "VitaTrivialLocals.h" // vita-trivial-inc\n#include <cstring>\n',
     'vita-trivial-inc')
edit("VM/Frame.cpp",
     re.escape("\t\tif (!layout->IsNativeFunc)\n\t\t{\n\t\t\tfor (UProperty* prop : layout->Properties)\n\t\t\t{\n\t\t\t\tprop->ConstructArray("),
     lambda m: ("\t\tif (!layout->IsNativeFunc)\n\t\t{\n"
                "#ifdef __vita__ // vita-trivial-init\n\t\t\tif (VitaLocalsTrivial(layout))\n\t\t\t\tstd::memset(Variables, 0, layout->StructSize);\n\t\t\telse\n#endif\n"
                "\t\t\tfor (UProperty* prop : layout->Properties)\n\t\t\t{\n\t\t\t\tprop->ConstructArray("),
     'vita-trivial-init')
edit("VM/Frame.cpp",
     re.escape("\t\tif (!layout->IsNativeFunc)\n\t\t{\n\t\t\tfor (UProperty* prop : layout->Properties)\n\t\t\t{\n\t\t\t\tprop->DestructArray("),
     lambda m: ("\t\tif (!layout->IsNativeFunc)\n\t\t{\n"
                "#ifdef __vita__ // vita-trivial-deinit: plain values need no destruction\n\t\t\tif (!VitaLocalsTrivial(layout))\n#endif\n"
                "\t\t\tfor (UProperty* prop : layout->Properties)\n\t\t\t{\n\t\t\t\tprop->DestructArray("),
     'vita-trivial-deinit')
edit("VM/Frame.cpp",
     re.escape("\t\tfor (UProperty* prop : func->Properties)\n\t\t{\n\t\t\tExpressionValue lvalue = ExpressionValue::Variable(frame.Variables, prop);\n\t\t\tif (AllFlags(prop->PropFlags, PropertyFlags::Parm))\n\t\t\t{\n"),
     lambda m: ("\t\tfor (UProperty* prop : func->Properties)\n\t\t{\n"
                "#ifdef __vita__ // vita-callargs: a local is no argument\n\t\t\tif (!AllFlags(prop->PropFlags, PropertyFlags::Parm))\n\t\t\t\tcontinue;\n#endif\n"
                "\t\t\tExpressionValue lvalue = ExpressionValue::Variable(frame.Variables, prop);\n\t\t\tif (AllFlags(prop->PropFlags, PropertyFlags::Parm))\n\t\t\t{\n"),
     'vita-callargs')
edit("VM/Frame.cpp",
     re.escape("\t\targindex = 0;\n\t\tfor (UProperty* prop : func->Properties)\n\t\t{\n\t\t\tExpressionValue lvalue = ExpressionValue::Variable(frame.Variables, prop);\n"),
     lambda m: ("\t\targindex = 0;\n\t\tfor (UProperty* prop : func->Properties)\n\t\t{\n"
                "#ifdef __vita__ // vita-callout: neither a param nor the return value: nothing to do\n"
                "\t\t\tif (!AllFlags(prop->PropFlags, PropertyFlags::Parm) && !AllFlags(prop->PropFlags, PropertyFlags::ReturnParm))\n\t\t\t\tcontinue;\n#endif\n"
                "\t\t\tExpressionValue lvalue = ExpressionValue::Variable(frame.Variables, prop);\n"),
     'vita-callout')


# 92. Laps in KW::FarMoveActor (HP1's SetLocation; the hoops' bobbing goes through it, not UActor::SetLocation: #90's laps stayed
#     empty in the log of 06 Nov 07:59).
edit("../../knowwonder/KWMove.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-farmove-inc\n',
     'vita-farmove-inc')
edit("../../knowwonder/KWMove.cpp",
     re.escape("\tbool FarMoveActor(UActor* actor, const vec3& destIn, bool test, bool noCheck)\n\t{\n"),
     lambda m: m.group(0) + "\t\tVITA_LAP_START; // vita-farmove-laps\n",
     'vita-farmove-laps')
edit("../../knowwonder/KWMove.cpp",
     re.escape("\t\t\tok = FindSpot(vec3(actor->CollisionRadius(), actor->CollisionRadius(), actor->CollisionHeight()), dest, false, false);\n\n\t\tif (ok)\n\t\t{\n\t\t\tif (!test && !noCheck)\n\t\t\t\tok = !CheckEncroachment(actor, dest, actor->Rotation(), true);\n"),
     lambda m: (m.group(0).replace("\n\t\tif (ok)\n\t\t{\n", "\t\tVITA_LAP(FarSpot); // vita-farmove-spot\n\n\t\tif (ok)\n\t\t{\n", 1) + "\t\t\tVITA_LAP(FarEncroach);\n"),
     'vita-farmove-spot')
edit("../../knowwonder/KWMove.cpp",
     re.escape("\t\tif (ok)\n\t\t\tSetActorZone(actor, test, false);\n\t\treturn ok;\n\t}\n"),
     lambda m: "\t\tif (ok)\n\t\t\tSetActorZone(actor, test, false);\n\t\tVITA_LAP(FarZone); // vita-farmove-zone\n\t\treturn ok;\n\t}\n",
     'vita-farmove-zone')


# 93. Script function lookups remembered (vita/VitaFuncCache.h): VirtualFunction and FindEventFunction searched the class chain's
#     state and function maps on every call. Cleared when a class or state is loaded or a mod wraps a function.
edit("VM/Frame.cpp",
     re.escape('#include "VitaTrivialLocals.h" // vita-trivial-inc\n'),
     lambda m: m.group(0) + '#include "VitaFuncCache.h" // vita-funccache-inc\n',
     'vita-funccache-inc')
edit("VM/Frame.cpp",
     re.escape("\t\t\t\t\tUClass* contextClass = UObject::TryCast<UClass>(context);\n\t\t\t\t\tif (!contextClass)\n\t\t\t\t\t\tcontextClass = context->Class;\n\n\t\t\t\t\t// Search states first\n"),
     lambda m: (m.group(0).replace("\n\t\t\t\t\t// Search states first\n", "") +
                "#ifdef __vita__ // vita-funccache-virtual: the remembered answer of the search below\n"
                "\t\t\t\t\tif (UFunction* vitaFunc = VitaFindFunction(contextClass, context->GetStateName(), funcExpr->Name))\n\t\t\t\t\t{\n"
                "\t\t\t\t\t\tauto callresult = Frame::Call(vitaFunc, context, funcArgs);\n"
                "\t\t\t\t\t\tPopValues(funcExpr->Args.size());\n\t\t\t\t\t\tPushValue(callresult);\n\t\t\t\t\t\tPopExpr();\n\t\t\t\t\t\tbreak;\n\t\t\t\t\t}\n#endif\n"
                "\n\t\t\t\t\t// Search states first\n"),
     'vita-funccache-virtual')
edit("VM/ScriptCall.cpp",
     re.escape('#include "Frame.h"\n'),
     lambda m: m.group(0) + '#include "VitaFuncCache.h" // vita-funccache-inc2\n',
     'vita-funccache-inc2')
edit("VM/ScriptCall.cpp",
     re.escape("UFunction* FindEventFunction(UObject* Context, const NameString& name)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-funccache-event\n\treturn VitaFindFunction(Context->Class, Context->GetStateName(), name);\n#endif\n",
     'vita-funccache-event')
edit("Packages/Core/UClass.cpp",
     re.escape('#include "UClass.h"\n'),
     lambda m: m.group(0) + '#include "VitaFuncCache.h" // vita-funccache-inc3\n',
     'vita-funccache-inc3')
edit("Packages/Core/UClass.cpp",
     re.escape("\t\telse if (auto func = UObject::TryCast<UFunction>(child))\n\t\t{\n\t\t\tFunctions[child->Name] = func;\n\t\t}\n\t}\n}\n"),
     lambda m: m.group(0)[:-len("}\n")] + "#ifdef __vita__ // vita-funccache-class\n\tVitaFuncCacheClear();\n#endif\n}\n",
     'vita-funccache-class')
edit("Packages/Core/UState.cpp",
     re.escape("\t\tif (auto func = UObject::TryCast<UFunction>(child))\n\t\t{\n\t\t\tFunctions[child->Name] = func;\n\t\t}\n\t}\n}\n"),
     lambda m: m.group(0)[:-len("}\n")] + "#ifdef __vita__ // vita-funccache-state\n\tVitaFuncCacheClear();\n#endif\n}\n",
     'vita-funccache-state')
edit("Packages/Core/UState.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaFuncCache.h" // vita-funccache-inc4\n',
     'vita-funccache-inc4')
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape("\t\tit->second = wrapper;\n\t\treturn original;\n"),
     lambda m: "\t\tit->second = wrapper;\n#ifdef __vita__ // vita-funccache-wrap\n\t\tVitaFuncCacheClear();\n#endif\n\t\treturn original;\n",
     'vita-funccache-wrap')
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape('#include "HP1Mods.h"\n'),
     lambda m: m.group(0) + '#include "VitaFuncCache.h" // vita-funccache-inc5\n',
     'vita-funccache-inc5')


# 94. The Tick event (395 a frame in Lev_Tut2) went through CallEvent(..., Array<ExpressionValue>): one heap allocation and free per
#     call for the one float argument (newlib's malloc takes a lock on the Vita). VitaCallEvent: CallEvent's body over an argument
#     on the stack.
edit("VM/ScriptCall.h",
     re.escape("ExpressionValue CallEvent(UObject* Context, EventName name, Array<ExpressionValue> args = {});\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-callevent-decl\nExpressionValue VitaCallEvent(UObject* Context, EventName eventname, ExpressionValue* args, size_t count);\n#endif\n",
     'vita-callevent-decl')
edit("VM/ScriptCall.cpp",
     re.escape("ExpressionValue CallEvent(UObject* Context, const NameString& name, Array<ExpressionValue> args)\n"),
     lambda m: ("#ifdef __vita__ // vita-callevent-def: CallEvent(EventName) above, the arguments not in an Array\n"
                "ExpressionValue VitaCallEvent(UObject* Context, EventName eventname, ExpressionValue* args, size_t count)\n{\n"
                "\tif (!Context->IsEventEnabled(eventname))\n\t\treturn ExpressionValue::NothingValue();\n\n"
                "\tif (auto actor = UObject::TryCast<UActor>(Context))\n\t{\n"
                "\t\tif (!actor->Level()->bBegunPlay() || (actor->bDeleteMe() && eventname != EventName::Destroyed))\n"
                "\t\t\treturn ExpressionValue::NothingValue();\n\t}\n\n"
                "\tUFunction* func = FindEventFunction(Context, ToNameString(eventname));\n"
                "\tif (func)\n\t\treturn Frame::Call(func, Context, { args, count });\n"
                "\telse\n\t\treturn ExpressionValue::NothingValue();\n}\n#endif\n\n" + m.group(0)),
     'vita-callevent-def')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\t\tCallEvent(this, EventName::Tick, { ExpressionValue::FloatValue(elapsed) });\n"),
     lambda m: ("#ifdef __vita__ // vita-callevent-tick\n\t\tExpressionValue vitaArg = ExpressionValue::FloatValue(elapsed);\n"
                "\t\tVitaCallEvent(this, EventName::Tick, &vitaArg, 1);\n#else\n" + m.group(0) + "#endif\n"),
     'vita-callevent-tick')


# 95. 'ticks by class' with each class's script Tick event and TickPhysics share (Lev_Tut1's hall: Harry 3.5 ms for one actor).
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t\tVitaProbes::ClassTime& entry = VitaProbes::classTimes[cls];\n"),
     lambda m: "\t\tVitaProbes::ClassTime& entry = VitaProbes::classTimes[cls];\n\t\tVitaProbes::currentClass = nullptr; // vita-classsplit-end\n",
     'vita-classsplit-end')
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t\tconst uint64_t start = VitaProbes::Now();\n\t\tactor->Tick(elapsed);\n"),
     lambda m: ("\t\tconst uint64_t start = VitaProbes::Now();\n\t\tVitaProbes::currentClass = &VitaProbes::classTimes[cls]; // vita-classsplit-start\n"
                "\t\tactor->Tick(elapsed);\n"),
     'vita-classsplit-start')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\tVITA_LAP(TickEvent); // vita-tickparts-event\n"),
     lambda m: "\tVITA_LAP_CLASS(TickEvent, eventUs); // vita-tickparts-event vita-classsplit-event\n",
     'vita-classsplit-event')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\t\tTickPhysics(elapsed);\n\tVITA_LAP(TickPhysics);\n"),
     lambda m: "\t\tTickPhysics(elapsed);\n\tVITA_LAP_CLASS(TickPhysics, physicsUs); // vita-classsplit-phys\n",
     'vita-classsplit-phys')


# 96. Mesh faces on three cores (render.cfg face_threads=1; Lev_Tut1's hall: 'mesh: faces' ~250 us x 15 meshes on the main thread,
#     cores 1 and 2 nearly idle). For a mesh with >= 192 faces, face_runs on and no fog balls: (1) the materials the faces use are
#     resolved first, on the main thread, as the loop does it (UpdateTexture, needTranslucentPass); (2) the faces in three contiguous
#     parts (VitaJobs::Run), each writing its triangles and their material into its own slice; (3) the slices joined in order and
#     consecutive triangles of one material handed over together. Same triangles, same order, same runs as the serial loop.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tmaterialCache.assign(mesh->Materials.size(), MaterialCache());\n\n\t\tfor (const MeshFace& face : mesh->Faces)\n"),
     lambda m: ("\t\tmaterialCache.assign(mesh->Materials.size(), MaterialCache());\n\n"
r"""#ifdef __vita__ // vita-faces-mt
		if (faceRuns && !vitaFogBalls && VitaFaceThreads() && VitaJobs::Mode() >= 2 && mesh->Faces.size() >= 192)
		{
			// (1) the materials, where the loop below would meet them first
			for (const MeshFace& face : mesh->Faces)
			{
				if (lodFaceSkipped(face) || face.MaterialIndex >= mesh->Materials.size())
					continue;
				MaterialCache& mc = materialCache[face.MaterialIndex];
				if (mc.ready)
					continue;
				mc.ready = true;
				const MeshMaterial& material = mesh->Materials[face.MaterialIndex];
				if (material.PolyFlags & PF_Invisible)
				{
					mc.skip = true;
					continue;
				}
				uint32_t renderflags = material.PolyFlags | polyFlags;
				ApplyOpacityFlags(opacity, renderflags);
				UTexture* tex = (renderflags & PF_Environment) ? engine->render->Mesh.envmap : (material.TextureIndex < engine->render->Mesh.textures.size() ? engine->render->Mesh.textures[material.TextureIndex] : nullptr);
				if (!tex)
				{
					mc.skip = true;
					continue;
				}
				bool isTranslucent = (renderflags & (PF_Translucent | PF_Modulated | PF_Highlighted)) != 0;
				if (isTranslucent != translucentPass)
				{
					needTranslucentPass |= isTranslucent;
					mc.skip = true;
					continue;
				}
				engine->render->UpdateTexture(tex);
				engine->render->UpdateTextureInfo(mc.texinfo, tex);
				mc.renderflags = renderflags;
				mc.width = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Width : 256.0f;
				mc.height = mc.texinfo.Texture ? (float)mc.texinfo.Texture->UsedMipmaps.front().Height : 256.0f;
			}

			// (2) the faces in three parts
			const size_t numFaces = mesh->Faces.size();
			enum { Parts = 3 };
			static std::vector<GouraudVertex> vitaTris;
			static std::vector<uint16_t> vitaTriMat;
			if (vitaTris.size() < numFaces * 3)
				vitaTris.resize(numFaces * 3);
			if (vitaTriMat.size() < numFaces)
				vitaTriMat.resize(numFaces);
			size_t partBegin[Parts], partCount[Parts];
			for (int p = 0; p < Parts; p++)
			{
				partBegin[p] = numFaces * p / Parts;
				partCount[p] = 0;
			}
			const mat3 envRot = mat3(frame->Frame.WorldToView * frame->Frame.ObjectToWorld);
			auto buildPart = [&](int p)
			{
				const size_t end = p + 1 < Parts ? partBegin[p + 1] : numFaces;
				GouraudVertex* out = vitaTris.data() + partBegin[p] * 3;
				uint16_t* outMat = vitaTriMat.data() + partBegin[p];
				size_t n = 0;
				GouraudVertex vertices[3];
				for (size_t f = partBegin[p]; f < end; f++)
				{
					const MeshFace& face = mesh->Faces[f];
					if (lodFaceSkipped(face) || face.MaterialIndex >= mesh->Materials.size())
						continue;
					const MaterialCache& mc = materialCache[face.MaterialIndex];
					if (mc.skip)
						continue;
					const uint32_t renderflags = mc.renderflags;
					const float width = mc.width;
					const float height = mc.height;
					if (!(renderflags & PF_TwoSided) && face.Indices[0] < numWedges && face.Indices[1] < numWedges && face.Indices[2] < numWedges)
					{
						const int c0 = wedgeVertex(lodWedge(face.Indices[0])), c1 = wedgeVertex(lodWedge(face.Indices[1])), c2 = wedgeVertex(lodWedge(face.Indices[2]));
						if (c0 < (int)verts.size() && c1 < (int)verts.size() && c2 < (int)verts.size())
						{
							const vec3 nrm = cross(verts[c1] - verts[c0], verts[c2] - verts[c0]);
							if (dot(nrm, eye - verts[c0]) <= 0.0f)
								continue;
						}
					}
					bool valid = true;
					vec3 faceNormals[3];
					int faceVerts[3];
					for (int i = 0; i < 3; i++)
					{
						int w = face.Indices[i];
						if (w >= (int)numWedges) { valid = false; break; }
						w = lodWedge(w);
						int v = wedgeVertex(w);
						if (v >= (int)verts.size()) { valid = false; break; }
						vertices[i].Point = verts[v];
						if (useExtWedges)
							vertices[i].UV = { mesh->ExtWedges[w].U * width, mesh->ExtWedges[w].V * height };
						else
							vertices[i].UV = { mesh->Wedges[w].U * width / 255.0f, mesh->Wedges[w].V * height / 255.0f };
						faceNormals[i] = normals[v];
						faceVerts[i] = v;
					}
					if (!valid)
						continue;
					if (renderflags & PF_Environment)
					{
						for (int i = 0; i < 3; i++)
						{
							vec3 v = normalize(vertices[i].Point);
							vec3 pr = envRot * reflect(v, faceNormals[i]);
							vertices[i].UV = { (pr.x + 1.0f) * 128.0f * width / 255.0f, (pr.y + 1.0f) * 128.0f * height / 255.0f };
						}
					}
					for (int i = 0; i < 3; i++)
					{
						vertices[i].Light = (renderflags & PF_Unlit) ? lighting.Unlit : vertexLights[faceVerts[i]];
						vertices[i].Fog = vec4(0.0f);
					}
					ApplyOpacityVertices(opacity, vertices, 3);
					out[n * 3 + 0] = vertices[0];
					out[n * 3 + 1] = vertices[1];
					out[n * 3 + 2] = vertices[2];
					outMat[n] = (uint16_t)face.MaterialIndex;
					n++;
				}
				partCount[p] = n;
			};
			struct VitaFaceCtx { decltype(buildPart)* fn; } vitaCtx{ &buildPart };
			VitaJobs::Run([](void* c, int i) { (*((VitaFaceCtx*)c)->fn)(i); }, &vitaCtx, Parts);

			// (3) joined in order, runs by material
			size_t total = partCount[0];
			for (int p = 1; p < Parts; p++)
			{
				if (partCount[p] && partBegin[p] != total)
				{
					std::memmove(vitaTris.data() + total * 3, vitaTris.data() + partBegin[p] * 3, partCount[p] * 3 * sizeof(GouraudVertex));
					std::memmove(vitaTriMat.data() + total, vitaTriMat.data() + partBegin[p], partCount[p] * sizeof(uint16_t));
				}
				total += partCount[p];
			}
			size_t runStart = 0;
			for (size_t t = 1; t <= total; t++)
			{
				if (t < total && vitaTriMat[t] == vitaTriMat[runStart])
					continue;
				MaterialCache& mc = materialCache[vitaTriMat[runStart]];
				VITA_PROBE(MeshDevice);
				frame->Device->DrawGouraudTriangles(&frame->Frame, mc.texinfo, vitaTris.data() + runStart * 3, (int)(t - runStart), mc.renderflags | PF_RenderFog);
				runStart = t;
			}
			VITA_LAP(MeshFaces);
			return needTranslucentPass;
		}
#endif
"""
                "\t\tfor (const MeshFace& face : mesh->Faces)\n"),
     'vita-faces-mt')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaConfig.h" // vita-skininc\n'),
     lambda m: m.group(0) + '#include "VitaJobs.h" // vita-facesinc\n#include <cstring>\n',
     'vita-facesinc')


# 97. The player's PlayerInput and PlayerTick events (every frame) through VitaCallEvent too (#94: no Array allocation).
edit("Packages/Engine/Actors/Pawn/UPlayerPawn.cpp",
     re.escape("\t\t\tCallEvent(this, EventName::PlayerInput, { ExpressionValue::FloatValue(elapsed) });\n\t\t\tif (!engine->LaunchInfo.IsHarryPotter1() || !HP1::ModsPlayerTick(this))\n\t\t\t\tCallEvent(this, EventName::PlayerTick, { ExpressionValue::FloatValue(elapsed) });\n"),
     lambda m: ("#ifdef __vita__ // vita-callevent-player\n"
                "\t\t\tExpressionValue vitaArg = ExpressionValue::FloatValue(elapsed);\n"
                "\t\t\tVitaCallEvent(this, EventName::PlayerInput, &vitaArg, 1);\n"
                "\t\t\tif (!engine->LaunchInfo.IsHarryPotter1() || !HP1::ModsPlayerTick(this))\n\t\t\t{\n"
                "\t\t\t\tExpressionValue vitaArg2 = ExpressionValue::FloatValue(elapsed);\n"
                "\t\t\t\tVitaCallEvent(this, EventName::PlayerTick, &vitaArg2, 1);\n\t\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-callevent-player')


# 98. #96 did not change 'mesh: faces' in Lev_Tut1's hall (log 06 Nov 09:31): it skipped zones with fog balls, and the hall has
#     them (the per-vertex fog, every fog ball's sphere density, is likely most of the loop there). The fog of every vertex is now
#     worked out first, in three parts on the job threads (GetVertexFog only reads; the serial loop worked it out for the vertices of
#     the faces it drew, the values are the same), then the faces as in #96. Log line 'mesh faces on three cores' counts the paths.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tif (faceRuns && !vitaFogBalls && VitaFaceThreads() && VitaJobs::Mode() >= 2 && mesh->Faces.size() >= 192)\n\t\t{\n"),
     lambda m: ("\t\tif (faceRuns && VitaFaceThreads() && VitaJobs::Mode() >= 2 && mesh->Faces.size() >= 192) // vita-faces-fog\n\t\t{\n"
                "\t\t\tVitaStats::facesThreaded++;\n"
                "\t\t\tif (vitaFogBalls)\n\t\t\t{\n"
                "\t\t\t\tVitaStats::facesThreadedFog++;\n"
                "\t\t\t\tconst size_t numVerts = verts.size();\n"
                "\t\t\t\tauto fogPart = [&](int p)\n\t\t\t\t{\n"
                "\t\t\t\t\tconst size_t b = numVerts * p / 3, e = numVerts * (p + 1) / 3;\n"
                "\t\t\t\t\tfor (size_t v = b; v < e; v++)\n\t\t\t\t\t\tvitaFog[v] = vertexLight.GetVertexFog(verts[v]);\n\t\t\t\t};\n"
                "\t\t\t\tstruct VitaFogCtx { decltype(fogPart)* fn; } fogCtx{ &fogPart };\n"
                "\t\t\t\tVitaJobs::Run([](void* c, int i) { (*((VitaFogCtx*)c)->fn)(i); }, &fogCtx, 3);\n\t\t\t}\n"),
     'vita-faces-fog')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\t\tfor (int i = 0; i < 3; i++)\n\t\t\t\t\t{\n\t\t\t\t\t\tvertices[i].Light = (renderflags & PF_Unlit) ? lighting.Unlit : vertexLights[faceVerts[i]];\n\t\t\t\t\t\tvertices[i].Fog = vec4(0.0f);\n\t\t\t\t\t}\n"),
     lambda m: ("\t\t\t\t\tfor (int i = 0; i < 3; i++)\n\t\t\t\t\t{\n\t\t\t\t\t\tvertices[i].Light = (renderflags & PF_Unlit) ? lighting.Unlit : vertexLights[faceVerts[i]];\n"
                "\t\t\t\t\t\tvertices[i].Fog = vitaFogBalls ? vitaFog[faceVerts[i]] : vec4(0.0f); // vita-faces-fogvert\n\t\t\t\t\t}\n"),
     'vita-faces-fogvert')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n\t\t\tif (lodFaceSkipped(face)) // vita-lodfaces\n"),
     lambda m: "#ifdef __vita__ // vita-faces-serialcount\n\t\tVitaStats::facesSerial++;\n#endif\n" + m.group(0),
     'vita-faces-serialcount')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaJobs.h" // vita-facesinc\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-faces-statsinc\n',
     'vita-faces-statsinc')


# 98. #96 did not change 'mesh: faces' in Lev_Tut1 (log 06 Nov 09:31): it skipped zones with fog balls. The fog of every vertex is
#     now worked out first, in three parts on the job threads (GetVertexFog only reads; the serial loop worked it out for the
#     vertices of the faces it drew, the values are the same), then the faces as in #96. Log line 'mesh faces on three cores'.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tif (faceRuns && !vitaFogBalls && VitaFaceThreads() && VitaJobs::Mode() >= 2 && mesh->Faces.size() >= 192)\n\t\t{\n"),
     lambda m: ("\t\tif (faceRuns && VitaFaceThreads() && VitaJobs::Mode() >= 2 && mesh->Faces.size() >= 192) // vita-faces-fog\n\t\t{\n"
                "\t\t\tVitaStats::facesThreaded++;\n"
                "\t\t\tif (vitaFogBalls)\n\t\t\t{\n"
                "\t\t\t\tVitaStats::facesThreadedFog++;\n"
                "\t\t\t\tconst size_t numVerts = verts.size();\n"
                "\t\t\t\tauto fogPart = [&](int p)\n\t\t\t\t{\n"
                "\t\t\t\t\tconst size_t b = numVerts * p / 3, e = numVerts * (p + 1) / 3;\n"
                "\t\t\t\t\tfor (size_t v = b; v < e; v++)\n\t\t\t\t\t\tvitaFog[v] = vertexLight.GetVertexFog(verts[v]);\n\t\t\t\t};\n"
                "\t\t\t\tstruct VitaFogCtx { decltype(fogPart)* fn; } fogCtx{ &fogPart };\n"
                "\t\t\t\tVitaJobs::Run([](void* c, int i) { (*((VitaFogCtx*)c)->fn)(i); }, &fogCtx, 3);\n\t\t\t}\n"),
     'vita-faces-fog')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\t\t\t\t\tvertices[i].Fog = vec4(0.0f);\n\t\t\t\t\t}\n\t\t\t\t\tApplyOpacityVertices(opacity, vertices, 3);\n\t\t\t\t\tout[n * 3 + 0]"),
     lambda m: m.group(0).replace("vertices[i].Fog = vec4(0.0f);", "vertices[i].Fog = vitaFogBalls ? vitaFog[faceVerts[i]] : vec4(0.0f); // vita-faces-fogvert"),
     'vita-faces-fogvert')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape("\t\tfor (const MeshFace& face : mesh->Faces)\n\t\t{\n\t\t\tif (lodFaceSkipped(face)) // vita-lodfaces\n"),
     lambda m: "#ifdef __vita__ // vita-faces-serialcount\n\t\tVitaStats::facesSerial++;\n#endif\n" + m.group(0),
     'vita-faces-serialcount')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaJobs.h" // vita-facesinc\n'),
     lambda m: m.group(0) + '#include "VitaStats.h" // vita-faces-statsinc\n',
     'vita-faces-statsinc')


# 99. 'opaque actors' 14 ms in Lev4_Sneak (slot 0 bench) with meshes 3.5 and the prepass 2.6: the brush actors (movers) timed apart.
edit("Render/VisibleActor.cpp",
     re.escape("\t\tVisibleBrush visbrush;\n\t\tif (visbrush.Draw(frame, Actor, false))\n"),
     lambda m: "\t\tVisibleBrush visbrush;\n\t\tVITA_TIMER(DrawBrushes); // vita-brushtimer\n\t\tif (visbrush.Draw(frame, Actor, false))\n",
     'vita-brushtimer')
edit("Render/VisibleActor.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-brushtimer-inc\n',
     'vita-brushtimer-inc')


# 100. Laps in VisibleBrush (movers 8.7 ms a frame in Lev4_Sneak, slot 0 bench).
edit("Render/VisibleBrush.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-brushlaps-inc\n',
     'vita-brushlaps-inc')
edit("Render/VisibleBrush.cpp",
     re.escape("\tengine->Level->Light.UpdateLightList(mover);\n\n\tbrushframe.ObjectToWorld = BrushToWorld(mover);\n\n\tframe->Device->SetSceneNode(&brushframe);\n"),
     lambda m: "\t{ VITA_PROBE(BrushStart); // vita-brushlaps-start\n" + m.group(0) + "\t}\n",
     'vita-brushlaps-start')
edit("Render/VisibleBrush.cpp",
     re.escape("\tauto zoneActor = mover->Region().Zone;\n\tif (!zoneActor)\n\t\tzoneActor = engine->LevelInfo;\n"),
     lambda m: "\tVITA_LAP_START; // vita-brushlaps-poly\n" + m.group(0),
     'vita-brushlaps-poly')
edit("Render/VisibleBrush.cpp",
     re.escape("\tTextureInfo lightmap;\n\tTextureInfo fogmap;\n#ifdef __vita__ // vita-nolight2\n\tif ((PolyFlags & PF_Unlit) == 0 && VitaLightmapsOn())\n\t\tlightmap = engine->Level->Light.GetMoverLightmap(mover, poly, zoneActor, model);\n"),
     lambda m: "\tVITA_LAP(BrushTex); // vita-brushlaps-tex\n" + m.group(0) + "\tVITA_LAP(BrushLight);\n",
     'vita-brushlaps-tex')
edit("Render/VisibleBrush.cpp",
     re.escape("\tsurfaceinfo.PolyFlags = PolyFlags;\n\tsurfaceinfo.LightMap = lightmap.NumMips != 0 ? &lightmap : nullptr;\n"),
     lambda m: "\tVITA_LAP(BrushFog); // vita-brushlaps-fog\n" + m.group(0),
     'vita-brushlaps-fog')
edit("Render/VisibleBrush.cpp",
     re.escape("\tframe->Device->DrawComplexSurface(&frame->Frame, surfaceinfo, facet);\n\treturn false;\n}\n"),
     lambda m: "\tframe->Device->DrawComplexSurface(&frame->Frame, surfaceinfo, facet);\n\tVITA_LAP(BrushDevice); // vita-brushlaps-dev\n\treturn false;\n}\n",
     'vita-brushlaps-dev')


# 101. A bDynamicLightMover's light maps were built again EVERY frame (LightSystem::GetLightmap: 'lastDynamicUpdate = FrameCounter;
#      // To do: ideally we only want to do this if the mover moved'): Lev4_Sneak (slot 0 bench) 130 mover polygons a frame, 'brush
#      poly: light map' 7.0 ms. What such a light map is made of: the polygon's place (coords, worldLocation, radius), the lights in
#      TempDynLightList in that order and their state (CheckLight bumps Light.LastUpdate on any change), and the zone's ambient (in
#      the cache ID). The same signature as at the last build: the light map as it is.
edit("Light/LightSystem_Light.cpp",
     re.escape("\n\tVITA_LAP(LmDynamic); // vita-lap-dynamic\n"),
     lambda m: ("\n#ifdef __vita__ // vita-moverlm-sig\n"
                "\tif (dynamicMover)\n\t{\n"
                "\t\tuint64_t h = 1469598103934665603ull;\n"
                "\t\tauto mix = [&](uint64_t v) { h ^= v; h *= 1099511628211ull; };\n"
                "\t\tauto mixf = [&](float f) { uint32_t u; std::memcpy(&u, &f, 4); mix(u); };\n"
                "\t\tauto mixv = [&](const vec3& v) { mixf(v.x); mixf(v.y); mixf(v.z); };\n"
                "\t\tmixv(coords.Origin); mixv(coords.XAxis); mixv(coords.YAxis); mixv(coords.ZAxis); mixv(worldLocation); mixf(radius);\n"
                "\t\tfor (UActor* light : TempDynLightList)\n\t\t{\n\t\t\tmix((uint64_t)(uintptr_t)light);\n\t\t\tmix((uint64_t)(uint32_t)light->Light.LastUpdate);\n\t\t}\n"
                "\t\tmix(TempDynLightList.size());\n"
                "\t\tstruct VitaMoverSig { uint64_t hash = 0; int stamp = 0; bool valid = false; };\n"
                "\t\tstatic std::unordered_map<uint64_t, VitaMoverSig, VitaHash64> vitaMoverSigs;\n"
                "\t\tVitaMoverSig& sig = vitaMoverSigs[cacheID];\n"
                "\t\tif (sig.valid && sig.hash == h)\n\t\t\tlastDynamicUpdate = sig.stamp;   // nothing it is made of changed\n"
                "\t\telse\n\t\t{\n\t\t\tsig.valid = true;\n\t\t\tsig.hash = h;\n\t\t\tsig.stamp = lastDynamicUpdate;\n\t\t}\n"
                "\t}\n#endif\n"
                "\tVITA_LAP(LmDynamic); // vita-lap-dynamic\n"),
     'vita-moverlm-sig')
edit("Light/LightSystem_Light.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include <cstring> // vita-moverlm-inc\n',
     'vita-moverlm-inc')


# 102. KW::DynamicMoverLights read every permeating light's Location and bSpecialLit (script properties) for every polygon of the
#      mover (130 a frame in Lev4_Sneak): the mover's leaf, and so the list, is the same for all its polygons, and nothing moves
#      while a frame is drawn. Once per mover and frame now (VitaTimers::frameNumber), then the plane test per polygon.
edit("../../knowwonder/KWLightmap.cpp",
     re.escape("\t\tbool specialLit = mover->bSpecialLit();\n\t\tfor (size_t i = first; i < model->Lights.size() && model->Lights[i]; i++)\n\t\t{\n"
               "\t\t\tUActor* light = model->Lights[i];\n\t\t\tif (dot(light->Location() - point, normal) > 0.0f && light->bSpecialLit() == specialLit)\n\t\t\t\tlights.push_back(light);\n\t\t}\n"),
     lambda m: ("#ifdef __vita__ // vita-moverlights-cache\n"
                "\t\tstruct VitaLeafLights { UActor* mover = nullptr; int leaf = -1; unsigned frame = ~0u; std::vector<std::pair<UActor*, vec3>> lights; };\n"
                "\t\tstatic VitaLeafLights cache;\n"
                "\t\tif (cache.mover != mover || cache.leaf != leaf || cache.frame != VitaTimers::frameNumber)\n\t\t{\n"
                "\t\t\tcache.mover = mover;\n\t\t\tcache.leaf = leaf;\n\t\t\tcache.frame = VitaTimers::frameNumber;\n\t\t\tcache.lights.clear();\n"
                "\t\t\tconst bool specialLit = mover->bSpecialLit();\n"
                "\t\t\tfor (size_t i = first; i < model->Lights.size() && model->Lights[i]; i++)\n\t\t\t{\n"
                "\t\t\t\tUActor* light = model->Lights[i];\n"
                "\t\t\t\tif (light->bSpecialLit() == specialLit)\n\t\t\t\t\tcache.lights.push_back({ light, light->Location() });\n\t\t\t}\n\t\t}\n"
                "\t\tfor (const auto& entry : cache.lights)\n\t\t{\n"
                "\t\t\tif (dot(entry.second - point, normal) > 0.0f)\n\t\t\t\tlights.push_back(entry.first);\n\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-moverlights-cache')
edit("../../knowwonder/KWLightmap.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-moverlights-inc\n',
     'vita-moverlights-inc')


# 103. 'draw game' had ~5 ms outside bsp info / process / draw nodes in Lev4_Sneak: PostRender (the HUD and console scripts),
#      PreRender/RenderOverlays/EndFlash and the device's Unlock timed apart; KW::DynamicMoverLights probed.
edit("Render/RenderSubsystem.cpp",
     re.escape("\tResetCanvas();\n\tPreRender();\n\n\tif (engine->LaunchInfo.ue1Version <= 219 || engine->console->bNoDrawWorld() == false)\n\t{\n\t\tDrawScene();\n\t\tRenderOverlays();\n"),
     lambda m: ("\tResetCanvas();\n\t{ VITA_TIMER(Overlays); PreRender(); } // vita-hudtimers\n\n"
                "\tif (engine->LaunchInfo.ue1Version <= 219 || engine->console->bNoDrawWorld() == false)\n\t{\n\t\tDrawScene();\n"
                "\t\t{ VITA_TIMER(Overlays); RenderOverlays(); }\n"),
     'vita-hudtimers')
edit("Render/RenderSubsystem.cpp",
     re.escape("\tPostRender();\n\n\tDevice->Unlock(true);\n"),
     lambda m: "\t{ VITA_TIMER(Hud); PostRender(); } // vita-hudtimer2\n\n\t{ VITA_TIMER(Unlock); Device->Unlock(true); }\n",
     'vita-hudtimer2')
edit("Render/RenderSubsystem.cpp",
     re.escape('#include "RenderSubsystem.h"\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-hudtimers-inc\n',
     'vita-hudtimers-inc')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tkwMoverLights.clear();\n\t\tKW::DynamicMoverLights(mover, point, normal, kwMoverLights);\n"),
     lambda m: "\t\tkwMoverLights.clear();\n\t\tVITA_PROBE(MoverLights); // vita-moverlights-probe\n\t\tKW::DynamicMoverLights(mover, point, normal, kwMoverLights);\n",
     'vita-moverlights-probe')


# 104. A dynamic mover polygon's nearby dynamic lights came from LightTree.CollectLights (the tree of every light of the level) and
#      then the !bStatic && !bNoDelete filter: VitaCollectDynamic gives the same lights from the short list of exactly those (#40,
#      as the level surfaces use it; same overlap test as the tree's leaves). 'lightmap: dynamic lights' ~20 us a mover polygon.
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t\t\tTempDynLightList.push_back(light);\n\t\t\t}\n\t\t\tLightTree.CollectLights(worldLocation, radius);\n"),
     lambda m: m.group(0).replace("\t\t\tLightTree.CollectLights(worldLocation, radius);\n", "\t\t\tVitaCollectDynamic(worldLocation, radius); // vita-moverdyn\n"),
     'vita-moverdyn')


# 105. GetMoverLightmap worked out the polygon's world placement (objectToWorld, Coords::FromMatrix, and for a dynamic mover
#      brushToWorld, point, normal) every frame for every polygon: kept per polygon while the mover's placement (location, rotation,
#      scale, prepivot; for a non-dynamic mover its BasePos/KeyPos/BaseRot/KeyRot) and the polygon are the same. Same arithmetic.
edit("Light/LightSystem_Light.cpp",
     re.escape("\tmat4 objectToWorld;\n\tif (mover->bDynamicLightMover())\n\t{\n\t\tvec3 moverLocation = mover->Location();\n"),
     lambda m: ("\tmat4 objectToWorld;\n"
                "#ifdef __vita__ // vita-moverxform\n"
                "\tstruct VitaPolyXform\n\t{\n\t\tconst UMover* mover = nullptr; bool dynamic = false; bool valid = false;\n"
                "\t\tvec3 loc, scale, pre, base, normal0, texU, texV; Rotator rot = Rotator(0, 0, 0);\n"
                "\t\tmat4 objectToWorld; Coords worldCoords; vec3 point, normal;\n\t};\n"
                "\tstatic std::unordered_map<const Poly*, VitaPolyXform> vitaXforms;\n"
                "\tVitaPolyXform& vx = vitaXforms[&poly];\n"
                "\t{\n"
                "\t\tconst bool dyn = mover->bDynamicLightMover();\n"
                "\t\tconst vec3 loc = dyn ? mover->Location() : mover->BasePos() + mover->KeyPos()[mover->BrushRaytraceKey()];\n"
                "\t\tconst Rotator rot = dyn ? mover->Rotation() : mover->BaseRot() + mover->KeyRot()[mover->BrushRaytraceKey()];\n"
                "\t\tconst vec3 pre = mover->PrePivot();\n"
                "\t\tif (!vx.valid || vx.mover != mover || vx.dynamic != dyn || !(vx.loc == loc) || vx.rot.Pitch != rot.Pitch || vx.rot.Yaw != rot.Yaw ||\n"
                "\t\t\tvx.rot.Roll != rot.Roll || !(vx.scale == scale) || !(vx.pre == pre) || !(vx.base == poly.Base) || !(vx.normal0 == poly.Normal) ||\n"
                "\t\t\t!(vx.texU == poly.TextureU) || !(vx.texV == poly.TextureV))\n\t\t{\n"
                "\t\t\tvx.valid = true; vx.mover = mover; vx.dynamic = dyn; vx.loc = loc; vx.rot = rot; vx.scale = scale; vx.pre = pre;\n"
                "\t\t\tvx.base = poly.Base; vx.normal0 = poly.Normal; vx.texU = poly.TextureU; vx.texV = poly.TextureV;\n"
                "\t\t\tvx.objectToWorld = mat4::translate(loc) * Coords::Rotation(rot).ToMatrix() * mat4::scale(scale) * mat4::translate(-pre) * localCoords.ToMatrix();\n"
                "\t\t\tvx.worldCoords = Coords::FromMatrix(vx.objectToWorld);\n"
                "\t\t\tif (dyn)\n\t\t\t{\n"
                "\t\t\t\tmat4 brushToWorld = mat4::translate(loc) * Coords::Rotation(rot).ToMatrix() * mat4::scale(scale) * mat4::translate(-pre);\n"
                "\t\t\t\tvx.point = (brushToWorld * vec4(poly.Base, 1.0f)).xyz();\n"
                "\t\t\t\tvx.normal = normalize((brushToWorld * vec4(poly.Normal, 0.0f)).xyz());\n\t\t\t}\n\t\t}\n"
                "\t\tobjectToWorld = vx.objectToWorld;\n\t}\n"
                "\tif (false)\n#endif\n"
                "\tif (mover->bDynamicLightMover())\n\t{\n\t\tvec3 moverLocation = mover->Location();\n"),
     'vita-moverxform')
edit("Light/LightSystem_Light.cpp",
     re.escape("\tCoords worldCoords = Coords::FromMatrix(objectToWorld);\n\n\tif (!mover->Light.Calculated)\n"),
     lambda m: ("#ifdef __vita__ // vita-moverxform-coords\n\tCoords worldCoords = vx.worldCoords;\n#else\n\tCoords worldCoords = Coords::FromMatrix(objectToWorld);\n#endif\n"
                "\n\tif (!mover->Light.Calculated)\n"),
     'vita-moverxform-coords')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tmat4 brushToWorld = mat4::translate(mover->Location()) * Coords::Rotation(mover->Rotation()).ToMatrix() * mat4::scale(scale) * mat4::translate(-mover->PrePivot());\n"
               "\t\tvec3 point = (brushToWorld * vec4(poly.Base, 1.0f)).xyz();\n\t\tvec3 normal = normalize((brushToWorld * vec4(poly.Normal, 0.0f)).xyz());\n"),
     lambda m: ("#ifdef __vita__ // vita-moverxform-kw\n\t\tconst vec3 point = vx.point;\n\t\tconst vec3 normal = vx.normal;\n#else\n" + m.group(0) + "#endif\n"),
     'vita-moverxform-kw')


# 106. GetMoverFogmap built the polygon's world matrix before GetFogmap found the zone has no fog (130 mover polygons a frame in
#      Lev4_Sneak, 5 us each): GetFogmap's own first test, made first.
edit("Light/LightSystem_Fog.cpp",
     re.escape("TextureInfo LightSystem::GetMoverFogmap(UMover* mover, const Poly& poly, UZoneInfo* zoneActor, UModel* model)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-moverfog-early: GetFogmap returns nothing for these\n\tif (!zoneActor || !zoneActor->bFogZone() || poly.BrushPolyIndex < 0)\n\t\treturn {};\n#endif\n",
     'vita-moverfog-early')


# 107. The rest of 'draw game' timed: LightSystem::BeginFrame and the coronas.
edit("Render/RenderScene.cpp",
     re.escape("\tengine->Level->Light.BeginFrame();\n\tTextureFrameCounter++;\n"),
     lambda m: "\t{ VITA_TIMER(LightBegin); engine->Level->Light.BeginFrame(); } // vita-lightbegin-timer\n\tTextureFrameCounter++;\n",
     'vita-lightbegin-timer')
edit("Render/RenderScene.cpp",
     re.escape("\t{ VITA_TIMER(DrawNodes); MainFrame.Draw(); }\n\tMainFrame.DrawCoronas();\n"),
     lambda m: "\t{ VITA_TIMER(DrawNodes); MainFrame.Draw(); }\n\t{ VITA_TIMER(Coronas); MainFrame.DrawCoronas(); } // vita-corona-timer\n",
     'vita-corona-timer')


# 108. Laps in LightSystem::BeginFrame (2.9 ms a frame in Lev4_Sneak).
edit("Light/LightSystem.cpp",
     re.escape("\tFrameCounter++;\n\n\tLightTree.Lights.clear();\n"),
     lambda m: "\tFrameCounter++;\n\tVITA_LAP_START; // vita-beginlaps-start\n\n\tLightTree.Lights.clear();\n",
     'vita-beginlaps-start')
edit("Light/LightSystem.cpp",
     re.escape("\tLightTree.CreateTLAS();\n#ifdef __vita__ // vita-lmskip-frame\n\tif (VitaLightmapSkip())\n\t\tVitaUpdateLightmapDirty();\n#endif\n"),
     lambda m: "\tVITA_LAP(BeginScan); // vita-beginlaps2\n\tLightTree.CreateTLAS();\n\tVITA_LAP(BeginTree);\n#ifdef __vita__ // vita-lmskip-frame\n\tif (VitaLightmapSkip())\n\t\tVitaUpdateLightmapDirty();\n#endif\n\tVITA_LAP(BeginDirty);\n",
     'vita-beginlaps2')
edit("Light/LightSystem.cpp",
     re.escape('#include "VitaStats.h" // vita-lsstatsinc\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-beginlaps-inc\n',
     'vita-beginlaps-inc')


# 109. The light tree was built again every frame while any light moved (Lev4_Sneak: one of 8 dynamic lights; 'light begin: tree'
#      1.9 ms of ~700 lights). Now the tree holds the fixed lights (bStatic or bNoDelete: those never move), built again only when
#      they change; the others are tested one by one in CollectLights with the test the tree's leaves make (the light's box grown
#      by 0.1 against the sphere). The same lights are found (fixed ones first). Version still goes up on any change.
edit("Light/LightActorTree.h",
     re.escape("\tunsigned Version = 0; // vita-lcversion-h: goes up every time the tree is built again\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-tree-fixed-h\n"
                             "\tstd::vector<char> VitaFixed;          // per light of Lights: bStatic or bNoDelete\n"
                             "\tstd::vector<UActor*> VitaFixedFor;    // the Lights those flags are for\n"
                             "\tstd::vector<int> VitaMoving;          // indices of the other lights\n"
                             "\tstd::vector<vec3> VitaMovingLocs, VitaFixedLocs;\n"
                             "\tstd::vector<float> VitaMovingRadii, VitaFixedRadii;\n"
                             "#endif\n"),
     'vita-tree-fixed-h')
edit("Light/LightActorTree.cpp",
     re.escape("\t// ...and keep the tree when nothing it was built from changed (most lights never move)\n"),
     lambda m: ("#ifdef __vita__ // vita-tree-fixed\n"
                "\tif (VitaFixedFor != Lights)\n\t{\n"
                "\t\tVitaFixed.resize(lightCount);\n"
                "\t\tfor (int i = 0; i < lightCount; i++)\n\t\t\tVitaFixed[i] = (Lights[i]->bStatic() || Lights[i]->bNoDelete()) ? 1 : 0;\n"
                "\t\tVitaFixedFor = Lights;\n\t\tTLAS.Root = -1; // a new list of lights: build\n\t}\n"
                "\tVitaMoving.clear();\n"
                "\tstd::vector<vec3> movingLocs;\n\tstd::vector<float> movingRadii;\n"
                "\tstatic std::vector<vec3> fixedLocs;\n\tstatic std::vector<float> fixedRadii;\n"
                "\tfixedLocs.clear();\n\tfixedRadii.clear();\n"
                "\tfor (int i = 0; i < lightCount; i++)\n\t{\n"
                "\t\tif (VitaFixed[i])\n\t\t{\n\t\t\tfixedLocs.push_back(Scratch.locs[i]);\n\t\t\tfixedRadii.push_back(Scratch.radii[i]);\n\t\t}\n"
                "\t\telse\n\t\t{\n\t\t\tVitaMoving.push_back(i);\n\t\t\tmovingLocs.push_back(Scratch.locs[i]);\n\t\t\tmovingRadii.push_back(Scratch.radii[i]);\n\t\t}\n\t}\n"
                "\tif (!SameData(VitaMovingLocs, movingLocs) || !SameData(VitaMovingRadii, movingRadii))\n\t{\n"
                "\t\tVersion++; // a moving light moved: lists made from the lights are old\n"
                "\t\tVitaMovingLocs.swap(movingLocs);\n\t\tVitaMovingRadii.swap(movingRadii);\n\t}\n"
                "\tif (TLAS.Root != -1 && SameData(VitaFixedLocs, fixedLocs) && SameData(VitaFixedRadii, fixedRadii))\n\t\treturn;\n"
                "\tVersion++;\n\tVitaStats::lightTreeBuilds++;\n"
                "\tVitaFixedLocs = fixedLocs;\n\tVitaFixedRadii = fixedRadii;\n"
                "\tScratch.leafs.clear();\n\tScratch.centroids.clear();\n"
                "\tfor (int i = 0; i < lightCount; i++)\n\t{\n"
                "\t\tScratch.centroids.push_back(vec4(Scratch.locs[i], 1.0f));   // indexed by light (Subdivide's instances)\n"
                "\t\tif (VitaFixed[i])\n\t\t\tScratch.leafs.push_back(i);\n\t}\n"
                "\tif (Scratch.workbuffer.size() < (size_t)lightCount * 2)\n\t\tScratch.workbuffer.resize((size_t)lightCount * 2);\n"
                "\tTLAS.Nodes.clear();\n"
                "\tTLAS.Root = Scratch.leafs.empty() ? -1 : Subdivide(Scratch.leafs.data(), (int)Scratch.leafs.size(), Scratch.centroids.data(), Scratch.workbuffer.data());\n"
                "\tif (TLAS.Root == -1)\n\t\tTLAS.Root = -2; // nothing fixed: built (empty)\n"
                "\treturn;\n#endif\n" + m.group(0)),
     'vita-tree-fixed')
edit("Light/LightActorTree.cpp",
     re.escape("\tCollectedLights.clear();\n\tif (TLAS.Root != -1)\n\t\tCollectLights(center, radius, TLAS.Root);\n}\n"),
     lambda m: ("\tCollectedLights.clear();\n"
                "#ifdef __vita__ // vita-tree-collect\n"
                "\tif (TLAS.Root >= 0)\n\t{\n"
                "\t\tconst Node& root = TLAS.Nodes[TLAS.Root];\n"
                "\t\t// a tree of one light is a leaf the walk does not test: test it as every other leaf\n"
                "\t\tif (!root.IsLeaf() || TestSphereAABB(center, radius, root.aabb.min, root.aabb.max) == OverlapResult::overlap)\n"
                "\t\t\tCollectLights(center, radius, TLAS.Root);\n\t}\n"
                "\tfor (size_t k = 0; k < VitaMoving.size(); k++)\n\t{\n"
                "\t\tconst vec3 l = VitaMovingLocs[k];\n\t\tconst float r = VitaMovingRadii[k];\n"
                "\t\tconst vec3 lo(l.x - r - 0.1f, l.y - r - 0.1f, l.z - r - 0.1f), hi(l.x + r + 0.1f, l.y + r + 0.1f, l.z + r + 0.1f);\n"
                "\t\tif (TestSphereAABB(center, radius, lo, hi) == OverlapResult::overlap)\n\t\t\tCollectedLights.push_back(Lights[VitaMoving[k]]);\n\t}\n"
                "\treturn;\n#endif\n"
                "\tif (TLAS.Root != -1)\n\t\tCollectLights(center, radius, TLAS.Root);\n}\n"),
     'vita-tree-collect')


# 110. 'engine' (outside the picture) was ~4 ms more than level tick + console + audio in Lev4_Sneak: the rest of Engine::Run timed
#      (VitaTimers::Add: a measured span into a section).
edit("Engine.cpp",
     re.escape("\t\t// Update the time fields\n\t\tstd::time_t now = std::time(nullptr);\n"),
     lambda m: "\t\t// Update the time fields\n\t\tdouble vitaT0 = VitaTimers::Now(); // vita-looprest\n\t\tstd::time_t now = std::time(nullptr);\n",
     'vita-looprest')
edit("Engine.cpp",
     re.escape("\t\tUpdateInput(realTimeElapsed);\n\t\tif (LaunchInfo.IsHarryPotter1())\n\t\t{\n\t\t\tHP1::BeginModsFrame(realTimeElapsed);\n\t\t\tlevelElapsed *= HP1::ModsTimeScale();\n\t\t}\n"),
     lambda m: ("\t\tVitaTimers::Add(VitaTimers::LoopRest, vitaT0); vitaT0 = VitaTimers::Now(); // vita-inputtimer\n" + m.group(0) +
                "\t\tVitaTimers::Add(VitaTimers::Input, vitaT0);\n"),
     'vita-inputtimer')
edit("Engine.cpp",
     re.escape("\t\t\tif (step == 0 && LaunchInfo.IsKnowWonder())\n\t\t\t\tHP1::TickMods(realTimeElapsed);\n"),
     lambda m: "\t\t\tif (step == 0 && LaunchInfo.IsKnowWonder())\n\t\t\t{ VITA_TIMER(Mods); HP1::TickMods(realTimeElapsed); } // vita-modstimer\n",
     'vita-modstimer')
edit("Engine.cpp",
     re.escape("\t\t\tif (LaunchInfo.IsKnowWonder() && viewport->Actor())\n\t\t\t\tCallEvent(viewport->Actor(), \"ViewFlash\""),
     lambda m: "\t\t\tVITA_TIMER(ViewFlash); // vita-flashtimer (to the end of the step)\n" + m.group(0),
     'vita-flashtimer')
edit("Engine.cpp",
     re.escape("\t\tCalcView();\n\n\t\t{ VITA_TIMER(Audio); UpdateAudio(); }"),
     lambda m: "\t\t{ VITA_TIMER(ViewFlash); CalcView(); } // vita-calcviewtimer\n\n\t\t{ VITA_TIMER(Audio); UpdateAudio(); }",
     'vita-calcviewtimer')


# 111. Probes in KW::MultiLineCheck (the walking physics' traces; Snail physics 4.5 ms for 9 snails in Lev2_Fire1).
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-checkprobe-inc\n',
     'vita-checkprobe-inc')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape("\t\t\tworld.Time = 1.0f;\n\t\t\tif (!ModelLineCheck(world, ModelFrame::Level(engine->Level->Model), end, start, extent, extraNodeFlags))\n"),
     lambda m: "\t\t\tworld.Time = 1.0f;\n\t\t\tbool vitaWorldHit;\n\t\t\t{ VITA_PROBE(CheckWorld); vitaWorldHit = !ModelLineCheck(world, ModelFrame::Level(engine->Level->Model), end, start, extent, extraNodeFlags); } // vita-checkprobe-world\n\t\t\tif (vitaWorldHit)\n",
     'vita-checkprobe-world')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape("\t\tif (traceActors || levelInfo)\n\t\t{\n\t\t\tfor (CheckResult& hit : ActorLineCheck(end, start, extent, extraNodeFlags))\n"),
     lambda m: "\t\tif (traceActors || levelInfo)\n\t\t{\n\t\t\tVITA_PROBE(CheckActors); // vita-checkprobe-actors\n\t\t\tfor (CheckResult& hit : ActorLineCheck(end, start, extent, extraNodeFlags))\n",
     'vita-checkprobe-actors')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape("\t\tArray<CheckResult> results;\n\t\tvec3 boxMin(std::min(start.x, end.x), std::min(start.y, end.y), std::min(start.z, end.z));\n\t\tvec3 boxMax(std::max(start.x, end.x), std::max(start.y, end.y), std::max(start.z, end.z));\n\t\tfor (UActor* actor : Hash().ActorsInBox(boxMin - extent, boxMax + extent))\n\t\t{\n\t\t\tif (!InHash(actor))\n\t\t\t\tcontinue;\n\t\t\tCheckResult hit;\n\t\t\thit.Time = 0.0f;\n\t\t\tif (!PrimitiveLineCheck(hit, actor, end, start, extent, extraNodeFlags))\n"),
     lambda m: ("\t\tArray<CheckResult> results;\n\t\tvec3 boxMin(std::min(start.x, end.x), std::min(start.y, end.y), std::min(start.z, end.z));\n\t\tvec3 boxMax(std::max(start.x, end.x), std::max(start.y, end.y), std::max(start.z, end.z));\n"
                "\t\tArray<UActor*> vitaInBox;\n\t\t{ VITA_PROBE(CheckHash); vitaInBox = Hash().ActorsInBox(boxMin - extent, boxMax + extent); } // vita-checkprobe-hash\n"
                "\t\tfor (UActor* actor : vitaInBox)\n\t\t{\n\t\t\tif (!InHash(actor))\n\t\t\t\tcontinue;\n\t\t\tCheckResult hit;\n\t\t\thit.Time = 0.0f;\n"
                "\t\t\tbool vitaMiss;\n\t\t\t{ VITA_PROBE(CheckPrims); vitaMiss = PrimitiveLineCheck(hit, actor, end, start, extent, extraNodeFlags); }\n\t\t\tif (!vitaMiss)\n"),
     'vita-checkprobe-hash')


# 112. CollisionSystem::ActorsInBox dropped an actor seen in two hash cells with std::find over the result (quadratic; the snails
#      and their dozens of SnailTrailColObj share cells): a per-actor stamp instead. Same actors, same order.
edit("Packages/Engine/Actors/UActor.h",
     re.escape("\t\tint CheckCounter = -1;\n\t} Collision;\n"),
     lambda m: "\t\tint CheckCounter = -1;\n\t\tuint32_t VitaBoxStamp = 0; // vita-boxstamp-h: CollisionSystem::ActorsInBox's last query that took it\n\t} Collision;\n",
     'vita-boxstamp-h')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape("\t\t\t\tfor (UActor* actor : it->second)\n\t\t\t\t{\n\t\t\t\t\tif (std::find(result.begin(), result.end(), actor) == result.end())\n\t\t\t\t\t\tresult.push_back(actor);\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n\treturn result;\n}\n"),
     lambda m: ("\t\t\t\tfor (UActor* actor : it->second)\n\t\t\t\t{\n"
                "#ifdef __vita__ // vita-boxstamp\n"
                "\t\t\t\t\tif (actor->Collision.VitaBoxStamp != vitaStamp)\n\t\t\t\t\t{\n\t\t\t\t\t\tactor->Collision.VitaBoxStamp = vitaStamp;\n\t\t\t\t\t\tresult.push_back(actor);\n\t\t\t\t\t}\n"
                "#else\n"
                "\t\t\t\t\tif (std::find(result.begin(), result.end(), actor) == result.end())\n\t\t\t\t\t\tresult.push_back(actor);\n"
                "#endif\n"
                "\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n\treturn result;\n}\n"),
     'vita-boxstamp')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape("\tif (end.x - start.x >= 100 || end.y - start.y >= 100 || end.z - start.z >= 100)\n\t\treturn result;\n\tfor (int z = start.z; z < end.z; z++)\n"),
     lambda m: (m.group(0).replace("\tfor (int z = start.z; z < end.z; z++)\n", "") +
                "#ifdef __vita__ // vita-boxstamp-next\n\tstatic uint32_t vitaStamp = 0;\n\tif (++vitaStamp == 0)\n\t\tvitaStamp = 1;\n\tresult.reserve(16);\n#endif\n"
                "\tfor (int z = start.z; z < end.z; z++)\n"),
     'vita-boxstamp-next')


# 113. The BSP collision of the level (KW::ModelLineCheck/PointCheck with an extent, every walking step of every pawn): each
#      leaf hull touched was loaded again (its planes through the frame) and its bevel planes worked out again (every pair of
#      planes x 3 axes: crosses, plane intersections) on every check, for geometry that never moves. For the level (an
#      untransformed frame) the hull and its bevel list are kept per collision bound; the tests run in the same order on the
#      same numbers (Lev2_Fire1: 'check: world' 23.6 us a sweep, 116 a frame).
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape("\t\tbevel = vec4(normal, dot(point, normal));\n\t\treturn true;\n\t}\n"),
     lambda m: (m.group(0) +
                "\n#ifdef __vita__ // vita-hullcache\n"
                "\t// A level hull and its bevel planes in the order TestLeaf meets them (i = 1.., j < i, axis 0..2)\n"
                "\tstruct VitaCachedHull\n\t{\n\t\tLeafHull Hull;\n\t\tstd::vector<vec4> Bevels;\n\t};\n"
                "\tstatic const VitaCachedHull* VitaLevelHull(const ModelFrame& frame, int node)\n\t{\n"
                "\t\tstatic UModel* cachedModel = nullptr;\n"
                "\t\tstatic std::unordered_map<int, std::unique_ptr<VitaCachedHull>> cache;\n"
                "\t\tif (frame.Model != cachedModel)\n\t\t{\n\t\t\tcache.clear();\n\t\t\tcachedModel = frame.Model;\n\t\t}\n"
                "\t\tconst int bound = frame.Model->Nodes[node].CollisionBound;\n"
                "\t\tif (bound == -1)\n\t\t\treturn nullptr;\n"
                "\t\tstd::unique_ptr<VitaCachedHull>& entry = cache[bound];\n"
                "\t\tif (!entry)\n\t\t{\n"
                "\t\t\tentry = std::make_unique<VitaCachedHull>();\n"
                "\t\t\tLoadHull(entry->Hull, frame, node);\n"
                "\t\t\tconst LeafHull& hull = entry->Hull;\n"
                "\t\t\tfor (int i = 1; i < hull.Count; i++)\n\t\t\t\tfor (int j = 0; j < i; j++)\n\t\t\t\t\tfor (int axis = 0; axis < 3; axis++)\n\t\t\t\t\t{\n"
                "\t\t\t\t\t\tvec4 bevel;\n\t\t\t\t\t\tif (BevelPlane(hull, i, j, axis, bevel))\n\t\t\t\t\t\t\tentry->Bevels.push_back(bevel);\n\t\t\t\t\t}\n"
                "\t\t}\n\t\treturn entry.get();\n\t}\n#endif\n"),
     'vita-hullcache')
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape("\t\tvoid TestLeaf(int node)\n\t\t{\n\t\t\tif (!LoadHull(Hull, *Frame, node))\n\t\t\t\treturn;\n"),
     lambda m: ("\t\tvoid TestLeaf(int node)\n\t\t{\n"
                "#ifdef __vita__ // vita-hullcache-sweep\n"
                "\t\t\tif (!Frame->Transformed)\n\t\t\t{\n"
                "\t\t\t\tconst VitaCachedHull* cached = VitaLevelHull(*Frame, node);\n"
                "\t\t\t\tif (!cached)\n\t\t\t\t\treturn;\n"
                "\t\t\t\tconst LeafHull& hull = cached->Hull;\n"
                "\t\t\t\tT0 = -1.0f;\n\t\t\t\tT1 = Hit->Time;\n\t\t\t\tBestNormal = vec3(0.0f);\n\t\t\t\tBestItem = node;\n"
                "\t\t\t\tfor (int i = 0; i < hull.Count; i++)\n\t\t\t\t\tif (!Clip(hull.Planes[i], hull.Nodes[i]))\n\t\t\t\t\t\treturn;\n"
                "\t\t\t\tvec4 box[6];\n\t\t\t\tHullBoxPlanes(hull, box);\n"
                "\t\t\t\tfor (int i = 0; i < 6; i++)\n\t\t\t\t\tif (!Clip(box[i], -1))\n\t\t\t\t\t\treturn;\n"
                "\t\t\t\tfor (const vec4& bevel : cached->Bevels)\n\t\t\t\t\tif (!Clip(bevel, -1))\n\t\t\t\t\t\treturn;\n"
                "\t\t\t\tif (T0 > -1.0f && T0 < T1 && T1 > 0.0f)\n\t\t\t\t{\n"
                "\t\t\t\t\tHit->Time = T0;\n\t\t\t\t\tHit->Normal = BestNormal;\n\t\t\t\t\tHit->Actor = Frame->Owner;\n"
                "\t\t\t\t\tHit->Model = Frame->Model;\n\t\t\t\t\tHit->Item = BestItem;\n\t\t\t\t\tHitSomething = true;\n\t\t\t\t}\n"
                "\t\t\t\treturn;\n\t\t\t}\n#endif\n"
                "\t\t\tif (!LoadHull(Hull, *Frame, node))\n\t\t\t\treturn;\n"),
     'vita-hullcache-sweep')
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape("\t\tbool TestLeaf(int node)\n\t\t{\n\t\t\tif (!LoadHull(Hull, *Frame, node))\n\t\t\t\treturn true;\n"),
     lambda m: ("\t\tbool TestLeaf(int node)\n\t\t{\n"
                "#ifdef __vita__ // vita-hullcache-point\n"
                "\t\t\tif (!Frame->Transformed)\n\t\t\t{\n"
                "\t\t\t\tconst VitaCachedHull* cached = VitaLevelHull(*Frame, node);\n"
                "\t\t\t\tif (!cached)\n\t\t\t\t\treturn true;\n"
                "\t\t\t\tconst LeafHull& hull = cached->Hull;\n"
                "\t\t\t\tfor (int i = 0; i < hull.Count; i++)\n\t\t\t\t\tif (!Test(hull.Planes[i], hull.Nodes[i]))\n\t\t\t\t\t\treturn true;\n"
                "\t\t\t\tvec4 box[6];\n\t\t\t\tHullBoxPlanes(hull, box);\n"
                "\t\t\t\tfor (int i = 0; i < 6; i++)\n\t\t\t\t\tif (!Test(box[i], -1))\n\t\t\t\t\t\treturn true;\n"
                "\t\t\t\tfor (const vec4& bevel : cached->Bevels)\n\t\t\t\t\tif (!Test(bevel, -1))\n\t\t\t\t\t\treturn true;\n"
                "\t\t\t\treturn false;\n\t\t\t}\n#endif\n"
                "\t\t\tif (!LoadHull(Hull, *Frame, node))\n\t\t\t\treturn true;\n"),
     'vita-hullcache-point')
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include <unordered_map> // vita-hullcache-inc\n#include <memory>\n',
     'vita-hullcache-inc')


# 114. MultiLineCheck sorted its hits with std::stable_sort (a temporary buffer from the heap, and newlib's malloc locks) on every
#      check: a stable insertion sort for up to 32 hits (the same order), std::stable_sort beyond.
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape("\t\tstd::stable_sort(results.begin(), results.end(), [](const CheckResult& a, const CheckResult& b) { return a.Time < b.Time; });\n\t\treturn results;\n"),
     lambda m: ("#ifdef __vita__ // vita-hitsort\n"
                "\t\tif (results.size() <= 32)\n\t\t{\n"
                "\t\t\tfor (size_t i = 1; i < results.size(); i++)\n\t\t\t{\n"
                "\t\t\t\tCheckResult item = results[i];\n\t\t\t\tsize_t k = i;\n"
                "\t\t\t\twhile (k > 0 && item.Time < results[k - 1].Time)\n\t\t\t\t{\n\t\t\t\t\tresults[k] = results[k - 1];\n\t\t\t\t\tk--;\n\t\t\t\t}\n"
                "\t\t\t\tresults[k] = item;\n\t\t\t}\n\t\t\treturn results;\n\t\t}\n#endif\n" + m.group(0)),
     'vita-hitsort')


# 115. Probes in KW::UpdateActorShadows ('process: shadows' 5.5 ms in Lev2_Fire1, 2 calls a frame: the main view and the sky's).
edit("../../knowwonder/KWActorRender.cpp",
     re.escape("#ifdef __vita__ // vita-shadowskip\n\t\t\tif (VitaShadowSkip(actor, shadow))\n\t\t\t\tcontinue;\n#endif\n\t\t\tCallEvent(shadow, NameString(\"Update\"), { ExpressionValue::ObjectValue(nullptr) });\n"),
     lambda m: ("#ifdef __vita__ // vita-shadowskip\n\t\t\tbool vitaSkip;\n\t\t\t{ VITA_PROBE(ShadowSkipped); vitaSkip = VitaShadowSkip(actor, shadow); } // vita-shadowprobes\n"
                "\t\t\tif (vitaSkip)\n\t\t\t\tcontinue;\n#endif\n"
                "\t\t\tVITA_PROBE(ShadowUpdate);\n\t\t\tCallEvent(shadow, NameString(\"Update\"), { ExpressionValue::ObjectValue(nullptr) });\n"),
     'vita-shadowprobes')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-shadowprobes-inc\n',
     'vita-shadowprobes-inc')


# 116. UDecal::AttachDecal clipped the decal's quad against EVERY BSP node of the hit plane (a floor: a long chain of coplanar
#      nodes), with vector inserts and erases per edge: ActorShadow.Update 211 us each, 17 a frame in Lev2_Fire1. A node whose
#      polygon's bounding box does not meet the quad's (both on the same plane) clips to nothing: skipped before the clipping.
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape("\t\t// Clip to BSP node shape\n\t\tint vertCount = (int)positions.size();\n\t\tBspVert* v = &model->Vertices[polynode->VertPool];\n"),
     lambda m: ("#ifdef __vita__ // vita-decalreject: the node's polygon box against the quad's box\n"
                "\t\t{\n"
                "\t\t\tvec3 qmin = positions[0], qmax = positions[0];\n"
                "\t\t\tfor (const vec3& p : positions)\n\t\t\t{\n"
                "\t\t\t\tqmin = vec3(std::min(qmin.x, p.x), std::min(qmin.y, p.y), std::min(qmin.z, p.z));\n"
                "\t\t\t\tqmax = vec3(std::max(qmax.x, p.x), std::max(qmax.y, p.y), std::max(qmax.z, p.z));\n\t\t\t}\n"
                "\t\t\tconst BspVert* pv = &model->Vertices[polynode->VertPool];\n"
                "\t\t\tbool vitaMiss = polynode->NumVertices > 0;\n"
                "\t\t\tif (vitaMiss)\n\t\t\t{\n"
                "\t\t\t\tvec3 nmin = model->Points[pv[0].Vertex], nmax = nmin;\n"
                "\t\t\t\tfor (int k = 1; k < polynode->NumVertices; k++)\n\t\t\t\t{\n"
                "\t\t\t\t\tconst vec3& p = model->Points[pv[k].Vertex];\n"
                "\t\t\t\t\tnmin = vec3(std::min(nmin.x, p.x), std::min(nmin.y, p.y), std::min(nmin.z, p.z));\n"
                "\t\t\t\t\tnmax = vec3(std::max(nmax.x, p.x), std::max(nmax.y, p.y), std::max(nmax.z, p.z));\n\t\t\t\t}\n"
                "\t\t\t\tconst float e = 0.5f; // margin: a box that only touches still goes to the clipping\n"
                "\t\t\t\tvitaMiss = qmax.x < nmin.x - e || qmin.x > nmax.x + e || qmax.y < nmin.y - e || qmin.y > nmax.y + e ||\n"
                "\t\t\t\t\tqmax.z < nmin.z - e || qmin.z > nmax.z + e;\n\t\t\t}\n"
                "\t\t\tif (vitaMiss)\n\t\t\t{\n"
                "\t\t\t\tif (polynode->Plane < 0)\n\t\t\t\t\tbreak;\n"
                "\t\t\t\tpolynode = &model->Nodes[polynode->Plane];\n"
                "\t\t\t\tcontinue;\n\t\t\t}\n"
                "\t\t}\n#endif\n" + m.group(0)),
     'vita-decalreject')


# 117. Probes in UDecal (ActorShadow.Update ~200 us each).
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape('#include "UDecal.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-decalprobe-inc\n',
     'vita-decalprobe-inc')
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape("UObject* UDecal::AttachDecal(float traceDistance, vec3 decalDir)\n{\n"),
     lambda m: m.group(0) + "\tVITA_PROBE(DecalAttach); // vita-decalprobe-attach\n",
     'vita-decalprobe-attach')
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape("\tCollisionHitList hits = XLevel()->Collision.TraceDecal(to_dvec3(Location()), 0.0f, to_dvec3(traceDirection), traceDistance, false);\n"),
     lambda m: "\tCollisionHitList hits;\n\t{ VITA_PROBE(DecalTrace); hits = XLevel()->Collision.TraceDecal(to_dvec3(Location()), 0.0f, to_dvec3(traceDirection), traceDistance, false); } // vita-decalprobe-trace\n",
     'vita-decalprobe-trace')
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape("void UDecal::DetachDecal()\n{\n"),
     lambda m: m.group(0) + "\tVITA_PROBE(DecalDetach); // vita-decalprobe-detach\n",
     'vita-decalprobe-detach')


# 118. KW::UpdateActorShadows ran over every actor of the level twice a frame (the main view and the sky's), reading Actor.Shadow
#      of each (~0.85 ms a pass in Lev2_Fire1): the (actor, shadow) pairs are gathered once per frame (actor and shadow present and
#      not bDeleteMe; nothing in between changes Actor.Shadow) and both passes go through them in the same order.
edit("../../knowwonder/KWActorRender.cpp",
     re.escape("\t\tauto& actors = engine->Level->Actors;\n\t\tfor (size_t i = 0; i < actors.size(); i++)\n\t\t{\n\t\t\tUActor* actor = actors[i];\n\t\t\tif (!actor || actor->bDeleteMe())\n\t\t\t\tcontinue;\n\t\t\tUActor* shadow = Shadow(actor);\n\t\t\tif (!shadow || shadow->bDeleteMe())\n\t\t\t\tcontinue;\n"),
     lambda m: ("#ifdef __vita__ // vita-shadowpairs\n"
                "\t\tstatic std::vector<std::pair<UActor*, UActor*>> vitaPairs;\n"
                "\t\tstatic unsigned vitaPairsFrame = ~0u;\n"
                "\t\tstatic void* vitaPairsLevel = nullptr;\n"
                "\t\tif (vitaPairsFrame != VitaTimers::frameNumber || vitaPairsLevel != engine->Level)\n\t\t{\n"
                "\t\t\tvitaPairsFrame = VitaTimers::frameNumber;\n\t\t\tvitaPairsLevel = engine->Level;\n\t\t\tvitaPairs.clear();\n"
                "\t\t\tfor (UActor* actor : engine->Level->Actors)\n\t\t\t{\n"
                "\t\t\t\tif (!actor || actor->bDeleteMe())\n\t\t\t\t\tcontinue;\n"
                "\t\t\t\tUActor* shadow = Shadow(actor);\n"
                "\t\t\t\tif (shadow)\n\t\t\t\t\tvitaPairs.push_back({ actor, shadow });\n\t\t\t}\n\t\t}\n"
                "\t\tfor (size_t i = 0; i < vitaPairs.size(); i++)\n\t\t{\n"
                "\t\t\tUActor* actor = vitaPairs[i].first;\n\t\t\tUActor* shadow = vitaPairs[i].second;\n"
                "\t\t\tif (actor->bDeleteMe() || shadow->bDeleteMe())\n\t\t\t\tcontinue;\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-shadowpairs')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('#include "VitaProbes.h" // vita-shadowprobes-inc\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-shadowpairs-inc\n',
     'vita-shadowpairs-inc')


# 119. Lev4_Sneak (the user): Harry and the camera moved 'like in a boss fight' (snappy) from the level start. Flipendo's free-cam
#      mod wraps HarryPotter.Harry's PlayerWalking/playeraiming PlayerTick and BaseCam's Standardstate. The player there is
#      Hub4.InvisibleHarry, which overrides PlayerWalking.PlayerTick (Super.PlayerTick + its opacity): events went to that override,
#      whose Super call reaches Harry's original, so the mod's movement half never ran while its camera half did. Now the PlayerTick
#      overrides of the player's own class chain below Harry are wrapped too, and the handler calls the original of the player's
#      class (its Super still reaches Harry's unwrapped original: the mod runs once). A Flipendo bug (retail packages as well).
FREECAM = "../../hp1/mods/FreeCamera.cpp"
edit(FREECAM,
     re.escape("\t\tvoid NWalkingPlayerTick(UObject* self, ExpressionValue* args) { PlayerTick(self, args, WalkingPlayerTick, false); }\n"
               "\t\tvoid NAimingPlayerTick(UObject* self, ExpressionValue* args) { PlayerTick(self, args, AimingPlayerTick, true); }\n"),
     lambda m: ("#ifdef __vita__ // vita-freecam-sub\n"
                "\t\t// The PlayerTick overrides of Harry's subclasses (Hub4.InvisibleHarry), wrapped too: the original of the nearest class\n"
                "\t\tstd::unordered_map<UClass*, UFunction*> SubWalking, SubAiming;\n"
                "\t\tstd::unordered_set<UClass*> SubSeen;\n"
                "\t\tUFunction* OriginalFor(UObject* self, const std::unordered_map<UClass*, UFunction*>& subs, UFunction* base)\n\t\t{\n"
                "\t\t\tfor (UClass* c = self->Class; c && c != HarryClass; c = static_cast<UClass*>(c->BaseStruct))\n\t\t\t{\n"
                "\t\t\t\tauto it = subs.find(c);\n\t\t\t\tif (it != subs.end())\n\t\t\t\t\treturn it->second;\n\t\t\t}\n"
                "\t\t\treturn base;\n\t\t}\n"
                "\t\tvoid NWalkingPlayerTick(UObject* self, ExpressionValue* args) { PlayerTick(self, args, OriginalFor(self, SubWalking, WalkingPlayerTick), false); }\n"
                "\t\tvoid NAimingPlayerTick(UObject* self, ExpressionValue* args) { PlayerTick(self, args, OriginalFor(self, SubAiming, AimingPlayerTick), true); }\n"
                "\t\tvoid WrapPlayerSubclass()\n\t\t{\n"
                "\t\t\tUPlayerPawn* player = engine->viewport ? engine->viewport->Actor() : nullptr;\n"
                "\t\t\tif (!player || !HarryClass || player->Class == HarryClass || !player->IsA(HarryClass->Name))\n\t\t\t\treturn;\n"
                "\t\t\tfor (UClass* c = player->Class; c && c != HarryClass; c = static_cast<UClass*>(c->BaseStruct))\n\t\t\t{\n"
                "\t\t\t\tif (!SubSeen.insert(c).second)\n\t\t\t\t\tcontinue;\n"
                "\t\t\t\tif (UFunction* original = WrapScriptFunction(c, \"PlayerWalking\", \"PlayerTick\", &NWalkingPlayerTick))\n\t\t\t\t\tSubWalking[c] = original;\n"
                "\t\t\t\tif (UFunction* original = WrapScriptFunction(c, \"playeraiming\", \"PlayerTick\", &NAimingPlayerTick))\n\t\t\t\t\tSubAiming[c] = original;\n"
                "\t\t\t}\n\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-freecam-sub')
edit(FREECAM,
     re.escape("\t\tcls = engine->packages->FindClass(\"HPBase.BaseCam\");\n\t\tif (cls && cls != CameraClass)\n"),
     lambda m: "#ifdef __vita__ // vita-freecam-subcall\n\t\tWrapPlayerSubclass();\n#endif\n" + m.group(0),
     'vita-freecam-subcall')
edit(FREECAM,
     re.escape('#include "VM/Frame.h"\n'),
     lambda m: m.group(0) + '#include <unordered_map> // vita-freecam-inc\n#include <unordered_set>\n',
     'vita-freecam-inc')


# 120. Chamber of Secrets (flipendo2, ~/flipendo2): HP2 starts with Game.exe's front end (New Game / Load Game in six save slots,
#      Options), which Flipendo draws in a SurrealWidgets window. The Vita has no windows: flipendo2's VitaHP2FrontEnd.cpp draws it
#      on the screen and gives back the same choice (HP2::VitaFrontEnd, weak: the HP1 app links without it). And --saveslot=<n>
#      (Game.exe's -SAVESLOT=<n> second run, Core.dll's appInit) points the save folder at Slot<n> without the front end, for
#      automated runs (with --loadgame=0 it loads the slot's save, with --url=PrivetDr.unr it is a new game in it).
HP2FE = "../../hp2/HP2FrontEnd.cpp"
edit(HP2FE,
     re.escape("\t// IDA Game.exe: not exported: _WinMain@16"),
     lambda m: ("#ifdef __vita__ // vita-hp2-fe-decl\n"
                "\t// flipendo2's front end (VitaHP2FrontEnd.cpp): false when the player quits\n"
                "\tbool VitaFrontEnd(bool& newGame, int& slot) __attribute__((weak));\n\n"
                "\t// Game.exe's -SAVESLOT=<n> (appInit makes SavePath\\Slot<n> the save folder) as --saveslot=<n>, for automated runs\n"
                "\tbool VitaUseSaveSlot()\n\t{\n"
                "\t\tint slot = std::atoi(commandline->GetArg(\"\", \"--saveslot\", \"0\").c_str());\n"
                "\t\tif (slot < 1 || slot > 6)\n\t\t\treturn false;\n"
                "\t\tfs::path folder = engine->packages->GetSaveFolderPath() / (\"Slot\" + std::to_string(slot));\n"
                "\t\tstd::error_code ec;\n\t\tfs::create_directories(folder, ec);\n"
                "\t\tengine->packages->SetSaveFolderPath(folder);\n"
                "\t\tLogMessage(\"Save Slot Path: \" + folder.string());\n"
                "\t\treturn true;\n\t}\n#endif\n\n" + m.group(0)),
     'vita-hp2-fe-decl')
edit(HP2FE,
     r"\t\tauto window = std::make_unique<FrontEndWindow>\(\);\n(?:[^\n]*\n)*?\t\twindow\.reset\(\);\n",
     lambda m: ("#ifdef __vita__ // vita-hp2-fe-call\n"
                "\t\tbool finished = false, newGame = false;\n\t\tint slot = 0;\n"
                "\t\tif (VitaFrontEnd)\n\t\t\tfinished = VitaFrontEnd(newGame, slot);\n"
                "\t\telse\n\t\t\tLogMessage(\"HP2 front end: not in this app\");\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-hp2-fe-call')
edit("Engine.cpp",
     re.escape("\tif (LaunchInfo.IsHarryPotter2() && LaunchInfo.url.empty() && !HP2::RunFrontEnd())\n"),
     lambda m: ("#ifdef __vita__ // vita-hp2-saveslot\n"
                "\tif (LaunchInfo.IsHarryPotter2() && !HP2::VitaUseSaveSlot() && LaunchInfo.url.empty() && !HP2::RunFrontEnd())\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-hp2-saveslot')
edit("../../hp2/HP2.h",
     re.escape("\tbool RunFrontEnd();\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-hp2-saveslot-decl\n\tbool VitaUseSaveSlot();\n#endif\n",
     'vita-hp2-saveslot-decl')


# 121. std::filesystem::copy_file makes an empty file on the Vita (newlib): HP2's save picture (Save0.bmp, so the front end showed
#      no picture) and its persistent actor cache (the hubs as they were at a save) were copied as 0 bytes. VitaFile.h copies.
for rel in ("../../knowwonder/KWSave.cpp", "../../hp2/HP2Persist.cpp"):
    edit(rel, r"\bfs::copy_file\(", "VITA_COPY_FILE(", "VITA_COPY_FILE(")
    edit(rel, r'(#include "Precomp\.h"\n)',
         lambda m: m.group(1) + ('#ifdef __vita__ // vita-copyfile\n#include "VitaFile.h"\n#define VITA_COPY_FILE VitaCopyFile\n'
                                 '#else\n#define VITA_COPY_FILE fs::copy_file\n#endif\n'),
         'vita-copyfile')


# 122. HP2's Adv1Willow (bench hp2_willow, 06 Nov): 'procedural textures' 22 ms of a 67 ms frame, inside 'node: texture' and
#      'node: detail/macro': WaterDE2 (WaveTexture) ~19 ms a picture, liquid7 (WetTexture) ~9 ms, on the main thread. The water
#      pictures are now made on a thread of their own (vita/VitaWaterJobs.h, cores 1+2, priority 160): UTexture::Update queues the
#      step and shows the picture the thread finished (one picture late); the thread writes into its own picture, copied into
#      the texture's level 0 on the main thread. render.cfg water_thread=0: the old way. The log's procedural textures then show
#      '<name> on the water thread' (the thread's time) next to the main thread's copy.
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("void UWaterTexture::UpdateFrame()\n{\n\tif (!TextureModified)\n"),
     lambda m: ("void UWaterTexture::UpdateFrame()\n{\n#ifdef __vita__ // vita-wthread-guard: the water thread makes its picture anyway\n"
                "\tif (!TextureModified || VitaWater::OnJob(this))\n#else\n\tif (!TextureModified)\n#endif\n"),
     'vita-wthread-guard')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\t\tuint8_t* pixels = (uint8_t*)mipmap.Data.data();\n\n#ifdef __vita__ // vita-shade-planar\n"),
     lambda m: m.group(0).replace("\n\n#ifdef", "\n#ifdef __vita__ // vita-wthread-out\n\t\tpixels = VitaWater::Output(this, pixels);\n#endif\n\n#ifdef", 1),
     'vita-wthread-out')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\t\tTextureModified = true;\n\t}\n}\n\nvoid UWaterTexture::UpdateWater()"),
     lambda m: ("#ifdef __vita__ // vita-wthread-mod: the main thread sets it when it takes the picture\n\t\tif (!VitaWater::OnJob(this))\n#endif\n"
                + m.group(0)),
     'vita-wthread-mod')
edit("Packages/Engine/Resources/Textures/UWaterTexture.cpp",
     re.escape("\t\tif ((++vitaSteps & 127) == 100 && vitaChecks < 4)\n"),
     lambda m: "\t\tif ((++vitaSteps & 127) == 100 && vitaChecks < 4 && !VitaWater::OnJob(this)) // vita-wthread-nocheck (logs, allocates)\n",
     'vita-wthread-nocheck')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape("void UWetTexture::UpdateFrame()\n{\n\tif (!TextureModified)\n"),
     lambda m: ("void UWetTexture::UpdateFrame()\n{\n#ifdef __vita__ // vita-wthread-wguard\n"
                "\tif (!TextureModified || VitaWater::OnJob(this))\n#else\n\tif (!TextureModified)\n#endif\n"),
     'vita-wthread-wguard')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape("\t\t\tuint8_t* pixels = (uint8_t*)mipmap.Data.data();\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-wthread-wout\n\t\t\tpixels = VitaWater::Output(this, pixels);\n#endif\n",
     'vita-wthread-wout')
edit("Packages/Engine/Resources/Textures/UWetTexture.cpp",
     re.escape("\t\tTextureModified = true;\n\t}\n}"),
     lambda m: "#ifdef __vita__ // vita-wthread-wmod\n\t\tif (!VitaWater::OnJob(this))\n#endif\n" + m.group(0),
     'vita-wthread-wmod')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape('#include "UWaterTexture.h" // vita-waterfps-inc\n'),
     lambda m: m.group(0) + '#include "VitaWaterJobs.h" // vita-wthread-inc\n',
     'vita-wthread-inc')
edit("Packages/Engine/Resources/Textures/UTexture.cpp",
     re.escape("#ifdef __vita__ // vita-textime: the time of the new pictures, by texture\n"),
     lambda m: ("#ifdef __vita__ // vita-wthread-update: water on its own thread (VitaWaterJobs.h)\n"
                "\tif (VitaWaterJobs::Enabled() && !UsedMipmaps.empty() && dynamic_cast<UWaterTexture*>(this))\n\t{\n"
                "\t\tUnrealMipmap& level0 = UsedMipmaps.front();\n"
                "\t\tVitaWaterJobs::Job* job = VitaWaterJobs::JobFor(this, [](void* t) { ((UTexture*)t)->UpdateFrame(); }, (const uint8_t*)level0.Data.data(), level0.Data.size(), level0.Width, level0.Height);\n"
                "\t\tif (job)\n\t\t{\n"
                "\t\t\tconst double vitaStart = VitaTimers::Now();\n"
                "\t\t\tbool took = false;\n"
                "\t\t\tif (job->status.load(std::memory_order_acquire) == 2)\n\t\t\t{\n"
                "\t\t\t\tstd::memcpy(level0.Data.data(), job->picture.data(), std::min(level0.Data.size(), job->picture.size()));\n"
                "\t\t\t\tTextureModified = true;\n"
                "\t\t\t\tjob->status.store(0, std::memory_order_relaxed);\n"
                "\t\t\t\ttook = true;\n"
                "\t\t\t\tVitaTimers::TexTime& w = VitaTimers::texTimes[(const char*)this + 1];\n"
                "\t\t\t\tif (w.name.empty())\n\t\t\t\t\tw.name = Name.ToString() + \" \" + std::to_string(level0.Width) + \"x\" + std::to_string(level0.Height) + \" on the water thread\";\n"
                "\t\t\t\tw.ms += job->ms;\n\t\t\t\tw.updates++;\n"
                "\t\t\t\tVitaTimers::TexTime& d = VitaTimers::texTimes[(const char*)this + 2];\n"
                "\t\t\t\tif (d.name.empty())\n\t\t\t\t\td.name = Name.ToString() + \" queued to done\";\n"
                "\t\t\t\td.ms += job->waitMs;\n\t\t\t\td.updates++;\n\t\t\t}\n"
                "\t\t\tbool due = false;\n"
                "\t\t\tfor (int iteration = 0; Accumulator() > animationSpeed; iteration++)\n\t\t\t{\n"
                "\t\t\t\tdue = true;\n\t\t\t\tAccumulator() -= animationSpeed;\n"
                "\t\t\t\tif (iteration == 10)\n\t\t\t\t{\n\t\t\t\t\tAccumulator() = 0.0f;\n\t\t\t\t\tbreak;\n\t\t\t\t}\n\t\t\t}\n"
                "\t\t\tif (due && job->status.load(std::memory_order_relaxed) == 0)\n\t\t\t\tVitaWaterJobs::Queue(job);\n"
                "\t\t\tif (took)\n\t\t\t{\n"
                "\t\t\t\tconst double t = VitaTimers::Now() - vitaStart;\n"
                "\t\t\t\tVitaTimers::ms[VitaTimers::TexUpdate] += t;\n\t\t\t\tVitaTimers::total[VitaTimers::TexUpdate] += t;\n"
                "\t\t\t\tVitaTimers::TexTime& e = VitaTimers::texTimes[this];\n"
                "\t\t\t\tif (e.name.empty())\n\t\t\t\t\te.name = Name.ToString() + \" (\" + Class->Name.ToString() + \")\";\n"
                "\t\t\t\te.ms += t;\n\t\t\t\te.updates++;\n\t\t\t}\n"
                "\t\t\treturn;\n\t\t}\n\t}\n#endif\n" + m.group(0)),
     'vita-wthread-update')


# 124. HP1_DUMP also lists the entry level's actors ('HP1 dump entry ...'): HP2's 'ticks by class' had two harry, BaseCam and
#      GameReplicationInfo ticks a frame with one of each in the level.
edit("../../knowwonder/KWDebug.cpp",
     re.escape("\t\t\tLogMessage(buf);\n\t\t}\n\t}\n\n\t// A property of the actor's class, or null"),
     lambda m: ("\t\t\tLogMessage(buf);\n\t\t}\n"
                "\t\tif (engine->EntryLevel && engine->EntryLevel != engine->Level) // vita-dump-entry\n"
                "\t\t\tfor (UActor* a : engine->EntryLevel->Actors)\n\t\t\t{\n"
                "\t\t\t\tif (!a)\n\t\t\t\t\tcontinue;\n"
                "\t\t\t\tLogMessage(\"HP1 dump entry \" + a->Class->Name.ToString() + \" \" + a->Name.ToString() + \" state=\" + a->GetStateName().ToString() +\n"
                "\t\t\t\t\t(a->bStatic() ? \" static\" : \"\") + (a->bDeleteMe() ? \" deleted\" : \"\"));\n\t\t\t}\n"
                "\t}\n\n\t// A property of the actor's class, or null"),
     'vita-dump-entry')


# 125. HP2's Entry.unr has a Harry placed in it: he, his BaseCam, StatusManager (a dozen HUD items), shadow, anim channels and the
#      entry's GameReplicationInfo tick every frame (HP1_DUMP 'HP1 dump entry', #124), unseen. The entry level is now ticked every
#      entry_tick_rate frames (render.cfg, default 10; 1 = every frame as before, 0 = never) with the time gathered since.
edit("Engine.cpp",
     re.escape("\t\t\t\tif (EntryLevel && EntryLevel != Level)\n\t\t\t\t\tEntryLevel->Tick(entryStepElapsed, m_GamePaused);\n"),
     lambda m: ("#ifdef __vita__ // vita-entrytick\n"
                "\t\t\t\tif (EntryLevel && EntryLevel != Level)\n\t\t\t\t{\n"
                "\t\t\t\t\tstatic const int vitaEntryRate = VitaConfigInt(\"entry_tick_rate\", 10);\n"
                "\t\t\t\t\tstatic int vitaEntryFrames = 0;\n\t\t\t\t\tstatic float vitaEntryElapsed = 0.0f;\n"
                "\t\t\t\t\tvitaEntryElapsed += entryStepElapsed;\n"
                "\t\t\t\t\tif (vitaEntryRate > 0 && ++vitaEntryFrames >= vitaEntryRate)\n\t\t\t\t\t{\n"
                "\t\t\t\t\t\tVITA_TIMER(EntryTick);\n"
                "\t\t\t\t\t\tEntryLevel->Tick(std::min(vitaEntryElapsed, 0.5f), m_GamePaused);\n"
                "\t\t\t\t\t\tvitaEntryFrames = 0;\n\t\t\t\t\t\tvitaEntryElapsed = 0.0f;\n\t\t\t\t\t}\n\t\t\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-entrytick')


# 126. HP2's Adv1Willow turning: 'particles' 12.8 ms a frame (stand 1.6). Laps in KW::DrawParticleSystem: update, setup, draw,
#      and the number of particles of the systems drawn ('particles: count' calls).
PR = "../../knowwonder/KWParticleRender.cpp"
edit(PR, re.escape('#include "VitaTimers.h" // vita-timers:include\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-pfxlaps-inc\n', 'vita-pfxlaps-inc')
edit(PR, re.escape("\t\tVITA_TIMER(Particles); // vita-timers:particles\n\t\tif (!UpdateParticleSystem(actor, 0.0f))\n\t\t\treturn;\n"),
     lambda m: ("\t\tVITA_TIMER(Particles); // vita-timers:particles\n\t\tVITA_LAP_START; // vita-pfxstart\n"
                "\t\tconst bool vitaUpdated = UpdateParticleSystem(actor, 0.0f);\n\t\tVITA_LAP(PfxUpdate);\n\t\tif (!vitaUpdated)\n\t\t\treturn;\n"),
     'vita-pfxstart')
edit(PR, re.escape("\t\tctx.LightColor = PFX::LightColor(actor);\n\n\t\tswitch (primitive)\n"),
     lambda m: ("\t\tctx.LightColor = PFX::LightColor(actor);\n\t\tVITA_LAP(PfxSetup); // vita-pfxlaps-setup\n"
                "#ifdef __vita__\n\t\tif (VitaProbes::enabled)\n\t\t\tVitaProbes::calls[VitaProbes::PfxCount] += (unsigned)state->Particles.size();\n#endif\n"
                "\n\t\tswitch (primitive)\n"),
     'vita-pfxlaps-setup')
edit(PR, re.escape("\t\t\tbreak;\n\t\t}\n\t\tengine->render->Stats.Actors++;\n"),
     lambda m: "\t\t\tbreak;\n\t\t}\n\t\tVITA_LAP(PfxDraw); // vita-pfxlaps-draw\n\t\tengine->render->Stats.Actors++;\n",
     'vita-pfxlaps-draw')

edit(PR, re.escape("\t\t\tctx.Frame->Device->DrawGouraudPolygon(&ctx.Frame->Frame, ctx.Texinfo, vertices, count, ctx.PolyFlags);\n"),
     lambda m: "\t\t\tVITA_PROBE(PfxDevice); // vita-pfxdevice\n" + m.group(0), 'vita-pfxdevice')


# 127. Adv1Willow turning (#126 laps): 1491 particles drawn as 2862 DrawGouraudPolygon calls (a liquid system draws its liquid
#      and billboard passes): 'particles: draw' ~9.5 ms. Not the calls: memory. The Vita's CPU copies at ~0.4 GB/s ('polygons:
#      keep copy' 693 KB in 1.8 ms) and each particle vertex went through GouraudVertex (52 bytes written and read), a zeroing
#      resize and the batch vertex (36) before the GL thread's copy. Now the device gives the system room in its batch
#      (RenderDevice::VitaBeginTriangles, an upper bound: 6 vertices per quad pass, 3 for a shard) and the passes write the batch
#      vertices themselves (same vertices, same order, one SwitchBatch per system); VitaRenderDevice's batch resizes without
#      zeroing (VitaNoInitAlloc).
edit("RenderDevice/RenderDevice.h",
     re.escape("\t\t\tDrawGouraudPolygon(Frame, Info, Pts + i * 3, 3, PolyFlags);\n\t}\n#endif\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-appendtris\n"
                "\t// Room for up to maxVerts triangle vertices (9 floats: x y z u v r g b a) in the device's batch, or null (then draw with\n"
                "\t// DrawGouraud*). params (4 floats out): u and v multipliers, the light multiplier, 1 when the colour is ignored (modulated).\n"
                "\t// VitaEndTriangles(the vertices written) closes it.\n"
                "\tvirtual float* VitaBeginTriangles(SceneNode* Frame, TextureInfo& Info, uint32_t PolyFlags, int maxVerts, float* params) { return nullptr; }\n"
                "\tvirtual void VitaEndTriangles(int usedVerts) {}\n#endif\n"),
     'vita-appendtris')
edit(PR, re.escape("\t\t\tvec4 LightColor = vec4(1.0f);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pfxtris-ctx\n"
                             "\t\t\tfloat* VitaOut = nullptr;      // the device's batch (VitaBeginTriangles), 9 floats a vertex\n"
                             "\t\t\tint VitaUsed = 0, VitaMax = 0;  // vertices written, room\n"
                             "\t\t\tfloat VitaParams[4] = {};       // u, v multipliers, light multiplier, modulated\n#endif\n"),
     'vita-pfxtris-ctx')
edit(PR, re.escape("\t\t\tGouraudVertex vertices[4];\n\t\t\tfor (int i = 0; i < count; i++)\n"),
     lambda m: ("#ifdef __vita__ // vita-pfxtris-add: the fan (0, i - 1, i) as the device's DrawGouraudPolygon makes it\n"
                "\t\t\tif (ctx.VitaOut)\n\t\t\t{\n"
                "\t\t\t\tif (ctx.VitaUsed + (count - 2) * 3 > ctx.VitaMax)\n\t\t\t\t\treturn;   // cannot happen: the room is an upper bound\n"
                "\t\t\t\tconst float um = ctx.UMax * ctx.VitaParams[0], vm = ctx.VMax * ctx.VitaParams[1];\n"
                "\t\t\t\tconst bool mod = ctx.VitaParams[3] != 0.0f;\n"
                "\t\t\t\tconst float lm = ctx.VitaParams[2];\n"
                "\t\t\t\tfloat* out = ctx.VitaOut + (size_t)ctx.VitaUsed * 9;\n"
                "\t\t\t\tfor (int i = 2; i < count; i++)\n\t\t\t\t{\n"
                "\t\t\t\t\tconst int corner[3] = { 0, i - 1, i };\n"
                "\t\t\t\t\tfor (int k : corner)\n\t\t\t\t\t{\n"
                "\t\t\t\t\t\tout[0] = points[k].x; out[1] = points[k].y; out[2] = points[k].z;\n"
                "\t\t\t\t\t\tout[3] = uvs[k].x * um; out[4] = uvs[k].y * vm;\n"
                "\t\t\t\t\t\tout[5] = mod ? 1.0f : lights[k].x * lm; out[6] = mod ? 1.0f : lights[k].y * lm; out[7] = mod ? 1.0f : lights[k].z * lm;\n"
                "\t\t\t\t\t\tout[8] = 1.0f;\n\t\t\t\t\t\tout += 9;\n\t\t\t\t\t}\n\t\t\t\t}\n"
                "\t\t\t\tctx.VitaUsed += (count - 2) * 3;\n"
                "\t\t\t\treturn;\n\t\t\t}\n#endif\n" + m.group(0)),
     'vita-pfxtris-add')
edit(PR, re.escape("\t\tVITA_LAP(PfxSetup); // vita-pfxlaps-setup\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-pfxtris-start\n"
                "\t\t{\n"
                "\t\t\tint perParticle = 6;   // billboard or shell\n"
                "\t\t\tif (primitive == PPRIM_Line)\n\t\t\t\tperParticle += 6 + 3 + 6;\n"
                "\t\t\telse if (primitive == PPRIM_Shard)\n\t\t\t\tperParticle += 3 + 6;\n"
                "\t\t\telse if (primitive == PPRIM_Liquid)\n\t\t\t\tperParticle += 6;\n"
                "\t\t\tctx.VitaMax = (int)state->Particles.size() * perParticle;\n"
                "\t\t\tctx.VitaOut = frame->Device->VitaBeginTriangles(&frame->Frame, ctx.Texinfo, ctx.PolyFlags, ctx.VitaMax, ctx.VitaParams);\n"
                "\t\t}\n#endif\n"),
     'vita-pfxtris-start')
edit(PR, re.escape("\t\tVITA_LAP(PfxDraw); // vita-pfxlaps-draw\n"),
     lambda m: ("#ifdef __vita__ // vita-pfxtris-draw\n"
                "\t\tif (ctx.VitaOut)\n\t\t\tframe->Device->VitaEndTriangles(ctx.VitaUsed);\n#endif\n" + m.group(0)),
     'vita-pfxtris-draw')


# 128. '@script <actor> <function>' (HP1_EXEC): the function as the engine's pretty printer shows it (DisassemblyCommandlet's
#      PrintPrettyExpression), from the actor's class and its parents (or 'console', or a class 'Package.Class'), in the class
#      and in every state: HP2's scripts are
#      stripped, and the Tick events of its torches, movers and lights are what its level tick spends.
edit("../../knowwonder/KWDebug.cpp",
     re.escape('#include "Packages/Core/UClass.h"\n'),
     lambda m: m.group(0) + ('#include "Packages/Core/UFunction.h" // vita-script-inc\n#include "Packages/Core/UState.h"\n'
                             '#include "VM/Bytecode.h"\n#include "Commandlet/VM/DisassemblyCommandlet.h"\n'),
     'vita-script-inc')
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\tif (text.rfind("@hull ", 0) == 0)\n'),
     lambda m: ('\t\tif (text.rfind("@script ", 0) == 0) // vita-script-cmd\n\t\t{\n'
                '\t\t\tstd::istringstream in(text.substr(8));\n\t\t\tstd::string actorName, funcName;\n\t\t\tin >> actorName >> funcName;\n'
                '\t\t\tUObject* actor = nullptr;\n'
                '\t\t\tUClass* startClass = nullptr;\n'
                '\t\t\tif (actorName == "console")\n\t\t\t\tactor = engine->console;\n'
                '\t\t\telse if (actorName.find(\'.\') != std::string::npos)\n\t\t\t\tstartClass = engine->packages->FindClass(actorName);\n'
                '\t\t\telse\n'
                '\t\t\t\tfor (UActor* a : engine->Level->Actors)\n\t\t\t\t\tif (a && a->Name.ToString() == actorName)\n\t\t\t\t\t{\n\t\t\t\t\t\tactor = a;\n\t\t\t\t\t\tbreak;\n\t\t\t\t\t}\n'
                '\t\t\tif (actor)\n\t\t\t\tstartClass = actor->Class;\n'
                '\t\t\tif (!startClass)\n\t\t\t{\n\t\t\t\tLogMessage("HP1 script: no actor or class " + actorName);\n\t\t\t\treturn;\n\t\t\t}\n'
                '\t\t\tauto print = [&](const std::string& where, UFunction* func)\n\t\t\t{\n'
                '\t\t\t\tLogMessage("HP1 script " + where + "." + funcName + (func->Code ? "" : " (no code)"));\n'
                '\t\t\t\tif (!func->Code)\n\t\t\t\t\treturn;\n'
                '\t\t\t\tfor (Expression* expr : func->Code->Statements)\n\t\t\t\t{\n'
                '\t\t\t\t\tstd::string line;\n'
                '\t\t\t\t\tPrintPrettyExpression::Print([&](const std::string& t) { line += t; }, expr);\n'
                '\t\t\t\t\tLogMessage("HP1 script   " + line);\n\t\t\t\t}\n\t\t\t};\n'
                '\t\t\tconst NameString wanted(funcName);\n'
                '\t\t\tfor (UStruct* s = startClass; s; s = s->BaseStruct)\n\t\t\t{\n'
                '\t\t\t\tUClass* cls = dynamic_cast<UClass*>(s);\n\t\t\t\tif (!cls)\n\t\t\t\t\tcontinue;\n'
                '\t\t\t\tauto f = cls->Functions.find(wanted);\n'
                '\t\t\t\tif (f != cls->Functions.end() && f->second)\n\t\t\t\t\tprint(cls->Name.ToString(), f->second);\n'
                '\t\t\t\tfor (auto& st : cls->States)\n\t\t\t\t{\n'
                '\t\t\t\t\tif (!st.second)\n\t\t\t\t\t\tcontinue;\n'
                '\t\t\t\t\tauto g = st.second->Functions.find(wanted);\n'
                '\t\t\t\t\tif (g != st.second->Functions.end() && g->second)\n'
                '\t\t\t\t\t\tprint(cls->Name.ToString() + ".state " + st.first.ToString(), g->second);\n'
                '\t\t\t\t}\n\t\t\t}\n'
                '\t\t\tLogMessage("HP1 script: end; state " + (actor ? actor->GetStateName().ToString() : std::string("-")));\n'
                '\t\t\treturn;\n\t\t}\n' + m.group(0)),
     'vita-script-cmd')


# 129. HP2's level tick (Adv1Willow, 'tick: Tick event' 16 us a call, 415 a frame): most Tick events are a few lines that start
#      with Super.Tick, which ends in Actor.Tick, an empty function (@script, #128: HPawn.Tick of 50 torches, 28 wisps, 24
#      collision objects; Mover.Tick of 42 movers). A script function whose whole code is 'return' without a value, with no
#      return value or out parameter, does nothing: Frame::Call returns at once (no frame, locals, arguments). Worked out once per
#      function (UStruct::VitaEmptyFunc). Log: 'script: empty calls skipped' (laps line, calls a frame).
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaTrivialLocals = -1; // vita-trivial-field: every property a plain value (1), not (0), unknown (-1)\n"),
     lambda m: m.group(0) + "\tint8_t VitaEmptyFunc = -1; // vita-emptyfunc-field: the code is a bare 'return' and nothing comes back (1), not (0), unknown (-1)\n",
     'vita-emptyfunc-field')
edit("VM/Frame.cpp",
     re.escape('#include "VitaFuncCache.h" // vita-funccache-inc\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-emptyfunc-inc\n',
     'vita-emptyfunc-inc')
edit("VM/Frame.cpp",
     re.escape("\telse\n\t{\n\t\t// While a singular function runs on an object, every singular call on that object is skipped"),
     lambda m: ("\telse\n\t{\n#ifdef __vita__ // vita-emptyfunc-skip\n"
                "\t\tif (func->VitaEmptyFunc < 0)\n\t\t{\n"
                "\t\t\tbool empty = func->Code && func->Code->Statements.size() == 1 && func->Code->Statements[0] &&\n"
                "\t\t\t\tfunc->Code->Statements[0]->Type == ExpressionType::Return;\n"
                "\t\t\tif (empty)\n\t\t\t{\n"
                "\t\t\t\tExpression* value = static_cast<ReturnExpression*>(func->Code->Statements[0])->Value;\n"
                "\t\t\t\tempty = !value || value->Type == ExpressionType::Nothing;\n\t\t\t}\n"
                "\t\t\tfor (UProperty* prop : func->Properties)\n"
                "\t\t\t\tif (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm) || AllFlags(prop->PropFlags, PropertyFlags::OutParm))\n"
                "\t\t\t\t\tempty = false;\n"
                "\t\t\tfunc->VitaEmptyFunc = empty ? 1 : 0;\n\t\t}\n"
                "\t\tif (func->VitaEmptyFunc == 1)\n\t\t{\n"
                "\t\t\tif (VitaProbes::enabled)\n\t\t\t\tVitaProbes::calls[VitaProbes::EmptySkip]++;\n"
                "\t\t\treturn ExpressionValue::NothingValue();\n\t\t}\n#endif\n"
                + m.group(0)[len("\telse\n\t{\n"):]),
     'vita-emptyfunc-skip')


# 130. Every native operator of a script (+=, <, ==, vector math: most statements have a few) went through Frame::Call: the
#      event table lookup (IsEventEnabled by name), TraceCall, then CallNative with a whole Frame (VM variable stack, the call
#      stack entry) for two or three ExpressionValues. A native function with the Operator flag and at most 8 properties now
#      runs its handler on an ExpressionValue array on the C++ stack, filled and read back exactly as CallNative does
#      (UStruct::VitaFastOp, worked out once). Log: 'script: operators without a frame' (laps line, calls a frame).
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaEmptyFunc = -1; // vita-emptyfunc-field"),
     lambda m: "\tint8_t VitaFastOp = -1; // vita-fastop-field: a native operator called without a Frame (1), not (0), unknown (-1)\n" + m.group(0),
     'vita-fastop-field')
edit("VM/Frame.cpp",
     re.escape("\tTraceCall(func, instance, args);\n\n\tif (!instance->IsEventEnabled(func->Name))\n"),
     lambda m: ("#ifdef __vita__ // vita-fastop-call\n"
                "\tif (func->VitaFastOp < 0)\n"
                "\t\tfunc->VitaFastOp = (AllFlags(func->FuncFlags, FunctionFlags::Native) && AllFlags(func->FuncFlags, FunctionFlags::Operator) &&\n"
                "\t\t\tfunc->NativeFuncIndex != 0 && func->Properties.size() <= 8) ? 1 : 0;\n"
                "\tif (func->VitaFastOp == 1)\n\t{\n"
                "\t\tif (VitaProbes::enabled)\n\t\t\tVitaProbes::calls[VitaProbes::FastOp]++;\n"
                "\t\tExpressionValue frameArgs[8];\n"
                "\t\tint argindex = 0, resultIndex = -1;\n"
                "\t\tfor (UProperty* prop : func->Properties)\n\t\t{\n"
                "\t\t\tif (!AllFlags(prop->PropFlags, PropertyFlags::Parm))\n\t\t\t\tcontinue;\n"
                "\t\t\tif (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm))\n\t\t\t{\n"
                "\t\t\t\tif (resultIndex < 0)\n\t\t\t\t\tresultIndex = argindex;\n"
                "\t\t\t\tframeArgs[argindex++] = ExpressionValue::PropertyValue(prop);\n\t\t\t}\n"
                "\t\t\telse if (argindex < (int)args.size())\n\t\t\t{\n"
                "\t\t\t\tif (args[argindex].GetType() == ExpressionValueType::Nothing && AllFlags(prop->PropFlags, PropertyFlags::OutParm) && !AllFlags(prop->PropFlags, PropertyFlags::OptionalParm))\n"
                "\t\t\t\t\tframeArgs[argindex] = ExpressionValue::DefaultValue(prop);\n"
                "\t\t\t\telse\n\t\t\t\t\tframeArgs[argindex] = args[argindex];\n"
                "\t\t\t\targindex++;\n\t\t\t}\n"
                "\t\t\telse\n\t\t\t\tframeArgs[argindex++] = ExpressionValue::NothingValue();\n\t\t}\n"
                "\t\ttry\n\t\t{\n\t\t\tNativeFunctions::NativeByIndex[func->NativeFuncIndex](instance, frameArgs);\n\t\t}\n"
                "\t\tcatch (const std::exception& e)\n\t\t{\n\t\t\tLogMessage(std::string(\"Script error: \") + e.what());\n\t\t\treturn ExpressionValue::NothingValue();\n\t\t}\n"
                "\t\tcatch (...)\n\t\t{\n\t\t\tLogMessage(\"Script error: Unknown error\");\n\t\t\treturn ExpressionValue::NothingValue();\n\t\t}\n"
                "\t\treturn resultIndex >= 0 ? frameArgs[resultIndex] : ExpressionValue::NothingValue();\n\t}\n#endif\n"
                + m.group(0)),
     'vita-fastop-call')


# 131. HP2's in-game menus (UWindow: Options, Save/Load) showed no mouse cursor on the Vita. The engine says a Windows mouse is
#      available when the game runs in a window (Engine::Run), and then UWindowRootWindow.DrawMouse leaves the cursor to the
#      operating system (none on a Vita). The original ran fullscreen by default, where UWindow draws its own cursor and moves it
#      by the mouse's IK_MouseX/IK_MouseY deltas (the stick's raw moves, vita_input.cpp, sent while the cursor is locked).
edit("Engine.cpp",
     re.escape("\tif (engine->LaunchInfo.ue1Version > 219 && !client->StartupFullscreen)\n\t\tviewport->bWindowsMouseAvailable() = true;\n"),
     lambda m: ("#ifdef __vita__ // vita-hp2-swcursor: HP2's menus draw their own cursor (as in the original's fullscreen)\n"
                "\tif (engine->LaunchInfo.ue1Version > 219 && !client->StartupFullscreen && !engine->LaunchInfo.IsHarryPotter2())\n"
                "\t\tviewport->bWindowsMouseAvailable() = true;\n#else\n" + m.group(0) + "#endif\n"),
     'vita-hp2-swcursor')

#      HPConsole.state UWindow.KeyEvent hands the mouse's deltas to its menu book first, which takes them, so a drawn cursor did
#      not move; HPConsole.RenderUWindow reads the position only from Viewport.WindowsMouseX/Y when a Windows mouse is available.
#      The stick's (and the touch screen's) absolute position is therefore written into the console's MouseX/MouseY as that
#      would: WindowsMouseX / Root.GUIScale.
edit("Engine.cpp",
     re.escape("\t\tif (LaunchInfo.IsKnowWonder()) // into the menu canvas (src/knowwonder/KWCanvas.cpp)\n\t\t\tKW::MenuMousePosition(viewport->WindowsMouseX(), viewport->WindowsMouseY());\n"),
     lambda m: (m.group(0) + "#ifdef __vita__ // vita-hp2-mousepos\n"
                "\t\tif (LaunchInfo.IsHarryPotter2() && console && console->HasProperty(\"MouseX\") && console->HasProperty(\"Root\"))\n\t\t{\n"
                "\t\t\tUObject* root = console->GetUObject(\"Root\");\n"
                "\t\t\tfloat scale = root && root->HasProperty(\"GUIScale\") ? root->GetFloat(\"GUIScale\") : 1.0f;\n"
                "\t\t\tif (scale <= 0.0f)\n\t\t\t\tscale = 1.0f;\n"
                "\t\t\tconsole->SetFloat(\"MouseX\", viewport->WindowsMouseX() / scale);\n"
                "\t\t\tconsole->SetFloat(\"MouseY\", viewport->WindowsMouseY() / scale);\n\t\t}\n#endif\n"),
     'vita-hp2-mousepos')


# 132. Particle update laps: 'particles: bounce trace' (KW::UpdateParticle's level trace for particles with Elasticity).
PFXF = "../../knowwonder/KWParticleFX.cpp"
edit(PFXF, re.escape('#include <cstdio>   // vita-particles:include'),
     lambda m: m.group(0) + '\n#include "VitaProbes.h" // vita-pfxbounce-inc', 'vita-pfxbounce-inc')
edit(PFXF, re.escape("\t\t\tif (PFX::Elasticity(a) > 0.0f && p.OldPosition != p.Position)\n\t\t\t{\n"),
     lambda m: m.group(0) + "\t\t\t\tVITA_PROBE(PfxBounce); // vita-pfxbounce\n", 'vita-pfxbounce')


# 133. Particles, per particle work that was per system: (a) every PFX::<property>(a) went through GetParticleFXProps()
#      (another file, a function-local static and a check), ~15 times a particle in UpdateParticle: the offsets are now read
#      through an inline pointer set once (VitaPfxProps); (b) ParticleLight asked IsHP2(), Opacity / ScaleGlow and Style for
#      every particle of every pass: the system's alpha and Modulated flag are worked out once in DrawParticleSystem.
edit("../../knowwonder/KWParticleFX.h",
     re.escape("\t\tinline const ParticleFXProps& P() { return GetParticleFXProps(); }\n"),
     lambda m: ("#ifdef __vita__ // vita-pfxprops-fast\n\t\tinline const ParticleFXProps* VitaPfxProps = nullptr;   // set by GetParticleFXProps once it has them\n"
                "\t\tinline const ParticleFXProps& P() { return VitaPfxProps ? *VitaPfxProps : GetParticleFXProps(); }\n#else\n"
                + m.group(0) + "#endif\n"),
     'vita-pfxprops-fast')
edit(PFXF, re.escape("\t\t\tProps = &props;\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-pfxprops-set\n\t\t\tPFX::VitaPfxProps = &props;\n#endif\n",
     'vita-pfxprops-set')
edit(PR, re.escape("\t\t\tvec4 LightColor = vec4(1.0f);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pfxlight-ctx\n"
                             "\t\t\tfloat VitaSysAlpha = 1.0f;      // HP2: Opacity, HP1: ScaleGlow (once per system)\n"
                             "\t\t\tbool VitaModulated = false;     // Style == STY_Modulated\n#endif\n"),
     'vita-pfxlight-ctx')
edit(PR, re.escape("\t\t\tfloat alpha = (IsHP2() ? Opacity(ctx.Actor) : ctx.Actor->ScaleGlow()) * p.Alpha;\n\t\t\tif (alpha < 1.0f)\n\t\t\t{\n\t\t\t\tlight *= alpha;\n\t\t\t\tif (ctx.Actor->Style() == STY_Modulated)\n"),
     lambda m: ("#ifdef __vita__ // vita-pfxlight-use\n"
                "\t\t\tfloat alpha = ctx.VitaSysAlpha * p.Alpha;\n\t\t\tif (alpha < 1.0f)\n\t\t\t{\n\t\t\t\tlight *= alpha;\n\t\t\t\tif (ctx.VitaModulated)\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-pfxlight-use')
edit(PR, re.escape("\t\tctx.LightColor = PFX::LightColor(actor);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pfxlight-set\n"
                             "\t\tctx.VitaSysAlpha = IsHP2() ? Opacity(actor) : actor->ScaleGlow();\n"
                             "\t\tctx.VitaModulated = actor->Style() == STY_Modulated;\n#endif\n"),
     'vita-pfxlight-set')


# 134. Adv1Willow's torch flames (FireHP2_bigtorch1, spinning billboards): ~37 us a particle to draw against ~2 us for plain
#      billboards. A particle's Spin only grows (Spin += dt * SpinRate, never wrapped) and std::cos / std::sin of a large float
#      take newlib's slow argument reduction. The billboard pass now turns the angle into [-pi, pi] first (std::remainder by
#      2 pi): the same cosine and sine to float precision.
edit(PR, re.escape("\t\t\t\t\tfloat c = std::cos(p.Spin);\n\t\t\t\t\tfloat s = std::sin(p.Spin);\n"),
     lambda m: ("#ifdef __vita__ // vita-pfxspin\n"
                "\t\t\t\t\tconst float spin = std::fabs(p.Spin) > 3.14159265f ? std::remainder(p.Spin, 6.28318531f) : p.Spin;\n"
                "\t\t\t\t\tfloat c = std::cos(spin);\n\t\t\t\t\tfloat s = std::sin(spin);\n#else\n" + m.group(0) + "#endif\n"),
     'vita-pfxspin')


# 135. render.cfg script_profile=1: Frame::Call times every script function it runs (and the natives it calls, not operators),
#      inclusive, by function; the log's 'script functions by time' lists the biggest. For HP2's Harry: 7.3 ms a frame walking
#      (2 standing), all of it his PlayerTick / PlayerInput scripts.
edit("VM/Frame.cpp",
     re.escape("\tTraceCall(func, instance, args);\n\n\tif (!instance->IsEventEnabled(func->Name))\n"),
     lambda m: ("#ifdef __vita__ // vita-scriptprof\n"
                "\tif (VitaProbes::scriptProfile < 0)\n\t\tVitaProbes::scriptProfile = VitaConfigInt(\"script_profile\", 0) != 0 ? 1 : 0;\n"
                "\tstruct VitaFuncTimer\n\t{\n"
                "\t\tUFunction* func = nullptr;\n\t\tuint64_t start = 0;\n\t\tstd::string cls;\n"
                "\t\t~VitaFuncTimer()\n\t\t{\n"
                "\t\t\tif (!func)\n\t\t\t\treturn;\n"
                "\t\t\tVitaProbes::FuncTime& e = VitaProbes::funcTimes[func];\n"
                "\t\t\tif (e.name.empty())\n"
                "\t\t\t\te.name = func->Name.ToString() + \" (\" + cls + \")\";\n"
                "\t\t\te.us += (double)(VitaProbes::Now() - start);\n\t\t\te.calls++;\n\t\t}\n"
                "\t} vitaFuncTimer;\n"
                "\tif (VitaProbes::scriptProfile == 1)\n\t{\n\t\tvitaFuncTimer.cls = instance->Class->Name.ToString();\n\t\tvitaFuncTimer.func = func;\n\t\tvitaFuncTimer.start = VitaProbes::Now();\n\t}\n"
                "#endif\n" + m.group(0)),
     'vita-scriptprof')

edit("VM/Frame.cpp", re.escape('#include "VitaProbes.h" // vita-emptyfunc-inc\n'),
     lambda m: m.group(0) + '#include "VitaConfig.h" // vita-sprof-include\n', 'vita-sprof-include')


# 136. HP2 walking (script_profile, #135): PlayFootStep ~10 ms a call, of which MakeNoise ~8 ms: every pawn of the level is asked
#      CanHearNoise (HP2's torches, wisps, beans and props are pawns), with a level trace each. Probes first.
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("void UActor::MakeNoise(float loudness)\n{\n"),
     lambda m: m.group(0) + "\tVITA_PROBE(NoiseAll); // vita-noiseprobe\n",
     'vita-noiseprobe')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape("\t\tif (pawn != noisePawn && pawn->CanHearNoise(this, loudness))\n\t\t{\n\t\t\tCallEvent(pawn, EventName::HearNoise, { ExpressionValue::FloatValue(loudness), ExpressionValue::ObjectValue(this) });\n\t\t}\n"),
     lambda m: ("#ifdef __vita__ // vita-noiseparts\n"
                "\t\tif (pawn == noisePawn)\n\t\t\tcontinue;\n"
                "\t\tbool vitaHears;\n\t\t{\n\t\t\tVITA_PROBE(NoiseHear);\n\t\t\tvitaHears = pawn->CanHearNoise(this, loudness);\n\t\t}\n"
                "\t\tif (vitaHears)\n\t\t{\n\t\t\tVITA_PROBE(NoiseEvent);\n"
                "\t\t\tCallEvent(pawn, EventName::HearNoise, { ExpressionValue::FloatValue(loudness), ExpressionValue::ObjectValue(this) });\n\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-noiseparts')


# 137. '@memory' (HP1_EXEC): every garbage-collected object's size plus the big arrays of textures, sounds, animations, meshes
#      and the BSP, by class, and the biggest objects. HP2's Grandstaircase_hub takes ~150 MB of heap (92 -> 246 MB) and a second
#      load of it (travel) runs out.
edit("../../knowwonder/KWDebug.cpp",
     re.escape('#include "Commandlet/VM/DisassemblyCommandlet.h"\n'),
     lambda m: m.group(0) + ('#include "GC/GC.h" // vita-memory-inc\n#include "Packages/Engine/Resources/USound.h"\n'
                             '#include "Packages/Engine/Resources/Mesh/UMesh.h"\n#include "Packages/Engine/Resources/Mesh/USkeletalMesh.h"\n'
                             '#include "Packages/Engine/Resources/Mesh/UAnimation.h"\n#include <map>\n'),
     'vita-memory-inc')
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\tif (text.rfind("@script ", 0) == 0) // vita-script-cmd\n'),
     lambda m: '\t\tif (text == "@memory") // vita-memory-cmd: where the heap goes, by class (the big arrays of resources counted)\n\t\t{\n\t\t\tstruct Use { size_t count = 0, bytes = 0; };\n\t\t\tstd::map<std::string, Use> byClass;\n\t\t\tstd::map<std::string, Use> byPackage;\n\t\t\tstd::vector<std::pair<size_t, std::string>> big;\n\t\t\tsize_t total = 0;\n\t\t\tfor (GCObject* gcobj : GC::GetObjects())\n\t\t\t{\n\t\t\t\tGCAllocation* alloc = ((GCAllocation*)gcobj) - 1;\n\t\t\t\tUObject* obj = dynamic_cast<UObject*>(gcobj);\n\t\t\t\tif (!obj || !obj->Class)\n\t\t\t\t\tcontinue;\n\t\t\t\tsize_t bytes = (size_t)alloc->memsize;\n\t\t\t\tif (auto tex = dynamic_cast<UTexture*>(obj))\n\t\t\t\t{\n\t\t\t\t\tfor (auto& m : tex->UsedMipmaps) bytes += m.Data.size();\n\t\t\t\t\tfor (auto& m : tex->UncompressedMipmaps) bytes += m.Data.size();\n\t\t\t\t\tfor (auto& m : tex->CompressedMipmaps) bytes += m.Data.size();\n\t\t\t\t}\n\t\t\t\telse if (auto snd = dynamic_cast<USound*>(obj))\n\t\t\t\t\tbytes += snd->Data.size() + snd->HP2ExtraData.size() + snd->samples.size() * sizeof(float);\n\t\t\t\telse if (auto anim = dynamic_cast<UAnimation*>(obj))\n\t\t\t\t{\n\t\t\t\t\tfor (auto& mv : anim->Moves)\n\t\t\t\t\t{\n\t\t\t\t\t\tbytes += mv.BoneIndices.size() * 4;\n\t\t\t\t\t\tfor (auto& t : mv.AnimTracks)\n\t\t\t\t\t\t\tbytes += t.KeyQuat.size() * sizeof(quaternion) + t.KeyPos.size() * sizeof(vec3) + t.KeyTime.size() * 4 + sizeof(AnimTrack);\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\telse if (auto mesh = dynamic_cast<UMesh*>(obj))\n\t\t\t\t{\n\t\t\t\t\tbytes += mesh->Verts.size() * sizeof(vec3) + mesh->Tris.size() * sizeof(MeshTri) + mesh->Connects.size() * sizeof(MeshVertConnect) +\n\t\t\t\t\t\tmesh->VertLinks.size() * 4 + mesh->Normals.size() * sizeof(vec3) + mesh->BoundingBoxes.size() * sizeof(BBox) + mesh->BoundingSpheres.size() * sizeof(vec4);\n\t\t\t\t\tif (auto skel = dynamic_cast<USkeletalMesh*>(obj))\n\t\t\t\t\t\tbytes += skel->ExtWedges.size() * sizeof(ExtMeshWedge) + skel->Points.size() * sizeof(vec3) + skel->LocalPoints.size() * sizeof(vec3) +\n\t\t\t\t\t\t\tskel->BoneWeights.size() * sizeof(BoneWeight) + skel->BoneWeightIndices.size() * sizeof(BoneWeightIndex);\n\t\t\t\t}\n\t\t\t\telse if (auto model = dynamic_cast<UModel*>(obj))\n\t\t\t\t\tbytes += model->Vectors.size() * sizeof(vec3) + model->Points.size() * sizeof(vec3) + model->Nodes.size() * sizeof(BspNode) +\n\t\t\t\t\t\tmodel->Surfaces.size() * sizeof(BspSurface) + model->Vertices.size() * sizeof(BspVert) + model->LightBits.size() + model->LightMap.size() * sizeof(LightMapIndex);\n\t\t\t\tUse& pu = byPackage[(obj->package ? obj->package->GetPackageName().ToString() : std::string("(none)")) + (obj->package == engine->LevelPackage ? std::string(" [current map]") : std::string())];\n\t\t\t\tpu.count++;\n\t\t\t\tpu.bytes += bytes;\n\t\t\t\tUse& u = byClass[obj->Class->Name.ToString()];\n\t\t\t\tu.count++;\n\t\t\t\tu.bytes += bytes;\n\t\t\t\ttotal += bytes;\n\t\t\t\tif (bytes > 512 * 1024)\n\t\t\t\t\tbig.push_back({ bytes, obj->Class->Name.ToString() + " " + obj->Name.ToString() });\n\t\t\t}\n\t\t\tstd::vector<std::pair<size_t, std::string>> classes;\n\t\t\tfor (auto& it : byClass)\n\t\t\t\tclasses.push_back({ it.second.bytes, it.first + " x" + std::to_string(it.second.count) });\n\t\t\tstd::sort(classes.rbegin(), classes.rend());\n\t\t\tstd::sort(big.rbegin(), big.rend());\n\t\t\tstd::string line = "HP1 memory: objects " + std::to_string(total / 1024) + " KB; by class:";\n\t\t\tfor (size_t i = 0; i < classes.size() && i < 20; i++)\n\t\t\t\tline += " " + classes[i].second + " " + std::to_string(classes[i].first / 1024) + " KB;";\n\t\t\tLogMessage(line);\n\t\t\t{\n\t\t\t\tstd::vector<std::pair<size_t, std::string>> pk;\n\t\t\t\tfor (auto& it : byPackage)\n\t\t\t\t\tpk.push_back({ it.second.bytes, it.first + " x" + std::to_string(it.second.count) });\n\t\t\t\tstd::sort(pk.rbegin(), pk.rend());\n\t\t\t\tstd::string pl = "HP1 memory: by package:";\n\t\t\t\tfor (size_t i = 0; i < pk.size() && i < 25; i++)\n\t\t\t\t\tpl += " " + pk[i].second + " " + std::to_string(pk[i].first / 1024) + " KB;";\n\t\t\t\tLogMessage(pl);\n\t\t\t}\n\t\t\tline = "HP1 memory: biggest:";\n\t\t\tfor (size_t i = 0; i < big.size() && i < 25; i++)\n\t\t\t\tline += " " + big[i].second + " " + std::to_string(big[i].first / 1024) + " KB;";\n\t\t\tLogMessage(line);\n\t\t\treturn;\n\t\t}\n' + m.group(0),
     'vita-memory-cmd')


# 137b. Trees patched by the first @memory: the by-package breakdown added (the first edit is skipped there by its marker).
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\t\tstd::map<std::string, Use> byClass;\n'),
     lambda m: m.group(0) + '\t\t\tstd::map<std::string, Use> byPackage;\n',
     'std::map<std::string, Use> byPackage;')
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\t\t\tUse& u = byClass['),
     lambda m: ('\t\t\t\tUse& pu = byPackage[(obj->package ? obj->package->GetPackageName().ToString() : std::string("(none)")) + (obj->package == engine->LevelPackage ? std::string(" [current map]") : std::string())];\n'
                '\t\t\t\tpu.count++;\n\t\t\t\tpu.bytes += bytes;\n') + m.group(0),
     'Use& pu = byPackage[')
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\t\tline = "HP1 memory: biggest:";\n'),
     lambda m: ('\t\t\t{\n\t\t\t\tstd::vector<std::pair<size_t, std::string>> pk;\n\t\t\t\tfor (auto& it : byPackage)\n'
                '\t\t\t\t\tpk.push_back({ it.second.bytes, it.first + " x" + std::to_string(it.second.count) });\n'
                '\t\t\t\tstd::sort(pk.rbegin(), pk.rend());\n\t\t\t\tstd::string pl = "HP1 memory: by package:";\n'
                '\t\t\t\tfor (size_t i = 0; i < pk.size() && i < 25; i++)\n'
                '\t\t\t\t\tpl += " " + pk[i].second + " " + std::to_string(pk[i].first / 1024) + " KB;";\n'
                '\t\t\t\tLogMessage(pl);\n\t\t\t}\n') + m.group(0),
     '"HP1 memory: by package:"')


# 138. heap_probe=1 also measures the heap's growth in every actor tick, by class (the 'ticks by class' line gets 'heap +N KB'):
#      Grandstaircase_hub --url's level tick took 77 MB of heap in its first 120 frames.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t\tVitaProbes::currentClass = &VitaProbes::classTimes[cls]; // vita-classsplit-start\n\t\tactor->Tick(elapsed);\n"),
     lambda m: ("\t\tVitaProbes::currentClass = &VitaProbes::classTimes[cls]; // vita-classsplit-start\n"
                "\t\tconst long long vitaHeap0 = VitaTimers::heapProbe == 1 ? VitaTimers::HeapInUse() : 0; // vita-classheap\n"
                "\t\tactor->Tick(elapsed);\n"
                "\t\tif (VitaTimers::heapProbe == 1)\n\t\t{\n\t\t\tconst long long vitaGrew = VitaTimers::HeapInUse() - vitaHeap0;\n"
                "\t\t\tVitaProbes::classTimes[cls].heapBytes += vitaGrew;\n"
                "\t\t\tif (vitaGrew > 256 * 1024)\n\t\t\t\tLogMessage(\"heap_probe: \" + actor->Name.ToString() + \" (\" + cls->Name.ToString() + \", state \" + actor->GetStateName().ToString() + \") tick +\" + std::to_string(vitaGrew / 1024) + \" KB\");\n\t\t}\n"),
     'vita-classheap')

edit("Packages/Engine/Resources/Level/ULevel.cpp", re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaTimers.h" // vita-classheap-include\n', 'vita-classheap-include')

edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape("\t\t\telse\n\t\t\t{\n\t\t\t\tTickActor(elapsed, actor);\n\t\t\t}\n\t\t}\n#else\n"),
     lambda m: ("\t\t\telse\n\t\t\t{\n"
                "\t\t\t\tconst long long vitaH0 = VitaTimers::heapProbe == 1 ? VitaTimers::HeapInUse() : 0; // vita-actorheap\n"
                "\t\t\t\tTickActor(elapsed, actor);\n"
                "\t\t\t\tif (VitaTimers::heapProbe == 1)\n\t\t\t\t{\n"
                "\t\t\t\t\tconst long long vitaGrew = VitaTimers::HeapInUse() - vitaH0;\n"
                "\t\t\t\t\tif (vitaGrew > 256 * 1024)\n"
                "\t\t\t\t\t\tLogMessage(\"heap_probe: TickActor(\" + actor->Name.ToString() + \", \" + actor->Class->Name.ToString() + \", state \" + actor->GetStateName().ToString() + \") +\" + std::to_string(vitaGrew / 1024) + \" KB\");\n"
                "\t\t\t\t}\n\t\t\t}\n\t\t}\n#else\n"),
     'vita-actorheap')


# 139. HP2's Grandstaircase_hub (GSTATE050): 37 jelly beans, 13 ms a frame of physics. A bean (an HProp, bBounce) rests in state
#      BounceIntoPlace as PHYS_Falling, bouncing on the floor by nothing: HitWall halves and mirrors its velocity and nothing
#      stops it (docs/re/engine/physics.md; Location exactly the same frame after frame, Velocity.Z 4 <-> 12). Such an actor
#      (PHYS_Falling, bBounce, Location unchanged for 30 physics steps, speed < 20) is put to sleep: its physFalling is not run
#      until its Location, Velocity, Physics, Base or script state changes (anything that touches it, a pickup, a spell).
#      Nothing visible changes (it did not move); its HitWall events stop. Log: 'physics: resting bouncers skipped' (laps).
PHYS = "../../knowwonder/KWPhysics.cpp"
edit(PHYS,
     re.escape("\tvoid PerformPhysics(UActor* actor, float deltaTime)\n\t{\n"),
     lambda m: ("#ifdef __vita__ // vita-restbounce-helpers\n"
                "\tstruct VitaRest { vec3 loc = vec3(0.0f); vec3 vel = vec3(0.0f); NameString state; UActor* base = nullptr; int frames = 0; bool asleep = false; };\n"
                "\tstatic std::unordered_map<UActor*, VitaRest> vitaRests;\n"
                "\tstatic bool VitaRestAsleep(UActor* actor)\n\t{\n"
                "\t\tauto it = vitaRests.find(actor);\n"
                "\t\tif (it == vitaRests.end() || !it->second.asleep)\n\t\t\treturn false;\n"
                "\t\tVitaRest& r = it->second;\n"
                "\t\tif (actor->Location() == r.loc && actor->Velocity() == r.vel && actor->ActorBase() == r.base && actor->GetStateName() == r.state)\n\t\t\treturn true;\n"
                "\t\tr.asleep = false;\n\t\tr.frames = 0;\n\t\treturn false;\n\t}\n"
                "\tstatic void VitaRestAfter(UActor* actor)\n\t{\n"
                "\t\tVitaRest& r = vitaRests[actor];\n"
                "\t\tconst vec3 v = actor->Velocity();\n"
                "\t\tif (actor->Physics() == PHYS_Falling && actor->Location() == r.loc && dot(v, v) < 400.0f)\n"
                "\t\t{\n\t\t\tif (++r.frames >= 30)\n\t\t\t{\n"
                "\t\t\t\tr.asleep = true;\n\t\t\t\tr.vel = v;\n\t\t\t\tr.base = actor->ActorBase();\n\t\t\t\tr.state = actor->GetStateName();\n\t\t\t}\n\t\t}\n"
                "\t\telse\n\t\t{\n\t\t\tr.frames = 0;\n\t\t\tr.loc = actor->Location();\n\t\t}\n\t}\n#endif\n\n"
                + m.group(0)),
     'vita-restbounce-helpers')
edit(PHYS,
     re.escape("\t\tcase PHYS_Falling: PhysFalling(actor, deltaTime, 0); break;\n"),
     lambda m: ("#ifdef __vita__ // vita-restbounce: resting bouncers sleep\n"
                "\t\tcase PHYS_Falling:\n"
                "\t\t\tif (actor->bBounce())\n\t\t\t{\n"
                "\t\t\t\tif (VitaRestAsleep(actor))\n\t\t\t\t{\n"
                "\t\t\t\t\tif (VitaProbes::enabled)\n\t\t\t\t\t\tVitaProbes::calls[VitaProbes::RestSkip]++;\n"
                "\t\t\t\t\tbreak;\n\t\t\t\t}\n"
                "\t\t\t\tPhysFalling(actor, deltaTime, 0);\n"
                "\t\t\t\tVitaRestAfter(actor);\n\t\t\t\tbreak;\n\t\t\t}\n"
                "\t\t\tPhysFalling(actor, deltaTime, 0);\n\t\t\tbreak;\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-restbounce:')

edit(PHYS, re.escape('#include "KWPhysics.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-restbounce-include\n#include <unordered_map>\n', 'vita-restbounce-include')


# 140. Grandstaircase_hub: 'bsp info' 15 ms, of which 'bsp info: skeletal box' 8.6 ms for 766 skeletal-mesh actors a frame
#      (KW::GetRenderBoundingBox poses the skeleton). The BSP placement is only for drawing, and a bHidden actor is never drawn:
#      DrawScene no longer places hidden actors (their placement is made again the frame they show; GetBoundingBox(exact) still
#      places them). render.cfg bsp_hidden=1: the old way.
edit("Render/RenderScene.cpp",
     re.escape("\t\tif (actor)\n\t\t\tactor->UpdateBspInfo(); // vita-probe-bspactor removed: vita-bspactor-off\n"),
     lambda m: ("#ifdef __vita__ // vita-bsphidden\n"
                "\t\tstatic const bool vitaBspHidden = VitaConfigInt(\"bsp_hidden\", 0) != 0;\n"
                "\t\tif (actor && (vitaBspHidden || !actor->bHidden()))\n\t\t\tactor->UpdateBspInfo();\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-bsphidden')


# 141. render.cfg vm_laps=1: laps in Frame::Call of a script function ('vm: setup / run / finish') and the statements run
#      ('vm: statements' calls): HP2's HPawn.Tick (Super.Tick, +=, <, return) costs ~15 us a call.
edit("VM/Frame.cpp",
     re.escape("\t\tFrame frame(instance, func, 0, false);\n\n\t\t// Store args in function frame local variables\n"),
     lambda m: ("#ifdef __vita__ // vita-vmlaps-start\n"
                "\t\tif (VitaProbes::vmLaps < 0)\n\t\t\tVitaProbes::vmLaps = VitaConfigInt(\"vm_laps\", 0) != 0 ? 1 : 0;\n"
                "\t\tstruct VitaVmLap\n\t\t{\n\t\t\tuint64_t last = 0;\n\t\t\tbool on = false;\n"
                "\t\t\tvoid Mark(VitaProbes::Id id)\n\t\t\t{\n\t\t\t\tif (!on)\n\t\t\t\t\treturn;\n"
                "\t\t\t\tconst uint64_t now = VitaProbes::Now();\n\t\t\t\tVitaProbes::us[id] += (double)(now - last);\n\t\t\t\tVitaProbes::calls[id]++;\n\t\t\t\tlast = now;\n\t\t\t}\n"
                "\t\t\t~VitaVmLap() { Mark(VitaProbes::VmFinish); }\n"
                "\t\t} vitaVmLap;\n"
                "\t\tif (VitaProbes::vmLaps == 1)\n\t\t{\n\t\t\tvitaVmLap.on = true;\n\t\t\tvitaVmLap.last = VitaProbes::Now();\n\t\t}\n#endif\n"
                + m.group(0)),
     'vita-vmlaps-start')
edit("VM/Frame.cpp",
     re.escape("\t\t// Run the function\n\t\tExpressionValue result = frame.Run().Value;\n"),
     lambda m: ("#ifdef __vita__ // vita-vmlaps-run\n\t\tvitaVmLap.Mark(VitaProbes::VmSetup);\n#endif\n" + m.group(0) +
                "#ifdef __vita__ // vita-vmlaps-ran\n\t\tvitaVmLap.Mark(VitaProbes::VmRun);\n#endif\n"),
     'vita-vmlaps-run')
edit("VM/Frame.cpp",
     re.escape("\t\tExpression* statement = Func->Code->Statements[curStatementIndex];\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-vmlaps-stmt\n\t\tif (VitaProbes::vmLaps == 1)\n\t\t\tVitaProbes::calls[VitaProbes::VmStatements]++;\n#endif\n",
     'vita-vmlaps-stmt')


# 142. Grandstaircase_hub (GSTATE050): ~1190 actor ticks a frame, ~9900 script calls and ~49000 statements (#141). The most
#      called script function is HPawn.Tick (hundreds of props, points and characters): Super.Tick (empty), fCurrTime += dtime,
#      'if (fCurrTime < 1.0) return', then once a second the despawn check. A function whose code starts with exactly that shape
#      (an optional call of an empty function with plain local arguments; <float instance variable> += <its first parameter>;
#      if (<that variable> < <float constant, or a float instance variable>) return without a value) is recognised once from its expressions; when the sum
#      stays under the constant, Frame::Call stores it and returns (what the script does); otherwise the script runs from the
#      start as before. Log: 'script: guard prefix answered' (laps). render.cfg tick_guard=0: off.
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaFastOp = -1; // vita-fastop-field"),
     lambda m: ("\tint8_t VitaGuard = -1; // vita-guard-field: the code starts with the accumulate-and-return guard (1), not (0), unknown (-1)\n"
                "\tUProperty* VitaGuardVar = nullptr; // vita-guard-field2\n\tfloat VitaGuardLimit = 0.0f;\n\tUProperty* VitaGuardLimitVar = nullptr; // or the limit is this float variable\n" + m.group(0)),
     'vita-guard-field')
edit("VM/Frame.cpp",
     re.escape("\t\t// While a singular function runs on an object, every singular call on that object is skipped"),
     lambda m: ("#ifdef __vita__ // vita-guard-call\n"
                "\t\tif (func->VitaGuard < 0)\n\t\t\tfunc->VitaGuard = VitaFindGuard(func) ? 1 : 0;\n"
                "\t\tif (func->VitaGuard == 1 && args.size() >= 1)\n\t\t{\n"
                "\t\t\tfloat* acc = (float*)((uint8_t*)instance->PropertyData.Data + func->VitaGuardVar->DataOffset.DataOffset);\n"
                "\t\t\tconst float sum = *acc + args[0].ToFloat();\n"
                "\t\t\tconst float limit = func->VitaGuardLimitVar ? *(const float*)((const uint8_t*)instance->PropertyData.Data + func->VitaGuardLimitVar->DataOffset.DataOffset) : func->VitaGuardLimit;\n"
                "\t\t\tif (sum < limit)\n\t\t\t{\n"
                "\t\t\t\t*acc = sum;\n"
                "\t\t\t\tif (VitaProbes::enabled)\n\t\t\t\t\tVitaProbes::calls[VitaProbes::TickGuard]++;\n"
                "\t\t\t\treturn ExpressionValue::NothingValue();\n\t\t\t}\n\t\t}\n#endif\n" + m.group(0)),
     'vita-guard-call')
edit("VM/Frame.cpp",
     re.escape("ExpressionValue Frame::Call(UFunction* func, UObject* instance, const ArrayView<ExpressionValue>& args)\n{\n"),
     lambda m: ("#ifdef __vita__ // vita-guard-find: see apply_fixes.sh #142\n"
                "static bool VitaIsEmptyCode(UFunction* f)\n{\n"
                "\tif (!f || AllFlags(f->FuncFlags, FunctionFlags::Native) || !f->Code || f->Code->Statements.size() != 1 || !f->Code->Statements[0] ||\n"
                "\t\tf->Code->Statements[0]->Type != ExpressionType::Return)\n\t\treturn false;\n"
                "\tExpression* value = static_cast<ReturnExpression*>(f->Code->Statements[0])->Value;\n"
                "\tif (value && value->Type != ExpressionType::Nothing)\n\t\treturn false;\n"
                "\tfor (UProperty* prop : f->Properties)\n"
                "\t\tif (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm) || AllFlags(prop->PropFlags, PropertyFlags::OutParm))\n\t\t\treturn false;\n"
                "\treturn true;\n}\n\n"
                "static bool VitaFindGuard(UFunction* func)\n{\n"
                "\tstatic const bool on = VitaConfigInt(\"tick_guard\", 1) != 0;\n"
                "\tif (!on || !func->Code || AllFlags(func->FuncFlags, FunctionFlags::Singular))\n\t\treturn false;\n"
                "\tUProperty* firstParm = nullptr;\n"
                "\tfor (UProperty* prop : func->Properties)\n\t\tif (AllFlags(prop->PropFlags, PropertyFlags::Parm))\n\t\t{\n\t\t\tfirstParm = prop;\n\t\t\tbreak;\n\t\t}\n"
                "\tif (!firstParm || !dynamic_cast<UFloatProperty*>(firstParm) || AllFlags(firstParm->PropFlags, PropertyFlags::OutParm))\n\t\treturn false;\n"
                "\tconst auto& st = func->Code->Statements;\n\tsize_t i = 0;\n"
                "\tif (st.size() >= 1 && st[0] && st[0]->Type == ExpressionType::FinalFunction)\n\t{\n"
                "\t\tauto call = static_cast<FinalFunctionExpression*>(st[0]);\n"
                "\t\tif (!VitaIsEmptyCode(call->Func))\n\t\t\treturn false;\n"
                "\t\tfor (Expression* a : call->Args)\n"
                "\t\t\tif (a && a->Type != ExpressionType::LocalVariable && a->Type != ExpressionType::Nothing)\n\t\t\t\treturn false;\n"
                "\t\ti = 1;\n\t}\n"
                "\tif (st.size() < i + 3 || !st[i] || !st[i + 1] || !st[i + 2])\n\t\treturn false;\n"
                "\tif (st[i]->Type != ExpressionType::NativeFunction)\n\t\treturn false;\n"
                "\tauto add = static_cast<NativeFunctionExpression*>(st[i]);\n"
                "\tUFunction* addFunc = NativeFunctions::FuncByIndex[add->nativeindex];\n"
                "\tif (!addFunc || addFunc->Name != NameString(\"AddEqual_FloatFloat\") || add->Args.size() != 2 || !add->Args[0] || !add->Args[1] ||\n"
                "\t\tadd->Args[0]->Type != ExpressionType::InstanceVariable || add->Args[1]->Type != ExpressionType::LocalVariable)\n\t\treturn false;\n"
                "\tUProperty* var = static_cast<InstanceVariableExpression*>(add->Args[0])->Variable;\n"
                "\tif (!var || !dynamic_cast<UFloatProperty*>(var) || var->ArrayDimension != 1 || static_cast<LocalVariableExpression*>(add->Args[1])->Variable != firstParm)\n\t\treturn false;\n"
                "\tif (st[i + 1]->Type != ExpressionType::JumpIfNot)\n\t\treturn false;\n"
                "\tExpression* cond = static_cast<JumpIfNotExpression*>(st[i + 1])->Condition;\n"
                "\tif (!cond || cond->Type != ExpressionType::NativeFunction)\n\t\treturn false;\n"
                "\tauto less = static_cast<NativeFunctionExpression*>(cond);\n"
                "\tUFunction* lessFunc = NativeFunctions::FuncByIndex[less->nativeindex];\n"
                "\tif (!lessFunc || lessFunc->Name != NameString(\"Less_FloatFloat\") || less->Args.size() != 2 || !less->Args[0] || !less->Args[1] ||\n"
                "\t\tless->Args[0]->Type != ExpressionType::InstanceVariable || static_cast<InstanceVariableExpression*>(less->Args[0])->Variable != var ||\n"
                "\t\t(less->Args[1]->Type != ExpressionType::FloatConst && less->Args[1]->Type != ExpressionType::InstanceVariable))\n\t\treturn false;\n"
                "\tUProperty* limitVar = nullptr;\n"
                "\tif (less->Args[1]->Type == ExpressionType::InstanceVariable)\n\t{\n"
                "\t\tlimitVar = static_cast<InstanceVariableExpression*>(less->Args[1])->Variable;\n"
                "\t\tif (!limitVar || !dynamic_cast<UFloatProperty*>(limitVar) || limitVar->ArrayDimension != 1)\n\t\t\treturn false;\n\t}\n"
                "\tif (st[i + 2]->Type != ExpressionType::Return)\n\t\treturn false;\n"
                "\tExpression* rv = static_cast<ReturnExpression*>(st[i + 2])->Value;\n"
                "\tif (rv && rv->Type != ExpressionType::Nothing)\n\t\treturn false;\n"
                "\tfor (UProperty* prop : func->Properties)\n"
                "\t\tif (AllFlags(prop->PropFlags, PropertyFlags::ReturnParm) || AllFlags(prop->PropFlags, PropertyFlags::OutParm))\n\t\t\treturn false;\n"
                "\tfunc->VitaGuardVar = var;\n"
                "\tfunc->VitaGuardLimitVar = limitVar;\n\tfunc->VitaGuardLimit = limitVar ? 0.0f : static_cast<FloatConstExpression*>(less->Args[1])->Value;\n"
                "\tLogMessage(\"tick_guard: \" + func->Name.ToString() + \" (\" + var->Name.ToString() + \" < \" + (limitVar ? limitVar->Name.ToString() : std::to_string(func->VitaGuardLimit)) + \") answered natively\");\n"
                "\treturn true;\n}\n#endif\n\n" + m.group(0)),
     'vita-guard-find')

edit("VM/Frame.cpp", re.escape('#include "VitaConfig.h" // vita-sprof-include\n'),
     lambda m: m.group(0) + '#include "Packages/Core/Properties/UFloatProperty.h" // vita-guard-include\n', 'vita-guard-include')



# 144. Grandstaircase_hub: 516 skeletal-mesh actors a frame get their render box made again (~11 us each, they animate: candle
#      flames), only to place them in the BSP for drawing. One that has not moved (same Location and Rotation as at its last
#      placement) and is farther than 1000 units from the camera is placed again every skel_box_rate (4) frames, staggered;
#      a moved or near one every frame as before. render.cfg skel_box_rate=1: every frame.
edit("Packages/Engine/Actors/UActor.h",
     re.escape("\t\tint8_t VitaStatic = -1;     // vita-bspstatic-field"),
     lambda m: ("\t\tvec3 VitaSkelLoc = vec3(0.0f); // vita-skelrate-field: Location / Rotation at the last skeletal box\n"
                "\t\tint VitaSkelRot[3] = { 0, 0, 0 };\n\t\tbool VitaSkelValid = false;\n" + m.group(0)),
     'vita-skelrate-field')
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape("\t\tif (!animated)\n\t\t{\n\t\t\tconst vec3 location = Location();\n"),
     lambda m: ("\t\tif (animated && BspInfo.Node && drawType == DT_Mesh) // vita-skelrate\n\t\t{\n"
                "\t\t\tstatic const int vitaSkelRate = std::max(VitaConfigInt(\"skel_box_rate\", 4), 1);\n"
                "\t\t\tconst vec3 location = Location();\n\t\t\tconst Rotator rotation = Rotation();\n"
                "\t\t\tconst bool still = BspInfo.VitaSkelValid && BspInfo.VitaSkelLoc == location && BspInfo.VitaSkelRot[0] == rotation.Pitch &&\n"
                "\t\t\t\tBspInfo.VitaSkelRot[1] == rotation.Yaw && BspInfo.VitaSkelRot[2] == rotation.Roll;\n"
                "\t\t\tconst vec3 d = location - engine->CameraLocation;\n"
                "\t\t\tif (vitaSkelRate > 1 && still && dot(d, d) > 1000.0f * 1000.0f &&\n"
                "\t\t\t\t((((uint32_t)(uintptr_t)this >> 6) + VitaTimers::frameNumber) % (uint32_t)vitaSkelRate) != 0)\n\t\t\t\treturn;\n"
                "\t\t\tBspInfo.VitaSkelValid = true;\n\t\t\tBspInfo.VitaSkelLoc = location;\n"
                "\t\t\tBspInfo.VitaSkelRot[0] = rotation.Pitch;\n\t\t\tBspInfo.VitaSkelRot[1] = rotation.Yaw;\n\t\t\tBspInfo.VitaSkelRot[2] = rotation.Roll;\n\t\t}\n"
                + m.group(0)),
     'vita-skelrate')


# 145. vm_laps=1 also splits VitaCallEvent ('event: enabled / checks / find / call'): an ActorShadow Tick event (bUpdated = false;
#      return) costs ~32 us, far more than its frame (setup + finish ~2 us).
edit("VM/ScriptCall.cpp",
     re.escape("ExpressionValue VitaCallEvent(UObject* Context, EventName eventname, ExpressionValue* args, size_t count)\n{\n\tif (!Context->IsEventEnabled(eventname))\n\t\treturn ExpressionValue::NothingValue();\n\n\tif (auto actor = UObject::TryCast<UActor>(Context))\n\t{\n\t\tif (!actor->Level()->bBegunPlay() || (actor->bDeleteMe() && eventname != EventName::Destroyed))\n\t\t\treturn ExpressionValue::NothingValue();\n\t}\n\n\tUFunction* func = FindEventFunction(Context, ToNameString(eventname));\n\tif (func)\n\t\treturn Frame::Call(func, Context, { args, count });\n"),
     lambda m: ("ExpressionValue VitaCallEvent(UObject* Context, EventName eventname, ExpressionValue* args, size_t count)\n{\n"
                "\tstruct VitaEvLap\n\t{\n\t\tuint64_t last = 0;\n\t\tbool on = false;\n"
                "\t\tvoid Mark(VitaProbes::Id id)\n\t\t{\n\t\t\tif (!on)\n\t\t\t\treturn;\n\t\t\tconst uint64_t now = VitaProbes::Now();\n"
                "\t\t\tVitaProbes::us[id] += (double)(now - last);\n\t\t\tVitaProbes::calls[id]++;\n\t\t\tlast = now;\n\t\t}\n\t} vitaLap; // vita-evlaps\n"
                "\tif (VitaProbes::vmLaps == 1 && VitaProbes::enabled)\n\t{\n\t\tvitaLap.on = true;\n\t\tvitaLap.last = VitaProbes::Now();\n\t}\n"
                "\tif (!Context->IsEventEnabled(eventname))\n\t\treturn ExpressionValue::NothingValue();\n\tvitaLap.Mark(VitaProbes::EvEnabled);\n\n"
                "\tif (auto actor = UObject::TryCast<UActor>(Context))\n\t{\n\t\tif (!actor->Level()->bBegunPlay() || (actor->bDeleteMe() && eventname != EventName::Destroyed))\n\t\t\treturn ExpressionValue::NothingValue();\n\t}\n"
                "\tvitaLap.Mark(VitaProbes::EvChecks);\n\n"
                "\tUFunction* func = FindEventFunction(Context, ToNameString(eventname));\n\tvitaLap.Mark(VitaProbes::EvFind);\n"
                "\tif (func)\n\t{\n\t\tExpressionValue r = Frame::Call(func, Context, { args, count });\n\t\tvitaLap.Mark(VitaProbes::EvCall);\n\t\treturn r;\n\t}\n"),
     'vita-evlaps')

edit("VM/ScriptCall.cpp", re.escape('#include "VitaFuncCache.h" // vita-funccache-inc2\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-evlaps-include\n', 'vita-evlaps-include')


# 146. The level the player leaves is let go (VitaLevelRelease.h: why and how). HP2 kept ~20 MB a level change and ran out of heap
#      on the 3rd-4th door between EntryHall_Hub and Grandstaircase_hub. render.cfg level_release=0: the old way.
#  a) GC::VitaFindUnreached: the collector's mark started from every object outside a set; says which objects of the set nothing
#     outside reaches. Marks are left as they were (unreferencedFlag true).
edit("GC/GC.h",
     re.escape('\tstatic GCAllocation* MarkObject(GCAllocation* marklist, GCObject* obj);\n'),
     lambda m: m.group(0) + ('\n\t// vita-gc-unreached (apply_fixes #146): result(obj, reached) for every object inside(obj) is true for: reached = an object\n'
                             '\t// outside the set points at it (through its properties, or a package\'s exports), directly or through others.\n'
                             '\ttemplate<typename Inside, typename Result> static void VitaFindUnreached(Inside inside, Result result);\n'),
     'vita-gc-unreached')
edit("GC/GC.h",
     re.escape('inline GCObjectList GC::GetObjects() { return {}; }\n'),
     lambda m: m.group(0) + ('\ntemplate<typename Inside, typename Result>\nvoid GC::VitaFindUnreached(Inside inside, Result result) // vita-gc-unreached-def\n{\n'
                             '\tGCAllocation* marklist = nullptr;\n'
                             '\tfor (GCAllocation* a = GetAllocations(); a; a = a->allocklistNext)\n'
                             '\t\tif (!inside(a->object()))\n\t\t\tmarklist = MarkObject(marklist, a->object());\n'
                             '\twhile (marklist)\n\t\tmarklist = Mark(marklist);\n'
                             '\tstd::vector<std::pair<GCObject*, bool>> found;\n'
                             '\tfor (GCAllocation* a = GetAllocations(); a; a = a->allocklistNext)\n\t{\n'
                             '\t\tif (inside(a->object()))\n\t\t\tfound.push_back({ a->object(), !a->unreferencedFlag });\n'
                             '\t\ta->unreferencedFlag = true;\n\t}\n'
                             '\tfor (auto& f : found)\n\t\tresult(f.first, f.second);\n}\n'),
     'vita-gc-unreached-def')
#  b) An object property marked the address of its slot, not the object in it (and dropped the mark list): nothing was ever marked
#     through one. (GC::Collect is never run on the Vita; the mark above needs it.)
edit("Packages/Core/Properties/UObjectProperty.cpp",
     re.escape('\tGC::MarkObject(marklist, static_cast<UObject*>(data));\n\treturn marklist;\n'),
     lambda m: '\treturn GC::MarkObject(marklist, *static_cast<UObject**>(data)); // vita-markobjprop\n',
     'vita-markobjprop')
#  c) An object not loaded yet (a delayed load) has no property block: mark only its class.
edit("Packages/Core/UObject.cpp",
     re.escape('\tif (Class)\n\t{\n\t\tmarklist = GC::MarkObject(marklist, Class);\n'),
     lambda m: m.group(0) + '\t\tif (!PropertyData.Data || PropertyData.Size < Class->StructSize) // vita-mark-unloaded\n\t\t\treturn marklist;\n',
     'vita-mark-unloaded')
#  d) UnloadMap lets the old map go (the renderer flushed first: no batch still points into it).
edit("Engine.cpp",
     re.escape('#include "VitaBoot.h" // vita-boot-inc\n'),
     lambda m: m.group(0) + '#include "VitaLevelRelease.h" // vita-levelrelease-inc\n',
     'vita-levelrelease-inc')
edit("Engine.cpp",
     re.escape('void Engine::UnloadMap()\n{\n'),
     lambda m: m.group(0) + ('\tPackage* vitaOldPackage = (LevelPackage && LevelPackage != EntryLevelPackage) ? LevelPackage : nullptr; // vita-levelrelease-old\n'
                             '\tULevel* vitaOldLevel = Level;\n'),
     'vita-levelrelease-old')
edit("Engine.cpp",
     re.escape('\tviewport->Actor() = nullptr;\n\n\tif (VitaConfigInt("gc", 0))'),
     lambda m: ('\tviewport->Actor() = nullptr;\n\n'
                '\tif (vitaOldPackage) // vita-levelrelease-call\n\t{\n'
                '\t\tif (render && render->Device)\n\t\t\trender->Device->Flush(true);\n'
                '\t\tVitaLevelRelease::Release(vitaOldPackage, vitaOldLevel, EntryLevelPackage);\n\t}\n\n'
                '\tif (VitaConfigInt("gc", 0))'),
     'vita-levelrelease-call')
#  e) The caches kept by actor empty themselves when a level is let go.
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "VitaConfig.h" // vita-skininc\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n', 'vita-epoch-inc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\tSkelCache& cache = SkelCaches[actor];\n'),
     lambda m: '\t\tVITA_LEVEL_EPOCH_CLEAR(SkelCaches); // vita-epoch-skel\n' + m.group(0), 'vita-epoch-skel')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\tif (VitaSkinCache.size() > 600)\n'),
     lambda m: '\t\tVITA_LEVEL_EPOCH_CLEAR(VitaSkinCache); // vita-epoch-skin\n' + m.group(0), 'vita-epoch-skin')
edit("../../knowwonder/KWParticleFX.cpp",
     re.escape('#include "VitaTimers.h" // vita-ptinc\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n', 'vita-epoch-inc')
edit("../../knowwonder/KWParticleFX.cpp",
     re.escape('\t\t\tif (!a || a->bDeleteMe())\n\t\t\t\treturn nullptr;\n\t\t\tauto it = States.find(a);\n'),
     lambda m: m.group(0).replace('\t\t\tauto it', '\t\t\tVITA_LEVEL_EPOCH_CLEAR(States); // vita-epoch-pfx\n\t\t\tauto it'), 'vita-epoch-pfx')
edit("../../knowwonder/KWPhysics.cpp",
     re.escape('#include "VitaProbes.h" // vita-restbounce-include\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n', 'vita-epoch-inc')
edit("../../knowwonder/KWPhysics.cpp",
     re.escape('\t\tVitaRest& r = vitaRests[actor];\n'),
     lambda m: '\t\tVITA_LEVEL_EPOCH_CLEAR(vitaRests); // vita-epoch-rest\n' + m.group(0), 'vita-epoch-rest')


#  f) GC::VitaDirectRefs: the objects one object points at directly (its Mark, with the marks put back): level_release_why=1 logs
#     which outside objects keep the old level's objects (VitaLevelRelease.h).
edit("GC/GC.h",
     re.escape('template<typename Inside, typename Result>\nvoid GC::VitaFindUnreached'),
     lambda m: ('template<typename Visit>\nvoid GC::VitaDirectRefs(GCObject* obj, Visit visit) // vita-gc-directrefs\n{\n'
                '\tGCAllocation* list = obj->Mark(nullptr);\n'
                '\tfor (GCAllocation* a = list; a; a = a->marklistNext)\n\t\ta->unreferencedFlag = true;\n'
                '\tfor (GCAllocation* a = list; a; a = a->marklistNext)\n\t\tvisit(a->object());\n}\n\n') + m.group(0),
     'vita-gc-directrefs')
edit("GC/GC.h",
     re.escape('\ttemplate<typename Inside, typename Result> static void VitaFindUnreached(Inside inside, Result result);\n'),
     lambda m: m.group(0) + '\ttemplate<typename Visit> static void VitaDirectRefs(GCObject* obj, Visit visit); // vita-gc-directrefs-decl\n',
     'vita-gc-directrefs-decl')

#  g) Trees patched by the first #146: Release takes the Entry level's package too.
edit("Engine.cpp",
     re.escape('VitaLevelRelease::Release(vitaOldPackage, vitaOldLevel);'),
     lambda m: 'VitaLevelRelease::Release(vitaOldPackage, vitaOldLevel, EntryLevelPackage);',
     'vitaOldLevel, EntryLevelPackage')

#  h) An event sent to an actor with no LevelInfo (a let-go actor still known to some native code: its properties are its class's
#     defaults now) is dropped and logged, instead of crashing on Level()->bBegunPlay (seen right after a door, by data abort).
edit("VM/ScriptCall.cpp",
     re.escape('\tif (auto actor = UObject::TryCast<UActor>(Context))\n\t{\n\t\tif (!actor->Level()->bBegunPlay()'),
     lambda m: ('\tif (auto actor = UObject::TryCast<UActor>(Context))\n\t{\n'
                '\t\tif (!actor->Level()) // vita-nolevel-event\n\t\t{\n\t\t\tstatic int vitaNoLevel = 0;\n'
                '\t\t\tif (vitaNoLevel++ < 20)\n'
                '\t\t\t\tLogMessage("CallEvent: " + ToNameString(eventname).ToString() + " sent to " + actor->Name.ToString() + " (" +\n'
                '\t\t\t\t\t(actor->Class ? actor->Class->Name.ToString() : std::string("?")) + "), an actor with no level: dropped");\n'
                '\t\t\treturn ExpressionValue::NothingValue();\n\t\t}\n'
                '\t\tif (!actor->Level()->bBegunPlay()'),
     'vita-nolevel-event')

edit("VM/ScriptCall.cpp",
     r'(const NameString& name, Array<ExpressionValue> args\)\n\{[\s\S]*?)ToNameString\(eventname\)\.ToString\(\)',
     lambda m: m.group(1) + 'name.ToString()',
     'name.ToString() + " sent to "')
edit("VM/ScriptCall.cpp",
     re.escape('#include "VitaProbes.h" // vita-evlaps-include\n'),
     lambda m: m.group(0) + '#include "Utils/Logger.h" // vita-nolevel-include\n',
     'vita-nolevel-include')

#  i) The let-go actors are freed too (level_free_actors=0: only hollowed): their shells (~2.3 MB a level, ~400 bytes each with
#     their state frames) were what still grew. GC::VitaFree takes objects out of the list and frees them like Sweep does; the old
#     package forgets them (Package::VitaForgetExports: its Mark would read them). The caches compared by pointer that could meet
#     a new actor at a freed one's address empty themselves with the level epoch (VitaLevelEpoch.h): music's player, coronas.
edit("GC/GC.h",
     re.escape('\ttemplate<typename Visit> static void VitaDirectRefs(GCObject* obj, Visit visit); // vita-gc-directrefs-decl\n'),
     lambda m: m.group(0) + '\tstatic void VitaFree(const std::vector<GCObject*>& objects); // vita-gc-free-decl\n',
     'vita-gc-free-decl')
edit("GC/GC.cpp",
     re.escape('GCStats GC::GetStats()\n'),
     lambda m: ('void GC::VitaFree(const std::vector<GCObject*>& objects) // vita-gc-free (apply_fixes #146)\n{\n'
                '\tif (objects.empty())\n\t\treturn;\n'
                '\tstd::unordered_set<GCObject*> gone(objects.begin(), objects.end());\n'
                '\tGCAllocation* prev = nullptr;\n\tGCAllocation* cur = allocations;\n'
                '\twhile (cur)\n\t{\n\t\tGCAllocation* next = cur->allocklistNext;\n'
                '\t\tif (gone.count(cur->object()))\n\t\t{\n'
                '\t\t\tif (prev)\n\t\t\t\tprev->allocklistNext = next;\n\t\t\telse\n\t\t\t\tallocations = next;\n'
                '\t\t\tstats.memoryUsage -= cur->memsize;\n\t\t\tstats.numObjects--;\n'
                '\t\t\tcur->object()->~GCObject();\n\t\t\tfree(cur);\n\t\t}\n'
                '\t\telse\n\t\t\tprev = cur;\n\t\tcur = next;\n\t}\n}\n\n') + m.group(0),
     'vita-gc-free (apply_fixes')
edit("GC/GC.cpp",
     re.escape('#include "GC.h"\n'),
     lambda m: m.group(0) + '#include <unordered_set> // vita-gc-free-inc\n',
     'vita-gc-free-inc')
edit("Package/Package.h",
     re.escape('\ttemplate<class T> Array<T*> GetAllObjects();\n'),
     lambda m: m.group(0) + ('\n\t// vita-forget-exports (apply_fixes #146): the exports gone(obj) says were freed are forgotten (a later GetUObject loads them again)\n'
                             '\ttemplate<class F> void VitaForgetExports(F gone) { for (UObject*& obj : ExportObjects) if (obj && gone(obj)) obj = nullptr; }\n'),
     'vita-forget-exports')
edit("../../knowwonder/KWSound.cpp",
     re.escape('\t\tif (player != music.player)\n\t\t{\n\t\t\tmusic.player = player;\n'),
     lambda m: ('\t\tstatic int vitaMusicEpoch = 0; // vita-epoch-music: a new PlayerPawn can be where a freed one was\n'
                '\t\tif (player != music.player || vitaMusicEpoch != vitaLevelEpoch)\n\t\t{\n\t\t\tvitaMusicEpoch = vitaLevelEpoch;\n\t\t\tmusic.player = player;\n'),
     'vita-epoch-music')
edit("../../knowwonder/KWSound.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n',
     'vita-epoch-inc')
edit("Render/VisibleCorona.cpp",
     re.escape('\tif (cache.size() > 4096)\n\t\tcache.clear();\n'),
     lambda m: '\tVITA_LEVEL_EPOCH_CLEAR(cache); // vita-epoch-corona\n' + m.group(0),
     'vita-epoch-corona')
edit("Render/VisibleCorona.cpp",
     re.escape('#ifdef __vita__ // vita-corona\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n',
     'vita-epoch-inc')

#  j) The let-go BSP models (and their polygons) are freed too, and the old package forgets its name, import and export tables
#     (Package::VitaForgetTables). KWBspCheck's hull cache (kept by model) empties itself with the epoch.
edit("Package/Package.h",
     re.escape('\ttemplate<class F> void VitaForgetExports(F gone) { for (UObject*& obj : ExportObjects) if (obj && gone(obj)) obj = nullptr; }\n'),
     lambda m: m.group(0) + ('\tvoid VitaForgetTables() // vita-forget-tables: a map package left behind (nothing loads from it again)\n\t{\n'
                             '\t\tArray<NameTableEntry>().swap(NameTable);\n\t\tArray<ExportTableEntry>().swap(ExportTable);\n'
                             '\t\tArray<ImportTableEntry>().swap(ImportTable);\n\t\tNameHash.clear();\n\t}\n'),
     'vita-forget-tables')
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape('\t\tif (frame.Model != cachedModel)\n\t\t{\n\t\t\tcache.clear();\n'),
     lambda m: '\t\tVITA_LEVEL_EPOCH_CLEAR(cache); // vita-epoch-hull: a new model can be where a freed one was\n' + m.group(0),
     'vita-epoch-hull')
edit("../../knowwonder/KWBspCheck.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-epoch-inc\n',
     'vita-epoch-inc')


# 147. The log was written out only when a line came more than a second after the last write: a game that hung while starting
#      left flipendo.log EMPTY (twice on 07 Nov, Lev2_Fire1 by --level). The first 400 lines and every 'Boot:' line are now written
#      at once, so a hang at the start shows where it stopped.
edit("GameApp.cpp",
     re.escape('\t\t\t\tif (now - lastFlush > std::chrono::seconds(1) || line.Text.find("FATAL") != std::string::npos)\n'),
     lambda m: ('\t\t\t\tstatic int vitaLogLines = 0; // vita-logstart: the start is written line by line\n'
                '\t\t\t\tif (now - lastFlush > std::chrono::seconds(1) || line.Text.find("FATAL") != std::string::npos ||\n'
                '\t\t\t\t\t++vitaLogLines < 400 || line.Text.compare(0, 5, "Boot:") == 0)\n'),
     'vita-logstart')
# 148. The log on its own thread (VitaLogWriter.h): the once-a-second write to the card (#33) was 5-6% of the engine thread in the
#      profile of 07 Nov. The engine thread appends; the 'logwriter' thread writes every 250 ms; FATAL lines and the end at once.
edit("GameApp.cpp",
     re.escape('#include "VitaBoot.h" // vita-boot-appinc\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-logwriter-inc\n#include "VitaLogWriter.h"\n#endif\n',
     'vita-logwriter-inc')
edit("GameApp.cpp",
     re.escape('\t\t\tlogfile.open(logfilename, std::ios::out | std::ios::trunc);\n'),
     lambda m: ('#ifdef __vita__ // vita-logwriter-open\n\t\t\tif (!VitaLogWriter::Open(logfilename))\n#endif\n' + m.group(0)),
     'vita-logwriter-open')
edit("GameApp.cpp",
     re.escape('#ifdef __vita__ // vita-logbuffer\n'),
     lambda m: (m.group(0) +
                '\t\t\t\tif (VitaLogWriter::fd >= 0) // vita-logwriter-line\n\t\t\t\t{\n'
                '\t\t\t\t\tchar time[32];\n\t\t\t\t\tsnprintf(time, sizeof(time), "[%g] ", line.Time); // as the stream writes it\n'
                '\t\t\t\t\tstd::string text = time + line.Source + (line.Source.empty() ? "" : ": ") + line.Text + "\\n";\n'
                '\t\t\t\t\tVitaLogWriter::Append(text, line.Text.find("FATAL") != std::string::npos);\n'
                '\t\t\t\t\treturn;\n\t\t\t\t}\n'),
     'vita-logwriter-line')
edit("GameApp.cpp",
     re.escape('\t\t\tif (logfile.is_open())\n\t\t\t\tlogfile << "FATAL: " << e.what() << std::endl;\n'),
     lambda m: ('#ifdef __vita__ // vita-logwriter-fatal\n\t\t\tif (VitaLogWriter::fd >= 0)\n'
                '\t\t\t\tVitaLogWriter::Append(std::string("FATAL: ") + e.what() + "\\n", true);\n#endif\n' + m.group(0)),
     'vita-logwriter-fatal')
edit("GameApp.cpp",
     re.escape('\tDeinitWidgetResources();\n\treturn 0;\n}'),
     lambda m: '#ifdef __vita__ // vita-logwriter-end\n\tVitaLogWriter::Flush();\n#endif\n' + m.group(0),
     'vita-logwriter-end')
# 149. Loading: Package::FindObjectReference walked the whole export table for every object it was asked for (every import of
#      every package, every GetUObject by name): ~20% of a level load in the profile of 07 Nov (GetUObject 13.5, GetName 6.9,
#      FindObjectReference 5.4 with the inlined loop). Now the exports are listed by name (compare index) once per table size,
#      and only those with the name are looked at, in the same order (the same answer). The names compared with fixed
#      strings ("Class", "UnrealI", "UnrealShare") are made once (each NameString("...") is a string hash lookup).
edit("Package/Package.h",
     re.escape('\tstd::map<NameString, int> NameHash;\n'),
     lambda m: m.group(0) + ('#ifdef __vita__ // vita-exportsbyname\n'
                             '\tstd::unordered_map<int, std::vector<int>> VitaExportsByName; // compare index -> export indexes, ascending\n'
                             '\tsize_t VitaExportsIndexed = 0;\n'
                             '\tconst std::vector<int>* VitaExportsNamed(const NameString& name)\n\t{\n'
                             '\t\tif (VitaExportsIndexed != ExportTable.size())\n\t\t{\n'
                             '\t\t\tVitaExportsByName.clear();\n'
                             '\t\t\tfor (size_t i = 0; i < ExportTable.size(); i++)\n'
                             '\t\t\t\tVitaExportsByName[GetName(ExportTable[i].ObjName).GetCompareIndex()].push_back((int)i);\n'
                             '\t\t\tVitaExportsIndexed = ExportTable.size();\n\t\t}\n'
                             '\t\tauto it = VitaExportsByName.find(name.GetCompareIndex());\n'
                             '\t\treturn it != VitaExportsByName.end() ? &it->second : nullptr;\n\t}\n'
                             '#endif\n'),
     'vita-exportsbyname')
edit("Package/Package.cpp",
     re.escape('\tbool isClass = className == "Class";\n\n\tsize_t count = ExportTable.size();\n\tfor (size_t index = 0; index < count; index++)\n\t{\n\t\tExportTableEntry& entry = ExportTable[index];\n\t\tif (GetName(entry.ObjName) != objectName)\n\t\t\tcontinue;\n'),
     lambda m: ('#ifdef __vita__ // vita-findref\n'
                '\tstatic const NameString classString("Class");\n'
                '\tbool isClass = className == classString;\n'
                '\tconst std::vector<int>* named = VitaExportsNamed(objectName);\n'
                '\tsize_t count = named ? named->size() : 0;\n'
                '\tfor (size_t vitaI = 0; vitaI < count; vitaI++)\n\t{\n'
                '\t\tsize_t index = (size_t)(*named)[vitaI];\n'
                '\t\tExportTableEntry& entry = ExportTable[index];\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-findref')
edit("Package/Package.cpp",
     re.escape('\t\tif (!obj && packageName == "UnrealI")\n'),
     lambda m: ('#ifdef __vita__ // vita-unreali\n'
                '\t\tstatic const NameString unrealI("UnrealI"), unrealShare("UnrealShare");\n'
                '\t\tif (!obj && packageName == unrealI)\n'
                '\t\t\tobj = Packages->GetPackage(unrealShare)->GetUObject(className, objectName, group);\n'
                '\t\telse if (!obj && packageName == unrealShare)\n'
                '\t\t\tobj = Packages->GetPackage(unrealI)->GetUObject(className, objectName, group);\n'
                '#else\n' + m.group(0)),
     'vita-unreali')
edit("Package/Package.cpp",
     re.escape('\t\t\tobj = Packages->GetPackage("UnrealI")->GetUObject(className, objectName, group);\n'),
     lambda m: m.group(0) + '#endif // vita-unreali-end\n',
     'vita-unreali-end')
edit("Package/Package.h",
     re.escape('\t\tArray<ImportTableEntry>().swap(ImportTable);\n\t\tNameHash.clear();\n'),
     lambda m: m.group(0) + '\t\tstd::unordered_map<int, std::vector<int>>().swap(VitaExportsByName); // vita-forget-byname\n\t\tVitaExportsIndexed = 0;\n',
     'vita-forget-byname')
# 150. 'LoadMap done' also gives the speed of the whole-file reads alone (one read() of up to 20 MB each): the card's own speed,
#      to tell whether loading (~8.5 MB/s over all reads) is bound by the card or by the many small reads.
edit("Utils/File.cpp",
     re.escape('\tstatic inline uint64_t statSlurps = 0, statSlurpBytes = 0;\n'),
     lambda m: m.group(0) + '\tstatic inline uint64_t statSlurpMicros = 0; // vita-slurptime\n',
     'vita-slurptime')
edit("Utils/File.cpp",
     re.escape('\t\tif (DeviceRead(0, whole.data(), (size_t)length) != (size_t)length)\n'),
     lambda m: ('\t\tconst uint64_t vitaSlurpStart = sceKernelGetProcessTimeWide(); // vita-slurptime-read\n'
                '\t\tconst bool vitaSlurpOk = DeviceRead(0, whole.data(), (size_t)length) == (size_t)length;\n'
                '\t\tstatSlurpMicros += sceKernelGetProcessTimeWide() - vitaSlurpStart;\n'
                '\t\tif (!vitaSlurpOk)\n'),
     'vita-slurptime-read')
edit("Utils/File.cpp",
     re.escape('\t\tFileImpl::statWritten / 1048576.0, (unsigned long long)FileImpl::statWrites, FileImpl::statWriteMicros / 1000.0);\n\treturn text;\n'),
     lambda m: (m.group(0)[:-len('\treturn text;\n')] +
                '\tif (FileImpl::statSlurpMicros > 0) // vita-slurptime-text\n'
                '\t\treturn std::string(text) + "; whole files at " + std::to_string((int)(FileImpl::statSlurpBytes / 1048576.0 * 1e6 / FileImpl::statSlurpMicros)) + " MB/s";\n'
                '\treturn text;\n'),
     'vita-slurptime-text')
# 151. ActorShadow's Tick event natively when the class does not override it (VitaShadows.cpp VitaShadowTick; render.cfg
#      shadow_tick=0: off): 52 shadows in Lev2_Fire1 took 1.1 ms a frame in the event for three lines of script.
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape('\t\tVitaCallEvent(this, EventName::Tick, &vitaArg, 1);\n'),
     lambda m: '\t\tif (!VitaShadowTick(this)) // vita-shadowtick\n\t' + m.group(0),
     'vita-shadowtick')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape('#include "UActor.h"\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-shadowtick-decl\nbool VitaShadowTick(UActor* actor); // vita/VitaShadows.cpp\n#endif\n',
     'vita-shadowtick-decl')
# 152. Fog maps while the camera orbits Harry (Lev2_Fire1, a fog zone): every surface's fog map was built and uploaded again
#      every fog_rate frames once the eye had moved 1 unit ('node: fogmap' 3.4 -> 14.9 us, 'node: device' 8.7 -> 17 us a surface
#      while turning: +4 ms). The fog seen on a texel changes with the angle of the eye's ray, i.e. with eye movement / distance:
#      a fog map is now built again when the eye moved more than fog_move_percent (render.cfg, default 3; 0 = 1 unit as before)
#      of its distance to the surface, at least 1 unit.
edit("Light/LightSystem_Fog.cpp",
     re.escape('\tconst bool vitaMoved = vitaFogNew || dot(de, de) > 1.0f || dot(dor, dor) > 0.01f;\n'),
     lambda m: ('\tstatic const float vitaFogMove = VitaConfigInt("fog_move_percent", 3) * 0.01f; // vita-fogeyemove\n'
                '\tconst vec3 vitaToSurface = coords.Origin - vitaEye;\n'
                '\tconst float vitaFogLimit = std::max(1.0f, vitaFogMove * vitaFogMove * dot(vitaToSurface, vitaToSurface));\n'
                '\tconst bool vitaMoved = vitaFogNew || dot(de, de) > vitaFogLimit || dot(dor, dor) > 0.01f;\n'),
     'vita-fogeyemove')
# 153. Fog maps while the camera orbits (#152 did not help: the eye moves ~4 units a frame, ~39 fog maps a frame were built and
#      uploaded at ~107 us each): at most fog_budget (render.cfg, default 10; 0 = no limit) are built again a frame because the
#      eye moved; a new fog map always is, and so is one that has waited 4 x fog_rate frames (no starving the ones drawn last).
edit("Light/LightSystem_Fog.cpp",
     re.escape('\telse if ((FrameCounter - fogtex.first >= vitaFogRate || FrameCounter < fogtex.first) && vitaMoved) // vita-fogmoved\n'),
     lambda m: ('\tstatic const int vitaFogBudget = VitaConfigInt("fog_budget", 10); // vita-fogbudget\n'
                '\tstatic uint64_t vitaFogBudgetFrame = 0;\n\tstatic int vitaFogBuilt = 0;\n'
                '\tif (vitaFogBudgetFrame != (uint64_t)FrameCounter)\n\t{\n\t\tvitaFogBudgetFrame = (uint64_t)FrameCounter;\n\t\tvitaFogBuilt = 0;\n\t}\n'
                '\tconst bool vitaFogWaitedLong = FrameCounter - fogtex.first >= 4 * vitaFogRate;\n'
                '\tconst bool vitaFogInBudget = vitaFogBudget <= 0 || vitaFogBuilt < vitaFogBudget || vitaFogWaitedLong;\n'
                '\tif (vitaFogNew)\n\t\tvitaFogBuilt++;\n'
                '\telse if ((FrameCounter - fogtex.first >= vitaFogRate || FrameCounter < fogtex.first) && vitaMoved && vitaFogInBudget && ++vitaFogBuilt) // vita-fogmoved\n'),
     'vita-fogbudget')
# 154. The main view's mesh prepass starts before its level surfaces are drawn (VitaMeshPrepass.inc VitaPrepareMeshesBegin,
#      VitaJobs::BeginAsync): the two workers skin while the main thread draws the surfaces; DrawOpaqueActors joins in and stores
#      the results. After DrawPortals: the sky/mirror frames draw the same actors (their skeleton caches). prepass_early=0: off.
edit("Render/VisibleFrame.cpp",
     re.escape('\t\t{ VITA_TIMER(DrawPortals); DrawPortals(); }\n'),
     lambda m: m.group(0) + '\t\tif (engine->LaunchInfo.IsKnowWonder()) // vita-prepass-early\n\t\t\tKW::VitaPrepareMeshesBegin(this);\n',
     'vita-prepass-early')
edit("Render/VisibleFrame.cpp",
     re.escape('namespace KW { void VitaPrepareMeshes(VisibleFrame* frame); }\n'),
     lambda m: m.group(0) + 'namespace KW { void VitaPrepareMeshesBegin(VisibleFrame* frame); } // vita-prepass-early-decl\n',
     'vita-prepass-early-decl')
# 155. LightSystem::BeginFrame (the light scan, the light tree, the light maps' dirty marks: ~2.2 ms in Lev2_Fire1) runs on a
#      worker (VitaJobs::BeginAsync) while the main thread places the actors in the BSP ('bsp info', ~2.2 ms): the two touch
#      different fields (actor->Light.*, the light tree / actor->BspInfo, the BSP's actor lists). The first frames run it on
#      the main thread (the render.cfg readers' statics are made there, vita/CLAUDE.md). render.cfg light_begin_async=0: off.
edit("Render/RenderScene.cpp",
     re.escape('\t{ VITA_TIMER(LightBegin); engine->Level->Light.BeginFrame(); } // vita-lightbegin-timer\n'),
     lambda m: ('#ifdef __vita__ // vita-lightbegin-async\n'
                '\tstatic int vitaSceneFrames = 0;\n'
                '\tstatic const bool vitaLightAsyncOn = VitaConfigInt("light_begin_async", 1) != 0;\n'
                '\tconst bool vitaLightAsync = vitaLightAsyncOn && ++vitaSceneFrames > 3 &&\n'
                '\t\tVitaJobs::BeginAsync([](void*, int) { engine->Level->Light.BeginFrame(); }, nullptr, 1);\n'
                '\tif (!vitaLightAsync)\n#endif\n' + m.group(0)),
     'vita-lightbegin-async')
edit("Render/RenderScene.cpp",
     re.escape('\tmat4 worldToView = Coords::ViewToRenderDev().ToMatrix() * Coords::Rotation(engine->CameraRotation).Inverse().ToMatrix() * Coords::Location(engine->CameraLocation).ToMatrix();\n\t{ VITA_TIMER(Process);'),
     lambda m: ('#ifdef __vita__ // vita-lightbegin-join\n\tif (vitaLightAsync)\n\t{\n\t\tVITA_TIMER(LightBegin);\n\t\tVitaJobs::FinishAsync();\n\t}\n#endif\n' + m.group(0)),
     'vita-lightbegin-join')
edit("Render/RenderScene.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-jobs-scene-inc\n#include "VitaJobs.h"\n#endif\n',
     'vita-jobs-scene-inc')
edit("Render/RenderScene.cpp",
     re.escape('\tstatic const bool vitaLightAsyncOn = VitaConfigInt("light_begin_async", 1) != 0;\n'),
     lambda m: m.group(0) + ('\tif (vitaSceneFrames < 3) // vita-lightbegin-touch: BeginFrame reads these only in some branches: made here, not on a worker\n'
                             '\t\t(void)(VitaStillLights() + VitaLightAnimDivider() + VitaDynamicLightList() + VitaLightmapSkip() + VitaLightmapIncremental());\n'),
     'vita-lightbegin-touch')
# 156. AttachDecal (actor shadows: ~5 a frame in Lev2_Fire1, 'decal attach trace' 168 us each) traced the whole ray through
#      the BSP, collected every hit, sorted them and used the first. TraceRayModel::VitaTraceFirst finds that first hit alone:
#      the same walk in the same order, but every test made against the nearest hit so far (a subtree or polygon past it is
#      skipped; a later hit at the same distance loses, as after the stable sort).
edit("Collision/BottomLevel/TraceRayModel.h",
     re.escape('\tbool TraceAnyHit(UActor* owner, UModel* model, const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly);\n'),
     lambda m: m.group(0) + ('#ifdef __vita__ // vita-tracefirst-h\n'
                             '\tCollisionHitList VitaTraceFirst(UActor* owner, UModel* model, const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly);\n'
                             'private:\n'
                             '\tvoid VitaTraceFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double& best, bool visibilityOnly, BspNode* node, CollisionHit& hit, bool& found);\n'
                             'public:\n#endif\n'),
     'vita-tracefirst-h')
edit("Collision/BottomLevel/TraceRayModel.cpp",
     re.escape('bool TraceRayModel::TraceAnyHit(UActor* owner, UModel* model, const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly)\n'),
     lambda m: ('#ifdef __vita__ // vita-tracefirst\n'
                'CollisionHitList TraceRayModel::VitaTraceFirst(UActor* owner, UModel* model, const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly)\n{\n'
                '\tOwner = owner;\n\tModel = model;\n\tCollisionHitList hits;\n\tCollisionHit hit;\n\tbool found = false;\n\tdouble best = tmax;\n'
                '\tVitaTraceFirst(origin, tmin, dirNormalized, best, visibilityOnly, &Model->Nodes.front(), hit, found);\n'
                '\tif (found)\n\t\thits.push_back(hit);\n\treturn hits;\n}\n\n'
                'void TraceRayModel::VitaTraceFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double& best, bool visibilityOnly, BspNode* node, CollisionHit& hit, bool& found)\n{\n'
                '\tBspNode* polynode = node;\n\twhile (true)\n\t{\n'
                '\t\tif (!visibilityOnly || (polynode->NodeFlags & NF_NotVisBlocking) == 0)\n\t\t{\n'
                '\t\t\tdouble t = NodeRayIntersect(origin, tmin, dirNormalized, best, polynode);\n'
                '\t\t\tif (t >= tmin && t < best)\n\t\t\t{\n'
                '\t\t\t\tbest = t;\n\t\t\t\tfound = true;\n'
                '\t\t\t\thit = { (float)t, vec3(node->PlaneX, node->PlaneY, node->PlaneZ), Owner, polynode, node };\n'
                '\t\t\t\tif (dot(to_dvec3(hit.Normal), dirNormalized) > 0.0)\n\t\t\t\t\thit.Normal = -hit.Normal;\n'
                '\t\t\t}\n\t\t}\n'
                '\t\tif (polynode->Plane < 0) break;\n\t\tpolynode = &Model->Nodes[polynode->Plane];\n\t}\n\n'
                '\tdvec4 plane = { node->PlaneX, node->PlaneY, node->PlaneZ, -node->PlaneW };\n'
                '\tdouble fromSide = dot(dvec4(origin, 1.0), plane);\n'
                '\tdouble toSide = dot(dvec4(origin + dirNormalized * best, 1.0), plane);\n'
                '\tif (node->Front >= 0 && (fromSide >= 0.0 || toSide >= 0.0))\n'
                '\t\tVitaTraceFirst(origin, tmin, dirNormalized, best, visibilityOnly, &Model->Nodes[node->Front], hit, found);\n'
                '\ttoSide = dot(dvec4(origin + dirNormalized * best, 1.0), plane); // best may be nearer now\n'
                '\tif (node->Back >= 0 && (fromSide <= 0.0 || toSide <= 0.0))\n'
                '\t\tVitaTraceFirst(origin, tmin, dirNormalized, best, visibilityOnly, &Model->Nodes[node->Back], hit, found);\n'
                '}\n#endif\n\n' + m.group(0)),
     'vita-tracefirst')
edit("Packages/Engine/Actors/UDecal.cpp",
     re.escape('{ VITA_PROBE(DecalTrace); hits = XLevel()->Collision.TraceDecal(to_dvec3(Location()), 0.0f, to_dvec3(traceDirection), traceDistance, false); }'),
     lambda m: ('{ VITA_PROBE(DecalTrace); hits = XLevel()->Collision.VitaTraceDecalFirst(to_dvec3(Location()), 0.0f, to_dvec3(traceDirection), traceDistance, false); } // vita-decalfirst'),
     'vita-decalfirst')
edit("Collision/TopLevel/CollisionSystem.h",
     re.escape('\tCollisionHitList TraceDecal(const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly);\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-decalfirst-h\n\tCollisionHitList VitaTraceDecalFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly);\n#endif\n',
     'vita-decalfirst-h')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape('CollisionHit CollisionSystem::TraceFirstHit('),
     lambda m: ('#ifdef __vita__ // vita-decalfirst-fn: TraceDecal\'s first hit alone (#156)\n'
                'CollisionHitList CollisionSystem::VitaTraceDecalFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double tmax, bool visibilityOnly)\n{\n'
                '\tTraceRayModel trace;\n\treturn trace.VitaTraceFirst(LevelInfo, Level->Model, origin, tmin, dirNormalized, tmax, visibilityOnly);\n}\n#endif\n\n' + m.group(0)),
     'vita-decalfirst-fn')
# 157. SingleLineCheck with only TRACE_Movers / TRACE_Level (the walking physics' ledge and step probes: most of the ~90 line
#      checks a frame in Lev2_Fire1, snails) can accept only the level or a mover, yet every actor in the box was line checked
#      against its primitive first. Such a check now skips the other actors before their primitive test (the answer is the
#      same: SingleLineCheck would pass over them).
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\tArray<CheckResult> ActorLineCheck(const vec3& end, const vec3& start, const vec3& extent, uint8_t extraNodeFlags)\n\t{\n'),
     lambda m: ('#ifdef __vita__ // vita-moversonly\n\tstatic bool vitaMoversOnly = false; // SingleLineCheck can accept only movers (and the level)\n#endif\n' + m.group(0)),
     'vita-moversonly')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t\t\tif (!InHash(actor))\n\t\t\t\tcontinue;\n\t\t\tCheckResult hit;\n\t\t\thit.Time = 0.0f;\n\t\t\tbool vitaMiss;\n'),
     lambda m: m.group(0).replace('\t\t\t\tcontinue;\n', '\t\t\t\tcontinue;\n#ifdef __vita__ // vita-moversonly-skip\n\t\t\tif (vitaMoversOnly && !UObject::TryCast<UMover>(actor))\n\t\t\t\tcontinue;\n#endif\n', 1),
     'vita-moversonly-skip')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t\tfor (const CheckResult& r : MultiLineCheck(end, start, extent, traceActors, levelInfo, extraNodeFlags))\n'),
     lambda m: ('#ifdef __vita__ // vita-moversonly-set\n'
                '\t\tvitaMoversOnly = (traceFlags & (TRACE_Blocking | TRACE_Others | TRACE_ZoneChanges)) == 0;\n'
                '\t\tArray<CheckResult> vitaResults = MultiLineCheck(end, start, extent, traceActors, levelInfo, extraNodeFlags);\n'
                '\t\tvitaMoversOnly = false;\n'
                '\t\tfor (const CheckResult& r : vitaResults)\n#else\n' + m.group(0) + '#endif\n'),
     'vita-moversonly-set')
# 158. The scripts' actor iterators (AllActors, RadiusActors, VisibleActors, ...) test every actor of the level with IsA(name),
#      a walk up the class chain comparing names: GameReplicationInfo.Timer's foreach AllActors(class'PlayerReplicationInfo')
#      every 0.2 s over ~1300 actors was 0.66 ms a frame on average in Lev2_Fire1. The answer depends only on the actor's class:
#      VitaIsA keeps it in a 1024-entry direct-mapped table keyed by (class, name) (classes are never freed, #146).
edit("VM/Iterator.cpp",
     r'([A-Za-z_][A-Za-z_0-9.]*)->IsA\(BaseClass->Name\)',
     lambda m: 'VITA_ISA(' + m.group(1) + ', BaseClass->Name)',
     'VITA_ISA(')
edit("VM/Iterator.cpp",
     re.escape('#include <algorithm>\n'),
     lambda m: m.group(0) + ('#ifdef __vita__ // vita-isa-cache: IsA(name) by the object\'s class, remembered (#158)\n'
                             'static bool VitaIsA(const UObject* obj, const NameString& name)\n{\n'
                             '\tstruct Entry { const void* cls; int name; bool result; };\n'
                             '\tstatic Entry table[1024];\n'
                             '\tconst int key = name.GetCompareIndex();\n'
                             '\tEntry& e = table[(((uintptr_t)obj->Class >> 4) ^ ((uintptr_t)key * 2654435761u)) & 1023];\n'
                             '\tif (e.cls == obj->Class && e.name == key)\n\t\treturn e.result;\n'
                             '\tconst bool result = obj->IsA(name);\n'
                             '\te = { obj->Class, key, result };\n'
                             '\treturn result;\n}\n'
                             '#define VITA_ISA(o, n) VitaIsA((o), (n))\n#else\n#define VITA_ISA(o, n) (o)->IsA(n)\n#endif\n'),
     'vita-isa-cache')
# 159. '@script <name> <function>' also takes a class name: the first actor of that class (map actors can have other names).
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\t\t\t\tif (a && a->Name.ToString() == actorName)\n'),
     lambda m: '\t\t\t\t\tif (a && (a->Name.ToString() == actorName || a->Class->Name.ToString() == actorName)) // vita-script-byclass\n',
     'vita-script-byclass')
# 160. VitaShadows.cpp does all of ActorShadow.Update natively when the owner moved (render.cfg shadow_native=0: the script):
#      the same natives in the order of its bytecode (@script ActorShadow Update): DetachDecal, GetRenderExtent (KW's,
#      through KW::VitaRenderExtent), the int Max of the bytecode, SetLocation = FarMoveActor, SetRotation = MoveActor,
#      AttachDecal. ~350 us a moving shadow, of which ~120 us AttachDecal.
edit("../../knowwonder/KWCollision.cpp",
     re.escape('\t\tReturnValue = box.max - box.min;\n\t}\n'),
     lambda m: m.group(0) + '\n#ifdef __vita__ // vita-renderextent: GetRenderExtent for vita/VitaShadows.cpp\n\tvec3 VitaRenderExtent(UActor* a)\n\t{\n\t\tvec3 r;\n\t\tNGetRenderExtent(a, r);\n\t\treturn r;\n\t}\n#endif\n',
     'vita-renderextent')
# 161. Every line, point, radius and encroachment check asked CollisionSystem::ActorsInBox for a new Array of the actors in its
#      box (a heap allocation each: newlib's malloc takes a lock): ~80 line checks a frame in Lev2_Fire1 spent ~10 us each
#      outside the hash query and the primitives. VitaActorsInBox fills a list given to it; KWLevelCheck.cpp's VitaBoxList
#      hands out one of 4 kept lists by nesting depth (deeper: a local one). The same actors in the same order.
edit("Collision/TopLevel/CollisionSystem.h",
     re.escape('\tArray<UActor*> ActorsInBox(const vec3& boxMin, const vec3& boxMax); // every actor in the hash cells the box touches\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-boxfill-h\n\tvoid VitaActorsInBox(const vec3& boxMin, const vec3& boxMax, Array<UActor*>& result); // the same, into a list kept by the caller\n#endif\n',
     'vita-boxfill-h')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape('void CollisionSystem::SetLevel(ULevelInfo* levelInfo, ULevel* level)\n'),
     lambda m: ('#ifdef __vita__ // vita-boxfill: ActorsInBox into the caller\'s list (#161)\n'
                'void CollisionSystem::VitaActorsInBox(const vec3& boxMin, const vec3& boxMax, Array<UActor*>& result)\n{\n'
                '\tresult.clear();\n'
                '\tvec3 center = (boxMin + boxMax) * 0.5f;\n\tvec3 extents = (boxMax - boxMin) * 0.5f;\n'
                '\tivec3 start = GetStartExtents(center, extents);\n\tivec3 end = GetEndExtents(center, extents);\n'
                '\tif (end.x - start.x >= 100 || end.y - start.y >= 100 || end.z - start.z >= 100)\n\t\treturn;\n'
                '\tstatic uint32_t vitaStamp = 0x80000000u; // its own sequence: ActorsInBox\'s stamps count up from 1\n'
                '\tif (++vitaStamp == 0)\n\t\tvitaStamp = 0x80000000u;\n'
                '\tfor (int z = start.z; z < end.z; z++)\n\t\tfor (int y = start.y; y < end.y; y++)\n\t\t\tfor (int x = start.x; x < end.x; x++)\n\t\t\t{\n'
                '\t\t\t\tauto it = CollisionActors.find(GetBucketId(x, y, z));\n\t\t\t\tif (it == CollisionActors.end())\n\t\t\t\t\tcontinue;\n'
                '\t\t\t\tfor (UActor* actor : it->second)\n\t\t\t\t\tif (actor->Collision.VitaBoxStamp != vitaStamp)\n\t\t\t\t\t{\n'
                '\t\t\t\t\t\tactor->Collision.VitaBoxStamp = vitaStamp;\n\t\t\t\t\t\tresult.push_back(actor);\n\t\t\t\t\t}\n\t\t\t}\n}\n#endif\n\n' + m.group(0)),
     'vita-boxfill')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\tstatic bool InHash(UActor* actor)\n'),
     lambda m: ('#ifdef __vita__ // vita-boxlist: the actors in a box, in a kept list (#161)\n'
                '\tstruct VitaBoxList\n\t{\n'
                '\t\tstatic inline Array<UActor*> pool[4];\n\t\tstatic inline int depth = 0;\n'
                '\t\tArray<UActor*> local;\n\t\tArray<UActor*>* list;\n'
                '\t\tVitaBoxList(const vec3& boxMin, const vec3& boxMax)\n\t\t{\n'
                '\t\t\tlist = depth < 4 ? &pool[depth] : &local;\n\t\t\tdepth++;\n'
                '\t\t\tHash().VitaActorsInBox(boxMin, boxMax, *list);\n\t\t}\n'
                '\t\t~VitaBoxList() { depth--; }\n'
                '\t\tVitaBoxList(const VitaBoxList&) = delete;\n'
                '\t\tUActor** begin() { return list->data(); }\n'
                '\t\tUActor** end() { return list->data() + list->size(); }\n\t};\n'
                '#define VITA_ACTORS_IN_BOX(a, b) VitaBoxList(a, b)\n'
                '#else\n#define VITA_ACTORS_IN_BOX(a, b) Hash().ActorsInBox(a, b)\n#endif\n\n' + m.group(0)),
     'vita-boxlist')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t\tArray<UActor*> vitaInBox;\n\t\t{ VITA_PROBE(CheckHash); vitaInBox = Hash().ActorsInBox(boxMin - extent, boxMax + extent); } // vita-checkprobe-hash\n\t\tfor (UActor* actor : vitaInBox)\n'),
     lambda m: '\t\tfor (UActor* actor : VITA_ACTORS_IN_BOX(boxMin - extent, boxMax + extent)) // vita-boxlist-line (was vita-checkprobe-hash)\n',
     'vita-boxlist-line')
edit("../../knowwonder/KWLevelCheck.cpp",
     r'for \(UActor\* (\w+) : Hash\(\)\.ActorsInBox\(',
     lambda m: 'for (UActor* ' + m.group(1) + ' : VITA_ACTORS_IN_BOX(',
     'VITA_ACTORS_IN_BOX(location')
# 162. Every jump of a script (each 'if' that is false, each loop) looked its target up with OffsetToExpression.find: a
#      std::map of every expression of the function, ~10 nodes deep, a cache miss each. FindStatementIndex now reads a
#      dense table (code offset -> statement index, int16), made from the map the first time the function jumps.
edit("VM/Bytecode.h",
     re.escape('\tint FindStatementIndex(uint16_t offset) const\n\t{\n\t\tauto it = OffsetToExpression.find(offset);\n\t\treturn it != OffsetToExpression.end() ? it->second->StatementIndex : -1;\n\t}\n'),
     lambda m: ('#ifdef __vita__ // vita-jumptable\n'
                '\tmutable std::vector<int16_t> VitaJumpTable; // code offset -> statement index (-1: none)\n'
                '\tmutable size_t VitaJumpTableFor = 0;     // OffsetToExpression.size() it was made from\n'
                '\tint FindStatementIndex(uint16_t offset) const\n\t{\n'
                '\t\tif (VitaJumpTableFor != OffsetToExpression.size() || VitaJumpTable.empty())\n\t\t{\n'
                '\t\t\tVitaJumpTable.assign(OffsetToExpression.empty() ? 1 : (size_t)OffsetToExpression.rbegin()->first + 1, (int16_t)-1);\n'
                '\t\t\tfor (const auto& it : OffsetToExpression)\n'
                '\t\t\t\tVitaJumpTable[it.first] = (int16_t)it.second->StatementIndex;\n'
                '\t\t\tVitaJumpTableFor = OffsetToExpression.size();\n\t\t}\n'
                '\t\treturn offset < VitaJumpTable.size() ? VitaJumpTable[offset] : -1;\n\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-jumptable')
# 163. A native function without a native index (registered by name: LinkSkelAnim, the Decal natives, ...) was found again on
#      every call in NativeByName, a std::map keyed by two names. The map's entry is kept in the UFunction (map entries
#      do not move).
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaFastOp = -1; // vita-fastop-field"),
     lambda m: "\tvoid* VitaNativeByName = nullptr; // vita-nativename-field: its NativeByName entry, once found\n" + m.group(0),
     'vita-nativename-field')
edit("VM/Frame.cpp",
     re.escape('\t\tcallback = &NativeFunctions::NativeByName[{ func->Name, func->NativeStruct->Name }];\n'),
     lambda m: ('#ifdef __vita__ // vita-nativename\n\t{\n'
                '\t\tif (!func->VitaNativeByName)\n'
                '\t\t\tfunc->VitaNativeByName = &NativeFunctions::NativeByName[{ func->Name, func->NativeStruct->Name }];\n'
                '\t\tcallback = static_cast<NativeFuncHandler*>(func->VitaNativeByName);\n\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-nativename')
# 164. The sky frame (a SkyZoneInfo seen through the fake backdrop) walked the whole level's BSP with the sky's camera, every
#      node box tested against its clipper (~1.7 ms a frame in Lev2_Fire1, 2.4 turning). When the sky zone is sealed (no
#      PF_Portal surface on its border) nothing outside it can be seen from inside: the walk skips a subtree none of whose
#      nodes touch the sky zone (zones worked out from every node's Zone0/Zone1 once per model, not the file's ZoneMask).
#      What it skips would have been hidden by the zone's own walls. render.cfg sky_zone_walk=0: off.
edit("Render/VisibleFrame.cpp",
     re.escape('void VisibleFrame::Process(const vec3& location, const mat4& worldToView, const Coords& viewRotation, bool mirrorFlag, int portalDepth, const Array<PortalSpan>& portalSpans, const vec4& portalPlane)\n'),
     lambda m: ('#ifdef __vita__ // vita-skyzone: see apply_fixes.sh #164\n'
                'static uint64_t VitaWalkZoneBit = 0;              // the sky zone of the frame being walked (0: walk everything)\n'
                'static std::vector<uint64_t> VitaNodeZones;       // zones a node\'s subtree touches (with its coplanar nodes)\n'
                'static uint64_t VitaPortalZones = 0;              // zones with a PF_Portal surface on their border\n'
                'static UModel* VitaZonesModel = nullptr;\n'
                'static size_t VitaZonesNodes = 0;\n'
                'static uint64_t VitaZoneBit(int zone) { return zone >= 0 && zone < 64 ? 1ULL << zone : 0; }\n'
                'static uint64_t VitaComputeZones(UModel* model, int index)\n{\n'
                '\tBspNode& node = model->Nodes[index];\n'
                '\tuint64_t mask = 0;\n'
                '\tfor (BspNode* p = &node;; p = &model->Nodes[p->Plane])\n\t{\n'
                '\t\tmask |= VitaZoneBit(p->Zone0) | VitaZoneBit(p->Zone1);\n'
                '\t\tif (p->Surf >= 0 && (model->Surfaces[p->Surf].PolyFlags & PF_Portal))\n'
                '\t\t\tVitaPortalZones |= VitaZoneBit(p->Zone0) | VitaZoneBit(p->Zone1);\n'
                '\t\tif (p != &node && p->Front >= 0) mask |= VitaComputeZones(model, p->Front);\n'
                '\t\tif (p != &node && p->Back >= 0) mask |= VitaComputeZones(model, p->Back);\n'
                '\t\tif (p->Plane < 0) break;\n\t}\n'
                '\tif (node.Front >= 0) mask |= VitaComputeZones(model, node.Front);\n'
                '\tif (node.Back >= 0) mask |= VitaComputeZones(model, node.Back);\n'
                '\tVitaNodeZones[index] = mask;\n'
                '\treturn mask;\n}\n'
                'static uint64_t VitaSkyWalkBit(int viewZone)\n{\n'
                '\tstatic const bool on = VitaConfigInt("sky_zone_walk", 1) != 0;\n'
                '\tUModel* model = engine->Level->Model;\n'
                '\tif (!on || !model || model->Nodes.empty() || viewZone <= 0 || viewZone >= 64)\n\t\treturn 0;\n'
                '\tUZoneInfo* zone = engine->GetZoneActor(viewZone);\n'
                '\tif (!zone || !zone->IsA("SkyZoneInfo"))\n\t\treturn 0;\n'
                '\tif (VitaZonesModel != model || VitaZonesNodes != model->Nodes.size())\n\t{\n'
                '\t\tVitaZonesModel = model;\n\t\tVitaZonesNodes = model->Nodes.size();\n'
                '\t\tVitaPortalZones = 0;\n\t\tVitaNodeZones.assign(model->Nodes.size(), 0);\n'
                '\t\tVitaComputeZones(model, 0);\n\t}\n'
                '\tconst uint64_t bit = VitaZoneBit(viewZone);\n'
                '\tstatic int told = -1;\n'
                '\tif (told != viewZone)\n\t{\n\t\ttold = viewZone;\n'
                '\t\tsize_t kept = 0;\n\t\tfor (uint64_t m : VitaNodeZones) kept += (m & bit) ? 1 : 0;\n'
                '\t\tLogMessage("VitaSkyWalk: sky zone " + std::to_string(viewZone) + (VitaPortalZones & bit ? " has a zone portal: whole BSP walked" : " sealed: walk keeps " + std::to_string(kept) + " of " + std::to_string(VitaNodeZones.size()) + " nodes"));\n\t}\n'
                '\treturn (VitaPortalZones & bit) ? 0 : bit;\n}\n'
                '#endif\n\n' + m.group(0)),
     'vita-skyzone')
edit("Render/VisibleFrame.cpp",
     re.escape('void VisibleFrame::ProcessNode(BspNode* node)\n{\n'),
     lambda m: (m.group(0) + '#ifdef __vita__ // vita-skyzone-skip\n'
                '\tif (VitaWalkZoneBit && (VitaNodeZones[node - engine->Level->Model->Nodes.data()] & VitaWalkZoneBit) == 0)\n\t\treturn;\n'
                '#endif\n'),
     'vita-skyzone-skip')
edit("Render/VisibleFrame.cpp",
     re.escape('\tif (!vitaParallel)\n#endif\n\tProcessNode(&engine->Level->Model->Nodes[0]);\n'),
     lambda m: ('\tVitaWalkZoneBit = (!vitaParallel && PortalDepth > 0) ? VitaSkyWalkBit(ViewZone) : 0; // vita-skyzone-set\n' + m.group(0) +
                '#ifdef __vita__\n\tVitaWalkZoneBit = 0;\n#endif\n'),
     'vita-skyzone-set')
# 165. Laps in DrawPortals' sky frame (sort of the portal spans / Process / Draw): the sky step stayed 1.7 ms after #164.
edit("Render/VisibleFrame.cpp",
     re.escape('\tfor (VisiblePortal& portal : Portals)\n\t{\n\t\t// BspClipper requires the visible spans list to be sorted\n'),
     lambda m: m.group(0).replace('\t{\n', '\t{\n\t\tVITA_LAP_START; // vita-skylaps\n', 1),
     'vita-skylaps')
edit("Render/VisibleFrame.cpp",
     re.escape('\t\t\tVisibleFrame skyframe;\n\t\t\tskyframe.Process('),
     lambda m: '\t\t\tVITA_LAP(SkySort); // vita-skylaps-sort\n' + m.group(0),
     'vita-skylaps-sort')
edit("Render/VisibleFrame.cpp",
     re.escape('\t\t\tDevice->SetSceneNode(&skyframe.Frame);\n\t\t\tskyframe.Draw();\n\t\t\tDevice->ClearZ();\n'),
     lambda m: '\t\t\tVITA_LAP(SkyProcess); // vita-skylaps2\n' + m.group(0) + '\t\t\tVITA_LAP(SkyDraw);\n',
     'vita-skylaps2')
# 166. UpdateActorShadows runs again for the sky frame (and any mirror/warp frame) of the same game frame: ~1 ms in Lev2_Fire1
#      ('sky: process' 1.1 ms with a 16-node walk after #164), every shadow pair's visibility tests and bone check again.
#      Nothing ticks between the main frame's Process and the portal frames', so a shadow handled once this frame (its
#      Update made, or answered by VitaShadowSkip) would only get bUpdated = true and the same Opacity again: skipped.
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('\t\t\tvitaPairs.clear();\n'),
     lambda m: m.group(0) + '\t\t\tvitaDone.clear(); // vita-shadowonce\n',
     'vita-shadowonce')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('\t\tstatic std::vector<std::pair<UActor*, UActor*>> vitaPairs;\n'),
     lambda m: m.group(0) + '\t\tstatic std::vector<char> vitaDone; // vita-shadowonce-decl: handled already this game frame\n',
     'vita-shadowonce-decl')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('\t\t\tUActor* actor = vitaPairs[i].first;\n\t\t\tUActor* shadow = vitaPairs[i].second;\n'),
     lambda m: ('\t\t\tif (vitaDone.size() != vitaPairs.size()) // vita-shadowonce-skip\n\t\t\t\tvitaDone.assign(vitaPairs.size(), 0);\n'
                '\t\t\tif (vitaDone[i])\n\t\t\t\tcontinue;\n' + m.group(0)),
     'vita-shadowonce-skip')
edit("../../knowwonder/KWActorRender.cpp",
     re.escape('\t\t\t{ VITA_PROBE(ShadowSkipped); vitaSkip = VitaShadowSkip(actor, shadow); } // vita-shadowprobes\n'),
     lambda m: '\t\t\tvitaDone[i] = 1; // vita-shadowonce-mark: Update or its native answer, once a game frame\n' + m.group(0),
     'vita-shadowonce-mark')
# 167. Laps in VisibleFrame::Process of portal frames (PortalDepth > 0): 'sky: process' stayed ~1.1 ms with a 16-node walk.
edit("Render/VisibleFrame.cpp",
     re.escape('\tSetupSceneFrame(worldToView);\n'),
     lambda m: '\tVitaProbes::Lap vitaPortalLap; // vita-portallaps\n\tconst bool vitaPortalLaps = portalDepth > 0;\n' + m.group(0) + '\tif (vitaPortalLaps) vitaPortalLap.Mark(VitaProbes::PortalSetup);\n',
     'vita-portallaps')
edit("Render/VisibleFrame.cpp",
     re.escape('\tClipper.Setup(Frame.Projection * Frame.WorldToView * Frame.ObjectToWorld, portalSpans, portalPlane);\n'),
     lambda m: m.group(0) + '\tif (vitaPortalLaps) vitaPortalLap.Mark(VitaProbes::PortalClipper); // vita-portallaps-clip\n',
     'vita-portallaps-clip')
edit("Render/VisibleFrame.cpp",
     re.escape('\tPortals.clear();\n\n\tif (engine->LaunchInfo.IsKnowWonder())\n'),
     lambda m: m.group(0).replace('\tPortals.clear();\n', '\tPortals.clear();\n\tif (vitaPortalLaps) vitaPortalLap.Mark(VitaProbes::PortalZone); // vita-portallaps-zone\n', 1),
     'vita-portallaps-zone')
edit("Render/VisibleFrame.cpp",
     re.escape('{ VITA_PROBE(ProcShadows); KW::UpdateActorShadows(this); } // vita-probe-shadows\n'),
     lambda m: m.group(0) + '\tif (vitaPortalLaps) vitaPortalLap.Mark(VitaProbes::PortalShadows); // vita-portallaps-shadows\n',
     'vita-portallaps-shadows')
edit("Render/VisibleFrame.cpp",
     re.escape('#ifdef __vita__\n\tVitaWalkZoneBit = 0;\n#endif\n'),
     lambda m: m.group(0) + '\tif (vitaPortalLaps) vitaPortalLap.Mark(VitaProbes::PortalWalk); // vita-portallaps-walk\n',
     'vita-portallaps-walk')
# 168. (vita-spansort2: + spans that touch merged) DrawPortals sorted a portal's spans (by y, then x0) with std::sort: thousands of spans for the sky windows of Lev2_Fire1,
#      'sky: sort spans' ~0.4 ms a frame. They are put in row buckets (counting sort by y) and each row's few spans sorted by
#      insertion: the same order (the spans of a row do not overlap, so no two have the same y and x0).
edit("Render/VisibleFrame.cpp",
     re.escape('\t\tstd::sort(portal.Spans.begin(), portal.Spans.end(), [](const PortalSpan& a, const PortalSpan& b) { return a.y != b.y ? a.y < b.y: a.x0 < b.x0; });\n'),
     lambda m: ('#ifdef __vita__ // vita-spansort2\n\t\t{\n'
                '\t\t\tstatic std::vector<int> rowStart;\n\t\t\tstatic Array<PortalSpan> sorted;\n'
                '\t\t\tint maxY = 0;\n\t\t\tbool ok = true;\n'
                '\t\t\tfor (const PortalSpan& span : portal.Spans)\n\t\t\t{\n'
                '\t\t\t\tif (span.y < 0 || span.y > 4096) { ok = false; break; }\n'
                '\t\t\t\tmaxY = std::max(maxY, (int)span.y);\n\t\t\t}\n'
                '\t\t\tif (ok && !portal.Spans.empty())\n\t\t\t{\n'
                '\t\t\t\trowStart.assign(maxY + 2, 0);\n'
                '\t\t\t\tfor (const PortalSpan& span : portal.Spans)\n\t\t\t\t\trowStart[span.y + 1]++;\n'
                '\t\t\t\tfor (int y = 0; y <= maxY; y++)\n\t\t\t\t\trowStart[y + 1] += rowStart[y];\n'
                '\t\t\t\tsorted.resize(portal.Spans.size());\n'
                '\t\t\t\tfor (const PortalSpan& span : portal.Spans)\n\t\t\t\t\tsorted[rowStart[span.y]++] = span;\n'
                '\t\t\t\tfor (size_t i = 1; i < sorted.size(); i++)\n\t\t\t\t{\n'
                '\t\t\t\t\tPortalSpan item = sorted[i];\n\t\t\t\t\tsize_t k = i;\n'
                '\t\t\t\t\twhile (k > 0 && sorted[k - 1].y == item.y && item.x0 < sorted[k - 1].x0)\n\t\t\t\t\t{\n'
                '\t\t\t\t\t\tsorted[k] = sorted[k - 1];\n\t\t\t\t\t\tk--;\n\t\t\t\t\t}\n'
                '\t\t\t\t\tsorted[k] = item;\n\t\t\t\t}\n'
                '\t\t\t\tsize_t n = 0; // spans that touch (x1 == the next x0 on the row) made one: the same union, the same clipper\n'
                '\t\t\t\tfor (size_t i = 0; i < sorted.size(); i++)\n\t\t\t\t{\n'
                '\t\t\t\t\tif (n > 0 && portal.Spans[n - 1].y == sorted[i].y && portal.Spans[n - 1].x1 == sorted[i].x0)\n'
                '\t\t\t\t\t\tportal.Spans[n - 1].x1 = sorted[i].x1;\n'
                '\t\t\t\t\telse\n\t\t\t\t\t\tportal.Spans[n++] = sorted[i];\n\t\t\t\t}\n'
                '\t\t\t\tportal.Spans.resize(n);\n\t\t\t}\n'
                '\t\t\telse\n\t' + m.group(0).lstrip('\t').join(['\t\t\t', '']) +
                '\t\t}\n#else\n' + m.group(0) + '#endif\n'),
     'vita-spansort2')
# 169. vm_laps=1 also counts the expression nodes run by kind (log line 'expressions run a frame'), to see where the
#      interpreter's ~1 us a statement goes.
edit("VM/Frame.cpp",
     re.escape('\t\t\tint pass = vmstack.pass[vmstack.exprEnd - 1]++;\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-exprcount\n\t\t\tif (VitaProbes::vmLaps == 1 && pass == 0)\n\t\t\t\tVitaProbes::exprCounts[(int)expr->Type & 127]++;\n#endif\n',
     'vita-exprcount')
# 170. #130's frameless path for every native with a native index, not only operators (VSize, Normal, Rand, IsInState,
#      PlaySound, SetLocation, ... ~800 native calls a frame in Lev2_Fire1): CallNative built a whole Frame (locals on the VM
#      variable stack, the call stack entry) only to hand the arguments over. Latent and iterator natives keep the old way.
#      A non-operator still checks IsEventEnabled first, as Frame::Call did. The call stack entry was only read by the logger
#      (which skips a native's frame anyway), the debugger and exception texts.
edit("VM/Frame.cpp",
     re.escape('\t\tfunc->VitaFastOp = (AllFlags(func->FuncFlags, FunctionFlags::Native) && AllFlags(func->FuncFlags, FunctionFlags::Operator) &&\n\t\t\tfunc->NativeFuncIndex != 0 && func->Properties.size() <= 8) ? 1 : 0;\n\tif (func->VitaFastOp == 1)\n\t{\n'),
     lambda m: ('\t\tfunc->VitaFastOp = (AllFlags(func->FuncFlags, FunctionFlags::Native) && func->NativeFuncIndex != 0 && func->Properties.size() <= 8 &&\n'
                '\t\t\t!AllFlags(func->FuncFlags, FunctionFlags::Latent) && !AllFlags(func->FuncFlags, FunctionFlags::Iterator)) ? // vita-fastnative\n'
                '\t\t\t(AllFlags(func->FuncFlags, FunctionFlags::Operator) ? 1 : (VitaFastNatives() ? 2 : 0)) : 0;\n'
                '\tif (func->VitaFastOp == 2 && !instance->IsEventEnabled(func->Name))\n\t\treturn ExpressionValue::NothingValue();\n'
                '\tif (func->VitaFastOp >= 1)\n\t{\n'),
     'vita-fastnative')
edit("VM/Frame.cpp",
     re.escape('ExpressionValue Frame::Call(UFunction* func, UObject* instance, const ArrayView<ExpressionValue>& args)\n{\n'),
     lambda m: '#ifdef __vita__ // vita-fastnative-cfg: render.cfg fast_natives (read once)\nstatic bool VitaFastNatives() { static const bool on = VitaConfigInt("fast_natives", 1) != 0; return on; }\n#endif\n' + m.group(0),
     'vita-fastnative-cfg')
# 171. A script/native call's result was copied onto the VM stack (PushValue(callresult): a copy of a vector, string, struct)
#      though the local is not used again: moved.
edit("VM/Frame.cpp",
     re.escape('PushValue(callresult);'),
     lambda m: 'PushValue(std::move(callresult)); // vita-movecall',
     'vita-movecall')
# 172. The face loop of a mesh goes on three cores from face_threads_min faces (render.cfg, was a fixed 192): Lev2_Inc_A's
#      greenhouse draws ~19 meshes a frame of which 16 were smaller and done on one core ('mesh: faces' 270 us a mesh).
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('mesh->Faces.size() >= 192) // vita-faces-fog\n'),
     lambda m: 'mesh->Faces.size() >= VitaFaceThreadsMin()) // vita-faces-fog vita-facesmin\n',
     'vita-facesmin')
# 173. Probes in the three-core face loop of DrawSkeletalMesh: the material pass and the parts' run ('mesh: faces' stayed
#      ~270 us a mesh in Lev2_Inc_A with 3 or 11 meshes a frame on three cores).
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\t\t// (1) the materials, where the loop below would meet them first\n\t\t\tfor (const MeshFace& face : mesh->Faces)\n'),
     lambda m: '\t\t\tstd::optional<VitaProbes::Scope> vitaMatProbe; // vita-meshmatprobe\n\t\t\tvitaMatProbe.emplace(VitaProbes::MeshMats);\n' + m.group(0),
     'vita-meshmatprobe')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\t\t// (2) the faces in three parts\n'),
     lambda m: '\t\t\tvitaMatProbe.reset(); // vita-meshmatprobe-end\n' + m.group(0),
     'vita-meshmatprobe-end')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\t\tVitaJobs::Run([](void* c, int i) { (*((VitaFaceCtx*)c)->fn)(i); }, &vitaCtx, Parts);\n'),
     lambda m: '\t\t\t{ VITA_PROBE(MeshFacesRun); VitaJobs::Run([](void* c, int i) { (*((VitaFaceCtx*)c)->fn)(i); }, &vitaCtx, Parts); } // vita-meshrunprobe\n',
     'vita-meshrunprobe')
# 174. The mesh prepass also makes the main view's opaque faces of the meshes it skins (VitaMeshFaces.h, VitaMeshPrepass.inc
#      VitaMeshJobFaces): DrawSkeletalMesh's face loop moved to the workers, beside the level surfaces' drawing; DrawSkeletalMesh
#      hands the runs over. Lev2_Inc_A: 'mesh: faces' ~270 us x 19 meshes on the main thread. render.cfg prepass_faces=0: off.
edit("Render/VisibleMesh.h",
     re.escape('\tbool DrawMesh(VisibleFrame* frame, UActor* actor, bool wireframe, bool translucentPass);\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-meshtex-public: the mesh prepass picks an actor\'s textures as DrawSkeletalMesh will\n\tstatic void VitaSetupLodMeshTextures(UActor* actor, ULodMesh* mesh) { VisibleMesh vm; vm.SetupLodMeshTextures(actor, mesh); }\n#endif\n',
     'vita-meshtex-public')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#ifdef __vita__\n#include "VitaMeshLod.inc" // vita-lodinc\n#endif\n'),
     lambda m: m.group(0) + '#ifdef __vita__\n#include "VitaMeshFaces.h" // vita-meshfaces-inc\n#endif\n',
     'vita-meshfaces-inc')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\tconst int lod = VitaLodRequest(frame, actor, mesh); // vita-lodcalc\n'),
     lambda m: m.group(0) + ('\t\tif (!translucentPass && lightLocationActor == actor && VitaFacesOn()) // vita-meshfaces-use\n\t\t{\n'
                             '\t\t\tbool vitaNeedTranslucent = false;\n'
                             '\t\t\tif (VitaDrawPreparedFaces(frame, actor, mesh, lod, vitaNeedTranslucent))\n\t\t\t\treturn vitaNeedTranslucent;\n\t\t}\n'),
     'vita-meshfaces-use')
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('#include "Render/VisibleFrame.h"\n'),
     lambda m: m.group(0) + '#include "Render/VisibleMesh.h" // vita-meshfaces-meshinc\n',
     'vita-meshfaces-meshinc')
# 175. '@bench <actor or class> <function> <n>': the function called n times on the actor (each parameter its default value),
#      the log gets the microseconds a call ('HP1 bench'). For measuring the interpreter on the console. Calling a function
#      runs its code: use it on functions without lasting effects (CheckForHarryHit only damages Harry when he is in reach).
edit("../../knowwonder/KWDebug.cpp",
     re.escape('\t\tif (text.rfind("@script ", 0) == 0) // vita-script-cmd\n'),
     lambda m: ('\t\tif (text.rfind("@bench ", 0) == 0) // vita-bench-cmd\n\t\t{\n'
                '\t\t\tstd::istringstream in(text.substr(7));\n'
                '\t\t\tstd::string actorName, funcName;\n\t\t\tint count = 1000;\n'
                '\t\t\tin >> actorName >> funcName >> count;\n'
                '\t\t\tUActor* actor = nullptr;\n'
                '\t\t\tfor (UActor* a : engine->Level->Actors)\n'
                '\t\t\t\tif (a && (a->Name.ToString() == actorName || a->Class->Name.ToString() == actorName))\n\t\t\t\t{\n\t\t\t\t\tactor = a;\n\t\t\t\t\tbreak;\n\t\t\t\t}\n'
                '\t\t\tUFunction* func = actor ? FindEventFunction(actor, NameString(funcName)) : nullptr;\n'
                '\t\t\tif (!func)\n\t\t\t{\n\t\t\t\tLogMessage("HP1 bench: no actor or function " + actorName + " " + funcName);\n\t\t\t\treturn;\n\t\t\t}\n'
                '\t\t\tstd::vector<ExpressionValue> args;\n'
                '\t\t\tfor (UProperty* prop : func->Properties)\n'
                '\t\t\t\tif (AllFlags(prop->PropFlags, PropertyFlags::Parm) && !AllFlags(prop->PropFlags, PropertyFlags::ReturnParm))\n'
                '\t\t\t\t\targs.push_back(ExpressionValue::DefaultValue(prop));\n'
                '\t\t\tconst bool vitaWasEnabled = VitaProbes::enabled; // vm_laps=1: the call split into setup / run / finish\n'
                '\t\t\tVitaProbes::enabled = true;\n'
                '\t\t\tfor (VitaProbes::Id id : { VitaProbes::VmSetup, VitaProbes::VmRun, VitaProbes::VmFinish }) { VitaProbes::us[id] = 0; VitaProbes::calls[id] = 0; }\n'
                '\t\t\tconst auto start = std::chrono::steady_clock::now();\n'
                '\t\t\tfor (int i = 0; i < count; i++)\n'
                '\t\t\t\tFrame::Call(func, actor, ArrayView<ExpressionValue>(args.data(), args.size()));\n'
                '\t\t\tconst double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count() / std::max(count, 1);\n'
                '\t\t\tVitaProbes::enabled = vitaWasEnabled;\n'
                '\t\t\tauto vitaPer = [&](VitaProbes::Id id) { return std::to_string(VitaProbes::calls[id] ? VitaProbes::us[id] / VitaProbes::calls[id] : 0.0); };\n'
                '\t\t\tLogMessage("HP1 bench " + actor->Name.ToString() + "." + funcName + ": " + std::to_string(us) + " us a call (" + std::to_string(count) + " calls); laps (vm_laps=1) setup " + vitaPer(VitaProbes::VmSetup) + ", run " + vitaPer(VitaProbes::VmRun) + ", finish " + vitaPer(VitaProbes::VmFinish));\n'
                '\t\t\treturn;\n\t\t}\n' + m.group(0)),
     'vita-bench-cmd')
# 176. Frame::Call asked IsEventEnabled(func->Name) on every call: a hash lookup of the name among the engine's events first.
#      Whether a function's name is an event is kept in the UFunction (VitaEvent: -2 unknown, -1 none, else the EventName);
#      a non-event name only needs the object's disabled-event table when it has one (what IsEventEnabled(name) does).
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaEmptyFunc = -1; // vita-emptyfunc-field"),
     lambda m: "\tint16_t VitaEvent = -2; // vita-eventfield: the EventName of this function's name (-1: none, -2: unknown)\n" + m.group(0),
     'vita-eventfield')
edit("VM/Frame.cpp",
     re.escape('\tif (!instance->IsEventEnabled(func->Name))\n\t{\n\t\treturn ExpressionValue::NothingValue();\n\t}\n'),
     lambda m: ('#ifdef __vita__ // vita-eventcache\n'
                '\tif (func->VitaEvent == -2)\n\t{\n'
                '\t\tEventName vitaEv = {};\n'
                '\t\tfunc->VitaEvent = NameStringToEventName(func->Name, vitaEv) ? (int16_t)vitaEv : (int16_t)-1;\n\t}\n'
                '\tif (func->VitaEvent >= 0 ? !instance->IsEventEnabled((EventName)func->VitaEvent) :\n'
                '\t\t(!instance->DisabledEvents.empty() && !instance->IsEventEnabled(func->Name)))\n'
                '\t{\n\t\treturn ExpressionValue::NothingValue();\n\t}\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-eventcache')
edit("VM/Frame.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VM/ScriptCall.h" // vita-eventcache-inc\n',
     'vita-eventcache-inc')
edit("../../knowwonder/KWDebug.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-bench-inc\n',
     'vita-bench-inc')
# 177. KW::SetupMeshLighting tested every light of the level per mesh (Lev3_Intro's Great Hall: ~140 us a mesh, 2.3 ms a frame):
#      VitaLightGrid.h gives the lights whose sphere touches the point's grid cell (plus the ones that moved), in the snapshot's
#      order; the same exact test then picks the same lights in the same order.
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape('\t\t\tstd::vector<uint8_t> LightSpecialLit;\n'),
     lambda m: m.group(0) + '\t\t\tVitaLightGrid Grid; // vita-lightgrid-member\n',
     'vita-lightgrid-member')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape('#include "VitaConfig.h" // vita-inc-maxlights\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-lightgrid-inc\n#include "VitaLightGrid.h"\n#endif\n',
     'vita-lightgrid-inc')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape('\t\t\t\ts.LightSpecialLit[i] = s.Lights[i]->bSpecialLit() ? 1 : 0;\n\t\t\t}\n'),
     lambda m: m.group(0) + '\t\t\ts.Grid.Update(s.Lights, s.LightLocations, s.LightRadii); // vita-lightgrid-update\n',
     'vita-lightgrid-update')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape('\t\tfor (size_t li = 0; li < s.Lights.size(); li++)\n\t\t{\n\t\t\tUActor* light = s.Lights[li];\n'),
     lambda m: '\t\tfor (uint32_t li : s.Grid.Query(location)) // vita-lightgrid-query\n\t\t{\n\t\t\tUActor* light = s.Lights[li];\n',
     'vita-lightgrid-query')
# 178. KW's mesh light snapshot (KWMeshLight.cpp BeginFrame, once a frame) scanned every actor of the level for lights: the
#      same list (LightType != None and LightBrightness != 0, in the level's order) LightSystem::BeginFrame has just made for
#      this frame. Taken from there when LightSystem's frame counter moved since the last snapshot (else the scan as before).
edit("Light/LightSystem.h",
     re.escape('\tvoid InitVertexLight(VertexLight& vertexlight, UActor* actor, UZoneInfo* zoneActor, const vec4& boundingSphere);\n'),
     lambda m: m.group(0) + ('#ifdef __vita__ // vita-framelights: this frame\'s lights (BeginFrame) for KW\'s mesh light snapshot\n'
                             '\tconst std::vector<UActor*>& VitaFrameLights() const { return LightTree.Lights; }\n'
                             '\tint VitaFrameCounter() const { return FrameCounter; }\n#endif\n'),
     'vita-framelights')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape('\t\t\ts.Lights.clear();\n\t\t\tfor (UActor* light : s.Level->Actors)\n\t\t\t{\n\t\t\t\tif (light && light->LightType() != LT_None && light->LightBrightness() != 0)\n\t\t\t\t\ts.Lights.push_back(light);\n\t\t\t}\n'),
     lambda m: ('#ifdef __vita__ // vita-framelights-use\n'
                '\t\t\tstatic int vitaLightFrame = -1;\n'
                '\t\t\tif (s.Level->Light.VitaFrameCounter() != vitaLightFrame)\n\t\t\t{\n'
                '\t\t\t\tvitaLightFrame = s.Level->Light.VitaFrameCounter();\n'
                '\t\t\t\ts.Lights = s.Level->Light.VitaFrameLights();\n\t\t\t}\n\t\t\telse\n\t\t\t{\n'
                + m.group(0).replace('\t\t\t', '\t\t\t\t') +
                '\t\t\t}\n#else\n' + m.group(0) + '#endif\n'),
     'vita-framelights-use')
# 179. probe 'check: brush primitives': the line checks against a mover's BSP among the actor primitives
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t\tcase PrimitiveKind::Brush: return ModelLineCheck(hit, ModelFrame::Brush(actor), end, start, extent, extraNodeFlags);\n'),
     lambda m: '\t\tcase PrimitiveKind::Brush: { VITA_PROBE(CheckPrimBrush); return ModelLineCheck(hit, ModelFrame::Brush(actor), end, start, extent, extraNodeFlags); } // vita-brushprobe\n',
     'vita-brushprobe')
# 180. The collision hash's cells were std::list (a heap node per actor per cell: every move of an actor freed and allocated
#      them again, and a query chased the nodes): std::vector, the same actors in the same order (push_back; removal keeps the
#      order of the others). An emptied cell is kept (was erased: its next actor allocated the map node again).
edit("Collision/TopLevel/CollisionSystem.h",
     re.escape('\tstd::unordered_map<uint32_t, std::list<UActor*>> CollisionActors;\n'),
     lambda m: '#ifdef __vita__ // vita-hashvec\n\tstd::unordered_map<uint32_t, std::vector<UActor*>> CollisionActors;\n#else\n' + m.group(0) + '#endif\n',
     'vita-hashvec')
edit("Collision/TopLevel/CollisionTest.h",
     re.escape('\tconst std::list<UActor*>& GetActors(int x, int y, int z) const\n'),
     lambda m: '#ifdef __vita__ // vita-hashvec-get\n\tconst std::vector<UActor*>& GetActors(int x, int y, int z) const\n#else\n' + m.group(0) + '#endif\n',
     'vita-hashvec-get')
edit("Collision/TopLevel/CollisionTest.h",
     re.escape('\tinline static std::list<UActor*> emptyList;\n'),
     lambda m: '#ifdef __vita__ // vita-hashvec-empty\n\tinline static std::vector<UActor*> emptyList;\n#else\n' + m.group(0) + '#endif\n',
     'vita-hashvec-empty')
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape('\t\t\t\t\t\tit->second.remove(actor);\n\t\t\t\t\t\tif (it->second.empty())\n\t\t\t\t\t\t\tCollisionActors.erase(it);\n'),
     lambda m: ('#ifdef __vita__ // vita-hashvec-remove\n'
                '\t\t\t\t\t\tit->second.erase(std::remove(it->second.begin(), it->second.end(), actor), it->second.end());\n'
                '#else\n' + m.group(0) + '#endif\n'),
     'vita-hashvec-remove')
# 181. The decal trace (VitaTraceFirst, #156) walked every polygon of a node's coplanar chain (Lev3_Intro: 15 nodes but 173
#      polygons a trace, ~110 us: the hall floor's long chain; the plane test of each scattered BspNode, then the triangle test).
#      Now each chain is kept once as a contiguous list (member, a copy of its plane, its box): a member whose plane the ray does
#      not cross is skipped (NodeRayIntersect's own test, same numbers), and one whose box the ray's point on the plane is outside of, by
#      more than a margin that grows as the ray grazes the plane, is skipped (the triangle test's hit lies in the polygon).
#      The rest go to NodeRayIntersect in the same order. trace_check=1 compares every trace with the full walk.
edit("Collision/BottomLevel/TraceRayModel.cpp",
     re.escape('\tBspNode* polynode = node;\n\twhile (true)\n\t{\n\t\tif (!visibilityOnly || (polynode->NodeFlags & NF_NotVisBlocking) == 0)\n\t\t{\n\t\t\tdouble t = NodeRayIntersect(origin, tmin, dirNormalized, best, polynode);\n\t\t\tif (t >= tmin && t < best)\n\t\t\t{\n\t\t\t\tbest = t;\n\t\t\t\tfound = true;\n\t\t\t\thit = { (float)t, vec3(node->PlaneX, node->PlaneY, node->PlaneZ), Owner, polynode, node };\n\t\t\t\tif (dot(to_dvec3(hit.Normal), dirNormalized) > 0.0)\n\t\t\t\t\thit.Normal = -hit.Normal;\n\t\t\t}\n\t\t}\n\t\tif (polynode->Plane < 0) break;\n\t\tpolynode = &Model->Nodes[polynode->Plane];\n\t}\n'),
     lambda m: ('\t// vita-polychain (#181)\n'
                '\tconst VitaChain& chain = VitaChainOf(node);\n'
                '\tdvec3 endPoint = origin + dirNormalized * best;\n'
                '\t// a hit lies on the segment and in its polygon: the segment\'s box (one unit wider) must touch the polygon\'s box\n'
                '\tfloat segBox[6];\n'
                '\tauto setSegBox = [&]()\n\t{\n'
                '\t\tfor (int c = 0; c < 3; c++)\n\t\t{\n'
                '\t\t\tsegBox[c] = (float)std::min(origin[c], endPoint[c]) - 1.0f;\n'
                '\t\t\tsegBox[c + 3] = (float)std::max(origin[c], endPoint[c]) + 1.0f;\n\t\t}\n\t};\n'
                '\tauto boxMissed = [&](const float* b)\n\t{\n'
                '\t\treturn segBox[0] > b[3] || segBox[1] > b[4] || segBox[2] > b[5] || segBox[3] < b[0] || segBox[4] < b[1] || segBox[5] < b[2];\n\t};\n'
                '\tsetSegBox();\n'
                '\tif (!boxMissed(chain.box))\n'
                '\tfor (uint32_t ci = chain.first; ci < chain.first + chain.count; ci++)\n\t{\n'
                '\t\tconst VitaChainMember& member = VitaMembers[ci];\n'
                '\t\tif (boxMissed(member.box))\n\t\t\tcontinue;\n'
                '\t\t// NodeRayIntersect\'s own plane test, from the copy of the plane: not crossed, it returns best\n'
                '\t\tconst dvec4 plane = { member.plane[0], member.plane[1], member.plane[2], -member.plane[3] };\n'
                '\t\tconst double fromSide = dot(dvec4(origin, 1.0), plane);\n'
                '\t\tconst double toSide = dot(dvec4(endPoint, 1.0), plane);\n'
                '\t\tif ((fromSide > 0.0 && toSide > 0.0) || (fromSide < 0.0 && toSide < 0.0))\n\t\t\tcontinue;\n'
                '\t\tconst double cosine = std::abs(dot(dvec3(plane.x, plane.y, plane.z), dirNormalized));\n'
                '\t\tif (cosine >= 0.05 && fromSide != toSide)\n\t\t{\n'
                '\t\t\tconst double margin = 1.0 + 1.0 / cosine;\n'
                '\t\t\tconst dvec3 p = origin + dirNormalized * (best * fromSide / (fromSide - toSide));\n'
                '\t\t\tif (p.x < member.box[0] - margin || p.y < member.box[1] - margin || p.z < member.box[2] - margin ||\n'
                '\t\t\t\tp.x > member.box[3] + margin || p.y > member.box[4] + margin || p.z > member.box[5] + margin)\n'
                '\t\t\t\tcontinue;\n\t\t}\n'
                '\t\tBspNode* polynode = &Model->Nodes[member.node];\n'
                '\t\tif (!visibilityOnly || (polynode->NodeFlags & NF_NotVisBlocking) == 0)\n\t\t{\n'
                '\t\t\tdouble t = NodeRayIntersect(origin, tmin, dirNormalized, best, polynode);\n'
                '\t\t\tif (t >= tmin && t < best)\n\t\t\t{\n'
                '\t\t\t\tbest = t;\n\t\t\t\tfound = true;\n'
                '\t\t\t\thit = { (float)t, vec3(node->PlaneX, node->PlaneY, node->PlaneZ), Owner, polynode, node };\n'
                '\t\t\t\tif (dot(to_dvec3(hit.Normal), dirNormalized) > 0.0)\n\t\t\t\t\thit.Normal = -hit.Normal;\n'
                '\t\t\t\tendPoint = origin + dirNormalized * best;\n\t\t\t\tsetSegBox();\n'
                '\t\t\t}\n\t\t}\n\t}\n'),
     'vita-polychain')
edit("Collision/BottomLevel/TraceRayModel.cpp",
     re.escape('void TraceRayModel::VitaTraceFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double& best, bool visibilityOnly, BspNode* node, CollisionHit& hit, bool& found)\n'),
     lambda m: ('// vita-polychain-fn: a node\'s coplanar chain as a contiguous list, made the first time it is walked (#181)\n'
                'const TraceRayModel::VitaChain& TraceRayModel::VitaChainOf(BspNode* node)\n{\n'
                '\tif (VitaChainModel != Model || VitaChains.size() != Model->Nodes.size())\n\t{\n'
                '\t\tVitaChainModel = Model;\n\t\tVitaChains.assign(Model->Nodes.size(), VitaChain());\n\t\tVitaMembers.clear();\n\t}\n'
                '\tVitaChain& chain = VitaChains[node - Model->Nodes.data()];\n'
                '\tif (chain.count != 0)\n\t\treturn chain;\n'
                '\tchain.first = (uint32_t)VitaMembers.size();\n'
                '\tfor (BspNode* p = node; ; p = &Model->Nodes[p->Plane])\n\t{\n'
                '\t\tVitaChainMember m;\n\t\tm.node = (uint32_t)(p - Model->Nodes.data());\n'
                '\t\tm.box[0] = m.box[1] = m.box[2] = FLT_MAX;\n\t\tm.box[3] = m.box[4] = m.box[5] = -FLT_MAX;\n'
                '\t\tfor (int k = 0; k < p->NumVertices; k++)\n\t\t{\n'
                '\t\t\tconst vec3& v = Model->Points[Model->Vertices[p->VertPool + k].Vertex];\n'
                '\t\t\tfor (int c = 0; c < 3; c++)\n\t\t\t{\n\t\t\t\tm.box[c] = std::min(m.box[c], v[c]);\n\t\t\t\tm.box[c + 3] = std::max(m.box[c + 3], v[c]);\n\t\t\t}\n\t\t}\n'
                '\t\tm.plane[0] = p->PlaneX;\n\t\tm.plane[1] = p->PlaneY;\n\t\tm.plane[2] = p->PlaneZ;\n\t\tm.plane[3] = p->PlaneW;\n'
                '\t\tVitaMembers.push_back(m);\n'
                '\t\tif (p->Plane < 0)\n\t\t\tbreak;\n\t}\n'
                '\tchain.count = (uint32_t)VitaMembers.size() - chain.first;\n'
                '\tchain.box[0] = chain.box[1] = chain.box[2] = FLT_MAX;\n\tchain.box[3] = chain.box[4] = chain.box[5] = -FLT_MAX;\n'
                '\tfor (uint32_t i = chain.first; i < chain.first + chain.count; i++)\n'
                '\t\tfor (int c = 0; c < 3; c++)\n\t\t{\n\t\t\tchain.box[c] = std::min(chain.box[c], VitaMembers[i].box[c]);\n\t\t\tchain.box[c + 3] = std::max(chain.box[c + 3], VitaMembers[i].box[c + 3]);\n\t\t}\n'
                '\treturn chain;\n}\n\n'
                + m.group(0)),
     'vita-polychain-fn')
edit("Collision/BottomLevel/TraceRayModel.h",
     re.escape('\tvoid VitaTraceFirst(const dvec3& origin, double tmin, const dvec3& dirNormalized, double& best, bool visibilityOnly, BspNode* node, CollisionHit& hit, bool& found);\n'),
     lambda m: m.group(0) + ('\tstruct VitaChainMember { uint32_t node; float plane[4]; float box[6]; }; // vita-polychain-h\n'
                             '\tstruct VitaChain { uint32_t first = 0, count = 0; float box[6]; };\n'
                             '\tinline static UModel* VitaChainModel = nullptr;\n'
                             '\tinline static std::vector<VitaChain> VitaChains;\n'
                             '\tinline static std::vector<VitaChainMember> VitaMembers;\n'
                             '\tconst VitaChain& VitaChainOf(BspNode* node);\n'),
     'vita-polychain-h')
# 182. VisibleMesh::Draw made the actor's light list (UpdateLightList: a ray from every light in range, each time the actor
#      moved 6 units) for every mesh actor. KW's skeletal meshes light themselves from KW's own snapshot (KWMeshLight.cpp) and
#      never read it: Lev3_Intro's walking students cost 136 us each, 2.5 ms a frame (the candles). The list is still made for
#      a pawn with a weapon (the engine draws a non-skeletal weapon with its pawn's lights) and for every other mesh kind.
edit("Render/VisibleMesh.cpp",
     re.escape('\t{ VITA_PROBE(MeshLightList); engine->Level->Light.UpdateLightList(actor); } // vita-probe-lightlist\n'),
     lambda m: ('#ifdef __vita__ // vita-kwlightlist\n'
                '\tif (!(engine->LaunchInfo.IsKnowWonder() && UObject::TryCast<USkeletalMesh>(mesh) && !(UObject::TryCast<UPawn>(actor) && static_cast<UPawn*>(actor)->Weapon())))\n'
                '#endif\n' + m.group(0)),
     'vita-kwlightlist')
# 183. probes 'mod: ...': each mod in HP1::TickMods
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape('\t\tMods::TickLoadingScreenHold();\n\t\tMods::TickLaunchSkips();\n\t\tLevelStartTick();\n\t\tMods::TickStorybookSkip();\n\t\tMods::TickDiscordPresence(realElapsed);\n\t\tMods::TickPathFixes();\n#ifdef __vita__ // vita-spelllesson\n\t\tVitaTickSpellLesson();\n#endif\n\t\tMods::TickImprovedMovement();\n\t\tMods::TickFreeCamera();\n\t\tMods::TickFrameLimit();\n'),
     lambda m: ('\t\tVITA_LAP_START; // vita-modlaps\n'
                '\t\tMods::TickLoadingScreenHold();\n\t\tVITA_LAP(ModA);\n\t\tMods::TickLaunchSkips();\n\t\tVITA_LAP(ModB);\n\t\tLevelStartTick();\n\t\tVITA_LAP(ModC);\n'
                '\t\tMods::TickStorybookSkip();\n\t\tVITA_LAP(ModD);\n\t\tMods::TickDiscordPresence(realElapsed);\n\t\tVITA_LAP(ModE);\n\t\tMods::TickPathFixes();\n\t\tVITA_LAP(ModF);\n'
                '#ifdef __vita__ // vita-spelllesson\n\t\tVitaTickSpellLesson();\n#endif\n\t\tVITA_LAP(ModG);\n'
                '\t\tMods::TickImprovedMovement();\n\t\tVITA_LAP(ModH);\n\t\tMods::TickFreeCamera();\n\t\tVITA_LAP(ModI);\n\t\tMods::TickFrameLimit();\n\t\tVITA_LAP(ModJ);\n'),
     'vita-modlaps')
edit("../../hp1/mods/HP1Mods.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaProbes.h" // vita-modlaps-inc\n',
     'vita-modlaps-inc')
# 184. The frame-limit mod (60 fps, for HP1's movement bugs above ~110 fps) on the Vita: vsync paces the game and it never comes
#      near those rates, but the limit's waits cost the engine thread: Lev3_Intro turning 37.8 -> 34.6 ms with
#      --no-mod=frame-limit ('mod: frame limit' 1.1 ms a frame standing). Off on the Vita while vsync is on (render.cfg vsync=1:
#      the GL thread presents at most 60 a second, and the engine waits for it); with vsync=0 the limit stays.
edit("../../hp1/mods/FrameLimit.cpp",
     re.escape('\tvoid TickFrameLimit()\n\t{\n\t\tint fps = FrameLimit();\n'),
     lambda m: m.group(0).replace('\t\tint fps = FrameLimit();\n', '#ifdef __vita__ // vita-nofps2: with vsync (render.cfg vsync=1) the frame rate stays under 60\n\t\tstatic const bool vitaVsync = VitaConfigInt("vsync", 1) != 0;\n\t\tif (vitaVsync)\n\t\t\treturn;\n#endif\n\t\tint fps = FrameLimit();\n'),
     'vita-nofps2')
edit("../../hp1/mods/FrameLimit.cpp",
     re.escape('#include "HP1Mods.h"\n'),
     lambda m: m.group(0) + '#include "VitaConfig.h" // vita-nofps-inc\n',
     'vita-nofps-inc')
# 188. counts (probes): why DrawSkeletalMesh makes its faces itself
edit("../../knowwonder/Anim/KWSkeletal.cpp",
     re.escape('\t\t\tif (VitaDrawPreparedFaces(frame, actor, mesh, lod, vitaNeedTranslucent))\n\t\t\t\treturn vitaNeedTranslucent;\n\t\t}\n'),
     lambda m: m.group(0) + ('\t\tif (VitaProbes::enabled) // vita-oldfaces-count\n'
                             '\t\t\tVitaProbes::calls[translucentPass ? VitaProbes::OldFacesTransl : lightLocationActor != actor ? VitaProbes::OldFacesWeapon : VitaProbes::OldFacesNoJob]++;\n'),
     'vita-oldfaces-count')
# 191. MultiLineCheck's world part (ModelLineCheck against the level's BSP: static, the answer depends only on the line, the
#      extent and the node flags) kept in a small table by exactly those values: the walking physics of actors that stand
#      asks the same lines frame after frame (Lev3_Intro: ~100 world checks a frame at ~14 us). Emptied when the level is let go
#      (epoch) or another model comes. world_cache=0: off.
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t\t\t{ VITA_PROBE(CheckWorld); vitaWorldHit = !ModelLineCheck(world, ModelFrame::Level(engine->Level->Model), end, start, extent, extraNodeFlags); } // vita-checkprobe-world\n'),
     lambda m: ('\t\t\t{ VITA_PROBE(CheckWorld); vitaWorldHit = !VitaWorldLineCheck(world, end, start, extent, extraNodeFlags); } // vita-checkprobe-world vita-worldcache-use\n'),
     'vita-worldcache-use')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('\t// IDA Engine.dll: ?MultiLineCheck@ULevel@@'),
     lambda m: ('#ifdef __vita__ // vita-wlcache-fn2\n'
                '\tstatic bool VitaWorldLineCheck(CheckResult& world, const vec3& end, const vec3& start, const vec3& extent, uint8_t extraNodeFlags)\n\t{\n'
                '\t\tstatic const bool on = VitaConfigInt("world_cache", 1) != 0;\n'
                '\t\tUModel* model = engine->Level->Model;\n'
                '\t\tif (!on)\n\t\t\treturn ModelLineCheck(world, ModelFrame::Level(model), end, start, extent, extraNodeFlags);\n'
                '\t\tstruct Entry { float key[9]; uint8_t flags; bool used; bool clear; CheckResult result; };\n'
                '\t\tstatic Entry table[1024];\n\t\tstatic UModel* tableModel = nullptr;\n\t\tstatic int tableEpoch = -1;\n'
                '\t\tstatic unsigned asked = 0, found = 0;\n'
                '\t\tif (tableModel != model || tableEpoch != vitaLevelEpoch)\n\t\t{\n'
                '\t\t\tfor (Entry& e : table)\n\t\t\t\te.used = false;\n\t\t\ttableModel = model;\n\t\t\ttableEpoch = vitaLevelEpoch;\n\t\t}\n'
                '\t\tconst float key[9] = { end.x, end.y, end.z, start.x, start.y, start.z, extent.x, extent.y, extent.z };\n'
                '\t\tuint32_t hash = 2166136261u ^ extraNodeFlags;\n'
                '\t\tfor (float v : key)\n\t\t{\n\t\t\tuint32_t bits;\n\t\t\tmemcpy(&bits, &v, 4);\n\t\t\thash = (hash ^ bits) * 16777619u;\n\t\t}\n'
                '\t\tEntry& e = table[(hash ^ (hash >> 15)) & 1023u];\n'
                '\t\tasked++;\n'
                '\t\tif ((asked & 4095u) == 0)\n\t\t\tLogMessage("VitaWorldCache: " + std::to_string(found) + " of " + std::to_string(asked) + " level line checks from the table");\n'
                '\t\tstatic const bool check = VitaConfigInt("world_cache_check", 0) != 0;   // the check made again and compared\n'
                '\t\tif (e.used && e.flags == extraNodeFlags && memcmp(e.key, key, sizeof(key)) == 0)\n\t\t{\n'
                '\t\t\tfound++;\n'
                '\t\t\tif (check)\n\t\t\t{\n'
                '\t\t\t\tstatic unsigned wrong = 0;\n\t\t\t\tCheckResult again = world;\n'
                '\t\t\t\tconst bool clearAgain = ModelLineCheck(again, ModelFrame::Level(model), end, start, extent, extraNodeFlags);\n'
                '\t\t\t\tif (clearAgain != e.clear || memcmp(&again, &e.result, sizeof(CheckResult)) != 0)\n'
                '\t\t\t\t\tLogMessage("VitaWorldCache: DIFFERS (" + std::to_string(++wrong) + ")");\n\t\t\t}\n'
                '\t\t\tworld = e.result;\n\t\t\treturn e.clear;\n\t\t}\n'
                '\t\tconst CheckResult before = world;\n'
                '\t\tconst bool clear = ModelLineCheck(world, ModelFrame::Level(model), end, start, extent, extraNodeFlags);\n'
                '\t\tif (before.Time == 1.0f && before.Actor == nullptr && before.Model == nullptr && before.Item == -1)\n\t\t{\n'
                '\t\t\tmemcpy(e.key, key, sizeof(key));\n\t\t\te.flags = extraNodeFlags;\n\t\t\te.used = true;\n\t\t\te.clear = clear;\n\t\t\te.result = world;\n\t\t}\n'
                '\t\treturn clear;\n\t}\n#endif\n\n' + m.group(0)),
     'vita-wlcache-fn2')
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape('#include "VitaProbes.h" // vita-checkprobe-inc\n'),
     lambda m: m.group(0) + '#include "VitaConfig.h" // vita-worldcache-inc\n#include "VitaLevelEpoch.h"\n#include "Utils/Logger.h"\n#include <cstring>\n',
     'vita-worldcache-inc')
# 192. AllActors(Class) walked every slot of Level.Actors (GameReplicationInfo.Timer, every 0.2 s: 880 us, for one
#      PlayerReplicationInfo). Now the slots holding an actor of the class are kept per class as a sorted list of indices: valid
#      until the list is compacted (vitaActorsVersion) or the level goes; slots appended since are looked at on demand. The
#      iterator still reads the live slot (null = destroyed: skipped, as before) and checks Tag/Event there, in index order.
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape('\t\tActors.swap(newActorList);\n\t\tindexedLevel = this;\n'),
     lambda m: m.group(0).replace('\t\tActors.swap(newActorList);\n', '\t\tActors.swap(newActorList);\n\t\tvitaActorsVersion++; // vita-actorsversion\n'),
     'vita-actorsversion')
edit("Packages/Engine/Resources/Level/ULevel.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-actorsversion-inc\n',
     'vita-actorsversion-inc')
edit("VM/Iterator.cpp",
     re.escape('\tsize_t size = engine->Level->Actors.size();\n\twhile (index < size)\n\t{\n\t\tUActor* actor = engine->Level->Actors[index++];\n\t\tif (actor && VITA_ISA(actor, BaseClass->Name) && (!matchTag || actor->Tag() == MatchTag) && (!matchEvent || actor->Event() == MatchEvent))\n'),
     lambda m: ('#ifdef __vita__ // vita-classindex\n'
                '\t{\n'
                '\t\tstruct ClassIndex { void* level = nullptr; int epoch = -1, version = -1; size_t scanned = 0; std::vector<uint32_t> slots; };\n'
                '\t\tstatic std::unordered_map<const UObject*, ClassIndex> indexes;\n'
                '\t\tstatic int epochSeen = -1;\n'
                '\t\tif (epochSeen != vitaLevelEpoch)\n\t\t{\n\t\t\tepochSeen = vitaLevelEpoch;\n\t\t\tindexes.clear();\n\t\t}\n'
                '\t\tauto& actors = engine->Level->Actors;\n'
                '\t\tClassIndex& ci = indexes[BaseClass];\n'
                '\t\tif (ci.level != engine->Level || ci.epoch != vitaLevelEpoch || ci.version != vitaActorsVersion || ci.scanned > actors.size())\n\t\t{\n'
                '\t\t\tci.level = engine->Level;\n\t\t\tci.epoch = vitaLevelEpoch;\n\t\t\tci.version = vitaActorsVersion;\n\t\t\tci.scanned = 0;\n\t\t\tci.slots.clear();\n\t\t}\n'
                '\t\tfor (; ci.scanned < actors.size(); ci.scanned++)\n\t\t{\n'
                '\t\t\tUActor* a = actors[ci.scanned];\n'
                '\t\t\tif (a && VITA_ISA(a, BaseClass->Name))\n\t\t\t\tci.slots.push_back((uint32_t)ci.scanned);\n\t\t}\n'
                '\t\tfor (auto it = std::lower_bound(ci.slots.begin(), ci.slots.end(), (uint32_t)index); it != ci.slots.end(); ++it)\n\t\t{\n'
                '\t\t\tindex = (size_t)*it + 1;\n'
                '\t\t\tUActor* actor = actors[*it];\n'
                '\t\t\tif (actor && (!matchTag || actor->Tag() == MatchTag) && (!matchEvent || actor->Event() == MatchEvent))\n\t\t\t{\n'
                '\t\t\t\t*ReturnValue = actor;\n\t\t\t\treturn true;\n\t\t\t}\n\t\t}\n'
                '\t\tindex = actors.size();\n'
                '\t\t*ReturnValue = nullptr;\n\t\treturn false;\n'
                '\t}\n#endif\n' + m.group(0)),
     'vita-classindex')
edit("VM/Iterator.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#include "VitaLevelEpoch.h" // vita-classindex-inc\n#include <unordered_map>\n',
     'vita-classindex-inc')
# 193. Engine.GameReplicationInfo.Timer natively (vita/VitaScriptNatives.cpp; render.cfg gri_timer): ~820 us a call in the VM,
#      ~250 us a frame in every level.
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape('\t\t\tif (!bTimerLoop())\n\t\t\t\tTimerRate() = 0.0f;\n\t\t\tCallEvent(this, EventName::Timer);\n'),
     lambda m: m.group(0).replace('\t\t\tCallEvent(this, EventName::Timer);\n', '#ifdef __vita__ // vita-gritimer\n\t\t\tif (!VitaGRITimer(this))\n#endif\n\t\t\tCallEvent(this, EventName::Timer);\n'),
     'vita-gritimer')
edit("Packages/Engine/Actors/UActor.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + '#ifdef __vita__ // vita-gritimer-decl\nclass UActor;\nbool VitaGRITimer(UActor* actor); // vita/VitaScriptNatives.cpp\n#endif\n',
     'vita-gritimer-decl')
# 194. ExpressionValue's copy and move of a scalar (Nothing, Byte, Int, Bool, Float, Object: at most 4 bytes on the Vita) copied
#      the whole value buffer (48 bytes: it is sized for Coords) on every push, pop and move of the VM's value stack. Now 4 bytes
#      (the rest of the buffer is never read for those types).
edit("VM/ExpressionValue.h",
     r'default: Buffer = v\.Buffer; break;',
     lambda m: 'default: VITA_SCALAR_COPY(Buffer, v.Buffer); break;',
     'VITA_SCALAR_COPY(Buffer')
edit("VM/ExpressionValue.h",
     re.escape('#include "Packages/Core/Properties/UStructProperty.h"\n'),
     lambda m: m.group(0) + ('#include <cstring>\n'
                             '#ifdef __vita__ // vita-scalarcopy\n'
                             'static_assert(sizeof(void*) == 4 && sizeof(float) == 4 && sizeof(int32_t) == 4, "VITA_SCALAR_COPY copies 4 bytes");\n'
                             '#define VITA_SCALAR_COPY(dst, src) memcpy(&(dst), &(src), 4)\n'
                             '#else\n#define VITA_SCALAR_COPY(dst, src) ((dst) = (src))\n#endif\n'),
     'vita-scalarcopy')
# 181b. render.cfg trace_check=1: every decal trace also made the old way (all hits, the first by time and order), compared
edit("Collision/TopLevel/CollisionSystem.cpp",
     re.escape('\tTraceRayModel trace;\n\treturn trace.VitaTraceFirst(LevelInfo, Level->Model, origin, tmin, dirNormalized, tmax, visibilityOnly);\n'),
     lambda m: ('\tTraceRayModel trace;\n'
                '\tCollisionHitList vitaFirst = trace.VitaTraceFirst(LevelInfo, Level->Model, origin, tmin, dirNormalized, tmax, visibilityOnly);\n'
                '\tstatic const bool vitaCheck = VitaConfigInt("trace_check", 0) != 0; // vita-tracecheck\n'
                '\tif (vitaCheck)\n\t{\n'
                '\t\tstatic unsigned traces = 0, wrong = 0;\n'
                '\t\tCollisionHitList all = TraceDecal(origin, tmin, dirNormalized, tmax, visibilityOnly);\n'
                '\t\tconst CollisionHit* first = nullptr;\n'
                '\t\tfor (const CollisionHit& h : all)\n\t\t\tif (!first || h.Fraction < first->Fraction)\n\t\t\t\tfirst = &h;\n'
                '\t\tconst bool same = first ? (!vitaFirst.empty() && vitaFirst.front().Fraction == first->Fraction && vitaFirst.front().Node == first->Node && vitaFirst.front().Normal == first->Normal) : vitaFirst.empty();\n'
                '\t\ttraces++;\n\t\tif (!same)\n\t\t\twrong++;\n'
                '\t\tif (traces % 200 == 0 || (!same && wrong < 20))\n'
                '\t\t\tLogMessage("VitaTraceCheck: " + std::to_string(traces) + " decal traces, " + std::to_string(wrong) + " differ");\n\t}\n'
                '\treturn vitaFirst;\n'),
     'vita-tracecheck')
# 195. The menu book's UWindow scripts natively (vita/VitaScriptNatives.cpp; render.cfg uwindow_natives, uwindow_check): the folio
#      page ran at 3 fps (UWindowWrappedTextArea.Paint walks its whole ring buffer: ~750 WrapClipText("") a frame), the options page
#      at 25-30. Canvas.SetPos/SetOrigin/SetClip, UWindowWindow.TextSize/ClipText/DrawStretchedTextureSegment and WrapClipText of an
#      empty line, each exactly as its script. Frame::Call asks once per function for a native twin (UStruct::VitaScriptNative).
edit("Packages/Core/UStruct.h",
     re.escape("\tint8_t VitaEmptyFunc = -1; // vita-emptyfunc-field"),
     lambda m: "\tint8_t VitaScriptNativeState = -1; // vita-scriptnative-field: a native twin (1, VitaScriptNative), none (0), unknown (-1)\n\tvoid* VitaScriptNative = nullptr;\n" + m.group(0),
     'vita-scriptnative-field')
edit("VM/Frame.cpp",
     re.escape('#include "VitaProbes.h" // vita-emptyfunc-inc\n'),
     lambda m: m.group(0) + '#include "VitaScriptNatives.h" // vita-scriptnative-inc\n',
     'vita-scriptnative-inc')
edit("VM/Frame.cpp",
     re.escape("\telse\n\t{\n#ifdef __vita__ // vita-emptyfunc-skip\n"),
     lambda m: ("\telse\n\t{\n#ifdef __vita__ // vita-scriptnative-call\n"
                "\t\tif (func->VitaScriptNativeState < 0)\n\t\t{\n"
                "\t\t\tfunc->VitaScriptNative = (void*)VitaFindScriptNative(func, instance);\n"
                "\t\t\tfunc->VitaScriptNativeState = func->VitaScriptNative ? 1 : 0;\n\t\t}\n"
                "\t\tif (func->VitaScriptNativeState == 1)\n\t\t{\n"
                "\t\t\tExpressionValue vitaResult;\n"
                "\t\t\tif (VitaRunScriptNative((VitaScriptNativeFn)func->VitaScriptNative, func, instance, args, vitaResult))\n"
                "\t\t\t\treturn vitaResult;\n\t\t}\n#endif\n"
                "#ifdef __vita__ // vita-emptyfunc-skip\n"),
     'vita-scriptnative-call')
# 197. Mouse sensitivity (and the other PlayerPawn options) went back to User.ini's value at every level change: HP1's options page
#      only sets GetPlayerOwner().MouseSensitivity (FEOptionsPage.SensitivityChanged; no script calls SaveConfig for it), and
#      Engine::LoadMap's login reads the new player's PlayerPawn options from User.ini (UPlayerPawn::LoadProperties). The player's
#      options are written to the ini before the old level goes, and at exit (KnowWonder games only).
edit("Engine.cpp",
     re.escape("\taudiodev->StopSounds();\n\tUnloadMap();\n"),
     lambda m: ("#ifdef __vita__ // vita-savepawncfg-map\n"
                "\tif (LaunchInfo.IsKnowWonder() && Level && viewport && viewport->Actor())\n"
                "\t\tviewport->Actor()->SaveConfig();   // the options page's values reach the next level's player (UPlayerPawn::LoadProperties)\n"
                "#endif\n" + m.group(0)),
     'vita-savepawncfg-map')
edit("Engine.cpp",
     re.escape('\tpackages->SetIniValue("System", "Engine.SurrealWindowSystem", "WindowSystem", windowingSystemName);\n'),
     lambda m: ("#ifdef __vita__ // vita-savepawncfg-exit\n"
                "\tif (LaunchInfo.IsKnowWonder() && Level && viewport && viewport->Actor())\n"
                "\t\tviewport->Actor()->SaveConfig();\n"
                "#endif\n" + m.group(0)),
     'vita-savepawncfg-exit')
# 195b. The natives' classes were looked up with FindClass at the first script call of the boot, which loads the UWindow package
#       that early: the menu cursor no longer moved. Now taken from the calling window's class chain, at the first UWindowWindow
#       call; until then the function is asked about again (VitaFindScriptNative returns -1).
edit("VM/Frame.cpp",
     re.escape("\t\t\tfunc->VitaScriptNative = (void*)VitaFindScriptNative(func, instance);\n\t\t\tfunc->VitaScriptNativeState = func->VitaScriptNative ? 1 : 0;\n"),
     lambda m: ("\t\t\tVitaScriptNativeFn vitaFn = nullptr; // vita-scriptnative-later\n"
                "\t\t\tconst int vitaFound = VitaFindScriptNative(func, instance, vitaFn);\n"
                "\t\t\tfunc->VitaScriptNative = (void*)vitaFn;\n"
                "\t\t\tif (vitaFound >= 0)\n\t\t\t\tfunc->VitaScriptNativeState = (int8_t)vitaFound;\n"),
     'vita-scriptnative-later')
# 198. HP1's debug mode in a debug build (vita_main.cpp VitaGameDebug: bash build.sh debug, render.cfg game_debug): HPConsole.bDebugMode
#      set on the console when it is made; FEMainPage.BeforePaint then shows Level Select, Language, Credits and Version.
edit("Engine.cpp",
     re.escape("\tconsole->Viewport() = viewport;\n\tcanvas->Viewport() = viewport;\n"),
     lambda m: ("#ifdef __vita__ // vita-gamedebug\n"
                "\tif (VitaGameDebug() && LaunchInfo.IsHarryPotter1() && console->HasProperty(\"bDebugMode\"))\n\t{\n"
                "\t\tconsole->SetBool(\"bDebugMode\", true);\n"
                "\t\tLogMessage(\"Game debug build: HPConsole.bDebugMode on (Level Select in the title menu)\");\n\t}\n"
                "#endif\n" + m.group(0)),
     'vita-gamedebug')
edit("Engine.cpp",
     re.escape('#include "Precomp.h"\n'),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-gamedebug-decl\nbool VitaGameDebug(); // vita_main.cpp\n#endif\n",
     'vita-gamedebug-decl')
# 199. Canvas text with no font (Canvas.Font None) dereferenced null in RenderSubsystem: HP1's debug mode (#198) draws text before
#      its font is set, a data abort in DrawText at the first frame of the title menu. No font: nothing drawn, size 0 (logged once).
edit("Render/RenderCanvas.cpp",
     re.escape("bool newlineAtEnd, const std::string& text, uint32_t polyflags, bool center, float spaceX, float spaceY, float clipX, float clipY, bool noDraw)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-nofont-text\n\tif (!font)\n\t{\n\t\tstatic bool logged = false;\n\t\tif (!logged)\n\t\t\tLogMessage(\"Canvas.DrawText without a font: not drawn\");\n\t\tlogged = true;\n\t\treturn;\n\t}\n#endif\n",
     'vita-nofont-text')
edit("Render/RenderCanvas.cpp",
     re.escape("const std::string& text, uint32_t polyflags, bool checkHotKey, float clipX, float clipY, bool center)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-nofont-clipped\n\tif (!font)\n\t\treturn;\n#endif\n",
     'vita-nofont-clipped')
edit("Render/RenderCanvas.cpp",
     re.escape("vec2 RenderSubsystem::GetTextSize(UFont* font, const std::string& text, float spaceX, float spaceY)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-nofont-size\n\tif (!font)\n\t\treturn vec2(0.0f);\n#endif\n",
     'vita-nofont-size')
# 200. Laps inside a light map built again (LightSystem::GetLightmap): setup, the static lights made or loaded, the dynamic
#      lights, the conversion. Lev4_Sneak2's opening: ~36 built again a frame, 9 ms.
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tBuilder.Setup(model, coords, lightmapIndex);\n"),
     lambda m: "\t\tVITA_LAP_START; // vita-lmr-start\n" + m.group(0) + "\t\tVITA_LAP(LmRSetup);\n",
     'vita-lmr-start')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t\tBuilder.SaveStaticLight(lmtexture->StaticLightColors);\n\t\t}\n#else\n"),
     lambda m: "\t\t\tBuilder.SaveStaticLight(lmtexture->StaticLightColors);\n\t\t\tVITA_LAP(LmRStaticAll); // vita-lmr-static\n\t\t}\n#else\n",
     'vita-lmr-static')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\t\tBuilder.LoadStaticLight(lmtexture->StaticLightColors);\n\t\t}\n\n\t\tBuilder.AddDynamicLights(model, lightmapIndex, TempDynLightList);\n"),
     lambda m: ("\t\t\tBuilder.LoadStaticLight(lmtexture->StaticLightColors);\n\t\t\tVITA_LAP(LmRStaticKept); // vita-lmr-kept\n\t\t}\n\n"
                "\t\tBuilder.AddDynamicLights(model, lightmapIndex, TempDynLightList);\n\t\tVITA_LAP(LmRDynamic);\n"),
     'vita-lmr-kept')
edit("Light/LightSystem_Light.cpp",
     re.escape("#ifdef __vita__ // vita-rebuildend\n"),
     lambda m: "\t\tVITA_LAP(LmRConvert); // vita-lmr-convert\n" + m.group(0),
     'vita-lmr-convert')
# 201. A light map built again and again (a dynamic light moving near it: Lev4_Sneak2's opening, ~35 a frame) worked out every
#      texel's world location each time (LightmapBuilder::Setup, 1.7 ms a frame there). From its second build on, the locations are
#      kept with it and copied when the map's coordinates are bit for bit the same (a moving mover's are not: made again).
edit("Light/LightmapBuilder.h",
     re.escape("\tint Width() const { return width; }\n"),
     lambda m: ("#ifdef __vita__ // vita-lmpoints-api\n"
                "\t// Setup without working out the texels' world locations: they are copied from a kept set (#201)\n"
                "\tvoid VitaSetupKept(UModel* model, const Coords& mapCoords, int lightMap, const Array<vec3>& keptPoints);\n"
                "\tconst Array<vec3>& VitaPoints() const { return points; }\n"
                "#endif\n" + m.group(0)),
     'vita-lmpoints-api')
edit("Light/LightmapBuilder.cpp",
     re.escape("void LightmapBuilder::SetAmbientLight(UZoneInfo* zoneActor)\n"),
     lambda m: ("#ifdef __vita__ // vita-lmpoints-fn\n"
                "void LightmapBuilder::VitaSetupKept(UModel* model, const Coords& mapCoords, int lightMap, const Array<vec3>& keptPoints)\n{\n"
                "\tconst LightMapIndex& lmindex = model->LightMap[lightMap];\n"
                "\twidth = lmindex.UClamp;\n\theight = lmindex.VClamp;\n"
                "\tnormal = normalize(mapCoords.ZAxis);\n\tbase = mapCoords.Origin;\n"
                "\tsize_t size = (size_t)width * height;\n"
                "\tif (points.size() < size)\n\t\tpoints.resize(size);\n"
                "\tif (lightcolors.size() < size)\n\t\tlightcolors.resize(size);\n"
                "\tif (illuminationmap.size() < size)\n\t\tilluminationmap.resize(size);\n"
                "\tstd::memcpy(points.data(), keptPoints.data(), size * sizeof(vec3));\n}\n\n"
                "#endif\n" + m.group(0)),
     'vita-lmpoints-fn')
edit("Light/LightSystem.h",
     re.escape("\tuintptr_t SteadyAnimatedKey = 0;\n"),
     lambda m: m.group(0) + ("\t// vita-lmpoints-fields: the texels' world locations, kept from the second build on, and the coordinates they were made with (#201)\n"
                             "\tArray<vec3> VitaPoints;\n\tCoords VitaPointsCoords;\n\tbool VitaPointsValid = false;\n\tuint8_t VitaBuilds = 0;\n"),
     'vita-lmpoints-fields')
edit("Light/LightSystem_Light.cpp",
     re.escape("\t\tBuilder.Setup(model, coords, lightmapIndex);\n\t\tVITA_LAP(LmRSetup);\n"),
     lambda m: ("#ifdef __vita__ // vita-lmpoints-use\n"
                "\t\tauto vitaSameBits = [](const vec3& a, const vec3& b) { return std::memcmp(&a, &b, sizeof(vec3)) == 0; };\n"
                "\t\tconst size_t vitaTexels = (size_t)lmindex.UClamp * lmindex.VClamp;\n"
                "\t\tif (lmtexture && lmtexture->VitaPointsValid && lmtexture->VitaPoints.size() == vitaTexels &&\n"
                "\t\t\tvitaSameBits(lmtexture->VitaPointsCoords.Origin, coords.Origin) && vitaSameBits(lmtexture->VitaPointsCoords.XAxis, coords.XAxis) &&\n"
                "\t\t\tvitaSameBits(lmtexture->VitaPointsCoords.YAxis, coords.YAxis) && vitaSameBits(lmtexture->VitaPointsCoords.ZAxis, coords.ZAxis))\n"
                "\t\t\tBuilder.VitaSetupKept(model, coords, lightmapIndex, lmtexture->VitaPoints);\n"
                "\t\telse\n\t\t{\n"
                "\t\t\tBuilder.Setup(model, coords, lightmapIndex);\n"
                "\t\t\tif (lmtexture && !dynamicMover && ++lmtexture->VitaBuilds >= 2)\n\t\t\t{\n"
                "\t\t\t\tlmtexture->VitaPoints.resize(vitaTexels);\n"
                "\t\t\t\tstd::memcpy(lmtexture->VitaPoints.data(), Builder.VitaPoints().data(), vitaTexels * sizeof(vec3));\n"
                "\t\t\t\tlmtexture->VitaPointsCoords = coords;\n\t\t\t\tlmtexture->VitaPointsValid = true;\n\t\t\t}\n\t\t}\n"
                "#else\n" + m.group(0)[:m.group(0).index("\t\tVITA_LAP")] + "#endif\n\t\tVITA_LAP(LmRSetup);\n"),
     'vita-lmpoints-use')
# 202. A faster way through the commonest statements (vita/VitaFastEval.inc; render.cfg fast_eval, fast_eval_check): a statement made
#      only of variables, constants, conversions, struct members, contexts, assignments, native operators and calls is evaluated
#      by recursion, each node as its RunExpr case does it; everything else in RunExpr's stack machine as before.
edit("VM/Expression.h",
     re.escape("\tExpressionType Type;\n\tint StatementIndex = -1;\n"),
     lambda m: ("\tExpressionType Type;\n"
                "\tint8_t VitaFast = -1; // vita-fasteval-fields: this node and its tree for VitaFastEval (1), not (0), unknown (-1)\n"
                "\tint8_t VitaFastStmt = -1; // as a whole statement\n"
                "\tint StatementIndex = -1;\n"),
     'vita-fasteval-fields')
edit("VM/Frame.cpp",
     re.escape("ExpressionEvalResult Frame::RunExpr(Expression* statementExpr, UObject* self, UObject* context, void* variables)\n{\n"),
     lambda m: ('#include "VitaFastEval.inc" // vita-fasteval-inc\n\n' + m.group(0) +
                "#ifdef __vita__ // vita-fasteval-use\n"
                "\t{\n\t\tExpressionEvalResult vitaFast;\n"
                "\t\tif (VitaFastTry(statementExpr, self, context, variables, vitaFast))\n\t\t\treturn vitaFast;\n\t}\n"
                "#endif\n"),
     'vita-fasteval-inc')
# 202b. fast_eval_check's second run (RunExpr is private: the comparison is made in RunExpr itself)
edit("VM/Frame.cpp",
     re.escape("\t\tif (VitaFastTry(statementExpr, self, context, variables, vitaFast))\n\t\t\treturn vitaFast;\n"),
     lambda m: ("\t\tconst int vitaTaken = VitaFastTry(statementExpr, self, context, variables, vitaFast); // vita-fasteval-check\n"
                "\t\tif (vitaTaken == 1)\n\t\t\treturn vitaFast;\n"
                "\t\tif (vitaTaken == 2)\n\t\t{\n"
                "\t\t\tvitaFastOff = true;\n"
                "\t\t\tstruct VitaRestore { ~VitaRestore() { vitaFastOff = false; } } vitaRestore;\n"
                "\t\t\tExpressionEvalResult vitaNormal = RunExpr(statementExpr, self, context, variables);\n"
                "\t\t\tVitaFastCompare(statementExpr, vitaFast, vitaNormal);\n"
                "\t\t\treturn vitaNormal;\n\t\t}\n"),
     'vita-fasteval-check')
# 202c. Why a statement stays in RunExpr (VitaFastEval statistics, render.cfg fast_eval_stats)
edit("VM/Expression.h",
     re.escape("\tint8_t VitaFastStmt = -1; // as a whole statement\n"),
     lambda m: m.group(0) + "\tuint8_t VitaFastWhy = 0; // vita-fastwhy-field: the type of the node that keeps the statement in RunExpr\n",
     'vita-fastwhy-field')
# 202d. Frame::Run takes a fast statement straight into its own result (VitaFastRunInto), not through RunExpr's returned copy
edit("VM/Frame.cpp",
     re.escape("\t\tExpressionEvalResult result = RunExpr(statement, Object, Object, Variables);\n"),
     lambda m: ("#ifdef __vita__ // vita-fasteval-run\n"
                "\t\tExpressionEvalResult result;\n"
                "\t\tif (!VitaFastRunInto(statement, Object, Object, Variables, result))\n"
                "\t\t\tresult = RunExpr(statement, Object, Object, Variables);\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-fasteval-run')
edit("VM/Frame.cpp",
     re.escape("\t{\n\t\tExpressionEvalResult vitaFast;\n\t\tconst int vitaTaken"),
     lambda m: "\tif (statementExpr->VitaFastStmt != 0) // vita-fasteval-known: not for a statement already known to stay here\n" + m.group(0),
     'vita-fasteval-known')
edit("VM/Frame.cpp",
     re.escape('#include "VitaProbes.h" // vita-emptyfunc-inc\n'),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-fasteval-decl\nstatic bool VitaFastRunInto(Expression* statement, UObject* self, UObject* context, void* variables, ExpressionEvalResult& result);\n#endif\n",
     'vita-fasteval-decl')
# 203. A frame's projected level points kept (BspClipper: VitaPointPos/Dist by the model's point index, valid while VitaPointGen is
#      the clipper's Setup count): BSP surfaces share their corners, and every surface projected each of its corners again
#      (clip: project ~3.5 us a surface). The same expressions as before on a miss, so a kept value is the value it would compute.
#      render.cfg point_cache=0: off; point_cache_check=1: every kept value computed again and compared bit for bit.
edit("Render/BspClipper.h",
     re.escape("\tbool VitaCheckPolygon(const vec3* vertices, uint32_t count, bool solid);\n"),
     lambda m: m.group(0) + ("\t// vita-pointcache-fields (#203): the corners' model point indexes for the next CheckSurface (or null), and the kept projections\n"
                             "\tconst int* VitaPointIndex = nullptr;\n"
                             "\tstd::vector<vec4> VitaPointPos;\n\tstd::vector<float> VitaPointDist;\n\tstd::vector<uint32_t> VitaPointStamp;\n"
                             "\tuint32_t VitaPointGen = 1;\n"),
     'vita-pointcache-fields')
edit("Render/BspClipper.cpp",
     re.escape("\tWorldToProjection = world_to_projection;\n\tFrustumClip = FrustumPlanes(world_to_projection);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-pointcache-gen: a new view, the kept projections are old\n"
                             "\tif (++VitaPointGen == 0)\n\t{\n\t\tstd::fill(VitaPointStamp.begin(), VitaPointStamp.end(), 0u);\n\t\tVitaPointGen = 1;\n\t}\n"
                             "#endif\n"),
     'vita-pointcache-gen')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tvitaSurfaceVisible = Clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0);\n"),
     lambda m: ("\t\t{\n#ifdef __vita__ // vita-pointcache-idx: the corners' point indexes, in the order of 'points'\n"
                "\t\t\tint vitaIdx[32];\n"
                "\t\t\tif (numverts <= 32)\n\t\t\t{\n"
                "\t\t\t\tfor (int j = 0; j < numverts; j++)\n"
                "\t\t\t\t\tvitaIdx[MirrorFlag ? numverts - 1 - j : j] = v[j].Vertex;\n"
                "\t\t\t\tClipper.VitaPointIndex = vitaIdx;\n\t\t\t}\n#endif\n"
                "\t" + m.group(0) +
                "#ifdef __vita__\n\t\t\tClipper.VitaPointIndex = nullptr;\n#endif\n\t\t}\n"),
     'vita-pointcache-idx')
edit("Render/BspClipper.h",
     re.escape("\tint VitaWidth() const { return ViewportWidth; }\n"),
     lambda m: m.group(0) + "\tvoid VitaSetPointIndex(const int* index) { VitaPointIndex = index; } // vita-pointcache-set (#203)\n",
     'vita-pointcache-set')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\t\t\tClipper.VitaPointIndex = vitaIdx;\n"),
     lambda m: "\t\t\t\tClipper.VitaSetPointIndex(vitaIdx); // vita-pointcache-setcall\n",
     'vita-pointcache-setcall')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\t\tClipper.VitaPointIndex = nullptr;\n"),
     lambda m: "\t\t\tClipper.VitaSetPointIndex(nullptr); // vita-pointcache-unset\n",
     'vita-pointcache-unset')
# 204. LaunchInfo.IsHarryPotter1() / IsHarryPotter2() / IsKnowWonder() compared gameExecutableName with a literal at every call
#      (std::string == "HP"): ~200 places, many per script call, per actor tick, per physics step. The answer is kept in the
#      struct (vitaGame: 0 none, 1 HP1, 2 HP2; -1 not yet), reset where GameFolder.cpp names the executable.
edit("GameFolder.h",
     re.escape('\tbool IsHarryPotter1() const { return gameExecutableName == "HP"; }\n\tbool IsHarryPotter2() const { return gameExecutableName == "Game"; }\n'),
     lambda m: ("#ifdef __vita__ // vita-gamecache\n"
                "\tmutable int8_t vitaGame = -1;   // HP1 1, HP2 2, else 0 (-1: not worked out); reset when gameExecutableName is set\n"
                "\tint VitaGame() const { if (vitaGame < 0) vitaGame = gameExecutableName == \"HP\" ? 1 : (gameExecutableName == \"Game\" ? 2 : 0); return vitaGame; }\n"
                "\tbool IsHarryPotter1() const { return VitaGame() == 1; }\n"
                "\tbool IsHarryPotter2() const { return VitaGame() == 2; }\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-gamecache')
edit("GameFolder.h",
     re.escape("\tbool IsKnowWonder() const { return IsHarryPotter1() || IsHarryPotter2(); }\n"),
     lambda m: ("#ifdef __vita__ // vita-gamecache-kw\n\tbool IsKnowWonder() const { return VitaGame() != 0; }\n#else\n" + m.group(0) + "#endif\n"),
     'vita-gamecache-kw')
edit("GameFolder.cpp",
     re.escape("\t\tinfo.gameExecutableName = fs::path(ue1_game.second).stem().string();\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-gamecache-reset\n\t\tinfo.vitaGame = -1;\n#endif\n",
     'vita-gamecache-reset')
# 205. UActor::UpdateBspInfo worked out a skeletal mesh's mesh-to-world box (three mat4 products, a box transform, a second
#      Coords::Rotation) and then overwrote it with KW::GetRenderBoundingBox: in KnowWonder games the skeletal box alone.
edit("Packages/Engine/Actors/UActor_Render.cpp",
     re.escape("\tif (dt == DT_Mesh && Mesh())\n\t{\n\t\tUMesh* mesh = Mesh();\n"),
     lambda m: ("#ifdef __vita__ // vita-skelbox-only: the box below would be overwritten (KW::GetRenderBoundingBox)\n"
                "\tUSkeletalMesh* vitaSkel = (dt == DT_Mesh && Mesh() && engine->LaunchInfo.IsKnowWonder()) ? UObject::TryCast<USkeletalMesh>(Mesh()) : nullptr;\n"
                "\tif (vitaSkel)\n\t{\n\t\tVITA_PROBE(BspSkelBox);\n\t\tbbox = KW::GetRenderBoundingBox(this, vitaSkel);\n\t}\n"
                "\telse\n#endif\n" + m.group(0)),
     'vita-skelbox-only')
# 206. KW::SetupMeshLighting's 'does the light see the actor' check (ModelLineCheck on the level BSP, each light every 16 frames per
#      actor) through #191's table of level line checks (exact: same line, same answer); probe 'mesh light: sees the actor'.
edit("../../knowwonder/KWLevelCheck.cpp",
     re.escape("\t// IDA Engine.dll: ?MultiLineCheck@ULevel@@UAEPAUFCheckResult@@AAVFMemStack@@VFVector@@11HPAVALevelInfo@@E@Z [HP1 0x103AC620]\n"),
     lambda m: ("#ifdef __vita__ // vita-wlcache-export: the table for other callers (KWMeshLight.cpp, #206)\n"
                "\tbool VitaLevelLineCheckCached(CheckResult& result, const vec3& end, const vec3& start, const vec3& extent, uint8_t extraNodeFlags)\n"
                "\t{\n\t\treturn VitaWorldLineCheck(result, end, start, extent, extraNodeFlags);\n\t}\n#endif\n\n" + m.group(0)),
     'vita-wlcache-export')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\t\t\t\tpicked = ModelLineCheck(hit, ModelFrame::Level(engine->Level->Model), light->Location(), location, vec3(0.0f), 0);\n"),
     lambda m: ("#ifdef __vita__ // vita-meshlight-seecache\n"
                "\t\t\t\t\t{\n\t\t\t\t\t\tVITA_PROBE(MeshLightSee);\n"
                "\t\t\t\t\t\tpicked = VitaLevelLineCheckCached(hit, light->Location(), location, vec3(0.0f), 0);\n\t\t\t\t\t}\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-meshlight-seecache')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("namespace KW\n{\n"),
     lambda m: ("#ifdef __vita__ // vita-meshlight-seedecl\n#include \"VitaProbes.h\"\n"
                "namespace KW { bool VitaLevelLineCheckCached(CheckResult& result, const vec3& end, const vec3& start, const vec3& extent, uint8_t extraNodeFlags); }\n#endif\n" + m.group(0)),
     'vita-meshlight-seedecl')
# 206b. probes: SetupMeshLighting's candidate count and its sort + picking loop
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\tstd::stable_sort(candidates.begin(), candidates.end(), [](const Candidate& a, const Candidate& b) { return a.Importance > b.Importance; });\n"),
     lambda m: ("#ifdef __vita__ // vita-meshlight-candprobe\n\t\tif (VitaProbes::enabled)\n\t\t\tVitaProbes::calls[VitaProbes::MeshLightCand] += (unsigned)candidates.size();\n"
                "\t\tVITA_PROBE(MeshLightPick);\n#endif\n" + m.group(0)),
     'vita-meshlight-candprobe')
# 206c. probes: SetupMeshLighting as a whole and its BeginFrame
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\tvoid SetupMeshLighting(MeshLighting& out, UActor* actor, UActor* lightActor, UZoneInfo* zone)\n\t{\n\t\tBeginFrame(actor);\n"),
     lambda m: ("\tvoid SetupMeshLighting(MeshLighting& out, UActor* actor, UActor* lightActor, UZoneInfo* zone)\n\t{\n"
                "#ifdef __vita__ // vita-meshlight-wholeprobe\n\t\tVITA_PROBE(MeshLightRest);\n\t\t{ VITA_PROBE(MeshLightBegin); BeginFrame(actor); }\n#else\n"
                "\t\tBeginFrame(actor);\n#endif\n"),
     'vita-meshlight-wholeprobe')
# 206d. laps inside KW's mesh light BeginFrame
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\t\tstd::uniform_real_distribution<float> frand(0.0f, 1.0f);\n"),
     lambda m: "\t\t\tVITA_LAP_START; // vita-mlb-laps\n" + m.group(0),
     'vita-mlb-laps')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("#ifdef __vita__ // vita-framelights-use\n"),
     lambda m: "\t\t\tVITA_LAP(MLBFlicker); // vita-mlb-flicker\n" + m.group(0),
     'vita-mlb-flicker')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("#ifdef __vita__ // vita-lightsnap-fill\n"),
     lambda m: "\t\t\tVITA_LAP(MLBSnapshot); // vita-mlb-snap\n" + m.group(0),
     'vita-mlb-snap')
edit("../../knowwonder/KWMeshLight.cpp",
     re.escape("\t\t\ts.Grid.Update(s.Lights, s.LightLocations, s.LightRadii); // vita-lightgrid-update\n"),
     lambda m: "\t\t\tVITA_LAP(MLBFill); // vita-mlb-fill\n" + m.group(0) + "\t\t\tVITA_LAP(MLBGrid);\n",
     'vita-mlb-fill')
# 207. A fog map built again (Lev2_Fire1 while the camera moves) made a new FogmapBuilder each time: its two arrays malloc'd and
#      freed per map (slow on a full heap, see #200). One builder kept (the main thread only); Setup clears only the texels used
#      (the rest of a bigger array is never read: the copy out takes Width x Height).
edit("Light/LightSystem_Fog.cpp",
     re.escape("\tFogmapBuilder builder;\n\tbuilder.Setup(model, mapCoords, lightMap, zoneActor);\n"),
     lambda m: ("#ifdef __vita__ // vita-fogbuilder-keep\n\tstatic FogmapBuilder builder;\n#else\n\tFogmapBuilder builder;\n#endif\n"
                "\tbuilder.Setup(model, mapCoords, lightMap, zoneActor);\n"),
     'vita-fogbuilder-keep')
edit("Light/FogmapBuilder.cpp",
     re.escape("\tvec4 zero(0.0f);\n\tfor (vec4& c : fogcolors)\n\t\tc = zero;\n"),
     lambda m: ("\tvec4 zero(0.0f);\n#ifdef __vita__ // vita-fogbuilder-clear: the texels of this map only\n"
                "\tfor (size_t i = 0; i < size; i++)\n\t\tfogcolors[i] = zero;\n#else\n"
                "\tfor (vec4& c : fogcolors)\n\t\tc = zero;\n#endif\n"),
     'vita-fogbuilder-clear')
# 208. The clipper's screen as one bit a pixel (vita/VitaClipBits.h; render.cfg clipper_bits, default 1): IsVisible and DrawSpan
#      on 32-pixel words instead of walking and editing the span lists (same answers: tests/clipbitstest.cpp, 1.6 M random
#      operations, 0 differ, collected portal spans included).
edit("Render/BspClipper.h",
     re.escape('#include "VitaConfig.h" // vita-clipperinc\n'),
     lambda m: m.group(0) + '#include "VitaClipBits.h" // vita-clipbits-inc\n',
     'vita-clipbits-inc')
edit("Render/BspClipper.h",
     re.escape("\tvoid VitaSetPointIndex(const int* index) { VitaPointIndex = index; } // vita-pointcache-set (#203)\n"),
     lambda m: m.group(0) + "\tVitaClipBits VitaBits; // vita-clipbits-fields (#208)\n\tbool VitaUseBits = false;\n",
     'vita-clipbits-fields')
edit("Render/BspClipper.cpp",
     re.escape("BspClipper::BspClipper()\n{\n\tViewport.resize(ViewportHeight);\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-clipbits-ctor\n"
                             "\tVitaUseBits = VitaConfigInt(\"clipper_bits\", 1) != 0;\n"
                             "\tif (VitaUseBits)\n\t\tVitaBits.Resize(ViewportWidth, ViewportHeight);\n#endif\n"),
     'vita-clipbits-ctor')
edit("Render/BspClipper.cpp",
     re.escape("\tfor (auto& line : Viewport)\n\t{\n\t\tline.clear();\n\t\tline.push_back(left);\n\t\tline.push_back(right);\n\t}\n"),
     lambda m: ("#ifdef __vita__ // vita-clipbits-setup\n\tif (VitaUseBits)\n\t\tVitaBits.Clear();\n\telse\n#endif\n" + m.group(0)),
     'vita-clipbits-setup')
edit("Render/BspClipper.cpp",
     re.escape("bool BspClipper::IsVisible(int16_t y, int16_t x0, int16_t x1)\n{\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-clipbits-visible\n\tif (VitaUseBits)\n\t\treturn VitaBits.IsVisible(y, x0, x1);\n#endif\n",
     'vita-clipbits-visible')
edit("Render/BspClipper.cpp",
     re.escape("\tnumDrawSpans++;\n\n\tauto& line = Viewport[y];\n"),
     lambda m: ("\tnumDrawSpans++;\n\n#ifdef __vita__ // vita-clipbits-draw\n"
                "\tif (VitaUseBits)\n\t{\n"
                "\t\tif (CollectSpans)\n\t\t{\n"
                "\t\t\tconst int c0 = std::max<int>(x0, 0), c1 = std::min<int>(x1, ViewportWidth);\n"
                "\t\t\tif (c0 < c1)\n"
                "\t\t\t\tVitaBits.OpenRuns(y, c0, c1, [&](int a, int e) { PortalSpan s; s.x0 = (int16_t)a; s.x1 = (int16_t)e; s.y = y; VisibleSpans.push_back(s); });\n"
                "\t\t}\n"
                "\t\treturn VitaBits.Fill(y, x0, x1);\n\t}\n#endif\n"
                "\tauto& line = Viewport[y];\n"),
     'vita-clipbits-draw')
# 208b. clipper_bits read once (VitaConfig.h VitaClipperBits): the constructor read render.cfg for every BspClipper made
edit("Render/BspClipper.cpp",
     re.escape("\tVitaUseBits = VitaConfigInt(\"clipper_bits\", 1) != 0;\n"),
     lambda m: "\tVitaUseBits = VitaClipperBits(); // vita-clipbits-once\n",
     'vita-clipbits-once')
# 210b. The name tables made before every other global (init_priority): with link-time optimization (#210) the global
#       constructors run in another order and a global NameString of another file asked the tables before they existed (data
#       abort in NameString::GetIndex at start). Harmless without LTO.
edit("Package/NameString.cpp",
     re.escape("Array<std::string> NameString::Names;\nstd::unordered_map<std::string, int> NameString::CompareStringToIndex;\nstd::unordered_map<std::string, std::pair<int, int>> NameString::SpellStringToIndex;\n"),
     lambda m: ("#ifdef __vita__ // vita-names-first\n"
                "__attribute__((init_priority(101))) Array<std::string> NameString::Names;\n"
                "__attribute__((init_priority(101))) std::unordered_map<std::string, int> NameString::CompareStringToIndex;\n"
                "__attribute__((init_priority(101))) std::unordered_map<std::string, std::pair<int, int>> NameString::SpellStringToIndex;\n"
                "#else\n" + m.group(0) + "#endif\n"),
     'vita-names-first')
# 211. Statistics: how often the main view is bit for bit the one of the frame before (a replay of the BSP walk would only pay
#      when it is): log line 'VitaViewSame: N of M main views unchanged' every 600 main views.
edit("Render/VisibleFrame.cpp",
     re.escape("\tVitaProbes::Lap vitaPortalLap; // vita-portallaps\n"),
     lambda m: ("#ifdef __vita__ // vita-viewsame-stat\n"
                "\tif (portalDepth == 0)\n\t{\n"
                "\t\tstatic float lastView[19] = {};\n\t\tstatic unsigned same = 0, views = 0;\n"
                "\t\tfloat now[19];\n\t\tstd::memcpy(now, worldToView.matrix, 64);\n\t\tnow[16] = location.x; now[17] = location.y; now[18] = location.z;\n"
                "\t\tif (std::memcmp(now, lastView, sizeof(now)) == 0)\n\t\t\tsame++;\n"
                "\t\tstd::memcpy(lastView, now, sizeof(now));\n"
                "\t\tif (++views % 600 == 0)\n\t\t{\n"
                "\t\t\tLogMessage(\"VitaViewSame: \" + std::to_string(same) + \" of \" + std::to_string(views) + \" main views unchanged\");\n"
                "\t\t\tsame = views = 0;\n\t\t}\n\t}\n#endif\n" + m.group(0)),
     'vita-viewsame-stat')
# 212. The main view's BSP walk replayed while the view is bit for bit unchanged (vita/VitaViewReplay.inc, VitaViewReplay.h;
#      render.cfg view_replay, view_replay_check). Standing still the view does not change (VitaViewSame, #211: 600 of 600).
edit("Render/BspClipper.h",
     re.escape("\tvoid VitaSetPointIndex(const int* index) { VitaPointIndex = index; } // vita-pointcache-set (#203)\n"),
     lambda m: m.group(0) + "\tstd::vector<uint64_t>* VitaFillRecord = nullptr; // vita-fillrecord-field (#212): the solid spans DrawSpan fills, logged\n",
     'vita-fillrecord-field')
edit("Render/BspClipper.cpp",
     re.escape("\tnumDrawSpans++;\n\n#ifdef __vita__ // vita-clipbits-draw\n"),
     lambda m: ("\tnumDrawSpans++;\n\n#ifdef __vita__ // vita-fillrecord\n\tif (VitaFillRecord)\n\t\tVitaFillRecord->push_back(VitaPackSpan(y, x0, x1));\n#endif\n"
                "#ifdef __vita__ // vita-clipbits-draw\n"),
     'vita-fillrecord')
edit("Render/BspClipper.h",
     re.escape('#include "VitaClipBits.h" // vita-clipbits-inc\n'),
     lambda m: m.group(0) + '#include "VitaViewReplay.h" // vita-viewreplay-inc-clip\n',
     'vita-viewreplay-inc-clip')
edit("Render/VisibleFrame.h",
     re.escape("\tArray<PortalSpan> VitaReplayPortal(BspNode* node);\n"),
     lambda m: m.group(0) + ("\t// vita/VitaViewReplay.inc (#212) vita-viewreplay-members\n"
                             "\tbool VitaViewWalk();\n\tbool VitaViewNext(uint64_t type, uint64_t& value);\n\tvoid VitaViewRefill();\n"
                             "\tbool VitaViewReplayBox(BspNode* node);\n\tbool VitaViewReplaySurface(BspNode* node);\n"
                             "\tArray<PortalSpan> VitaViewReplayPortal(BspNode* node);\n\tvoid VitaViewRecordBox(BspNode* node, bool visible);\n"
                             "\tbool VitaViewCheckSurface(BspNode* node, const vec3* points, int numverts, bool solid);\n"
                             "\tArray<PortalSpan> VitaViewCheckPortal(BspNode* node, const vec3* points, uint32_t count);\n"),
     'vita-viewreplay-members')
edit("Render/VisibleFrame.cpp",
     re.escape("#define VITA_CHECKPORTAL(node, points, count) (VitaReplay ? VitaReplayPortal(node) : Clipper.CheckPortal(points, count))\n"),
     lambda m: "#define VITA_CHECKPORTAL(node, points, count) (VitaReplay ? VitaReplayPortal(node) : VitaViewCheckPortal(node, points, count)) // vita-viewreplay-portal\n",
     'vita-viewreplay-portal')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\tvitaNodeVisible = node->RenderBound == -1 || Clipper.IsAABBVisible(engine->Level->Model->Bounds[node->RenderBound]);\n\t}\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-viewreplay-box\n\tif (!VitaReplay)\n\t\tVitaViewRecordBox(node, vitaNodeVisible);\n#endif\n",
     'vita-viewreplay-box')
edit("Render/VisibleFrame.cpp",
     re.escape("\t\t\tvitaSurfaceVisible = Clipper.CheckSurface(points, numverts, (PolyFlags & PF_NoOcclude) == 0);\n"),
     lambda m: "\t\t\tvitaSurfaceVisible = VitaViewCheckSurface(node, points, numverts, (PolyFlags & PF_NoOcclude) == 0); // vita-viewreplay-surface\n",
     'vita-viewreplay-surface')
edit("Render/VisibleFrame.cpp",
     re.escape("\tif (!vitaParallel)\n#endif\n\tProcessNode(&engine->Level->Model->Nodes[0]);\n"),
     lambda m: "\tif (!vitaParallel && !VitaViewWalk()) // vita-viewreplay-walk\n#endif\n\tProcessNode(&engine->Level->Model->Nodes[0]);\n",
     'vita-viewreplay-walk')
edit("Render/VisibleFrame.cpp",
     re.escape('#include "VitaParallelVis.inc" // vita-pvis-inc\n'),
     lambda m: m.group(0) + '#include "VitaViewReplay.inc" // vita-viewreplay-incl\n',
     'vita-viewreplay-incl')
edit("Render/VisibleBrush.cpp",
     re.escape("\t\tArray<PortalSpan> spans = frame->Clipper.CheckPortal(points, numverts);\n"),
     lambda m: ("#ifdef __vita__ // vita-viewreplay-mover: a mover's mirror fills the clipper: a logged walk with one cannot be replayed\n"
                "\t\tif (vitaViewLog.recording)\n\t\t\tvitaViewLog.spoiled = true;\n"
                "\t\tif (frame->VitaReplay && vitaReplaySource == 1)\n\t\t\tframe->VitaReplayFailed = true;\n#endif\n" + m.group(0)),
     'vita-viewreplay-mover')
edit("Render/BspClipper.h",
     re.escape("\tstd::vector<uint64_t>* VitaFillRecord = nullptr; // vita-fillrecord-field (#212): the solid spans DrawSpan fills, logged\n"),
     lambda m: m.group(0) + "\tbool VitaFill(int16_t y, int16_t x0, int16_t x1) { return DrawSpan(y, x0, x1, true); } // vita-fill-public: a logged span filled again\n",
     'vita-fill-public')
# 198b. The debug build's bDebugMode must not reach the ini: HPBase.baseConsole's config (bDebugMode) is saved with the console's
#       config, so a debug session wrote bDebugMode=True into SE-HP.ini and every later build (release too) opened in debug mode.
#       The value the ini gave is kept at start and put back into the ini before it is written at exit.
edit("Engine.cpp",
     re.escape("\t\tconsole->SetBool(\"bDebugMode\", true);\n"),
     lambda m: "\t\tvitaDebugModeBefore = console->GetBool(\"bDebugMode\") ? 1 : 0; // vita-gamedebug-keep\n" + m.group(0),
     'vita-gamedebug-keep')
edit("Engine.cpp",
     re.escape("#ifdef __vita__ // vita-gamedebug-decl\nbool VitaGameDebug(); // vita_main.cpp\n"),
     lambda m: m.group(0) + "static int vitaDebugModeBefore = -1; // vita-gamedebug-before: bDebugMode as the ini gave it (-1: the debug build did not set it)\n",
     'vita-gamedebug-before')
edit("Engine.cpp",
     re.escape("#ifdef __vita__ // vita-savepawncfg-exit\n"),
     lambda m: ("#ifdef __vita__ // vita-gamedebug-restore: the debug build's bDebugMode stays out of the ini\n"
                "\tif (vitaDebugModeBefore >= 0)\n"
                "\t\tpackages->SetIniValue(\"system\", \"HPBase.baseConsole\", \"bDebugMode\", vitaDebugModeBefore ? \"True\" : \"False\");\n"
                "#endif\n" + m.group(0)),
     'vita-gamedebug-restore')
# 213. The clipper's corner and vertex projections inline with NEON (vita/VitaMatNeon.h, bit for bit the operator's result;
#      render.cfg mat_neon, neon_check): mat4::operator*(vec4) was an out-of-line call per node box corner (8 a box).
edit("Render/BspClipper.cpp",
     r"\tvec4 verts\[8\] =\n\t\{\n(\t\tWorldToProjection \* vec4\(bbox[^\n]*\n)+\t\};\n",
     lambda m: ("#ifdef __vita__ // vita-boxneon\n\tvec4 verts[8] =\n\t{\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.min.x, bbox.min.y, bbox.min.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.max.x, bbox.min.y, bbox.min.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.min.x, bbox.max.y, bbox.min.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.max.x, bbox.max.y, bbox.min.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.min.x, bbox.min.y, bbox.max.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.max.x, bbox.min.y, bbox.max.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.min.x, bbox.max.y, bbox.max.z),\n"
                "\t\tVitaMulPoint(WorldToProjection, bbox.max.x, bbox.max.y, bbox.max.z)\n"
                "\t};\n#else\n" + m.group(0) + "#endif\n"),
     'vita-boxneon')
# 214. Settings kept when the app is closed from the LiveArea (the PS button, then close: the process is killed, Engine::Run's
#      end never comes). The ini files were written to the card only there, and the audio device / client options (the menu's
#      'set ini:Engine.Engine.AudioDevice SoundVolume', Brightness) only reached the ini at all when SE-HP.ini was missing.
#      Every 2 s the player's, the audio device's and the client's options go into the ini in memory (SetValue marks a file only
#      when a value really changed) and a changed file is written at once (#215 writes it safely).
edit("Package/PackageManager.h",
     re.escape("\tbool MissingSESystemIni() const { return missing_se_system_ini; }\n"),
     lambda m: m.group(0) + ("#ifdef __vita__ // vita-inimodified\n"
                             "\tbool VitaAnyIniModified() const { for (auto& ini : iniFiles) if (ini.second->IsModified()) return true; return false; }\n"
                             "#endif\n"),
     'vita-inimodified')
edit("Engine.cpp",
     re.escape("\t\t\tSaveGameInfo.SaveGameDescription.clear();\n\t\t}\n"),
     lambda m: m.group(0) + (
         "#ifdef __vita__ // vita-cfgautosave\n"
         "\t\t{\n"
         "\t\t\tstatic auto vitaNextConfigCheck = std::chrono::steady_clock::now() + std::chrono::seconds(2);\n"
         "\t\t\tauto vitaNow = std::chrono::steady_clock::now();\n"
         "\t\t\tif (vitaNow >= vitaNextConfigCheck)\n\t\t\t{\n"
         "\t\t\t\tvitaNextConfigCheck = vitaNow + std::chrono::seconds(2);\n"
         "\t\t\t\tif (LaunchInfo.IsKnowWonder() && Level && viewport && viewport->Actor())\n"
         "\t\t\t\t\tviewport->Actor()->SaveConfig();\n"
         "\t\t\t\tclient->SaveConfig();\n"
         "\t\t\t\taudiodev->SaveConfig();\n"
         "\t\t\t\tif (vitaDebugModeBefore >= 0)\n"
         "\t\t\t\t\tpackages->SetIniValue(\"system\", \"HPBase.baseConsole\", \"bDebugMode\", vitaDebugModeBefore ? \"True\" : \"False\");\n"
         "\t\t\t\tif (packages->VitaAnyIniModified())\n\t\t\t\t{\n"
         "\t\t\t\t\tpackages->SaveAllIniFiles();\n"
         "\t\t\t\t\tLogMessage(\"Settings written to the card (\" + std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - vitaNow).count()) + \" ms)\");\n"
         "\t\t\t\t}\n\t\t\t}\n\t\t}\n#endif\n"),
     'vita-cfgautosave')
# 215. An ini is written whole to <name>.new and then put in place: the app closed in the middle of the write left a cut ini
#      (every setting lost). vita_main.cpp takes a .new left behind when the ini itself is missing.
edit("Utils/File.cpp",
     re.escape("void File::write_all_text(const std::string& filename, const std::string& text)\n{\n"),
     lambda m: m.group(0) + (
         "#ifdef __vita__ // vita-atomicini\n"
         "\tif (filename.size() > 4 && filename.compare(filename.size() - 4, 4, \".ini\") == 0)\n\t{\n"
         "\t\tconst std::string temp = filename + \".new\";\n"
         "\t\tFILE* handle = fopen(temp.c_str(), \"wb\");\n"
         "\t\tif (handle == nullptr)\n\t\t\tException::Throw(\"Could not create \" + temp);\n"
         "\t\tbool written = fwrite(text.data(), 1, text.size(), handle) == text.size();\n"
         "\t\twritten = fclose(handle) == 0 && written;\n"
         "\t\tif (!written)\n\t\t{\n\t\t\tstd::remove(temp.c_str());\n\t\t\tException::Throw(\"Could not write \" + temp);\n\t\t}\n"
         "\t\tstd::remove(filename.c_str());   // the Vita's rename does not replace a file\n"
         "\t\tif (std::rename(temp.c_str(), filename.c_str()) != 0)\n\t\t\tException::Throw(\"Could not rename \" + temp);\n"
         "\t\treturn;\n\t}\n#endif\n"),
     'vita-atomicini')
# 216. SurrealEngine bug: IniKey::SetIndexed answered 1 ('changed') when the flag stayed the same, so every SetValue marked its
#      ini as modified: #214 wrote SE-HP.ini / SE-User.ini every 2 s (~135 ms each, a visible hitch). 1 only when it changed.
edit("Package/IniFile.cpp",
     re.escape("\tbool result = !((int)indexed ^ (int)newIndexed);\n"),
     lambda m: "\tbool result = indexed != newIndexed; // vita-setindexed-fix\n",
     'vita-setindexed-fix')
# 217. The Vita's input (vita_input.cpp) needs to know when a menu is up: HP1's console shows the UWindow mouse
#      (Viewport.bShowWindowsMouse) in the title and pause menus, but bWindowsMouseAvailable is false on the Vita, so the cursor
#      stays 'locked' there and CursorLocked can't tell a menu from the game (the menu touch never ran). The flag goes over as it is.
edit("Engine.cpp",
     re.escape("\t\tif (viewport->bShowWindowsMouse() && viewport->bWindowsMouseAvailable())\n\t\t\twindow->UnlockCursor();\n\t\telse\n\t\t\twindow->LockCursor();\n\t}\n"),
     lambda m: m.group(0) + "#ifdef __vita__ // vita-menumouse-set\n\tVitaMenuMouse = viewport && viewport->bShowWindowsMouse();\n#endif\n",
     'vita-menumouse-set')
edit("Engine.cpp",
     re.escape("#ifdef __vita__ // vita-gamedebug-decl\nbool VitaGameDebug(); // vita_main.cpp\n"),
     lambda m: m.group(0) + "extern bool VitaMenuMouse; // vita-menumouse-decl: vita_input.cpp\n",
     'vita-menumouse-decl')
PY
