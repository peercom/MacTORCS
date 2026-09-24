// SPDX-License-Identifier: GPL-2.0-only
// Reference-only headless boundary. No graphics implementation is linked.
#pragma once
#include <tgf.h>
#include <cmath>
#include <cstring>
using GLvoid = void;
enum { GL_PACK_ROW_LENGTH, GL_PACK_ALIGNMENT, GL_FRONT, GL_RGB, GL_UNSIGNED_BYTE };
void GfuiScreenActivate(void*);
void GfuiDisplay();
void GfScrGetSize(int*,int*,int*,int*);
void GfImgWritePng(unsigned char*,const char*,int,int);
void GfTime2Str(char*,int,double,int);
void glPixelStorei(int,int);
void glReadBuffer(int);
void glReadPixels(int,int,int,int,int,int,void*);
void glutPostRedisplay();
