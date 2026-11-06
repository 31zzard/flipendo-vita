#pragma once

// A stand-in for vitaGL on the PC (vita/tests/glqueuetest.cpp): every call is written into a log, with the data it reads (the
// vertex arrays at draw time, the pixels, the indices), so a test can compare the calls made at once with those made by the thread.

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef void GLvoid;

#define GL_TRUE 1
#define GL_FALSE 0
#define GL_TEXTURE_2D 0x0DE1
#define GL_FLOAT 0x1406
#define GL_UNSIGNED_SHORT 0x1403
#define GL_ARRAY_BUFFER 0x8892
#define GL_TRIANGLES 0x0004

namespace StubGL
{
	inline std::vector<std::string>& Log() { static std::vector<std::string> log; return log; }
	inline GLuint& NextName() { static GLuint n = 1; return n; }
	inline void Add(const std::string& s) { Log().push_back(s); }
	inline std::string Hex(const void* data, size_t bytes)
	{
		static const char* digits = "0123456789abcdef";
		std::string s;
		const uint8_t* p = (const uint8_t*)data;
		for (size_t i = 0; i < bytes; i++)
		{
			s += digits[p[i] >> 4];
			s += digits[p[i] & 15];
		}
		return s;
	}
	// the client arrays as they were given (read when a draw happens, as the GPU driver would)
	struct Arrays { const void* vertex = nullptr; GLint vsize = 0; GLsizei vstride = 0; const void* tex = nullptr; GLsizei tstride = 0; GLuint buffer = 0, vbuffer = 0; };
	inline Arrays& State() { static Arrays a; return a; }
}

