// SPDX-License-Identifier: GPL-2.0-only
// Capture unchanged TORCS grcar wheel update, with original PLIB transforms.
#include "CReference.h"
#include "private/car.h"
#include "private/tgf.h"
#include "private/plib/sg.h"
#include <cstring>
#include <vector>
struct WheelTransform { sgMat4 matrix; void setTransform(const sgCoord *c) { sgMakeCoordMat4(matrix,c); } };
struct WheelSelector { int mask=0; void select(int value) { mask=value; } };
struct BrakeColor { float values[4]={}; float *get(int) { return values; } };
struct WheelCapture { WheelTransform *wheelPos[4],*wheelRot[4]; WheelSelector *wheelselector[4]; BrakeColor *brkColor[4]; };
void ref_wheel_graphics(const float *body,const RefVisualWheel *wheels,RefVehicleVisual *output) {
    tCarElt elt{};tCarElt *car=&elt;WheelTransform position[4],rotation[4];WheelSelector selector[4];BrakeColor colors[4];
    WheelCapture grCarInfo[1]{};int index=0,i,j;sgCoord wheelpos;
    static float maxVel[3]={20.0,40.0,70.0};
    for(i=0;i<4;i++) {
        auto &p=car->priv.wheel[i].relPos;const auto &w=wheels[i];
        p.x=w.position[0];p.y=w.position[1];p.z=w.position[2];p.ax=w.orientation[0];p.ay=w.orientation[1];p.az=w.orientation[2];
        car->_wheelSpinVel(i)=w.spin;car->_brakeTemp(i)=w.brakeTemperature;
        grCarInfo[0].wheelPos[i]=&position[i];grCarInfo[0].wheelRot[i]=&rotation[i];grCarInfo[0].wheelselector[i]=&selector[i];grCarInfo[0].brkColor[i]=&colors[i];
    }
#include "graphics/wheel-update.inc"
    memcpy(output->matrix,body,sizeof(output->matrix));
    for(i=0;i<4;i++) {
        const auto &w=wheels[i];sgMat4 base,combined,tmp,flip,scale;
        memcpy(base,body,sizeof(base));sgMultMat4(combined,base,position[i].matrix);memcpy(output->brakeMatrix[i],combined,sizeof(combined));sgMultMat4(tmp,combined,rotation[i].matrix);
        sgMakeCoordMat4(flip,0,0,0,(i==0||i==2)?180:0,0,0);sgMultMat4(combined,tmp,flip);
        sgMakeIdentMat4(scale);scale[0][0]=w.radius*2;scale[1][1]=w.width;scale[2][2]=w.radius*2;
        sgMultMat4(tmp,combined,scale);memcpy(output->wheelMatrix[i],tmp,sizeof(tmp));
        output->level[i]=selector[i].mask==1?0:selector[i].mask==2?1:selector[i].mask==4?2:3;
        memcpy(output->brakeColor[i],colors[i].values,sizeof(output->brakeColor[i]));output->wheels[i]=w;
    }
}

