#pragma once

// The renderer's OpenGL calls, made on a thread of their own (render.cfg gl_thread=1) or at once (gl_thread=0, as before).
//
// The renderer calls these instead of gl*. With the thread, a call is written down (a command), and at the end of a frame
// (Submit, after Swap) the frame's commands go to the "glsubmit" thread, which makes the real calls and presents the picture
// while the engine already works on the next frame (scripts, physics, the next picture's preparation). The engine waits only
// when it has a frame ready and the thread is still busy with the one before. vitaGL keeps one global state and no per-thread
// context: what matters is that only one thread calls it at a time, which Submit and WaitIdle make sure of.
//
// What a command reads later must still be there then: vertex arrays, pixels and index lists that the caller reuses go through
// Keep(), which copies them into memory of the frame (freed when the thread is done with it); without the thread it returns the
// pointer itself. GL objects the caller needs to know right away (an atlas page's pixels, a vertex buffer's memory) are made
// with RunNow(), which waits until the thread is idle and then runs the code on the calling thread.
//
// Textures are VitaGL::Texture objects: the GL name in them is made, used and deleted by the GL side only (DeleteTexture also
// frees the object), so the renderer can drop a texture at once while the thread still draws the last frame with it.
//
// PC tests: vita/tests/glqueuetest.cpp and surfacecachetest.cpp (vita/tests/pcstub: a recording stand-in for vitaGL; std::thread
// for the kernel threads).

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#ifdef __vita__
#include <vitaGL.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/kernel/processmgr.h>
#else
#include <vitaGL.h>   // vita/tests/pcstub: a recording stand-in
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#endif

namespace VitaGL
{
	struct Texture
	{
		GLuint id = 0;
	};

	enum Op : uint8_t
	{
		OpViewport, OpEnable, OpDisable, OpBlendFunc, OpAlphaFunc, OpDepthMask, OpDepthFunc, OpEnableClient, OpDisableClient,
		OpColor4f, OpClearColor, OpClear, OpMatrixMode, OpLoadIdentity, OpLoadMatrixf, OpOrtho,
		OpGenTexture, OpDeleteTexture, OpBindTexture, OpTexParameteri, OpTexImage2D, OpCompressedTexImage2D, OpTexSubImage2D,
		OpGenerateMipmap, OpVertexPointer, OpTexCoordPointer, OpColorPointer, OpBindArrayBuffer, OpDeleteBuffer,
		OpDrawArrays, OpDrawElements16, OpSwap
	};

	struct Cmd
	{
		uint8_t op;
		uint32_t i[7];
		const void* p;
	};

	inline uint32_t FloatBits(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }
	inline float BitsFloat(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }

	// Memory for one frame's data: blocks that never move (a pointer handed out stays good until Reset)
	class Arena
	{
	public:
		~Arena()
		{
			for (Block& b : blocks)
				std::free(b.data);
		}

		void* Alloc(size_t bytes)
		{
			bytes = (bytes + 15) & ~(size_t)15;
			while (current < blocks.size())
			{
				Block& b = blocks[current];
				if (b.used + bytes <= b.size)
				{
					void* p = b.data + b.used;
					b.used += bytes;
					return p;
				}
				current++;
			}
			const size_t size = bytes > BlockSize ? bytes : BlockSize;
			Block b;
			b.data = (uint8_t*)std::malloc(size);
			if (!b.data)
				throw std::bad_alloc();
			b.size = size;
			b.used = bytes;
			blocks.push_back(b);
			current = blocks.size() - 1;
			return b.data;
		}

		// Everything is free again; blocks bigger than usual (a large texture) are given back
		void Reset()
		{
			size_t kept = 0;
			for (Block& b : blocks)
			{
				if (b.size > BlockSize)
				{
					std::free(b.data);
					continue;
				}
				b.used = 0;
				blocks[kept++] = b;
			}
			blocks.resize(kept);
			current = 0;
		}

	private:
		static constexpr size_t BlockSize = 256 * 1024;
		struct Block
		{
			uint8_t* data = nullptr;
			size_t size = 0;
			size_t used = 0;
		};
		std::vector<Block> blocks;
		size_t current = 0;
	};

	class Queue
	{
	public:
#ifndef __vita__
		// (the PC test: the thread ends with the queue; on the Vita the renderer's queue lives as long as the game)
		~Queue()
		{
			if (!threaded)
				return;
			WaitIdle();
			quit = true;
			Signal(work);
			worker.join();
		}
#endif
		bool Threaded() const { return threaded; }

