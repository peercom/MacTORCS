// SPDX-License-Identifier: GPL-2.0-only
// Test-only storage adapter around byte-verified original PLIB HOT traversal.
// No OpenGL context, materials, scene callbacks are emulated; selector traversal is original.
#include "CReference.h"
#include <sg.h>
#include <vector>
#include <array>
#include <cstring>
#include <algorithm>
namespace HeightReference {
enum { GL_POINTS=0,GL_LINES=1,GL_LINE_LOOP=2,GL_LINE_STRIP=3,GL_TRIANGLES=4,
 GL_TRIANGLE_STRIP=5,GL_TRIANGLE_FAN=6,GL_QUADS=7,GL_QUAD_STRIP=8,GL_POLYGON=9,
 SSG_OUTSIDE=0,SSG_INSIDE=1,SSG_STRADDLE=2,SSGTRAV_HOT=2,SSG_MAXPATH=128,MAX_HITS=100 };
using ssgCullResult=int;
static int stats_hot_test,stats_hot_triv_accept,stats_hot_radius_reject,stats_hot_straddle,stats_hot_triangles;
static int _ssgBackFaceCollisions=0,_ssgIsHotTest=1,_ssgIsLosTest=0;
struct ssgEntity {
 sgSphere bsphere;bool bsphere_is_invalid=true;
 virtual ~ssgEntity()=default;
 virtual void recalcBSphere()=0;
 virtual void hot(sgVec3,sgMat4,int)=0;
 sgSphere *getBSphere(){if(bsphere_is_invalid)recalcBSphere();return &bsphere;}
 void emptyBSphere(){bsphere.empty();}
 void extendBSphere(sgSphere *s){bsphere.extend(s);}void extendBSphere(sgBox *b){bsphere.extend(b);}
 void dirtyBSphere(){}bool preTravTests(int*,int){return true;}void postTravTests(int){}
 ssgCullResult hot_test(sgVec3,sgMat4,int);
};
struct ssgBranch:ssgEntity {
 std::vector<ssgEntity*> children;size_t cursor=0;
 ~ssgBranch(){for(auto *c:children)delete c;}
 ssgEntity *getKid(int i){cursor=i;return cursor<children.size()?children[cursor]:nullptr;}
 ssgEntity *getNextKid(){return getKid(int(cursor+1));}
 void recalcBSphere() override;void hot(sgVec3,sgMat4,int) override;
};
struct ssgSelector:ssgBranch {bool selection[32]{};void hot(sgVec3,sgMat4,int) override;};
struct ssgRangeSelector:ssgBranch {bool additive=false;void hot(sgVec3,sgMat4,int) override;};
struct ssgTransform:ssgBranch {sgMat4 transform;void recalcBSphere() override;void hot(sgVec3,sgMat4,int) override;};
struct ssgLeaf:ssgEntity {void hot(sgVec3,sgMat4,int) override;virtual void hot_triangles(sgVec3,sgMat4,int)=0;};
struct VertexArray {std::vector<std::array<float,3>> values;float *get(int i){return values.at(i).data();}};
struct ssgVtxTable:ssgLeaf {
 int primitive;bool cull;VertexArray storage,*vertices=&storage;sgBox bbox;
 int getPrimitiveType(){return primitive;}int getNumVertices(){return int(vertices->values.size());}
 float *getVertex(int i){return vertices->get(i);}bool getCullFace(){return cull;}
 int getNumTriangles();void getTriangle(int,short*,short*,short*);
 void recalcBSphere() override;void hot_triangles(sgVec3,sgMat4,int) override;
};
struct ssgHit {ssgLeaf *leaf;int triangle,num_entries;ssgEntity *path[SSG_MAXPATH];sgMat4 matrix;sgVec4 plane;};
static ssgHit hitlist[MAX_HITS];static int next_hit,next_path;
static ssgEntity *pathlist[SSG_MAXPATH];
static void _ssgPushPath(ssgEntity *e){if(next_path<SSG_MAXPATH)pathlist[next_path]=e;++next_path;}
static void _ssgPopPath(){--next_path;}
#include "graphics/height/add-hit.inc"
#include "graphics/height/triangles.inc"
#include "graphics/height/triangle-count.inc"
#include "graphics/height/leaf-bounds.inc"
#include "graphics/height/leaf-triangles.inc"
#include "graphics/height/bounds-test.inc"
#include "graphics/height/leaf-traverse.inc"
#include "graphics/height/branch-bounds.inc"
#include "graphics/height/branch-traverse.inc"
#include "graphics/height/transform-bounds.inc"
#include "graphics/height/transform-traverse.inc"
#include "graphics/height/selector-traverse.inc"
#include "graphics/height/range-traverse.inc"
#include "graphics/height/query.inc"
static ssgBranch *TheScene;
#include "graphics/height/gr-height.inc"
struct Scene {ssgBranch root;std::vector<ssgEntity*> nodes;};
}
void *ref_scene_height_create(){return new HeightReference::Scene;}
int ref_scene_height_add(void *handle,int parent,int kind,const float *matrix,int primitive,int cull,const float *vertices,int count){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);
 if(!s||parent<-1||parent>=int(s->nodes.size())||kind<0||kind>4||count<0||count>32768)return 0;
 auto *p=parent<0?&s->root:dynamic_cast<ssgBranch*>(s->nodes[parent]);if(!p)return 0;
 ssgEntity *n;
 if(kind==2){auto *v=new ssgVtxTable;v->primitive=primitive;v->cull=cull!=0;for(int i=0;i<count;++i)v->storage.values.push_back({vertices[i*3],vertices[i*3+1],vertices[i*3+2]});n=v;}
 else if(kind==0){if(!matrix)return 0;auto *t=new ssgTransform;memcpy(t->transform,matrix,sizeof(t->transform));n=t;}
 else if(kind==3)n=new ssgSelector;
 else if(kind==4)n=new ssgRangeSelector;
 else n=new ssgBranch;
 s->nodes.push_back(n);p->children.push_back(n);return 1;
}
void ref_scene_height_query(void *handle,const float *xy,int count,float *heights,int *hits,int *triangles){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);TheScene=&s->root;
 for(int i=0;i<count;++i){stats_hot_triangles=0;heights[i]=grGetHOT(xy[i*2],xy[i*2+1]);hits[i]=next_hit;triangles[i]=stats_hot_triangles;}
 TheScene=nullptr;
}
void ref_scene_height_spheres(void *handle,float *output){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);
 for(size_t i=0;i<s->nodes.size();++i){auto *b=s->nodes[i]->getBSphere();for(int j=0;j<3;++j)output[i*4+j]=b->isEmpty()?0:b->getCenter()[j];output[i*4+3]=b->getRadius();}
}
void ref_scene_height_destroy(void *handle){delete static_cast<HeightReference::Scene*>(handle);}