// Capture the unmodified chase-camera class; track height is supplied separately
// so this oracle isolates camera update from already-tested native track queries.
#include "private/robottools.h"
#include "private/raceman.h"
struct cGrScreen { bool active=false;tCarElt *car=nullptr;bool isActive(){return active;}tCarElt *getCurrentCar(){return car;}void setCurrentCar(tCarElt *value){car=value;}int currentHead=0;int getCurCamHead(){return currentHead;}float viewRatio=1;int getId(){return 0;}float getViewRatio(){return viewRatio;} };
class cGrPerspCamera {
public:
    float eye[3]{},center[3]{},up[3]{},speed[3]{},fovy=0,fnear=0,ffar=0,fogstart=0,fogend=0;
    float *getPosv(){return eye;}float *getCenterv(){return center;}float *getUpv(){return up;}float getFovY(){return fovy;}
    cGrScreen *screen=nullptr;float fovydflt=0;int drawCar=0,drawDriver=0,drawBackground=0,mirrorAllowed=0;
    void limitFov() {} // Original grcam.h perspective implementation is empty.
    int cameraID=0;float fovymin=0,fovymax=0;int getId(){return cameraID;}
    virtual void setZoom(int);
    virtual void loadDefaults(char *);
    cGrPerspCamera()=default;
    cGrPerspCamera(cGrScreen *sc,int identifier,int curr,int drv,int bg,int mirror,float fy,float minimum,float maximum,float nearValue,float farValue,float fogStart,float fogEnd):fovy(fy),fnear(nearValue),ffar(farValue),fogstart(fogStart),fogend(fogEnd),screen(sc),fovydflt(fy),drawCar(curr),drawDriver(drv),drawBackground(bg),mirrorAllowed(mirror),cameraID(identifier),fovymin(minimum),fovymax(maximum) {}
    virtual ~cGrPerspCamera()=default;
    virtual void update(tCarElt *,tSituation *) {}
    void add(std::vector<cGrPerspCamera *> *list) { list->push_back(this); }
};
static float capturedGroundHeight;
static float captureCameraHeight(tTrackSeg *,float,float) { return capturedGroundHeight; }
#define RtTrackHeightG captureCameraHeight
#include "graphics/camera-behind.inc"
#undef RtTrackHeightG
void ref_camera_chase(const float *samples,int count,float distance,float height,float *output) {
    cGrCarCamBehind camera(nullptr,0,1,1,40,5,95,distance,height,1,600,300,600);
    tCarElt car{};
    for(int i=0;i<count;i++) {
        const float *v=samples+i*5;
        car._pos_X=v[0];car._pos_Y=v[1];car._pos_Z=v[2];car._yaw=v[3];capturedGroundHeight=v[4];
        camera.update(&car,nullptr);
        memcpy(output+i*6,camera.eye,3*sizeof(float));memcpy(output+i*6+3,camera.center,3*sizeof(float));
    }
}

void ref_camera_behind(const float *samples,int count,float *output) { ref_camera_chase(samples,count,6,2,output); }
#include "graphics/camera-bonnet.inc"
using cGrCamera=cGrPerspCamera;

// Original track-aligned, front, side and overhead classes and their factory block.
static float capturedCameraTangent;
static float captureCameraTangent(tTrkLocPos *) { return capturedCameraTangent; }
#define RtTrackHeightG captureCameraHeight
#define RtTrackSideTgAngleL captureCameraTangent
#include "graphics/camera-exterior.inc"
#undef RtTrackHeightG
#undef RtTrackSideTgAngleL
void ref_camera_exterior(int kind,const float *samples,int count,float *output) {
    if(kind<0 || kind>=14 || count<0)return;
    cGrScreen *myscreen=nullptr;cGrPerspCamera *cam=nullptr;
    int c=0,id=0;float fovFactor=1;
    std::vector<cGrPerspCamera *> cams[3];
#undef GF_TAILQ_INIT
#define GF_TAILQ_INIT(head) (head)->clear()
#include "graphics/camera-exterior-presets.inc"
#undef GF_TAILQ_INIT
    auto *selected=kind==0 ? cams[0][0]:kind==1 ? cams[0][2]:kind<10 ? cams[1][kind-2]:cams[2][kind-10];
    tCarElt car{};
    for(int i=0;i<count;i++) {
        const float *s=samples+i*6;car._pos_X=s[0];car._pos_Y=s[1];car._pos_Z=s[2];car._yaw=s[3];capturedCameraTangent=s[4];capturedGroundHeight=s[5];
        selected->update(&car,nullptr);float *o=output+i*14;
        memcpy(o,selected->eye,12);memcpy(o+3,selected->center,12);memcpy(o+6,selected->up,12);
        o[9]=selected->fovy;o[10]=selected->fnear;o[11]=selected->ffar;o[12]=selected->fogstart;o[13]=selected->fogend;
    }
    for(auto &list:cams)for(auto *item:list)delete item;
}

