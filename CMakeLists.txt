# Flipendo / SurrealEngine on PS Vita: compile + link spike (UNTESTED draft, step 2).
#
# Goal of this step: see what is still missing to LINK the engine for the Vita.
# No renderer, audio device, window or launcher yet. The link of flipendo_link_spike is expected to FAIL;
# the list of "undefined reference" lines is the result we want.
#
# Needs the vdpm libraries (see below). Usage (WSL):
#   export VITASDK=/usr/local/vitasdk; export PATH=$VITASDK/bin:$PATH
#   cd ~/flipendo/vita/build && cmake .. && make -k -j4 2>&1 | tee build.log

cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
	if(DEFINED ENV{VITASDK})
		set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
	else()
		message(FATAL_ERROR "VITASDK is not set (export VITASDK=/usr/local/vitasdk)")
	endif()
endif()

project(SurrealVita C CXX)

# The SurrealEngine submodule of flipendo (override with -DENGINE_DIR=...)
set(ENGINE_DIR "${CMAKE_CURRENT_LIST_DIR}/../src/engine" CACHE PATH "SurrealEngine source folder")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 17)

# ---- engine core sources: everything except UI, editor, desktop renderers and the desktop apps ----
file(GLOB_RECURSE CORE_SOURCES "${ENGINE_DIR}/SurrealEngine/*.cpp")

list(FILTER CORE_SOURCES EXCLUDE REGEX "/SurrealEngine/UI/Editor/")   # the level editor UI only
list(FILTER CORE_SOURCES EXCLUDE REGEX "/SurrealEngine/Audio/AudioPlayer\\.cpp$")   # Linux ALSA player: replaced later
list(FILTER CORE_SOURCES EXCLUDE REGEX "/SurrealEngine/RenderDevice/(D3D11|OpenGL|Vulkan)/")
list(FILTER CORE_SOURCES EXCLUDE REGEX "/SurrealEngine/RenderDevice/RenderDevice\\.cpp$")
list(FILTER CORE_SOURCES EXCLUDE REGEX "/SurrealEngine/(EditorApp|MainGame|MainEditor|MainDebugger)\\.cpp$")

# ---- third party code the core needs (from the engine's own THIRDPARTY_SOURCES list) ----
set(THIRDPARTY_SOURCES
	${ENGINE_DIR}/Thirdparty/MurmurHash3/MurmurHash3.cpp
	${ENGINE_DIR}/Thirdparty/resample/pffft.cpp
	${ENGINE_DIR}/Thirdparty/resample/r8bbase.cpp
	${ENGINE_DIR}/Thirdparty/miniz/miniz.c
	${ENGINE_DIR}/Thirdparty/kissfft/kiss_fft.c
	${ENGINE_DIR}/Thirdparty/kissfft/kiss_fftr.c
)

# ---- Flipendo's own code (src/knowwonder, src/hp1, src/hp2) ----
# It hooks into the engine through src/surreal-patches: tools/apply_patches.sh must have been run.
set(FLIPENDO_DIR "${CMAKE_CURRENT_LIST_DIR}/../src" CACHE PATH "Flipendo src folder")
file(GLOB_RECURSE FLIPENDO_SOURCES
	"${FLIPENDO_DIR}/knowwonder/*.cpp"
	"${FLIPENDO_DIR}/hp1/*.cpp"
	"${FLIPENDO_DIR}/hp2/*.cpp")
list(FILTER FLIPENDO_SOURCES EXCLUDE REGEX "KWNativeFontApple\\.cpp$")      # macOS only
list(FILTER FLIPENDO_SOURCES EXCLUDE REGEX "/mods/DiscordPresence\\.cpp$")  # Discord: not on a Vita (see stubs.cpp)

add_library(SurrealCoreVita STATIC
	${CORE_SOURCES} ${THIRDPARTY_SOURCES} ${FLIPENDO_SOURCES}
	${CMAKE_CURRENT_LIST_DIR}/stubs.cpp
	${CMAKE_CURRENT_LIST_DIR}/VitaSpellLesson.cpp   # spell lessons: touch drawing and stick rails
	${CMAKE_CURRENT_LIST_DIR}/VitaShadows.cpp       # actor shadows: the Update event only when needed
	${CMAKE_CURRENT_LIST_DIR}/VitaOverlay.cpp       # the on-screen frame counter (render.cfg overlay)
	${CMAKE_CURRENT_LIST_DIR}/RenderDeviceVita.cpp   # the engine's RenderDevice.cpp with a Vita-only factory
	${CMAKE_CURRENT_LIST_DIR}/VitaRenderDevice.cpp)  # the Vita renderer (null for now)

