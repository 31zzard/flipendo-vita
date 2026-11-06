#pragma once

// A stand-in for vitaGL on the PC (vita/tests/glqueuetest.cpp, surfacecachetest.cpp). Every call is written into a log (with the data it
// reads), and the triangles drawn can be collected with the state they were drawn with (texture, blend, depth, colour) and the
// positions and texture coordinates they were drawn from, read through the vertex arrays or vertex buffers as a GPU would.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef unsigned char GLubyte;
typedef void GLvoid;

#define GL_TRUE 1
#define GL_FALSE 0
#define GL_ZERO 0
#define GL_ONE 1
#define GL_TRIANGLES 0x0004
#define GL_TRIANGLE_FAN 0x0006
#define GL_EQUAL 0x0202
#define GL_LEQUAL 0x0203
#define GL_GREATER 0x0204
#define GL_SRC_COLOR 0x0300
#define GL_ONE_MINUS_SRC_COLOR 0x0301
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_DST_COLOR 0x0306
#define GL_CULL_FACE 0x0B44
#define GL_DEPTH_TEST 0x0B71
#define GL_ALPHA_TEST 0x0BC0
#define GL_BLEND 0x0BE2
#define GL_TEXTURE_2D 0x0DE1
#define GL_UNSIGNED_BYTE 0x1401
#define GL_UNSIGNED_SHORT 0x1403
#define GL_FLOAT 0x1406
#define GL_MODELVIEW 0x1700
#define GL_PROJECTION 0x1701
#define GL_RGB 0x1907
#define GL_RGBA 0x1908
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_NEAREST_MIPMAP_NEAREST 0x2700
#define GL_LINEAR_MIPMAP_LINEAR 0x2703
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_REPEAT 0x2901
#define GL_UNSIGNED_SHORT_5_5_5_1 0x8034
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_UNSIGNED_SHORT_5_6_5 0x8363
#define GL_VERTEX_ARRAY 0x8074
#define GL_COLOR_ARRAY 0x8076
#define GL_TEXTURE_COORD_ARRAY 0x8078
#define GL_ARRAY_BUFFER 0x8892
#define GL_WRITE_ONLY 0x88B9
#define GL_STATIC_DRAW 0x88E4
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_DEPTH_BUFFER_BIT 0x0100

struct SceGxmTexture;

// (the text of a log line is only made when the log is on)
#define STUB_ADD(text) do { if (StubGL::Logging()) StubGL::Add(text); } while (0)

namespace StubGL
{
	inline std::vector<std::string>& Log() { static std::vector<std::string> log; return log; }
	inline bool& Logging() { static bool on = true; return on; }
	inline GLuint& NextName() { static GLuint n = 1; return n; }
	inline void Add(const std::string& s) { if (Logging()) Log().push_back(s); }
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

	struct Arrays
	{
		const void* vertex = nullptr; GLint vsize = 0; GLsizei vstride = 0; GLuint vbuffer = 0;
		const void* tex = nullptr; GLsizei tstride = 0; GLuint tbuffer = 0;
		GLuint buffer = 0;   // bound to GL_ARRAY_BUFFER
	};
	inline Arrays& State() { static Arrays a; return a; }
	inline std::map<GLuint, std::vector<uint8_t>>& Buffers() { static std::map<GLuint, std::vector<uint8_t>> b; return b; }

