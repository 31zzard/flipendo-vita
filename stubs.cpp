// Stand-ins for desktop-only pieces that are left out of the Vita build.

#include "Audio/AudioPlayer.h"
#include "Audio/AudioSource.h"
#include <memory>
#include <stdexcept>

namespace HP1
{
	namespace Mods
	{
		// Discord Rich Presence does not exist on a Vita (DiscordPresence.cpp is not built).
		void TickDiscordPresence(float)
		{
		}
	}
}

// The engine's AudioPlayer plays a stream straight on the sound card (WASAPI on Windows, ALSA on Linux).
// A Vita version is still to be written; the game's own sounds and music go through OpenAL (AudioDevice) instead.
std::unique_ptr<AudioPlayer> AudioPlayer::Create(std::unique_ptr<AudioSource> source)
{
	throw std::runtime_error("AudioPlayer is not available on the Vita yet");
}

// vita-elf-create appends about 4.5 KB of system data to the end of the code segment. The data segment starts on
// the next 64 KB boundary after the code, and when the end of the code happens to lie closer than that to the
// boundary, the build stops with "Cannot allocate ... bytes for SCE data at end of segment 0; segment 1 overlaps".
// This block pushes the end of the code over the boundary, so the data segment moves up and there is room.
// If the same message ever comes back after the code has grown, change the size (any value between 8 and 40 KB).
#ifndef VITA_TEXT_PADDING
#define VITA_TEXT_PADDING 12288
#endif
extern "C" __attribute__((used, section(".text.zz_vita_padding")))
const unsigned char vita_text_padding[VITA_TEXT_PADDING] = { 1 };
