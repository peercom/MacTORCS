// SPDX-License-Identifier: GPL-2.0-only
// Test-only storage/GL adapters around notice-retaining original SSG traversal,
// deferred queue, TORCS anchor initialization, driver wrapping and car comparator.
#include "CReference.h"
#include "private/plib/sg.h"
#include <vector>
#include <memory>
#include <algorithm>
#include <cstring>
#include <cstdlib>
namespace DrawOrderReference {
enum {SSG_OUTSIDE=0,SSG_INSIDE=1,SSGTRAV_CULL=1,GL_TEXTURE=0,GL_MODELVIEW=1,UL_WARNING=1};
struct ssgBranch;
struct ssgEntity {
 int id=-1;bool visible=true;const char *name=nullptr;std::vector<ssgBranch*> parents;
 virtual ~ssgEntity()=default;virtual void cull(sgFrustum*,sgMat4,int)=0;
 int cull_test(sgFrustum*,sgMat4,int){return visible?SSG_INSIDE:SSG_OUTSIDE;}
 bool preTravTests(int*,int){return true;}void postTravTests(int){}
 const char *getName(){return name;}virtual ssgEntity *getByName(char*);
 ssgBranch *getParent(int i){return parents.at(i);}
};
struct ssgBranch:ssgEntity {
 std::vector<ssgEntity*> children;size_t cursor=0;
 ssgEntity *getKid(int i){cursor=i;return cursor<children.size()?children[cursor]:nullptr;}
 ssgEntity *getNextKid(){return getKid(int(cursor+1));}
 void addKid(ssgEntity *p){children.push_back(p);p->parents.push_back(this);}
 void removeKid(ssgEntity *p){children.erase(std::find(children.begin(),children.end(),p));auto &v=p->parents;v.erase(std::find(v.begin(),v.end(),this));}
 void cull(sgFrustum*,sgMat4,int) override;ssgEntity *getByName(char*) override;
};
static std::vector<int> recorded;
struct ssgLeaf:ssgEntity {
 bool translucent=false;int isTranslucent(){return translucent;}
 void draw(){recorded.push_back(id);}void cull(sgFrustum*,sgMat4,int) override;
};
struct ssgSelector:ssgBranch {void select(int){};};
static void glPopMatrix(){}static void glPushMatrix(){}static void glLoadMatrixf(float*){}
static void glLoadIdentity(){}static void glMatrixMode(int){}
static void _ssgSetRealCurrentTweenSettings(float,int){}
static void ulSetError(int,const char*){std::abort();}
#include "graphics/order/deferred-list.inc"
#include "graphics/order/deferred-append.inc"
#include "graphics/order/leaf-cull.inc"
#include "graphics/order/branch-cull.inc"
#include "graphics/order/entity-name.inc"
#include "graphics/order/branch-name.inc"
struct tCarElt {float _pos_X,_pos_Y;int index;};
struct cGrCamera {float eye[3];float getDist2(tCarElt*);};
struct cGrPerspCamera:cGrCamera {};
#include "graphics/order/car-distance.inc"
#include "graphics/order/car-compare.inc"
}
int ref_draw_order(const int *parents,const int *flags,const int *visible,const int *driverNames,int count,int wrapDriver,int *output,int capacity){
 using namespace DrawOrderReference;
 if(count<1||count>4096||capacity<count||parents[0]!=-1||flags[0]!=-1)return -1;
 std::vector<std::unique_ptr<ssgEntity>> nodes;
 for(int i=0;i<count;i++){
  if(i>0&&(parents[i]<0||parents[i]>=i||flags[parents[i]]!=-1))return -1;
  std::unique_ptr<ssgEntity> p;
  if(flags[i]<0)p=std::make_unique<ssgBranch>();else {auto leaf=std::make_unique<ssgLeaf>();leaf->translucent=flags[i]&32;p=std::move(leaf);}
  p->id=i;p->visible=!visible||visible[i];p->name=driverNames&&driverNames[i]?"DRIVER":nullptr;
  if(i>0)static_cast<ssgBranch*>(nodes[parents[i]].get())->addKid(p.get());nodes.push_back(std::move(p));
 }
 auto *carEntity=static_cast<ssgBranch*>(nodes[0].get());
 std::unique_ptr<ssgSelector> selector;
 if(wrapDriver){
  for(int i=0;i<count;i++)if(driverNames&&driverNames[i]&&(i==0||flags[i]>=0))return -1;
  struct {ssgSelector *driverSelector;bool driverSelectorinsg;} grCarInfo[1]{};int index=0;
#include "graphics/order/driver-wrap.inc"
  selector.reset(grCarInfo[0].driverSelector);
 }
 recorded.clear();next_dlist=0;sgMat4 m;sgMakeIdentMat4(m);sgFrustum f;
 carEntity->cull(&f,m,1);_ssgDrawDList();
 std::copy(recorded.begin(),recorded.end(),output);return int(recorded.size());
}
int ref_scene_anchor_order(int *output){
 using namespace DrawOrderReference;ssgBranch root,*TheScene=&root;
 ssgBranch *LandAnchor,*PitsAnchor,*SkidAnchor,*ShadowAnchor,*CarlightAnchor,*CarsAnchor,*SmokeAnchor,*SunAnchor;
#include "graphics/order/anchor-init.inc"
 ssgBranch *names[]={LandAnchor,PitsAnchor,SkidAnchor,ShadowAnchor,CarlightAnchor,CarsAnchor,SmokeAnchor,SunAnchor};
 for(int i=0;i<8;i++){output[i]=-1;for(int j=0;j<8;j++)if(root.children[i]==names[j])output[i]=j;}
 for(auto *p:names)delete p;return int(root.children.size());
}
int ref_car_draw_order(const float *positions,const float *eye,int *order,int count,float *distances){
 using namespace DrawOrderReference;if(count<0||count>1024)return 0;
 std::vector<tCarElt> values(count);std::vector<tCarElt*> cars(count);cGrPerspCamera camera;std::copy(eye,eye+3,camera.eye);ThedispCam=&camera;
 for(int i=0;i<count;i++){values[i]={positions[i*3],positions[i*3+1],i};if(order[i]<0||order[i]>=count)return 0;cars[i]=&values[order[i]];distances[i]=camera.getDist2(&values[i]);}
 qsort(cars.data(),count,sizeof(tCarElt*),comparCars);
 for(int i=0;i<count;i++)order[i]=cars[i]->index;return 1;
}