	// the state a triangle is drawn with
	struct DrawState
	{
		GLuint texture = 0;
		bool blend = false, alphaTest = false, depthMask = true, depthEqual = false, colorArray = false;
		GLenum blendSrc = 1, blendDst = 0;
		float color[4] = { 1, 1, 1, 1 };
	};
	inline DrawState& Current() { static DrawState s; return s; }
	struct Triangle
	{
		std::string state;
		float v[3][5];   // x y z u v
	};
	inline bool& Capture() { static bool on = false; return on; }
	// a texture's name for the comparison: what was first uploaded to it (the GL names depend on the order things are made in)
	inline std::map<GLuint, std::string>& Labels() { static std::map<GLuint, std::string> l; return l; }
	inline int& AtlasCount() { static int n = 0; return n; }
	inline void Label(GLuint texture, GLsizei w, GLsizei h, const void* data, size_t bytes)
	{
		if (Labels().count(texture))
			return;
		bool blank = true;
		uint64_t hash = 1469598103934665603ull;
		const uint8_t* p = (const uint8_t*)data;
		for (size_t i = 0; p && i < bytes; i++)
		{
			blank &= p[i] == 0;
			hash = (hash ^ p[i]) * 1099511628211ull;
		}
		char text[64];
		if (blank && w == 512 && h == 512)
			snprintf(text, sizeof(text), "atlas%d", AtlasCount()++);
		else
			snprintf(text, sizeof(text), "%dx%d:%016llx", w, h, (unsigned long long)hash);
		Labels()[texture] = text;
	}
	inline std::vector<Triangle>& Triangles() { static std::vector<Triangle> t; return t; }
	inline int& Draws() { static int n = 0; return n; }

	inline std::string StateKey()
	{
		const DrawState& s = Current();
		char text[200];
		auto label = Labels().find(s.texture);
		snprintf(text, sizeof(text), "tex %s blend %d %u %u alpha %d depth %d %d colour %g %g %g %g ca %d", label == Labels().end() ? "?" : label->second.c_str(), s.blend, s.blendSrc, s.blendDst, s.alphaTest,
			s.depthMask, s.depthEqual, s.color[0], s.color[1], s.color[2], s.color[3], s.colorArray);
		return text;
	}
	inline const uint8_t* Resolve(const void* p, GLuint buffer)
	{
		if (!buffer)
			return (const uint8_t*)p;
		return Buffers()[buffer].data() + (uintptr_t)p;
	}
	inline void Vertex(uint32_t index, float* out)
	{
		const Arrays& a = State();
		const uint8_t* vb = Resolve(a.vertex, a.vbuffer);
		const uint8_t* tb = Resolve(a.tex, a.tbuffer);
		const size_t vs = a.vstride ? a.vstride : a.vsize * 4;
		const size_t ts = a.tstride ? a.tstride : 8;
		float pos[3] = { 0, 0, 0 };
		std::memcpy(pos, vb + index * vs, (size_t)a.vsize * 4);
		out[0] = pos[0]; out[1] = pos[1]; out[2] = pos[2];
		std::memcpy(out + 3, tb + index * ts, 8);
	}
	inline void AddTriangle(uint32_t a, uint32_t b, uint32_t c)
	{
		Triangle t;
		t.state = StateKey();
		Vertex(a, t.v[0]);
		Vertex(b, t.v[1]);
		Vertex(c, t.v[2]);
		Triangles().push_back(t);
	}
}

