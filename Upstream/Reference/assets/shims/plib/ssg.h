// SPDX-License-Identifier: GPL-2.0-only
// Test-only scene storage adapter for the unchanged TORCS ACC parser.
// No rendering, texture decoding, geometry conversion or parser logic here.
#pragma once
#include <sg.h>
#include <tgf.h>
#include <array>
#include <vector>
#include <string>
#include <map>
#include <cstring>
#include <cstdlib>
using GLenum=unsigned int;
enum { GL_TRIANGLES=4,GL_TRIANGLE_STRIP=5,GL_TRIANGLE_FAN=6,GL_LINE_LOOP=2,GL_LINE_STRIP=3,
 GL_SPECULAR=0x1202,GL_EMISSION=0x1600,GL_AMBIENT_AND_DIFFUSE=0x1602,GL_COLOR_MATERIAL=0xB57,
 GL_LIGHTING=0xB50,GL_SMOOTH=0x1D01,GL_BLEND=0xBE2,GL_ALPHA_TEST=0xBC0,GL_TEXTURE_2D=0xDE1,
 SSG_CALLBACK_PREDRAW=1 };
struct ssgBase { int refs=0; virtual ~ssgBase()=default; void ref(){++refs;} int getRef(){return refs;} };
inline void ssgDeRefDelete(ssgBase *p){ if(p && --p->refs<=0) delete p; }
template<int N> struct Array: ssgBase {
 std::vector<std::array<float,N>> values;
 explicit Array(int capacity=0){values.reserve(capacity);}
 void add(const float *v){std::array<float,N> a;std::copy(v,v+N,a.begin());values.push_back(a);}
 float *get(int i){return values.at(i).data();}
};
using ssgVertexArray=Array<3>;using ssgNormalArray=Array<3>;using ssgTexCoordArray=Array<2>;using ssgColourArray=Array<4>;
struct ssgIndexArray: ssgBase { std::vector<unsigned short> values;void add(int v){values.push_back(v);} };
struct ssgTexture: ssgBase {std::string path;explicit ssgTexture(const char *p):path(p){} };
struct ssgState: ssgBase {
 std::map<int,std::array<float,4>> material;float shininess=0,alpha=0;bool translucent=false;unsigned alphaCare=0;
 std::map<int,bool> enabled;ssgTexture *texture=nullptr;
 ~ssgState(){ssgDeRefDelete(texture);}
 void setMaterial(int k,const float *v){std::copy(v,v+4,material[k].begin());}
 void setShininess(float v){shininess=v;} void setAlphaClamp(float v){alpha=v;alphaCare|=2;}
 void setColourMaterial(int){} void setShadeModel(int){}
 void enable(int k){enabled[k]=true;if(k==GL_ALPHA_TEST)alphaCare|=1;}void disable(int k){enabled[k]=false;if(k==GL_ALPHA_TEST)alphaCare|=1;}
 void setTranslucent(){translucent=true;}void setOpaque(){translucent=false;}
 void setTexture(ssgTexture *t){texture=t;if(t)t->ref();}
};
using grManagedState=ssgState;using grMultiTexState=ssgState;
inline grManagedState *grStateFactory(){return new grManagedState;}
struct ssgEntity: ssgBase {
 std::string name;virtual int kind()const{return 1;}
 void setName(const char *s){name=s;}const char *getName(){return name.c_str();}
 bool isAKindOf(int){return kind()!=2;}
};
struct ssgBranch: ssgEntity {
 std::vector<ssgEntity*> children;
 ~ssgBranch(){for(auto *p:children)ssgDeRefDelete(p);}
 void addKid(ssgEntity *p){p->ref();children.push_back(p);}int getNumKids(){return children.size();}
 ssgEntity *getKid(int i){return children.at(i);}void setCallback(int,int(*)(ssgEntity*)){}
};
struct ssgBranchCb: ssgBranch {};
struct ssgTransform: ssgBranch {
 sgMat4 matrix;ssgTransform(){sgMakeIdentMat4(matrix);}int kind()const override{return 0;}
 void setTransform(const sgMat4 m){std::memcpy(matrix,m,sizeof(matrix));}
};
struct ssgLeaf: ssgEntity { int kind()const override{return 2;} };
struct grVtxTable: ssgLeaf {
 GLenum primitive;ssgVertexArray *vertices;ssgNormalArray *normals;ssgTexCoordArray *uv[4];ssgColourArray *colors;
 ssgIndexArray *strips=nullptr,*indices=nullptr;int numMapLevel,mapLevel,indexCar,numStripes=0;bool cull=true;
 ssgState *states[4]={};
 grVtxTable(GLenum p,ssgVertexArray *v,ssgNormalArray *n,ssgTexCoordArray *u0,ssgTexCoordArray *u1,ssgTexCoordArray *u2,ssgTexCoordArray *u3,int count,int level,ssgColourArray *c,int car):primitive(p),vertices(v),normals(n),uv{u0,u1,u2,u3},colors(c),numMapLevel(count),mapLevel(level),indexCar(car){
  v->ref();n->ref();c->ref();for(auto *u:uv)if(u)u->ref();
 }
 grVtxTable(GLenum p,ssgVertexArray *v,ssgIndexArray *s,int ns,ssgIndexArray *i,ssgNormalArray *n,ssgTexCoordArray *u0,ssgTexCoordArray *u1,ssgTexCoordArray *u2,ssgTexCoordArray *u3,int count,int level,ssgColourArray *c,int car):grVtxTable(p,v,n,u0,u1,u2,u3,count,level,c,car){strips=s;indices=i;numStripes=ns;s->ref();i->ref();}
 ~grVtxTable(){ssgDeRefDelete(vertices);ssgDeRefDelete(normals);ssgDeRefDelete(colors);for(auto *u:uv)ssgDeRefDelete(u);ssgDeRefDelete(strips);ssgDeRefDelete(indices);for(auto *s:states)ssgDeRefDelete(s);}
 void setState(ssgState *s){states[0]=s;if(s)s->ref();}void setState1(ssgState *s){states[1]=s;if(s)s->ref();}
 void setState2(ssgState *s){states[2]=s;if(s)s->ref();}void setState3(ssgState *s){states[3]=s;if(s)s->ref();}
 void setCullFace(bool v){cull=v;}
};
struct ssgLoaderOptions {
 std::vector<const char*> ignoredData;
 ~ssgLoaderOptions(){for(auto *p:ignoredData)delete[]p;}
 void makeModelPath(char *out,const char *in){std::strcpy(out,in);}
 ssgTexture *createTexture(const char *p){return new ssgTexture(p);}
 ssgBranch *createBranch(const char *p){ignoredData.push_back(p);return nullptr;}
 ssgLeaf *createLeaf(ssgLeaf *p,int){return p;}
};
inline ssgLoaderOptions *assetOptions=nullptr;
inline void ssgSetCurrentOptions(ssgLoaderOptions *p){assetOptions=p;}
inline ssgLoaderOptions *ssgGetCurrentOptions(){return assetOptions;}
inline int ssgTypeBranch(){return 1;}
inline void ssgFlatten(ssgEntity*){abort();}inline void ssgStripify(ssgEntity*){abort();}

#define LEVEL0 1
#define LEVEL1 2
#define LEVEL2 4
#define LEVEL3 8
#define LEVELC -1
#define LEVELC2 -2
#define LEVELC3 -3
inline int maxTextureUnits=4;
inline void InitMultiTex(){maxTextureUnits=4;}