		// Starts the thread; false (and the calls are made at once) when it cannot be made
		bool Start(int priority, int coreMask)
		{
			if (threaded)
				return true;
#ifdef __vita__
			work = sceKernelCreateSema("glwork", 0, 0, 1, nullptr);
			done = sceKernelCreateSema("gldone", 0, 0, 1, nullptr);
			if (work < 0 || done < 0)
				return false;
			SceUID thread = sceKernelCreateThread("glsubmit", ThreadEntry, priority, 1024 * 1024, 0, coreMask, nullptr);   // (vitaGL compiles shaders on first use: room for that)
			if (thread < 0)
				return false;
			Queue* self = this;
			if (sceKernelStartThread(thread, sizeof(self), &self) < 0)
				return false;
#else
			(void)priority;
			(void)coreMask;
			worker = std::thread([this]() { Loop(); });
#endif
			threaded = true;
			return true;
		}

		// the calls, as their gl* namesakes (target GL_TEXTURE_2D, vertex data GL_FLOAT)
		void Viewport(GLint x, GLint y, GLsizei w, GLsizei h) { if (!threaded) { glViewport(x, y, w, h); return; } Cmd& c = Add(OpViewport); c.i[0] = x; c.i[1] = y; c.i[2] = w; c.i[3] = h; }
		void Enable(GLenum cap) { if (!threaded) { glEnable(cap); return; } Add(OpEnable).i[0] = cap; }
		void Disable(GLenum cap) { if (!threaded) { glDisable(cap); return; } Add(OpDisable).i[0] = cap; }
		void BlendFunc(GLenum s, GLenum d) { if (!threaded) { glBlendFunc(s, d); return; } Cmd& c = Add(OpBlendFunc); c.i[0] = s; c.i[1] = d; }
		void AlphaFunc(GLenum f, GLfloat ref) { if (!threaded) { glAlphaFunc(f, ref); return; } Cmd& c = Add(OpAlphaFunc); c.i[0] = f; c.i[1] = FloatBits(ref); }
		void DepthMask(GLboolean on) { if (!threaded) { glDepthMask(on); return; } Add(OpDepthMask).i[0] = on; }
		void DepthFunc(GLenum f) { if (!threaded) { glDepthFunc(f); return; } Add(OpDepthFunc).i[0] = f; }
		void EnableClientState(GLenum a) { if (!threaded) { glEnableClientState(a); return; } Add(OpEnableClient).i[0] = a; }
		void DisableClientState(GLenum a) { if (!threaded) { glDisableClientState(a); return; } Add(OpDisableClient).i[0] = a; }
		void Color4f(float r, float g, float b, float a) { if (!threaded) { glColor4f(r, g, b, a); return; } Cmd& c = Add(OpColor4f); Floats4(c, r, g, b, a); }
		void ClearColor(float r, float g, float b, float a) { if (!threaded) { glClearColor(r, g, b, a); return; } Cmd& c = Add(OpClearColor); Floats4(c, r, g, b, a); }
		void Clear(GLbitfield mask) { if (!threaded) { glClear(mask); return; } Add(OpClear).i[0] = mask; }
		void MatrixMode(GLenum m) { if (!threaded) { glMatrixMode(m); return; } Add(OpMatrixMode).i[0] = m; }
		void LoadIdentity() { if (!threaded) { glLoadIdentity(); return; } Add(OpLoadIdentity); }
		void LoadMatrixf(const float* m) { if (!threaded) { glLoadMatrixf(m); return; } Add(OpLoadMatrixf).p = Keep(m, 16 * sizeof(float)); }
		void Ortho(float l, float r, float b, float t, float n, float f)
		{
			if (!threaded) { glOrtho(l, r, b, t, n, f); return; }
			Cmd& c = Add(OpOrtho);
			c.i[0] = FloatBits(l); c.i[1] = FloatBits(r); c.i[2] = FloatBits(b); c.i[3] = FloatBits(t); c.i[4] = FloatBits(n); c.i[5] = FloatBits(f);
		}

