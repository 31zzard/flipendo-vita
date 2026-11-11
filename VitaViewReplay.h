// The main view's BSP walk replayed while the view does not change (apply_fixes.sh #212; vita/VitaViewReplay.inc has the code).
// Shared state: VisibleBrush.cpp marks a recorded walk that a replay could not repeat (a mover's mirror filled the clipper).

#pragma once

#include <cstdint>
#include <vector>

struct VitaViewLog
{
	// One walk of the main view as it went: what each node box test, surface test and portal check answered, each surface's
	// flags, and the clipper spans each one filled, in walk order (see VitaViewReplay.inc for the event encoding)
	std::vector<uint64_t> events;
	float key[19] = {};           // the clipper's world-to-projection matrix and the view location, bit for bit
	const void* model = nullptr;  // the level model the walk was made in
	int epoch = -1;               // vitaLevelEpoch then
	bool valid = false;           // the walk can be replayed
	bool recording = false;
	bool spoiled = false;         // something happened in the walk a replay would not repeat
	size_t pos = 0;               // the replay's place in events
};
inline VitaViewLog vitaViewLog;
inline int vitaReplaySource = 0;   // what VisibleFrame::VitaReplay* answer from: 0 the parallel strips, 1 the view log

// a clipper span (y, x0, x1) packed for the log
inline uint64_t VitaPackSpan(int y, int x0, int x1) { return (uint64_t)(uint16_t)y | ((uint64_t)(uint16_t)x0 << 16) | ((uint64_t)(uint16_t)x1 << 32); }
