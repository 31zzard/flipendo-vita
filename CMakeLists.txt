# Harry Potter and the Philosopher's Stone on PS Vita (flipendo.vpk). The build itself is flipendo-vita.cmake, shared with
# Chamber of Secrets (~/flipendo2). Usage: bash build.sh (see there).

cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
	if(DEFINED ENV{VITASDK})
		set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "toolchain file")
	else()
		message(FATAL_ERROR "VITASDK is not set (export VITASDK=/usr/local/vitasdk)")
	endif()
endif()

project(SurrealVita C CXX)

set(VITA_APP_TARGET  flipendo)
set(VITA_APP_NAME    "Harry Potter Flipendo")
set(VITA_TITLEID     "FLPD00001")
set(VITA_VERSION     "00.03")
set(VITA_DATA_ROOT   "ux0:data/flipendo")
set(VITA_GAME_FOLDER "hp1")
set(VITA_GAME_EXE    "System/HP.exe")
set(VITA_SCE_SYS     ${CMAKE_CURRENT_LIST_DIR}/sce_sys)

include(${CMAKE_CURRENT_LIST_DIR}/flipendo-vita.cmake)