inline void glViewport(GLint x, GLint y, GLsizei w, GLsizei h) { StubGL::Add("Viewport " + std::to_string(x) + " " + std::to_string(y) + " " + std::to_string(w) + " " + std::to_string(h)); }
inline void glEnable(GLenum c) { StubGL::Add("Enable " + std::to_string(c)); }
inline void glDisable(GLenum c) { StubGL::Add("Disable " + std::to_string(c)); }
inline void glBlendFunc(GLenum a, GLenum b) { StubGL::Add("BlendFunc " + std::to_string(a) + " " + std::to_string(b)); }
inline void glAlphaFunc(GLenum a, GLfloat r) { StubGL::Add("AlphaFunc " + std::to_string(a) + " " + std::to_string(r)); }
inline void glDepthMask(GLboolean b) { StubGL::Add("DepthMask " + std::to_string(b)); }
inline void glDepthFunc(GLenum f) { StubGL::Add("DepthFunc " + std::to_string(f)); }
inline void glEnableClientState(GLenum a) { StubGL::Add("EnableClient " + std::to_string(a)); }
inline void glDisableClientState(GLenum a) { StubGL::Add("DisableClient " + std::to_string(a)); }
inline void glColor4f(float r, float g, float b, float a) { StubGL::Add("Color4f " + std::to_string(r) + " " + std::to_string(g) + " " + std::to_string(b) + " " + std::to_string(a)); }
inline void glClearColor(float r, float g, float b, float a) { StubGL::Add("ClearColor " + std::to_string(r) + " " + std::to_string(g) + " " + std::to_string(b) + " " + std::to_string(a)); }
inline void glClear(GLbitfield m) { StubGL::Add("Clear " + std::to_string(m)); }
inline void glMatrixMode(GLenum m) { StubGL::Add("MatrixMode " + std::to_string(m)); }
inline void glLoadIdentity() { StubGL::Add("LoadIdentity"); }
inline void glLoadMatrixf(const float* m) { StubGL::Add("LoadMatrixf " + StubGL::Hex(m, 64)); }
inline void glOrtho(double l, double r, double b, double t, double n, double f) { StubGL::Add("Ortho " + std::to_string(l) + " " + std::to_string(r) + " " + std::to_string(b) + " " + std::to_string(t) + " " + std::to_string(n) + " " + std::to_string(f)); }
inline void glGenTextures(GLsizei, GLuint* t) { *t = StubGL::NextName()++; StubGL::Add("GenTextures"); }
inline void glDeleteTextures(GLsizei, const GLuint* t) { StubGL::Add("DeleteTextures " + std::to_string(*t)); }
inline void glBindTexture(GLenum, GLuint t) { StubGL::Add("BindTexture " + std::to_string(t)); }
inline void glTexParameteri(GLenum, GLenum n, GLint v) { StubGL::Add("TexParameteri " + std::to_string(n) + " " + std::to_string(v)); }
inline void glTexImage2D(GLenum, GLint level, GLint fmt, GLsizei w, GLsizei h, GLint, GLenum f, GLenum t, const void* data)
{
	StubGL::Add("TexImage2D " + std::to_string(level) + " " + std::to_string(fmt) + " " + std::to_string(w) + "x" + std::to_string(h) + " " +
		std::to_string(f) + " " + std::to_string(t) + " " + (data ? StubGL::Hex(data, (size_t)w * h * 2) : "null"));
}
inline void glCompressedTexImage2D(GLenum, GLint level, GLenum fmt, GLsizei w, GLsizei h, GLint, GLsizei bytes, const void* data)
{
	StubGL::Add("CompressedTexImage2D " + std::to_string(level) + " " + std::to_string(fmt) + " " + std::to_string(w) + "x" + std::to_string(h) + " " + StubGL::Hex(data, bytes));
}
inline void glTexSubImage2D(GLenum, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLenum t, const void* data)
{
	StubGL::Add("TexSubImage2D " + std::to_string(level) + " " + std::to_string(x) + "," + std::to_string(y) + " " + std::to_string(w) + "x" + std::to_string(h) + " " +
		std::to_string(f) + " " + std::to_string(t) + " " + StubGL::Hex(data, (size_t)w * h * 2));
}
inline void glGenerateMipmap(GLenum) { StubGL::Add("GenerateMipmap"); }
inline void glVertexPointer(GLint size, GLenum, GLsizei stride, const void* p)
{
	StubGL::State().vertex = p; StubGL::State().vsize = size; StubGL::State().vstride = stride; StubGL::State().vbuffer = StubGL::State().buffer;
	StubGL::Add("VertexPointer " + std::to_string(size) + " " + std::to_string(stride) + (StubGL::State().buffer ? " offset " + std::to_string((uintptr_t)p) : ""));
}
inline void glTexCoordPointer(GLint size, GLenum, GLsizei stride, const void* p)
{
	StubGL::State().tex = p; StubGL::State().tstride = stride;
	StubGL::Add("TexCoordPointer " + std::to_string(size) + " " + std::to_string(stride) + (StubGL::State().buffer ? " offset " + std::to_string((uintptr_t)p) : ""));
}
inline void glColorPointer(GLint size, GLenum, GLsizei stride, const void*) { StubGL::Add("ColorPointer " + std::to_string(size) + " " + std::to_string(stride)); }
inline void glBindBuffer(GLenum, GLuint b) { StubGL::State().buffer = b; StubGL::Add("BindBuffer " + std::to_string(b)); }
inline void glDeleteBuffers(GLsizei, const GLuint* b) { StubGL::Add("DeleteBuffers " + std::to_string(*b)); }
inline void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
	// the vertices the draw reads: what the arrays hold now (a client array must still be intact)
	std::string data;
	const StubGL::Arrays& a = StubGL::State();
	if (!a.vbuffer && a.vertex)
		data = StubGL::Hex(a.vertex, (size_t)(first + count) * (a.vstride ? a.vstride : a.vsize * 4));
	StubGL::Add("DrawArrays " + std::to_string(mode) + " " + std::to_string(first) + " " + std::to_string(count) + " " + data);
}
inline void glDrawElements(GLenum mode, GLsizei count, GLenum, const void* indices)
{
	StubGL::Add("DrawElements " + std::to_string(mode) + " " + std::to_string(count) + " " + StubGL::Hex(indices, (size_t)count * 2));
}
inline void vglSwapBuffers(GLboolean) { StubGL::Add("Swap"); }
