// SPDX-License-Identifier: GPL-2.0-only
// Test-only storage/GL-call capture around verbatim TORCS car-light functions.
#include "CReference.h"
#include "private/car.h"
#include "private/tgf.h"
#include "private/plib/sg.h"
#include <vector>
#include <string>
#include <algorithm>
#include <cstring>
#include <cstdlib>
extern void GfParmInit(void);
extern void GfParmShutdown(void);
extern void *GfParmReadBuf(char *);
namespace LightReference {
#include "graphics/carlight-constants.inc"
constexpr int GL_FALSE=0,GL_TRUE=1,GL_TEXTURE_ENV=2,GL_TEXTURE_ENV_MODE=3,GL_MODULATE=4,
 GL_POLYGON_OFFSET_FILL=5,GL_MODELVIEW_MATRIX=6,GL_TEXTURE0_ARB=7,GL_TEXTURE=8,GL_MODELVIEW=9,GL_TRIANGLE_STRIP=5,SSG_CLONE_GEOMETRY=1;
using GLfloat=float;
static int maxTextureUnits=2,randomInput=0,randomDraws=0,currentMode=GL_MODELVIEW;
static RefCarLightDraw capture;
static sgMat4 inputView,textureMatrix;
static int rand(){++randomDraws;return randomInput;}
static void glDepthMask(int v){capture.depthMask[capture.depthMaskCount++]=v;}
static void glTexEnvf(int,int,int){}
static void glPolygonOffset(float a,float b){capture.offset[0]=a;capture.offset[1]=b;}
static void glEnable(int){capture.offsetEnabled++;}
static void glDisable(int){capture.offsetEnabled--;}
static void glGetFloatv(int,float *v){memcpy(v,inputView,sizeof(inputView));}
static void glActiveTextureARB(int){}
static void glMatrixMode(int v){currentMode=v;}
static void glLoadIdentity(){if(currentMode==GL_TEXTURE)sgMakeIdentMat4(textureMatrix);}
static void glMultMatrixf(float *v){sgMat4 b,tmp;memcpy(b,v,sizeof(b));sgMultMat4(tmp,textureMatrix,b);sgCopyMat4(textureMatrix,tmp);}
static void glBegin(int v){capture.primitive=v;memcpy(capture.textureMatrix,textureMatrix,sizeof(textureMatrix));}
static void glColor4f(float r,float g,float b,float a){capture.color[0]=r;capture.color[1]=g;capture.color[2]=b;capture.color[3]=a;}
static void glNormal3fv(float *){}
static void glTexCoord2f(float u,float v){capture.uv[capture.count*2]=u;capture.uv[capture.count*2+1]=v;}
static void glVertex3f(float x,float y,float z){float *p=capture.vertices+capture.count++*3;p[0]=x;p[1]=y;p[2]=z;}
static void glEnd(){}
struct Array { sgVec3 p{};float *get(int){return p;} };
class ssgVtxTableCarlight {
public:
 int on=1;float size=0;sgVec3 pos{};double factor=1;int gltype=GL_TRIANGLE_STRIP;
 Array vertexStorage,normalStorage;Array *vertices=&vertexStorage,*normals=&normalStorage;
 ssgVtxTableCarlight *clone(int){auto *copy=new ssgVtxTableCarlight;copy->on=on;copy->size=size;sgCopyVec3(copy->pos,pos);copy->vertexStorage=vertexStorage;return copy;}
 void setCullFace(int){};int getNumNormals(){return 0;}
 void transform(sgMat4 m){sgXformPnt3(vertexStorage.p,m);}
 void setOnOff(int v){on=v;}void setFactor(double v){factor=v;}
 void draw_geometry();
};
struct Branch {
 std::vector<ssgVtxTableCarlight*> children;
 int getNumKids(){return int(children.size());}
 void addKid(ssgVtxTableCarlight *p){children.push_back(p);}
 void removeKid(ssgVtxTableCarlight *p){auto it=std::find(children.begin(),children.end(),p);if(it!=children.end()){delete *it;children.erase(it);}}
 ~Branch(){for(auto *p:children)delete p;}
};
struct Lights { ssgVtxTableCarlight *lightArray[14]{},*lightCurr[14]{};int lightType[14]{},numberCarlight=0;Branch *lightAnchor=nullptr; };
static Lights theCarslight[1];
static struct { sgMat4 carPos; } grCarInfo[1];
class cGrPerspCamera {};
#include "graphics/carlight-draw.inc"
#include "graphics/carlight-update.inc"
static std::vector<RefCarLightConfig> configurations;
static void grAddCarlight(tCarElt *,int type,sgVec3 p,double size){RefCarLightConfig value{};value.type=type;memcpy(value.position,p,12);value.size=float(size);configurations.push_back(value);}
}
int ref_carlight_config_xml(const char *xml,RefCarLightConfig *output,int capacity){
 if(!xml||!output||capacity<14||strlen(xml)>65536||strstr(xml,"<!DOCTYPE")||strstr(xml,"<!ENTITY"))return -1;
 GfParmInit();std::string buffer(xml);void *handle=GfParmReadBuf(buffer.data());if(!handle){GfParmShutdown();return -1;}
 using namespace LightReference;configurations.clear();tCarElt value{};tCarElt *car=&value;
 constexpr int PATHSIZE=1024;char path[PATHSIZE];int i,lightNum,lightTypeNum;const char *lightType;sgVec3 lightPos;
#include "graphics/carlight-config.inc"
 int count=int(configurations.size());if(count<=capacity)std::copy(configurations.begin(),configurations.end(),output);else count=-1;
 configurations.clear();GfParmReleaseHandle(handle);GfParmShutdown();return count;
}
void ref_carlight_update(int type,float brake,unsigned lightCommand,int display,const float *position,float size,const float *body,int *state,float *world){
 using namespace LightReference;tCarElt car{};car.ctrl.brakeCmd=brake;car.ctrl.lightCmd=int(lightCommand);
 Branch anchor;ssgVtxTableCarlight original;original.size=size;memcpy(original.pos,position,12);memcpy(original.vertexStorage.p,position,12);
 auto &lights=theCarslight[0];lights={};lights.numberCarlight=1;lights.lightArray[0]=&original;lights.lightType[0]=type;lights.lightAnchor=&anchor;
 lights.lightCurr[0]=original.clone(1);anchor.addKid(lights.lightCurr[0]);memcpy(grCarInfo[0].carPos,body,sizeof(sgMat4));
 grUpdateCarlight(&car,nullptr,display);state[0]=anchor.getNumKids();state[1]=anchor.children.empty()?-1:anchor.children[0]->on;
 if(!anchor.children.empty())memcpy(world,anchor.children[0]->vertexStorage.p,12);
 lights={};
}
void ref_carlight_draw(const float *position,float size,double factor,const float *view,unsigned randomValue,int on,RefCarLightDraw *output){
 using namespace LightReference;capture={};randomDraws=0;randomInput=int(randomValue);memcpy(inputView,view,sizeof(sgMat4));currentMode=GL_MODELVIEW;sgMakeIdentMat4(textureMatrix);
 ssgVtxTableCarlight light;memcpy(light.vertexStorage.p,position,12);light.size=size;light.factor=factor;light.on=on;light.draw_geometry();
 capture.randomDraws=randomDraws;capture.finalMatrixMode=currentMode;memcpy(capture.finalTextureMatrix,textureMatrix,sizeof(textureMatrix));*output=capture;
}

void ref_carlight_random(unsigned seed,int count,unsigned *output){std::srand(seed);for(int i=0;i<count;++i)output[i]=unsigned(std::rand());}

int ref_carlight_frustum(float nearValue,float farValue,float right,float top,const float *view,const float *position){
 sgFrustum f;f.setFrustum(-right,right,-top,top,nearValue,farValue);sgMat4 m;memcpy(m,view,sizeof(m));sgSphere sphere;sphere.setCenter(position);sphere.setRadius(0);sphere.orthoXform(m);return f.contains(&sphere)!=SG_OUTSIDE;
}