static int grWrldX,grWrldY,grWrldZ,grWrldMaxSize;
static void *grHandle=nullptr;
static bool captureZoomLoad=false;
static float zoomLoadedValue=0,zoomStoredValue=0;
static float cameraParameter(void *handle,const char *path,const char *key,const char *unit,float fallback) {
    return captureZoomLoad ? (std::isnan(zoomLoadedValue) ? fallback:zoomLoadedValue) : GfParmGetNum(handle,path,key,unit,fallback);
}
#define GfParmGetNum cameraParameter
#define GR_SCT_DISPMODE "Display Mode"
#include "graphics/camera-survey.inc"
#undef GR_SCT_DISPMODE
#include "graphics/camera-driver.inc"
static void captureCameraFields(cGrPerspCamera *cam,float *output) {
    memcpy(output,cam->eye,12);memcpy(output+3,cam->center,12);memcpy(output+6,cam->up,12);
    output[9]=cam->fovy;output[10]=cam->fnear;output[11]=cam->ffar;output[12]=cam->fogstart;output[13]=cam->fogend;
    output[14]=cam->drawCar;output[15]=cam->drawDriver;output[16]=cam->drawBackground;
}
void ref_camera_survey(const float *bounds,const float *position,int kind,float *output) {
    struct Point { float x,y,z; };struct Track { Point min{0,0,0},max; } trackValue;auto *track=&trackValue;memcpy(&track->max,bounds,12);
#include "graphics/camera-world.inc"
    cGrScreen *myscreen=nullptr;cGrCamera *cam=nullptr;int c=-1,id=0;
    std::vector<cGrPerspCamera *> cams[2];
#define GF_TAILQ_INIT(head) (head)->clear()
#include "graphics/camera-survey-presets.inc"
#undef GF_TAILQ_INIT
    auto *selected=kind==0 ? cams[0][0]:cams[1][kind-1];
    tCarElt car{};car._pos_X=position[0];car._pos_Y=position[1];car._pos_Z=position[2];
    selected->update(&car,nullptr);captureCameraFields(selected,output);
    output[17]=grWrldX;output[18]=grWrldY;output[19]=grWrldZ;output[20]=grWrldMaxSize;
    for(auto &list:cams)for(auto *item:list)delete item;
}
void ref_camera_driver(const float *body,const float *position,float *output) {
    cGrScreen *myscreen=nullptr;cGrCamera *cam=nullptr;int c=0,id=0;float fovFactor=1;
    std::vector<cGrPerspCamera *> cams[1];
#include "graphics/camera-driver-preset.inc"
    tCarElt car{};memcpy(car._posMat,body,sizeof(sgMat4));car._drvPos_x=position[0];car._drvPos_y=position[1];car._drvPos_z=position[2];
    cam->update(&car,nullptr);captureCameraFields(cam,output);delete cam;
}

#define GR_SCT_DISPMODE "Display Mode"
#include "graphics/camera-road-fixed.inc"
#include "graphics/camera-road-zoom.inc"
#undef GR_SCT_DISPMODE
void ref_camera_trackside(const float *bounds,const float *position,const float *roadPosition,int zoom,float *output) {
    struct Point { float x,y,z; };struct Track { Point min{0,0,0},max; } value;auto *track=&value;memcpy(&track->max,bounds,12);
#include "graphics/camera-world.inc"
    cGrScreen *myscreen=nullptr;cGrCamera *cam=nullptr;int c=-1,id=0;float fovFactor=1;
    std::vector<cGrPerspCamera *> cams[2];
#define GF_TAILQ_INIT(head) (head)->clear()
#include "graphics/camera-road-presets.inc"
#undef GF_TAILQ_INIT
    tCarElt car{};tTrackSeg segment{};tRoadCam road{};
    car._trkPos.seg=&segment;
    if(roadPosition){memcpy(&road.pos,roadPosition,12);segment.cam=&road;}
    car._pos_X=position[0];car._pos_Y=position[1];car._pos_Z=position[2];
    cam=cams[zoom ? 1:0][0];cam->update(&car,nullptr);captureCameraFields(cam,output);
    for(auto &list:cams)for(auto *item:list)delete item;
}

