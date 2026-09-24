// SPDX-License-Identifier: GPL-2.0-only
// Test-only storage/GL capture around unchanged PLIB state functions. Material,
// texture and callback operations are stubs; original alpha state logic executes.
#include "CReference.h"
#include "private/plib/sg.h"
#include <array>
#include <utility>
#include <algorithm>
#include <cstdlib>
namespace AlphaReference {
#include "graphics/state/constants.inc"
using GLenum=int;
enum {GL_TEXTURE_2D,GL_CULL_FACE,GL_COLOR_MATERIAL,GL_LIGHTING,GL_BLEND,GL_ALPHA_TEST,GL_SMOOTH,GL_AMBIENT_AND_DIFFUSE,GL_FRONT_AND_BACK,GL_SHININESS,GL_SPECULAR,GL_EMISSION,GL_AMBIENT,GL_DIFFUSE,GL_GREATER,UL_WARNING};
static bool hardwareEnabled=false;static float hardwareClamp=0;static int stats_bind_textures=0;
struct ssgTexture {};
static int ssgTypeSimpleState(){return 0;}
static void glAlphaFunc(int,float value){hardwareClamp=std::clamp(value,0.0f,1.0f);}
static void glColorMaterial(int,int){}static void glMaterialf(int,int,float){}
static void glMaterialfv(int,int,const float*){}static void glBindTextureEXT(int,int){}
static void glShadeModel(int){}static void ulSetError(int,const char*,int){std::abort();}
template<size_t I> static void enableMask(){if(I&(1<<SSG_GL_ALPHA_TEST_EN))hardwareEnabled=true;}
template<size_t I> static void disableMask(){if(I&(1<<SSG_GL_ALPHA_TEST_EN))hardwareEnabled=false;}
template<size_t... I> static auto enableTable(std::index_sequence<I...>){return std::array<void(*)(),sizeof...(I)>{enableMask<I>...};}
template<size_t... I> static auto disableTable(std::index_sequence<I...>){return std::array<void(*)(),sizeof...(I)>{disableMask<I>...};}
static auto __ssgEnableTable=enableTable(std::make_index_sequence<64>{});
static auto __ssgDisableTable=disableTable(std::make_index_sequence<64>{});
struct ssgSimpleState {
 int type=0,enables=0,dont_care=0,colour_material_mode=0,shade_model=0;
 float shininess=0,alpha_clamp=0;sgVec4 specular_colour{},emission_colour{},ambient_colour{},diffuse_colour{};
 ssgTexture *texture=nullptr;
 ssgSimpleState();ssgSimpleState(int);
 void care_about(int mode){dont_care &= ~(1<<mode);}void preApply(){}void preDraw(){}
 void setColourMaterial(int mode){colour_material_mode=mode;care_about(SSG_GL_COLOR_MATERIAL);}
 void setShadeModel(int mode){shade_model=mode;care_about(SSG_GL_SHADE_MODEL);}
 void enable(GLenum);void disable(GLenum);void apply();void force();
 ssgTexture *getTexture(){return texture;}int getTextureHandle(){return 0;}
 void setTexture(ssgTexture *p){texture=p;}
#include "graphics/state/alpha-setter.inc"
};
struct Context {ssgSimpleState current;ssgSimpleState *getState(){return &current;}};
static Context context,*_ssgCurrentContext=&context;
#include "graphics/state/constructors.inc"
#include "graphics/state/disable.inc"
#include "graphics/state/enable.inc"
#include "graphics/state/apply.inc"
#include "graphics/state/force.inc"
static void reset(){
 ssgSimpleState basic(0),*basicState=&basic;
#include "graphics/state/basic.inc"
 basic.force();
}
}
int ref_alpha_state(const int *care,const int *enabled,const float *clamps,int count,float *output){
 using namespace AlphaReference;if(count<0||count>100000)return 0;
 context.current=ssgSimpleState();hardwareEnabled=false;hardwareClamp=0;reset();
 output[0]=hardwareEnabled;output[1]=hardwareClamp;
 for(int i=0;i<count;i++){
  if(care[i]==-1)reset();else {
   if(care[i]<0||care[i]>3)return 0;
   ssgSimpleState state;
   if(care[i]&1){if(enabled[i])state.enable(GL_ALPHA_TEST);else state.disable(GL_ALPHA_TEST);}
   if(care[i]&2)state.setAlphaClamp(clamps[i]);
   state.apply();
  }
  output[(i+1)*2]=hardwareEnabled;output[(i+1)*2+1]=hardwareClamp;
 }
 return count+1;
}
