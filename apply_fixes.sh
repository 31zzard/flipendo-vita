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

PY