#undef GfParmGetNum
#define GR_ZOOM_IN 0
#define GR_ZOOM_OUT 1
#define GR_ZOOM_MAX 2
#define GR_ZOOM_MIN 3
#define GR_ZOOM_DFLT 4
#define GR_SCT_DISPMODE "Display Mode"
#define GR_ATT_FOVY "fovy"
static char zoomSavedKey[256],zoomSavedPath[1024];
static int saveCameraZoom(void *,const char *path,const char *key,const char *,float value) {
    zoomStoredValue=value;snprintf(zoomSavedKey,sizeof(zoomSavedKey),"%s",key);snprintf(zoomSavedPath,sizeof(zoomSavedPath),"%s",path);return 0;
}
static int writeCameraZoom(const char *,void *,const char *) { return 0; }
#define GfParmSetNum saveCameraZoom
#define GfParmWriteFile writeCameraZoom
#include "graphics/camera-zoom.inc"
#undef GfParmSetNum
#undef GfParmWriteFile
#define GfParmGetNum cameraParameter
#include "graphics/camera-load-defaults.inc"
#undef GfParmGetNum
#undef GR_SCT_DISPMODE
void ref_camera_zoom(int head,int identifier,float saved,const int *commands,const float *positions,int count,float *output) {
    grWrldX=902;grWrldY=703;grWrldZ=31;grWrldMaxSize=902;
    cGrScreen screen;screen.currentHead=head;cGrScreen *myscreen=&screen;
    cGrCamera *cam=nullptr;int c=0,id=0;float fovFactor=1;
    std::vector<cGrPerspCamera *> cams[8];
#define GF_TAILQ_INIT(head) (head)->clear()
#include "graphics/camera-supported-presets.inc"
#undef GF_TAILQ_INIT
    cam=cams[head][identifier];captureZoomLoad=true;zoomLoadedValue=saved;zoomStoredValue=std::isnan(saved)?cam->fovydflt:saved;
    char key[64];snprintf(key,sizeof(key),"fovy-%d-%d",head,identifier);cam->loadDefaults(key);
    tCarElt car{};tTrackSeg segment{};tRoadCam road{};road.pos={25,35,10};segment.cam=&road;segment.type=TR_STR;segment.angle[TR_ZS]=0;
    car._trkPos.seg=&segment;capturedGroundHeight=5;sgMakeIdentMat4(car._posMat);
    for(int i=0;i<count;i++) {
        car._pos_X=positions[i*3];car._pos_Y=positions[i*3+1];car._pos_Z=positions[i*3+2];
        car._posMat[3][0]=car._pos_X;car._posMat[3][1]=car._pos_Y;car._posMat[3][2]=car._pos_Z;
        zoomSavedKey[0]=zoomSavedPath[0]=0;
        if(commands[i]>=0)cam->setZoom(commands[i]);
        cam->update(&car,nullptr);float *v=output+i*23;
        captureCameraFields(cam,v);v[17]=zoomStoredValue;v[18]=cam->fovydflt;v[19]=cam->fovymin;v[20]=cam->fovymax;
        v[21]=commands[i]<0 || strcmp(zoomSavedKey,key)==0;v[22]=commands[i]<0 || strcmp(zoomSavedPath,"Display Mode/0")==0;
    }
    captureZoomLoad=false;for(auto &list:cams)for(auto *item:list)delete item;
}

