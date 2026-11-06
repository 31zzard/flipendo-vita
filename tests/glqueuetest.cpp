// PC test of vita/VitaGLQueue.h: the same frames of GL calls made at once and through the thread must give the same calls with the
// same data, even though the caller changes its buffers right after each call (Keep), and RunNow must find the GL side idle.
//   g++ -std=gnu++20 -O1 -g -fsanitize=thread -Ipcstub -I.. glqueuetest.cpp -o glqueuetest -lpthread && setarch $(uname -m) -R ./glqueuetest
// (also with -fsanitize=address,undefined; ThreadSanitizer needs the setarch -R on newer kernels)

#include "../VitaGLQueue.h"
#include <cstdio>
#include <random>

static void Present(VitaGL::Queue& q)
{
	if (q.Threaded())
	{
		q.Swap();
		q.Submit();
	}
	else
	{
		vglSwapBuffers(GL_TRUE);
	}
}

// One frame of calls, made from a seeded random generator; buffers are overwritten after each call that reads them
static void Frame(VitaGL::Queue& q, std::mt19937& rng, std::vector<VitaGL::Texture*>& textures, int frame)
{
	q.Viewport(0, 0, 960, 544);
	q.ClearColor(0.1f, 0.2f, 0.3f, 1.0f);
	q.Clear(0x4100);
	q.EnableClientState(0x8074);
	float matrix[16];
	for (int i = 0; i < 16; i++)
		matrix[i] = (float)(rng() % 1000) / 7.0f;
	q.MatrixMode(0x1701);
	q.LoadMatrixf(matrix);
	std::memset(matrix, 0, sizeof(matrix));
	q.Ortho(0, 960, 544, 0, -1, 1);

	std::vector<float> verts(3 * 64), uvs(2 * 64);
	std::vector<uint16_t> pixels(16 * 16), indices(96);
	const int draws = 20 + (int)(rng() % 40);
	for (int d = 0; d < draws; d++)
	{
		switch (rng() % 9)
		{
		case 0:
			textures.push_back(q.GenTexture());
			q.BindTexture(textures.back());
			for (auto& p : pixels) p = (uint16_t)rng();
			q.TexImage2D(0, 0x1907, 16, 16, 0x1907, 0x8363, pixels.data(), pixels.size() * 2);
			for (auto& p : pixels) p = 0xdead;
			q.TexParameteri(0x2801, 0x2601);
			break;
		case 1:
			if (!textures.empty())
			{
				size_t i = rng() % textures.size();
				q.DeleteTexture(textures[i]);
				textures.erase(textures.begin() + (long)i);
			}
			break;
		case 2:
			if (!textures.empty())
			{
				q.BindTexture(textures[rng() % textures.size()]);
				for (auto& p : pixels) p = (uint16_t)rng();
				q.TexSubImage2D(0, 2, 3, 8, 8, 0x1907, 0x8363, pixels.data(), 8 * 8 * 2);
				for (auto& p : pixels) p = 0xbeef;
			}
			break;
		case 3:
		{
			const int n = 3 + (int)(rng() % 60);
			for (auto& v : verts) v = (float)(rng() % 100000) / 3.0f;
			q.VertexPointer(3, 0, q.Keep(verts.data(), (size_t)n * 3 * 4));
			q.TexCoordPointer(2, 0, q.Keep(uvs.data(), (size_t)n * 2 * 4));
			q.DrawArrays(GL_TRIANGLES, 0, n);
			for (auto& v : verts) v = -1.0f;
			break;
		}
		case 4:
		{
			q.BindArrayBuffer(7);
			q.VertexPointer(3, 28, (const void*)0);
			q.TexCoordPointer(2, 28, (const void*)12);
			for (auto& i : indices) i = (uint16_t)(rng() % 60000);
			q.DrawElements16(GL_TRIANGLES, 96, indices.data());
			for (auto& i : indices) i = 0;
			q.BindArrayBuffer(0);
			break;
		}
		case 5: q.Enable(0x0BE2); q.BlendFunc(1, 0x0301); break;
		case 6: q.Disable(0x0BE2); q.DepthMask((GLboolean)(rng() & 1)); q.DepthFunc(0x0203); break;
		case 7: q.Color4f(0.5f, (float)(rng() % 10), 1.0f, 1.0f); q.AlphaFunc(0x0204, 0.5f); break;
		case 8:
		{
			std::vector<uint8_t> block(8 * 4 * 4);
			for (auto& b : block) b = (uint8_t)rng();
			if (!textures.empty())
			{
				q.BindTexture(textures[rng() % textures.size()]);
				q.CompressedTexImage2D(0, 0x83F1, 16, 16, (GLsizei)block.size(), block.data());
			}
			break;
		}
		}
	}
	(void)frame;
	Present(q);
}

static std::vector<std::string> Run(bool threaded, unsigned seed, int frames, bool checkRunNow)
{
	StubGL::Log().clear();
	StubGL::NextName() = 1;
	StubGL::State() = StubGL::Arrays();
	VitaGL::Queue q;
	if (threaded && !q.Start(95, 0))
	{
		std::printf("could not start the thread\n");
		std::exit(1);
	}
	std::mt19937 rng(seed);
	std::vector<VitaGL::Texture*> textures;
	size_t swapsSeen = 0;
	for (int f = 0; f < frames; f++)
	{
		Frame(q, rng, textures, f);
		if (checkRunNow && threaded && f % 7 == 3)
		{
			// RunNow: every frame handed over so far is done when it runs (its Swap is in the log), nothing of this frame yet
			q.RunNow([&]()
			{
				size_t swaps = 0;
				for (const std::string& s : StubGL::Log())
					swaps += s == "Swap";
				if (swaps != (size_t)f + 1)
				{
					std::printf("RunNow: %zu frames presented, %d handed over\n", swaps, f + 1);
					std::exit(1);
				}
				swapsSeen = swaps;
			});
		}
	}
	for (VitaGL::Texture* t : textures)
		q.DeleteTexture(t);
	Present(q);
	q.WaitIdle();
	(void)swapsSeen;
	return StubGL::Log();
}

int main()
{
	int failures = 0;
	size_t calls = 0;
	for (unsigned seed = 1; seed <= 40; seed++)
	{
		const std::vector<std::string> direct = Run(false, seed, 30, false);
		const std::vector<std::string> threaded = Run(true, seed, 30, seed % 2 == 0);
		calls += direct.size();
		if (direct != threaded)
		{
			failures++;
			size_t i = 0;
			while (i < direct.size() && i < threaded.size() && direct[i] == threaded[i])
				i++;
			std::printf("seed %u: the calls differ at %zu of %zu/%zu:\n  at once: %s\n  thread:  %s\n", seed, i, direct.size(), threaded.size(),
				i < direct.size() ? direct[i].substr(0, 200).c_str() : "(end)", i < threaded.size() ? threaded[i].substr(0, 200).c_str() : "(end)");
		}
	}
	std::printf("%s: 40 seeds, %zu calls compared\n", failures ? "FAILED" : "ok", calls);
	return failures ? 1 : 0;
}