target_include_directories(SurrealCoreVita PRIVATE
	${CMAKE_CURRENT_LIST_DIR}
	${CMAKE_CURRENT_LIST_DIR}/compat   # stand-ins for headers the Vita's newlib lacks (sys/ioctl.h)
	${ENGINE_DIR}/SurrealEngine
	${ENGINE_DIR}/SurrealWidgets/include   # core headers include canvas.h / rect.h
	${ENGINE_DIR}/SurrealGPU/include
	${ENGINE_DIR}/Thirdparty
	${ENGINE_DIR}/Thirdparty/openmpt
	${ENGINE_DIR}/Thirdparty/openal-soft/include   # headers only for now
	${ENGINE_DIR}/Thirdparty/miniz
	# Flipendo's folders (its own .cmake files add these too)
	${FLIPENDO_DIR}
	${FLIPENDO_DIR}/knowwonder
	${FLIPENDO_DIR}/hp1
	${FLIPENDO_DIR}/hp2
	# KWNativeFont.cpp reads TrueType fonts with SurrealWidgets' internal headers
	${ENGINE_DIR}/SurrealWidgets/include/surrealwidgets
	${ENGINE_DIR}/SurrealWidgets/src
)

# The engine builds with Precomp.h precompiled (its sources may rely on it)
target_precompile_headers(SurrealCoreVita PRIVATE
	$<$<COMPILE_LANGUAGE:CXX>:${ENGINE_DIR}/SurrealEngine/Precomp.h>)

# The engine's non-Windows branches are written for Linux/macOS; UNIX selects them.
target_compile_definitions(SurrealCoreVita PRIVATE UNIX _UNIX PLATFORM_VITA)
target_compile_options(SurrealCoreVita PRIVATE -O2 -Wno-narrowing)
# -O3 and ARM instead of Thumb code (a Cortex-A9 runs it faster; the code gets bigger). If something misbehaves that did not:
# cmake -DVITA_AGGRESSIVE=OFF ..
option(VITA_AGGRESSIVE "compile the engine with -O3 -marm" ON)
if(VITA_AGGRESSIVE)
	target_compile_options(SurrealCoreVita PRIVATE -O3 -marm)
endif()
# Tuning for the Vita's processor. If something crashes that did not before, try it off:  cmake -DVITA_TUNE_FLAGS=OFF ..
option(VITA_TUNE_FLAGS "compile the engine with -mtune=cortex-a9 -fno-math-errno" ON)
if(VITA_TUNE_FLAGS)
	target_compile_options(SurrealCoreVita PRIVATE -mtune=cortex-a9 -fno-math-errno)
endif()

# The padding block in the code segment (see stubs.cpp): change the size if vita-elf-create complains about SCE data
# (a separate variable from the first version, so an old cache keeps no stale value; the definition goes to stubs.cpp only, so
# changing the size rebuilds one file, not the whole engine)
set(VITA_TEXT_PAD_BYTES 28672 CACHE STRING "size of the padding block in the code segment")
set_source_files_properties(${CMAKE_CURRENT_LIST_DIR}/stubs.cpp PROPERTIES COMPILE_DEFINITIONS "VITA_TEXT_PADDING=${VITA_TEXT_PAD_BYTES}")

# Profiling build (slow): cmake -DVITA_PROFILE=ON .. in a folder of its own. See profile.cpp.
option(VITA_PROFILE "Profiling build: samples where the engine spends its time" OFF)
if(VITA_PROFILE)
	target_compile_options(SurrealCoreVita PRIVATE -finstrument-functions
		"-finstrument-functions-exclude-file-list=/include/c++/,/Math/,Utils/Array.h,Thirdparty/")
endif()

