#pragma once

// A hash for 64 bit keys. std::hash<uint64_t> on the Vita (32 bit size_t) keeps only the low 32 bits, and a lightmap's CacheID is
// (lightmap << 32) | (zone ambient << 8) | 1: every lightmap of a zone fell into one bucket, and each lookup walked a chain of hundreds
// of entries (~65 us, three lookups per surface: ~70 ms a frame in big halls). This mixes all 64 bits (the finaliser of MurmurHash3).

#include <cstddef>
#include <cstdint>

struct VitaHash64
{
	size_t operator()(uint64_t k) const
	{
		k ^= k >> 33;
		k *= 0xff51afd7ed558ccdull;
		k ^= k >> 33;
		k *= 0xc4ceb9fe1a85ec53ull;
		k ^= k >> 33;
		return (size_t)k;
	}
};