namespace TVReference {
static int grNbCars;
static tTrack *grTrack;
#define GR_NB_MAX_SCREEN 4
static cGrScreen *grScreens[GR_NB_MAX_SCREEN];
static float settings[3];
static float parameter(void *,const char *,const char *key,const char *,float fallback){
    if(strcmp(key,"change camera interval")==0)return settings[0];
    if(strcmp(key,"event interval")==0)return settings[1];
    if(strcmp(key,"proximity threshold")==0)return settings[2];return fallback;
}
#define GR_SCT_TVDIR "TV Director View"
#define GR_ATT_CHGCAMINT "change camera interval"
#define GR_ATT_EVTINT "event interval"
#define GR_ATT_PROXTHLD "proximity threshold"
#define GfParmGetNum parameter
#define GfScrShutdown() ((void)0)
// Access-only instrumentation: the original implicit-private fields become
// public for capture. Constructor/update/helper statements remain byte-exact.
#define class struct
#include "graphics/camera-tv.inc"
#undef class
#undef GfScrShutdown
#undef GfParmGetNum
#undef GR_SCT_TVDIR
#undef GR_ATT_CHGCAMINT
#undef GR_ATT_EVTINT
#undef GR_ATT_PROXTHLD
struct Context {
    tTrack track{};cGrScreen screens[4];std::vector<tCarElt> cars;
    std::vector<tTrackSeg> segments;std::vector<tCarElt*> order;
    cGrCarCamRoadZoomTVD *camera=nullptr;
    explicit Context(int count):cars(count),segments(count),order(count){}
    ~Context(){delete camera;}
    void activate(){grWrldX=902;grWrldY=703;grWrldZ=31;grWrldMaxSize=902;grNbCars=int(cars.size());grTrack=&track;for(int i=0;i<4;++i)grScreens[i]=&screens[i];}
};
}
void *ref_tv_create(int count,const float *config,float trackLength,float trackWidth){
    using namespace TVReference;if(count<1||count>1024)return nullptr;
    auto *context=new Context(count);context->track.length=trackLength;context->track.width=trackWidth;context->activate();memcpy(settings,config,sizeof(settings));
    context->screens[0].currentHead=9;
    cGrScreen *myscreen=&context->screens[0];cGrCamera *cam=nullptr;int c=-1,id=0;float fovFactor=1;
    std::vector<cGrPerspCamera*> cams[1];
#define GF_TAILQ_INIT(head) (head)->clear()
#include "graphics/camera-tv-preset.inc"
#undef GF_TAILQ_INIT
    context->camera=static_cast<cGrCarCamRoadZoomTVD*>(cam);return context;
}
void ref_tv_destroy(void *handle){delete static_cast<TVReference::Context*>(handle);}
void ref_tv_step(void *handle,double time,int initialCar,const RefTVCar *input,const int *otherScreens,int screenCount,double *state,int *selection,int *collisions,float *view){
    using namespace TVReference;auto *context=static_cast<Context*>(handle);context->activate();const int count=grNbCars;
    for(int i=0;i<count;++i){
        const auto &in=input[i];auto &car=context->cars[in.index];auto &segment=context->segments[in.index];
        car.index=in.index;car._state=in.flags;car._remainingLaps=in.remainingLaps;car.ctrl.raceCmd=in.pitRequested?RM_CMD_PIT_ASKED:0;car.priv.collision=in.collision;
        segment.type=TR_STR;segment.lgfromstart=in.distanceFromStart;segment.cam=nullptr;
        car._trkPos.seg=&segment;car._trkPos.toStart=0;car._trkPos.toMiddle=in.toMiddle;car._pos_X=in.distanceFromStart;car._pos_Y=in.toMiddle;car._pos_Z=0;
        context->order[i]=&car;
    }
    for(int i=1;i<4;++i){context->screens[i].active=i<=screenCount;context->screens[i].car=i<=screenCount?&context->cars[otherScreens[i-1]]:nullptr;}
    tSituation situation{};situation.currentTime=time;situation.cars=context->order.data();situation._ncars=count;
    auto *camera=context->camera;int previous=camera->current;
    tCarElt absent{};camera->update(initialCar>=0&&initialCar<count?&context->cars[initialCar]:&absent,&situation);
    captureCameraFields(camera,view);
    selection[0]=context->screens[0].car->index;selection[1]=camera->current;
    // The first pointer lookup is initialization, not a collision-clear switch.
    int initial=0;for(int i=0;i<count;++i)if(context->order[i]->index==initialCar)initial=i;
    selection[2]=(previous<0?initial:previous)!=camera->current;
    state[0]=camera->lastEventTime;state[1]=camera->lastViewTime;
    for(int i=0;i<count;++i){state[2+i*2]=camera->schedView[i].prio;state[3+i*2]=camera->schedView[i].viewable;collisions[i]=context->cars[i].priv.collision;}
}
#undef GR_NB_MAX_SCREEN