# Debug info (-g) for the script interpreter only: crash addresses then turn into source lines
# (arm-vita-eabi-addr2line -i -f -C -e flipendo ADDRESS). It does not change the generated code.
set_source_files_properties(${ENGINE_DIR}/SurrealEngine/VM/Frame.cpp PROPERTIES COMPILE_FLAGS "-g")

# ---- SurrealVideo: the Indeo 5 video decoder for the cutscenes (the engine builds it as a DLL; static here) ----
set(VIDEO_DIR ${ENGINE_DIR}/SurrealVideo)
add_library(SurrealVideoVita STATIC
	${VIDEO_DIR}/SurrealVideo.cpp
	${VIDEO_DIR}/libavcodec/indeo5.c
	${VIDEO_DIR}/libavcodec/ivi.c
	${VIDEO_DIR}/libavcodec/ivi_dsp.c
	${VIDEO_DIR}/libavcodec/vlc.c
	${VIDEO_DIR}/libavcodec/adpcm.c
	${VIDEO_DIR}/libavcodec/adpcm_data.c
	${VIDEO_DIR}/libavutil/reverse.c
	${VIDEO_DIR}/libavutil/mem.c)
target_include_directories(SurrealVideoVita PRIVATE ${VIDEO_DIR})
set_target_properties(SurrealVideoVita PROPERTIES CXX_STANDARD 20 C_STANDARD 17)
target_compile_options(SurrealVideoVita PRIVATE -O2 -w)

# ---- Libraries installed with vdpm: SDL2 (vitaGL video driver), OpenAL, libopenmpt ----
# vdpm install vitaGL vitaShaRK sdl2_vitagl openal-soft libopenmpt libvorbis   (needs: sudo apt install pkg-config)
find_program(VITA_PKG_CONFIG arm-vita-eabi-pkg-config HINTS "$ENV{VITASDK}/bin")
function(vita_pkg out_cflags out_libs)
	execute_process(COMMAND ${VITA_PKG_CONFIG} --static --cflags ${ARGN}
		OUTPUT_VARIABLE _c OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _r1 ERROR_VARIABLE _e1)
	execute_process(COMMAND ${VITA_PKG_CONFIG} --static --libs ${ARGN}
		OUTPUT_VARIABLE _l OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _r2 ERROR_VARIABLE _e2)
	if(NOT _r1 EQUAL 0 OR NOT _r2 EQUAL 0)
		message(FATAL_ERROR "arm-vita-eabi-pkg-config failed for '${ARGN}': ${_e1}${_e2}\n(is pkg-config installed? sudo apt install pkg-config)")
	endif()
	separate_arguments(_c UNIX_COMMAND "${_c}")
	separate_arguments(_l UNIX_COMMAND "${_l}")
	set(${out_cflags} ${_c} PARENT_SCOPE)
	set(${out_libs} ${_l} PARENT_SCOPE)
endfunction()

vita_pkg(SDL2_CFLAGS SDL2_LIBS sdl2)
vita_pkg(OPENAL_CFLAGS OPENAL_LIBS openal)
vita_pkg(OPENMPT_CFLAGS OPENMPT_LIBS libopenmpt)

# ---- SurrealWidgets: the widget/window library the engine's window and canvas are built on.
# SDL2 backend only (window, keys, touch); the Linux/Windows/macOS backends and file dialogs are not built.
set(W ${ENGINE_DIR}/SurrealWidgets)
file(GLOB_RECURSE WIDGET_SOURCES
	"${W}/src/core/*.cpp" "${W}/src/widgets/*.cpp" "${W}/src/systemdialogs/*.cpp"
	"${W}/src/window/stub/*.cpp" "${W}/src/window/sdl2/*.cpp")
list(APPEND WIDGET_SOURCES ${W}/src/window/window.cpp)
list(FILTER WIDGET_SOURCES EXCLUDE REGEX "/resourcedata_(win|mac|unix)\\.")   # unix one needs GTK (gio)
list(APPEND WIDGET_SOURCES ${CMAKE_CURRENT_LIST_DIR}/resourcedata_vita.cpp)
list(APPEND WIDGET_SOURCES ${CMAKE_CURRENT_LIST_DIR}/vita_input.cpp)   # pad stick -> cursor / camera, cross -> click
add_library(SurrealWidgetsVita STATIC ${WIDGET_SOURCES})
target_include_directories(SurrealWidgetsVita PRIVATE ${W}/include ${W}/include/surrealwidgets ${W}/src ${W}/src/window/sdl2)
target_compile_options(SurrealWidgetsVita PRIVATE ${SDL2_CFLAGS} -O2 -Wno-narrowing)
target_compile_definitions(SurrealWidgetsVita PRIVATE UNIX _UNIX USE_SDL2)
set_target_properties(SurrealWidgetsVita PROPERTIES CXX_STANDARD 20)

