#pragma once
// PC stand-in (vita/tests): only what VitaRenderDevice.cpp names
struct SceGxmTexture;
enum { SCE_GXM_TEXTURE_FORMAT_U8U8U8U8_ABGR = 1, SCE_GXM_TEXTURE_LINEAR = 1 };
inline int sceGxmTextureGetFormat(const SceGxmTexture*) { return 0; }
inline int sceGxmTextureGetType(const SceGxmTexture*) { return 0; }
inline int sceGxmTextureGetWidth(const SceGxmTexture*) { return 0; }