		Texture* GenTexture()
		{
			Texture* t = new Texture();
			if (!threaded)
				glGenTextures(1, &t->id);
			else
				Add(OpGenTexture).p = t;
			return t;
		}
		// deletes the GL texture and frees t
		void DeleteTexture(Texture* t)
		{
			if (!t)
				return;
			if (!threaded)
			{
				glDeleteTextures(1, &t->id);
				delete t;
				return;
			}
			Add(OpDeleteTexture).p = t;
		}
		void BindTexture(const Texture* t) { if (!threaded) { glBindTexture(GL_TEXTURE_2D, t->id); return; } Add(OpBindTexture).p = t; }
		void TexParameteri(GLenum name, GLint value) { if (!threaded) { glTexParameteri(GL_TEXTURE_2D, name, value); return; } Cmd& c = Add(OpTexParameteri); c.i[0] = name; c.i[1] = (uint32_t)value; }
		// the pixels are copied (with the thread): the caller may reuse its buffer at once
		void TexImage2D(GLint level, GLint internalFormat, GLsizei w, GLsizei h, GLenum format, GLenum type, const void* data, size_t bytes)
		{
			if (!threaded) { glTexImage2D(GL_TEXTURE_2D, level, internalFormat, w, h, 0, format, type, data); return; }
			Cmd& c = Add(OpTexImage2D);
			c.i[0] = level; c.i[1] = internalFormat; c.i[2] = w; c.i[3] = h; c.i[4] = format; c.i[5] = type;
			c.p = data ? Keep(data, bytes) : nullptr;
		}
		void CompressedTexImage2D(GLint level, GLenum internalFormat, GLsizei w, GLsizei h, GLsizei bytes, const void* data)
		{
			if (!threaded) { glCompressedTexImage2D(GL_TEXTURE_2D, level, internalFormat, w, h, 0, bytes, data); return; }
			Cmd& c = Add(OpCompressedTexImage2D);
			c.i[0] = level; c.i[1] = internalFormat; c.i[2] = w; c.i[3] = h; c.i[4] = bytes;
			c.p = Keep(data, bytes);
		}
		void TexSubImage2D(GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type, const void* data, size_t bytes)
		{
			if (!threaded) { glTexSubImage2D(GL_TEXTURE_2D, level, x, y, w, h, format, type, data); return; }
			Cmd& c = Add(OpTexSubImage2D);
			c.i[0] = level; c.i[1] = x; c.i[2] = y; c.i[3] = w; c.i[4] = h; c.i[5] = format; c.i[6] = type;
			c.p = Keep(data, bytes);
		}
		void GenerateMipmap() { if (!threaded) { glGenerateMipmap(GL_TEXTURE_2D); return; } Add(OpGenerateMipmap); }

		// Vertex arrays: the pointer is used as it is (an offset when a vertex buffer is bound): Keep() client data first
		void VertexPointer(GLint size, GLsizei stride, const void* p) { if (!threaded) { glVertexPointer(size, GL_FLOAT, stride, p); return; } Pointer(OpVertexPointer, size, stride, p); }
		void TexCoordPointer(GLint size, GLsizei stride, const void* p) { if (!threaded) { glTexCoordPointer(size, GL_FLOAT, stride, p); return; } Pointer(OpTexCoordPointer, size, stride, p); }
		void ColorPointer(GLint size, GLsizei stride, const void* p) { if (!threaded) { glColorPointer(size, GL_FLOAT, stride, p); return; } Pointer(OpColorPointer, size, stride, p); }
		void BindArrayBuffer(GLuint buffer) { if (!threaded) { glBindBuffer(GL_ARRAY_BUFFER, buffer); return; } Add(OpBindArrayBuffer).i[0] = buffer; }
		void DeleteBuffer(GLuint buffer) { if (!threaded) { glDeleteBuffers(1, &buffer); return; } Add(OpDeleteBuffer).i[0] = buffer; }
		void DrawArrays(GLenum mode, GLint first, GLsizei count) { if (!threaded) { glDrawArrays(mode, first, count); return; } Cmd& c = Add(OpDrawArrays); c.i[0] = mode; c.i[1] = first; c.i[2] = count; }
		// the indices are copied (with the thread)
		void DrawElements16(GLenum mode, GLsizei count, const uint16_t* indices)
		{
			if (!threaded) { glDrawElements(mode, count, GL_UNSIGNED_SHORT, indices); return; }
			Cmd& c = Add(OpDrawElements16);
			c.i[0] = mode; c.i[1] = count;
			c.p = Keep(indices, (size_t)count * sizeof(uint16_t));
		}
		// the picture is done: present it (without the thread the caller presents it itself)
		void Swap() { if (threaded) Add(OpSwap); }

		// A copy of data that a later command reads, alive until the thread is done with the frame (the data itself without the thread)
		const void* Keep(const void* data, size_t bytes)
		{
			if (!threaded)
				return data;
			void* copy = slots[recording].arena.Alloc(bytes);
			std::memcpy(copy, data, bytes);
			return copy;
		}
		// Memory of the frame, for data the caller writes itself (with the thread; null without it)
		void* Alloc(size_t bytes)
		{
			if (!threaded)
				return nullptr;
			return slots[recording].arena.Alloc(bytes);
		}