void ref_camera_tv_zoom(float saved,const int *commands,int count,float *output){
    const float config[3]={10,1,10};auto *context=static_cast<TVReference::Context*>(ref_tv_create(1,config,1000,10));
    auto *cam=context->camera;
    captureZoomLoad=true;zoomLoadedValue=saved;zoomStoredValue=std::isnan(saved)?cam->fovydflt:saved;
    char key[]="fovy-9-0";cam->loadDefaults(key);
    for(int i=0;i<count;++i){
        zoomSavedKey[0]=zoomSavedPath[0]=0;
        if(commands[i]>=0)cam->setZoom(commands[i]);
        float *v=output+i*6;
        v[0]=zoomStoredValue;v[1]=cam->fovydflt;v[2]=cam->fovymin;v[3]=cam->fovymax;
        v[4]=commands[i]<0||strcmp(zoomSavedKey,"fovy-9-0")==0;
        v[5]=commands[i]<0||strcmp(zoomSavedPath,"Display Mode/0")==0;
    }
    captureZoomLoad=false;delete context;
}

namespace BrakeReference {
template<int N> struct Array { std::vector<float> values;explicit Array(int){};void add(const float *v){values.insert(values.end(),v,v+N);} };
using ssgVertexArray=Array<3>;using ssgNormalArray=Array<3>;using ssgColourArray=Array<4>;
struct State { int kind; };static State commonValue{0},brakeValue{1};static State *commonState=&commonValue,*brakeState=&brakeValue;
struct ssgVtxTable {
    int primitive,cull=1;ssgVertexArray *vertices;ssgNormalArray *normals;ssgColourArray *colors;State *state=nullptr;
    ssgVtxTable(int p,ssgVertexArray *v,ssgNormalArray *n,void *,ssgColourArray *c):primitive(p),vertices(v),normals(n),colors(c){}
    ~ssgVtxTable(){delete vertices;delete normals;delete colors;}
    void setCullFace(int v){cull=v;}void setState(State *v){state=v;}
};
struct ssgTransform { std::vector<ssgVtxTable*> children;void addKid(ssgVtxTable *v){children.push_back(v);}~ssgTransform(){for(auto *v:children)delete v;} };
static int grCarIndex=0;
static struct { ssgColourArray *brkColor[4];ssgTransform *wheelPos[4]; } grCarInfo[1];
#ifndef GL_TRIANGLE_FAN
#define GL_TRIANGLE_FAN 6
#define GL_TRIANGLE_STRIP 5
#endif
#define DBG_SET_NAME(...) ((void)0)
#include "graphics/brake-init.inc"
    return wheel;
}
#undef DBG_SET_NAME
#undef BRK_BRANCH
#undef BRK_ANGLE
#undef BRK_OFFSET
}
void ref_brake_geometry(int wheel,float radius,float width,float *vertices,float *normals,float *colors,int *metadata){
    tCarElt car{};car._tireWidth(wheel)=width;car._brakeDiskRadius(wheel)=radius;
    auto *node=BrakeReference::initWheel(&car,wheel);int offset=0;
    for(int part=0;part<3;++part){auto *mesh=node->children[part];const int count=int(mesh->vertices->values.size());
        memcpy(vertices+offset,mesh->vertices->values.data(),count*sizeof(float));offset+=count;
        memcpy(normals+part*3,mesh->normals->values.data(),3*sizeof(float));memcpy(colors+part*4,mesh->colors->values.data(),4*sizeof(float));
        metadata[part*4]=mesh->primitive;metadata[part*4+1]=count/3;metadata[part*4+2]=mesh->cull;metadata[part*4+3]=mesh->state->kind;
    }
    delete node;
}
