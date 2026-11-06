#pragma once

// Decoding MP2/MP3 sounds on a thread of their own (sound_thread=1 in render.cfg). The first play of a sound used to decode
// all of it in the game's frame: a line of dialogue 30-110 ms, a room's ambience up to 230 ms (minimp3, ~11 ms per second
// of mono sound). Now USound::GetSound only opens the file (length, rate and channels are known at once, so the scripts'
// GetSoundDuration is unchanged), the samples are decoded here, and the sound starts on the device a few frames later
// (USurrealAudioDevice::UpdateSounds waits for it). Included by USound.cpp only.

#ifdef __vita__
#include "Audio/AudioSource.h"
#include "Utils/Array.h"
#include "VitaConfig.h"
#include <psp2/kernel/cpu.h>
#include <psp2/kernel/threadmgr.h>
#include <memory>
#include <mutex>
#include <vector>

class USound;

namespace VitaSoundDecode
{
	struct Job
	{
		USound* sound = nullptr;
		std::unique_ptr<AudioSource> source;
		size_t expected = 0;      // samples the source says it has
		Array<float> samples;
		bool started = false;     // taken by the thread
		bool done = false;
		bool failed = false;
	};

	inline std::mutex mutex;
	inline std::vector<std::unique_ptr<Job>> jobs;   // the jobs stay at the same address: the thread keeps a pointer while it works
	inline SceUID thread = -1;

	// What USound::GetSound did: room for the samples, then the size of what was read, both rounded the same way
	inline size_t Round4(size_t x) { return (x & ~(size_t)3) + 4; }

	inline int Main(SceSize, void*)
	{
		for (;;)
		{
			Job* job = nullptr;
			{
				std::lock_guard lock(mutex);
				for (auto& j : jobs)
				{
					if (!j->started)
					{
						j->started = true;
						job = j.get();
						break;
					}
				}
			}
			if (!job)
			{
				sceKernelDelayThread(2000);
				continue;
			}

			Array<float> samples;
			bool failed = false;
			try
			{
				samples.resize(Round4(job->expected));
				samples.resize(Round4(job->source->ReadSamples(samples.data(), samples.size())));
			}
			catch (...)
			{
				failed = true;
			}
			job->source.reset();

			std::lock_guard lock(mutex);
			job->samples = std::move(samples);
			job->failed = failed;
			job->done = true;
		}
		return 0;
	}

	inline bool Enabled()
	{
		static const bool on = VitaConfigInt("sound_thread", 1) != 0;
		return on;
	}

	// The thread: below the engine thread (96 by default) and the audio thread, on whichever core is free. False: decode as before
	inline bool EnsureThread()
	{
		if (thread >= 0)
			return true;
		SceUID id = sceKernelCreateThread("sounddecode", Main, 140, 256 * 1024, 0, SCE_KERNEL_CPU_MASK_USER_ALL, nullptr);
		if (id < 0)
			return false;
		if (sceKernelStartThread(id, 0, nullptr) < 0)
		{
			sceKernelDeleteThread(id);
			return false;
		}
		thread = id;
		return true;
	}

	inline void Start(USound* sound, std::unique_ptr<AudioSource> source, size_t expected)
	{
		auto job = std::make_unique<Job>();
		job->sound = sound;
		job->source = std::move(source);
		job->expected = expected;
		std::lock_guard lock(mutex);
		jobs.push_back(std::move(job));
	}

	enum class State { Pending, Done, Failed };

	// Done: the samples are moved to out and the job is gone
	inline State Poll(USound* sound, Array<float>& out)
	{
		std::lock_guard lock(mutex);
		for (size_t i = 0; i < jobs.size(); i++)
		{
			Job* job = jobs[i].get();
			if (job->sound != sound)
				continue;
			if (!job->done)
				return State::Pending;
			const bool failed = job->failed;
			out = std::move(job->samples);
			jobs.erase(jobs.begin() + i);
			return failed ? State::Failed : State::Done;
		}
		return State::Failed;   // no job for it
	}
}
#endif