		// The end of a frame: wait for the thread to finish the frame before, then hand it this one
		void Submit()
		{
			if (!threaded)
				return;
			const double started = NowUs();
			WaitIdle();
			waitedUs += NowUs() - started;
			pending = &slots[recording];
			busy = true;
			Signal(work);
			recording ^= 1;
			slots[recording].cmds.clear();
			slots[recording].arena.Reset();
		}

		// Wait until the thread has made every call handed to it
		void WaitIdle()
		{
			if (!busy)
				return;
			Wait(done);
			busy = false;
		}

		// f() at once with the GL side idle (the calls recorded for this frame have not been made yet, so f must not depend on them)
		template<class F> void RunNow(F&& f)
		{
			WaitIdle();
			f();
		}

		// Statistics, microseconds summed since the last call of TakeStats: the thread making calls / presenting, the engine waiting for it
		struct Stats { double execUs = 0, swapUs = 0, waitedUs = 0; uint64_t commands = 0; int frames = 0; };
		Stats TakeStats()
		{
			Stats s;
			s.execUs = (double)execUs.exchange(0);
			s.swapUs = (double)swapUs.exchange(0);
			s.waitedUs = waitedUs;
			s.commands = commandCount.exchange(0);
			s.frames = framesDone.exchange(0);
			waitedUs = 0;
			return s;
		}

		static double NowUs()
		{
#ifdef __vita__
			return (double)sceKernelGetProcessTimeWide();
#else
			return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now().time_since_epoch()).count();
#endif
		}

		// Makes the calls of a list (the thread, or a test)
		static void Execute(const Cmd* cmds, size_t count, double* swapUs)
		{
			for (size_t k = 0; k < count; k++)
			{
				const Cmd& c = cmds[k];
				switch (c.op)
				{
				case OpViewport: glViewport((GLint)c.i[0], (GLint)c.i[1], (GLsizei)c.i[2], (GLsizei)c.i[3]); break;
				case OpEnable: glEnable(c.i[0]); break;
				case OpDisable: glDisable(c.i[0]); break;
				case OpBlendFunc: glBlendFunc(c.i[0], c.i[1]); break;
				case OpAlphaFunc: glAlphaFunc(c.i[0], BitsFloat(c.i[1])); break;
				case OpDepthMask: glDepthMask((GLboolean)c.i[0]); break;
				case OpDepthFunc: glDepthFunc(c.i[0]); break;
				case OpEnableClient: glEnableClientState(c.i[0]); break;
				case OpDisableClient: glDisableClientState(c.i[0]); break;
				case OpColor4f: glColor4f(BitsFloat(c.i[0]), BitsFloat(c.i[1]), BitsFloat(c.i[2]), BitsFloat(c.i[3])); break;
				case OpClearColor: glClearColor(BitsFloat(c.i[0]), BitsFloat(c.i[1]), BitsFloat(c.i[2]), BitsFloat(c.i[3])); break;
				case OpClear: glClear(c.i[0]); break;
				case OpMatrixMode: glMatrixMode(c.i[0]); break;
				case OpLoadIdentity: glLoadIdentity(); break;
				case OpLoadMatrixf: glLoadMatrixf((const float*)c.p); break;
				case OpOrtho: glOrtho(BitsFloat(c.i[0]), BitsFloat(c.i[1]), BitsFloat(c.i[2]), BitsFloat(c.i[3]), BitsFloat(c.i[4]), BitsFloat(c.i[5])); break;
				case OpGenTexture: glGenTextures(1, &((Texture*)c.p)->id); break;
				case OpDeleteTexture:
				{
					Texture* t = (Texture*)c.p;
					glDeleteTextures(1, &t->id);
					delete t;
					break;
				}
				case OpBindTexture: glBindTexture(GL_TEXTURE_2D, ((const Texture*)c.p)->id); break;
				case OpTexParameteri: glTexParameteri(GL_TEXTURE_2D, c.i[0], (GLint)c.i[1]); break;
				case OpTexImage2D: glTexImage2D(GL_TEXTURE_2D, (GLint)c.i[0], (GLint)c.i[1], (GLsizei)c.i[2], (GLsizei)c.i[3], 0, c.i[4], c.i[5], c.p); break;
				case OpCompressedTexImage2D: glCompressedTexImage2D(GL_TEXTURE_2D, (GLint)c.i[0], c.i[1], (GLsizei)c.i[2], (GLsizei)c.i[3], 0, (GLsizei)c.i[4], c.p); break;
				case OpTexSubImage2D: glTexSubImage2D(GL_TEXTURE_2D, (GLint)c.i[0], (GLint)c.i[1], (GLint)c.i[2], (GLsizei)c.i[3], (GLsizei)c.i[4], c.i[5], c.i[6], c.p); break;
				case OpGenerateMipmap: glGenerateMipmap(GL_TEXTURE_2D); break;
				case OpVertexPointer: glVertexPointer((GLint)c.i[0], GL_FLOAT, (GLsizei)c.i[1], c.p); break;
				case OpTexCoordPointer: glTexCoordPointer((GLint)c.i[0], GL_FLOAT, (GLsizei)c.i[1], c.p); break;
				case OpColorPointer: glColorPointer((GLint)c.i[0], GL_FLOAT, (GLsizei)c.i[1], c.p); break;
				case OpBindArrayBuffer: glBindBuffer(GL_ARRAY_BUFFER, c.i[0]); break;
				case OpDeleteBuffer: { GLuint b = c.i[0]; glDeleteBuffers(1, &b); break; }
				case OpDrawArrays: glDrawArrays(c.i[0], (GLint)c.i[1], (GLsizei)c.i[2]); break;
				case OpDrawElements16: glDrawElements(c.i[0], (GLsizei)c.i[1], GL_UNSIGNED_SHORT, c.p); break;
				case OpSwap:
				{
					const double started = NowUs();
					vglSwapBuffers(GL_TRUE);   // what SDL_GL_SwapWindow does (VITA_GLES_SwapWindow), without its check of the calling thread
					if (swapUs)
						*swapUs += NowUs() - started;
					break;
				}
				}
			}
		}

