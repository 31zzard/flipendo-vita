#!/bin/bash
# Builds the Vita package.
#   bash build.sh            normal build   (folder build/)
#   bash build.sh profile    profiling build (folder build-profile/, slow game, see profile.cpp)
#   bash build.sh debug      normal build with HP1's debug mode on (Level Select in the title menu): for working on the game
#   bash build.sh release    normal build with it off: the one to publish
#   (without debug/release the folder keeps the mode it was last built with; the end of the output says which)
set -e
cd "$(dirname "$0")"
export VITASDK=/usr/local/vitasdk
export PATH=$VITASDK/bin:$PATH

# the fixes in the engine's and Flipendo's sources (safe to run again)
bash ./apply_fixes.sh
# a second run must change nothing: an edit whose marker is not in the text it inserts applies again on every build
again=$(bash ./apply_fixes.sh | grep -E '^\[(ok|FAIL)\]' || true)
if [ -n "$again" ]; then
	echo "apply_fixes.sh changed files on a second run (a marker missing from its inserted text?):"
	echo "$again"
	exit 1
fi

# Files copied from another computer can carry a time that is older than the objects built here (another clock or
# time zone), and then make skips them as "unchanged". Only files whose content changed since the last build of
# this folder are touched (sha256 list in <dir>/.srcsums): touching all of them rebuilt every engine file that
# includes a Vita*.h.
dir=build
opts=""
if [ "$1" = "profile" ]; then
	dir=build-profile
	opts="-DVITA_PROFILE=ON"
elif [ "$1" = "debug" ]; then
	opts="-DVITA_GAME_DEBUG=ON"
elif [ "$1" = "release" ]; then
	opts="-DVITA_GAME_DEBUG=OFF"
fi
mkdir -p "$dir"

sums="$dir/.srcsums"
srcs=$(ls CMakeLists.txt flipendo-vita.cmake *.cpp *.h *.inc 2>/dev/null)
sha256sum $srcs > "$sums.new"
if [ -f "$sums" ]; then
	changed=$(diff "$sums" "$sums.new" | sed -n 's/^> [0-9a-f]*  //p')
else
	changed=$srcs
fi
[ -n "$changed" ] && touch $changed

cd "$dir"
cmake $opts ..

make -j"$(nproc)" > build.log 2>&1 || true
# "Cannot allocate N bytes for SCE data at end of segment 0" (vita-elf-create): the code ends just before a 64 KB boundary.
# The padding goes up by 16 KB and only the link steps run again (vita/CLAUDE.md, Build).
for try in 1 2 3; do
	grep -q "Cannot allocate .* bytes for SCE data" build.log || break
	pad=$(sed -n 's/^VITA_TEXT_PAD_BYTES:STRING=//p' CMakeCache.txt)
	pad=$(( ${pad:-28672} + 16384 ))
	echo "code segment padding raised to $pad (Cannot allocate ... SCE data)"
	cmake -DVITA_TEXT_PAD_BYTES=$pad .. > /dev/null
	make -j"$(nproc)" > build.log 2>&1 || true
done

if grep -q "Error [0-9]" build.log; then
	echo
	echo "THE BUILD FAILED. The errors (the whole log is in $dir/build.log):"
	grep -n -B1 -A6 "error\|Cannot allocate" build.log | head -80
	exit 1
fi

mv .srcsums.new .srcsums
tail -3 build.log
echo
if grep -q "^VITA_GAME_DEBUG:BOOL=ON" CMakeCache.txt; then
	echo "GAME DEBUG BUILD (HP1's debug mode, Level Select): not for publishing; 'bash build.sh release' for that"
else
	echo "release build (HP1's debug mode off)"
fi
ls -la --time-style=full-iso flipendo.vpk
sha256sum flipendo.vpk
echo "Install $PWD/flipendo.vpk"