static void invalidateHeight(void *handle){
 auto *s=static_cast<HeightReference::Scene*>(handle);s->root.bsphere_is_invalid=true;
 for(auto *n:s->nodes)n->bsphere_is_invalid=true;
}
int ref_scene_height_transform(void *handle,int node,const float *matrix){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);
 if(node<0||node>=int(s->nodes.size()))return 0;
 auto *t=dynamic_cast<ssgTransform*>(s->nodes[node]);if(!t)return 0;
 memcpy(t->transform,matrix,sizeof(t->transform));invalidateHeight(handle);return 1;
}
int ref_scene_height_select(void *handle,int node,unsigned mask){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);
 if(node<0||node>=int(s->nodes.size()))return 0;
 if(auto *t=dynamic_cast<ssgSelector*>(s->nodes[node])){for(int i=0;i<32;++i)t->selection[i]=(mask&(1u<<i))!=0;return 1;}
 if(auto *t=dynamic_cast<ssgRangeSelector*>(s->nodes[node])){t->additive=mask!=0;return 1;}
 return 0;
}
int ref_scene_height_driver_selector(void *handle,int parent,int child,int visible){
 using namespace HeightReference;auto *s=static_cast<Scene*>(handle);
 if(parent<0||child<0||parent>=int(s->nodes.size())||child>=int(s->nodes.size()))return -1;
 auto *p=dynamic_cast<ssgBranch*>(s->nodes[parent]);if(!p)return -1;
 auto it=std::find(p->children.begin(),p->children.end(),s->nodes[child]);if(it==p->children.end())return -1;
 auto *selector=new ssgSelector;selector->selection[0]=visible!=0;
 selector->children.push_back(*it);p->children.erase(it);p->children.push_back(selector);
 int result=int(s->nodes.size());s->nodes.push_back(selector);invalidateHeight(handle);return result;
}