# ---- The Vita program: the engine's own GameApp started by vita_main.cpp, packed as flipendo.vpk ----
include("${VITASDK}/share/vita.cmake" REQUIRED)

set(VITA_APP_NAME "Harry Potter Flipendo")
set(VITA_TITLEID  "FLPD00001")
set(VITA_VERSION  "00.03")

add_executable(flipendo vita_main.cpp)
# EXPERIMENT, off by default: asks the system for the "extended memory" mode through the app's param.sfo (-d ATTRIBUTE2=12),
# which, as far as I know, lets an app use more RAM. Not verified: if the app does not start, switch it off again
# (cmake -DVITA_EXTRA_MEMORY=OFF ..), and VITA_HEAP_MB can then be raised, e.g. to 300.
option(VITA_EXTRA_MEMORY "ask for the extended memory mode (experimental)" OFF)
if(VITA_EXTRA_MEMORY)
	set(VITA_MKSFOEX_FLAGS "${VITA_MKSFOEX_FLAGS} -d ATTRIBUTE2=12")
endif()
set(VITA_HEAP_MB 192 CACHE STRING "memory for malloc/new in megabytes: raise it if the log says std::bad_alloc")
target_compile_definitions(flipendo PRIVATE VITA_HEAP_MB=${VITA_HEAP_MB})
if(VITA_PROFILE)
	target_sources(flipendo PRIVATE profile.cpp)
	target_compile_definitions(flipendo PRIVATE VITA_PROFILE)
endif()

# vita_main.cpp includes the engine's headers: same include folders and definitions as the engine core
get_target_property(CORE_INCLUDES SurrealCoreVita INCLUDE_DIRECTORIES)
target_include_directories(flipendo PRIVATE ${CORE_INCLUDES})
target_compile_definitions(flipendo PRIVATE UNIX _UNIX PLATFORM_VITA)
target_compile_options(flipendo PRIVATE -O2 -Wno-narrowing)
set_target_properties(flipendo PROPERTIES CXX_STANDARD 20)

# Only the engine core is pulled in whole (its natives and classes register themselves from global objects):
# the widgets library holds a second copy of some small helpers (UTF8Reader), which a normal link resolves by
# taking the first one.
# No explicit "pthread": OpenAL's flags already bring -pthread, and a second -lpthread makes ld load the same
# libpthread member twice ("multiple definition of pte_os...").
target_link_libraries(flipendo PRIVATE
	-Wl,--whole-archive SurrealCoreVita -Wl,--no-whole-archive
	SurrealWidgetsVita
	SurrealVideoVita
	-Wl,--start-group ${OPENMPT_LIBS} ${OPENAL_LIBS} ${SDL2_LIBS} -lSceShaccCgExt -ltaihen_stub -Wl,--end-group)

vita_create_self(flipendo.self flipendo)
# The bubble and LiveArea pictures (made by tools/make_livearea.py from images/branding)
vita_create_vpk(flipendo.vpk ${VITA_TITLEID} flipendo.self
	VERSION ${VITA_VERSION}
	NAME ${VITA_APP_NAME}
	FILE ${CMAKE_CURRENT_LIST_DIR}/sce_sys/icon0.png sce_sys/icon0.png
	FILE ${CMAKE_CURRENT_LIST_DIR}/sce_sys/livearea/contents/bg.png sce_sys/livearea/contents/bg.png
	FILE ${CMAKE_CURRENT_LIST_DIR}/sce_sys/livearea/contents/startup.png sce_sys/livearea/contents/startup.png
	FILE ${CMAKE_CURRENT_LIST_DIR}/sce_sys/livearea/contents/template.xml sce_sys/livearea/contents/template.xml)
