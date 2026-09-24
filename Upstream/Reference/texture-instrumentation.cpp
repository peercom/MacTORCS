// SPDX-License-Identifier: GPL-2.0-only
// Original CPU decoder/mipmap execution. Capture glTexImage2D bytes before upload.
#include "CReference.h"
#include "textures/ssgLoadSGI.cxx"
#include "textures/grtexture.cpp"
#include <vector>
#include <cstdint>
static std::vector<unsigned char> textureCapture;
static int textureLimit=4096,proxyWidth=0,textureLevels=0;
static void textureInt(int n){for(int i=0;i<4;++i)textureCapture.push_back((n>>(i*8))&255);}
void glPixelStorei(int,int){} void glHint(int,int){}
bool isCompressARBEnabled(){return false;} int getUserTextureMaxSize(){return textureLimit;}
void ssgAddTextureFormat(const char*,bool(*)(const char*,ssgTextureInfo*)){}
void glGetTexLevelParameteriv(int,int,int,int *v){*v=proxyWidth;}
void glTexImage2D(int target,int level,int,int width,int height,int,int format,int,const void *bytes){
 if(target==GL_PROXY_TEXTURE_2D){proxyWidth=width;return;}
 int channels=format==GL_LUMINANCE?1:format==GL_LUMINANCE_ALPHA?2:format==GL_RGB?3:4;
 if(level!=textureLevels++)abort();
 textureInt(width);textureInt(height);textureInt(channels);textureInt(width*height*channels);
 auto *p=static_cast<const unsigned char*>(bytes);textureCapture.insert(textureCapture.end(),p,p+width*height*channels);
}
bool ssgMakeMipMaps(GLubyte *p,int w,int h,int c){return grMakeMipMaps(p,w,h,c,true);}
const unsigned char *ref_texture_sgi(const char *path,int maximum,int *count,int *levels){
 if(!path||strlen(path)>=512||maximum<1)return nullptr;
 textureCapture.clear();textureLevels=0;textureLimit=maximum;
 ssgTextureInfo info;if(!grLoadSGI(path,&info))return nullptr;
 *count=textureCapture.size();*levels=textureLevels;return textureCapture.data();
}
const unsigned char *ref_texture_mips(const unsigned char *pixels,int width,int height,int channels,int maximum,int mipmaps,int *count,int *levels){
 textureCapture.clear();textureLevels=0;textureLimit=maximum;
 auto *copy=new unsigned char[width*height*channels];memcpy(copy,pixels,width*height*channels);
 if(!grMakeMipMaps(copy,width,height,channels,mipmaps!=0))return nullptr;
 *count=textureCapture.size();*levels=textureLevels;return textureCapture.data();
}
int ref_texture_mipmap_rule(const char *path,int requested){return doMipMap(path,requested);}