inline const GLubyte* glGetString(GLenum) { return (const GLubyte*)"stub"; }
inline void glViewport(GLint x, GLint y, GLsizei w, GLsizei h) { STUB_ADD("Viewport " + std::to_string(x) + " " + std::to_string(y) + " " + std::to_string(w) + " " + std::to_string(h)); }
inline void glEnable(GLenum c)
{
	if (c == GL_BLEND) StubGL::Current().blend = true;
	if (c == GL_ALPHA_TEST) StubGL::Current().alphaTest = true;
	STUB_ADD("Enable " + std::to_string(c));
}
inline void glDisable(GLenum c)
{
	if (c == GL_BLEND) StubGL::Current().blend = false;
	if (c == GL_ALPHA_TEST) StubGL::Current().alphaTest = false;
	STUB_ADD("Disable " + std::to_string(c));
}
inline void glBlendFunc(GLenum a, GLenum b) { StubGL::Current().blendSrc = a; StubGL::Current().blendDst = b; STUB_ADD("BlendFunc " + std::to_string(a) + " " + std::to_string(b)); }
inline void glAlphaFunc(GLenum a, GLfloat r) { STUB_ADD("AlphaFunc " + std::to_string(a) + " " + std::to_string(r)); }
inline void glDepthMask(GLboolean b) { StubGL::Current().depthMask = b != 0; STUB_ADD("DepthMask " + std::to_string(b)); }
inline void glDepthFunc(GLenum f) { StubGL::Current().depthEqual = f == GL_EQUAL; STUB_ADD("DepthFunc " + std::to_string(f)); }
inline void glEnableClientState(GLenum a) { if (a == GL_COLOR_ARRAY) StubGL::Current().colorArray = true; STUB_ADD("EnableClient " + std::to_string(a)); }
inline void glDisableClientState(GLenum a) { if (a == GL_COLOR_ARRAY) StubGL::Current().colorArray = false; STUB_ADD("DisableClient " + std::to_string(a)); }
inline void glColor4f(float r, float g, float b, float a)
{
	float* c = StubGL::Current().color;
	c[0] = r; c[1] = g; c[2] = b; c[3] = a;
	STUB_ADD("Color4f " + std::to_string(r) + " " + std::to_string(g) + " " + std::to_string(b) + " " + std::to_string(a));
}
inline void glClearColor(float r, float g, float b, float a) { STUB_ADD("ClearColor " + std::to_string(r) + " " + std::to_string(g) + " " + std::to_string(b) + " " + std::to_string(a)); }
inline void glClear(GLbitfield m) { STUB_ADD("Clear " + std::to_string(m)); }
inline void glMatrixMode(GLenum m) { STUB_ADD("MatrixMode " + std::to_string(m)); }
inline void glLoadIdentity() { STUB_ADD("LoadIdentity"); }
inline void glLoadMatrixf(const float* m) { STUB_ADD("LoadMatrixf " + StubGL::Hex(m, 64)); }
inline void glOrtho(double l, double r, double b, double t, double n, double f) { STUB_ADD("Ortho " + std::to_string(l) + " " + std::to_string(r) + " " + std::to_string(b) + " " + std::to_string(t) + " " + std::to_string(n) + " " + std::to_string(f)); }
inline void glGenTextures(GLsizei, GLuint* t) { *t = StubGL::NextName()++; STUB_ADD("GenTextures"); }
inline void glDeleteTextures(GLsizei, const GLuint* t) { StubGL::Labels().erase(*t); STUB_ADD("DeleteTextures " + std::to_string(*t)); }
inline void glBindTexture(GLenum, GLuint t) { StubGL::Current().texture = t; STUB_ADD("BindTexture " + std::to_string(t)); }
inline void glTexParameteri(GLenum, GLenum n, GLint v) { STUB_ADD("TexParameteri " + std::to_string(n) + " " + std::to_string(v)); }
inline void glTexImage2D(GLenum, GLint level, GLint fmt, GLsizei w, GLsizei h, GLint, GLenum f, GLenum t, const void* data)
{
	if (level == 0)
		StubGL::Label(StubGL::Current().texture, w, h, data, (size_t)w * h * (t == GL_UNSIGNED_BYTE ? 4 : 2));
	STUB_ADD("TexImage2D " + std::to_string(level) + " " + std::to_string(fmt) + " " + std::to_string(w) + "x" + std::to_string(h) + " " +
		std::to_string(f) + " " + std::to_string(t) + " " + (data ? StubGL::Hex(data, (size_t)w * h * 2) : "null"));
}
inline void glCompressedTexImage2D(GLenum, GLint level, GLenum fmt, GLsizei w, GLsizei h, GLint, GLsizei bytes, const void* data)
{
	if (level == 0)
		StubGL::Label(StubGL::Current().texture, w, h, data, (size_t)bytes);
	STUB_ADD("CompressedTexImage2D " + std::to_string(level) + " " + std::to_string(fmt) + " " + std::to_string(w) + "x" + std::to_string(h) + " " + StubGL::Hex(data, bytes));
}
inline void glTexSubImage2D(GLenum, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLenum t, const void* data)
{
	STUB_ADD("TexSubImage2D " + std::to_string(level) + " " + std::to_string(x) + "," + std::to_string(y) + " " + std::to_string(w) + "x" + std::to_string(h) + " " +
		std::to_string(f) + " " + std::to_string(t) + " " + StubGL::Hex(data, (size_t)w * h * 2));
}
inline void glGenerateMipmap(GLenum) { STUB_ADD("GenerateMipmap"); }
inline void glVertexPointer(GLint size, GLenum, GLsizei stride, const void* p)
{
	StubGL::Arrays& a = StubGL::State();
	a.vertex = p; a.vsize = size; a.vstride = stride; a.vbuffer = a.buffer;
	STUB_ADD("VertexPointer " + std::to_string(size) + " " + std::to_string(stride) + (a.buffer ? " offset " + std::to_string((uintptr_t)p) : ""));
}
inline void glTexCoordPointer(GLint size, GLenum, GLsizei stride, const void* p)
{
	StubGL::Arrays& a = StubGL::State();
	a.tex = p; a.tstride = stride; a.tbuffer = a.buffer;
	STUB_ADD("TexCoordPointer " + std::to_string(size) + " " + std::to_string(stride) + (a.buffer ? " offset " + std::to_string((uintptr_t)p) : ""));
}
inline void glColorPointer(GLint size, GLenum, GLsizei stride, const void*) { STUB_ADD("ColorPointer " + std::to_string(size) + " " + std::to_string(stride)); }
inline void glGenBuffers(GLsizei, GLuint* b) { static GLuint next = 1000; *b = next++; STUB_ADD("GenBuffers"); }
inline void glBindBuffer(GLenum, GLuint b) { StubGL::State().buffer = b; STUB_ADD("BindBuffer " + std::to_string(b)); }
inline void glBufferData(GLenum, GLsizei size, const void* data, GLenum)
{
	std::vector<uint8_t>& b = StubGL::Buffers()[StubGL::State().buffer];
	b.assign((size_t)size, 0xcd);
	if (data)
		std::memcpy(b.data(), data, (size_t)size);
	STUB_ADD("BufferData " + std::to_string(size));
}
inline void* glMapBuffer(GLenum, GLbitfield) { return StubGL::Buffers()[StubGL::State().buffer].data(); }
inline GLboolean glUnmapBuffer(GLenum) { return GL_TRUE; }
inline void glDeleteBuffers(GLsizei, const GLuint* b) { StubGL::Buffers().erase(*b); STUB_ADD("DeleteBuffers " + std::to_string(*b)); }
inline void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
	StubGL::Draws()++;
	const StubGL::Arrays& a = StubGL::State();
	std::string data;
	if (StubGL::Logging() && !a.vbuffer && a.vertex)
		data = StubGL::Hex(a.vertex, (size_t)(first + count) * (a.vstride ? a.vstride : a.vsize * 4));
	STUB_ADD("DrawArrays " + std::to_string(mode) + " " + std::to_string(first) + " " + std::to_string(count) + " " + data);
	if (StubGL::Capture())
	{
		if (mode == GL_TRIANGLES)
			for (GLint i = first; i + 2 < first + count; i += 3)
				StubGL::AddTriangle(i, i + 1, i + 2);
		else if (mode == GL_TRIANGLE_FAN)
			for (GLint i = first + 2; i < first + count; i++)
				StubGL::AddTriangle(first, i - 1, i);
	}
}
inline void glDrawElements(GLenum mode, GLsizei count, GLenum, const void* indices)
{
	StubGL::Draws()++;
	STUB_ADD("DrawElements " + std::to_string(mode) + " " + std::to_string(count) + " " + StubGL::Hex(indices, (size_t)count * 2));
	if (StubGL::Capture() && mode == GL_TRIANGLES)
	{
		const uint16_t* idx = (const uint16_t*)indices;
		for (GLsizei i = 0; i + 2 < count; i += 3)
			StubGL::AddTriangle(idx[i], idx[i + 1], idx[i + 2]);
	}
}
inline void vglSwapBuffers(GLboolean) { STUB_ADD("Swap"); }
inline SceGxmTexture* vglGetGxmTexture(GLenum) { return nullptr; }
inline void* vglGetTexDataPointer(GLenum) { return nullptr; }