	private:
		struct Slot
		{
			std::vector<Cmd> cmds;
			Arena arena;
		};

		Cmd& Add(Op op)
		{
			std::vector<Cmd>& cmds = slots[recording].cmds;
			cmds.emplace_back();
			Cmd& c = cmds.back();
			c.op = op;
			return c;
		}
		static void Floats4(Cmd& c, float a, float b, float d, float e)
		{
			c.i[0] = FloatBits(a); c.i[1] = FloatBits(b); c.i[2] = FloatBits(d); c.i[3] = FloatBits(e);
		}
		void Pointer(Op op, GLint size, GLsizei stride, const void* p)
		{
			Cmd& c = Add(op);
			c.i[0] = (uint32_t)size;
			c.i[1] = (uint32_t)stride;
			c.p = p;
		}

		void Loop()
		{
			for (;;)
			{
				Wait(work);
#ifndef __vita__
				if (quit)
					return;
#endif
				Slot* slot = pending;
				const double started = NowUs();
				double swap = 0.0;
				Execute(slot->cmds.data(), slot->cmds.size(), &swap);
				execUs += (uint64_t)(NowUs() - started - swap);
				swapUs += (uint64_t)swap;
				commandCount += slot->cmds.size();
				framesDone++;
				Signal(done);
			}
		}

#ifdef __vita__
		typedef SceUID Sema;
		static void Wait(Sema s) { sceKernelWaitSema(s, 1, nullptr); }
		static void Signal(Sema s) { sceKernelSignalSema(s, 1); }
		static int ThreadEntry(SceSize, void* argument)
		{
			Queue* self = *(Queue**)argument;
			self->Loop();
			return 0;
		}
		Sema work = -1, done = -1;
#else
		struct Sema
		{
			std::mutex m;
			std::condition_variable cv;
			int count = 0;
		};
		static void Wait(Sema& s)
		{
			std::unique_lock<std::mutex> lock(s.m);
			s.cv.wait(lock, [&]() { return s.count > 0; });
			s.count--;
		}
		static void Signal(Sema& s)
		{
			{
				std::lock_guard<std::mutex> lock(s.m);
				s.count++;
			}
			s.cv.notify_one();
		}
		Sema work, done;
		std::thread worker;
		bool quit = false;
#endif

		bool threaded = false;
		bool busy = false;          // a frame was handed over and the thread may still be on it (the engine thread's view)
		Slot slots[2];
		int recording = 0;          // the slot this frame's commands go into
		Slot* pending = nullptr;    // the slot handed to the thread (set before the semaphore is signalled)

		// written by the thread, read for the log
		std::atomic<uint64_t> execUs{ 0 }, swapUs{ 0 }, commandCount{ 0 };
		std::atomic<int> framesDone{ 0 };
		double waitedUs = 0.0;      // the engine thread's own
	};
}
