#!/bin/bash
# Builds the Vita package.
#   bash build.sh            normal build   (folder build/)
#   bash build.sh profile    profiling build (folder build-profile/, slow game, see profile.cpp)
set -e
cd "$(dirname "$0")"
export VITASDK=/usr/local/vitasdk
export PATH=$VITASDK/bin:$PATH

# the fixes in the engine's and Flipendo's sources (safe to run again)
bash ./apply_fixes.sh

# Files copied from another computer can carry a time that is older than the objects built here (another clock or
# time zone), and then make skips them as "unchanged". Touching the sources of this folder makes sure that
# what you copied gets compiled.
touch CMakeLists.txt *.cpp *.h

dir=build
opts=""
if [ "$1" = "profile" ]; then
	dir=build-profile
	opts="-DVITA_PROFILE=ON"
fi

mkdir -p "$dir"
cd "$dir"
cmake $opts ..

if ! make -j4 > build.log 2>&1; then
	echo
	echo "THE BUILD FAILED. The errors (the whole log is in $dir/build.log):"
	grep -n -B1 -A6 "error\|Cannot allocate" build.log | head -80
	exit 1
fi

tail -3 build.log
echo
ls -la --time-style=full-iso flipendo.vpk
sha256sum flipendo.vpk
echo "Install $PWD/flipendo.vpk"
