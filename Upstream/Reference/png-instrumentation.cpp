// SPDX-License-Identifier: GPL-2.0-only
// Byte-verified original TORCS function; libpng version is pinned with the archive.
#include "CReference.h"
#include <png.h>
#include <tgf.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#define PNG_BYTES_TO_CHECK 4
#include "textures/png-read.inc"
static std::vector<unsigned char> pngCapture;
const unsigned char *ref_png_load(const char *path,float gamma,int *width,int *height,int *count){
 pngCapture.clear();*count=0;
 auto *pixels=GfImgReadPng(path,width,height,gamma);if(!pixels)return nullptr;
 *count=*width**height*4;pngCapture.assign(pixels,pixels+*count);free(pixels);return pngCapture.data();
}
const char *ref_png_version(void){return PNG_LIBPNG_VER_STRING;}
