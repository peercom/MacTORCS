// SPDX-License-Identifier: GPL-2.0-only
// Reference-only GL upload capture declarations; no OpenGL linkage.
#pragma once
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ul.h>
#define glPixelStorei refTexturePixelStorei
#define glHint refTextureHint
#define glTexImage2D refTextureImage2D
#define glGetTexLevelParameteriv refTextureLevelParameter
#define SSG_LOAD_SGI_SUPPORTED
using GLubyte=unsigned char; using GLint=int; using GLvoid=void;
struct ssgTextureInfo { int width=0,height=0,depth=0;bool alpha=false; };
enum { GL_UNPACK_ALIGNMENT=1,GL_TEXTURE_COMPRESSION_HINT_ARB,GL_NICEST,
 GL_COMPRESSED_LUMINANCE_ARB,GL_COMPRESSED_LUMINANCE_ALPHA_ARB,GL_COMPRESSED_RGB_ARB,GL_COMPRESSED_RGBA_ARB,
 GL_PROXY_TEXTURE_2D,GL_LUMINANCE,GL_LUMINANCE_ALPHA,GL_RGB,GL_RGBA,GL_UNSIGNED_BYTE,GL_TEXTURE_WIDTH,GL_TEXTURE_2D };
void glPixelStorei(int,int);void glHint(int,int);
void glTexImage2D(int,int,int,int,int,int,int,int,const void*);
void glGetTexLevelParameteriv(int,int,int,int*);
bool isCompressARBEnabled();int getUserTextureMaxSize();
void ssgAddTextureFormat(const char*,bool(*)(const char*,ssgTextureInfo*));
bool ssgMakeMipMaps(GLubyte*,int,int,int);
