// SPDX-License-Identifier: GPL-2.0-only
// Minimal declarations needed by unchanged grtexture.cpp; ssgSGIHeader's actual
// declaration/implementation is supplied by unchanged ssgLoadSGI.cxx first.
#pragma once
bool doMipMap(const char*,int);
bool grMakeMipMaps(GLubyte*,int,int,int,bool);
class grSGIHeader: public ssgSGIHeader { public: grSGIHeader(const char*,ssgTextureInfo*); };