// Captures depth state through original frame dispatch and ordinary mesh draw
// functions. State application, geometry and GL matrix/light operations are
// adapters; no callbacks or OpenGL rasterizer are exercised here.
namespace DepthStateReference {
enum {GL_LEQUAL=0x0203,GL_PROJECTION=0x1701,GL_MODELVIEW=0x1700,UL_FATAL=1,TABLE=0,LEVEL0=0};
static int comparison=0,depthWrite=1,stats_num_leaves=0,stats_num_vertices=0,_ssgFrameCounter=0;
static std::vector<int> captured;
static void glDepthFunc(int value){comparison=value;}
static void glMatrixMode(int){}static void glLoadIdentity(){}
static void ulSetError(int,const char*){std::abort();}
static void _ssgStartOfFrameInit(){}static void _ssgEndOfFrameCleanup(){}
static void ssgForceBasicState(){}
struct State {void apply(){}};
struct ssgBranch {};
struct Context {
 bool overridden=false;State state;
 bool stateOverridden(){return overridden;}State *overriddenState(){return &state;}
 void loadProjectionMatrix(){}void loadModelviewMatrix(){}void applyClipPlanes(){}
 void removeClipPlanes(){}void cull(ssgBranch*){}
};
static Context context,*_ssgCurrentContext=&context;
struct Light {bool isHeadlight(){return false;}void setup(){}};
static Light _ssgLights[8];
struct ssgVtxTable {
 State state;void (*postDrawCB)(ssgVtxTable*)=nullptr;
 bool preDraw(){return true;}bool hasState(){return true;}
 State *getState(){return &state;}int getNumVertices(){return 4;}
 void draw_geometry(){captured.push_back(depthWrite);}void draw();
};
struct grVtxTable:ssgVtxTable {
 int internalType=TABLE,mapLevelBitmap=LEVEL0,maxTextureUnits=4;
 void draw_geometry_for_a_car(){draw_geometry();}void draw_geometry_multi(){draw_geometry();}
 void draw_geometry_array(){draw_geometry();}void draw_geometry_for_a_car_array(){draw_geometry();}
 void draw();
};
#include "graphics/order/vertex-draw.inc"
#include "graphics/order/car-vertex-draw.inc"
static void _ssgDrawDList(){
 ssgVtxTable leaf;context.overridden=false;leaf.draw();context.overridden=true;leaf.draw();context.overridden=false;
 grVtxTable car;
 for(int type=0;type<2;type++)for(int level=-1;level<=1;level++){
  car.internalType=type;car.mapLevelBitmap=level;car.draw();
 }
}
#include "graphics/order/frame-draw.inc"
}
int ref_scene_depth_state(int initialWrite,int *output,int capacity){
 using namespace DepthStateReference;if(capacity<10)return -1;
 depthWrite=initialWrite!=0;comparison=0;captured.clear();stats_num_leaves=0;stats_num_vertices=0;
#include "graphics/order/frame-depth.inc"
 ssgBranch root;ssgCullAndDraw(&root);
 output[0]=comparison;output[1]=depthWrite;
 std::copy(captured.begin(),captured.end(),output+2);return int(captured.size())+2;
}
