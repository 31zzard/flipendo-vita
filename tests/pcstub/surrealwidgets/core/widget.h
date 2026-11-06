#pragma once
// PC stand-in (vita/tests): the few calls the Vita renderer makes on its viewport
#include <vitaGL.h>
class Widget
{
public:
	void CreateGLContext() {}
	void MakeGLContextCurrent() {}
	bool SetGLSwapInterval(int) { return true; }
	void SwapGLBuffers() { vglSwapBuffers(GL_TRUE); }
	int GetNativePixelWidth() { return 960; }
	int GetNativePixelHeight() { return 544; }
};
