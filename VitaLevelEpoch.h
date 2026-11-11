#pragma once
// apply_fixes.sh #146: the count of the levels let go (VitaLevelRelease.h). A cache kept by actor (KWSkeletal, KWParticleFX,
// KWPhysics) empties itself when it changes: its actors belong to a level that is gone, and their memory adds up level after level.
// Engine thread only (the caches are used there).

inline int vitaLevelEpoch = 0;

#define VITA_LEVEL_EPOCH_CLEAR(container) \
	do { static int vitaEpochSeen_ = 0; if (vitaEpochSeen_ != vitaLevelEpoch) { vitaEpochSeen_ = vitaLevelEpoch; (container).clear(); } } while (0)

// #192: counts the times a level's Actors list was compacted (ULevel::Tick drops the null slots): the indices of actors in it
// stay the same between two compactions (new actors are appended, a destroyed one leaves a null slot that is never reused)
inline int vitaActorsVersion = 0;
