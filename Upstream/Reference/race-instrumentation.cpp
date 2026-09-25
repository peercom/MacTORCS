// SPDX-License-Identifier: GPL-2.0-only
// The included original race routines are unchanged. Headless UI boundaries
// abort if entered unexpectedly; pit-menu notification is observed by tests.
#include "race/raceengine.cpp"
#include "race/pit-assignment.inc"
#include "race/starting-grid.inc"
#include "include/CReference.h"
#include <vector>
static void (*menuCallback)(void*) = nullptr;
static void *menuCar = nullptr;
void RmPitMenuStart(tCarElt*,tRmInfo*,void *car,void(*callback)(void*)) { menuCar=car; menuCallback=callback; }
void GfuiScreenActivate(void*) {}
void ReSetRaceMsg(const char*) {}
void ReSetRaceBigMsg(const char*) {}
void ReResScreenAddText(char*) { abort(); }
static bool capturingLaps=false;
void ref_race_capture_laps(bool value) { capturingLaps=value; }
void ReSavePracticeLap(tCarElt*) { if (!capturingLaps) abort(); }
void ReUpdateQualifCurRes(tCarElt*) { abort(); }
void GfuiDisplay() { abort(); }
void GfScrGetSize(int*,int*,int*,int*) { abort(); }
void GfImgWritePng(unsigned char*,const char*,int,int) { abort(); }
void GfTime2Str(char*,int,double,int) { abort(); }
void glPixelStorei(int,int) { abort(); }
void glReadBuffer(int) { abort(); }
void glReadPixels(int,int,int,int,int,int,void*) { abort(); }
void glutPostRedisplay() { abort(); }
double GfTimeClock() { abort(); }
void ref_race_assign_original(tRmInfo *info) { ReInfo=info; initPits(); }
void ref_race_starting_grid_original(tRmInfo *info) { ReInfo=info; initStartingGrid(); }

// The original qualifying ranking, compiled verbatim from the pinned results
// code. The excerpt is a switch case body, so this supplies exactly the names
// ReStoreRaceResults has in scope and nothing else.
#include <filesystem>
// Declared where world.cpp declares them: params.cpp defines these, and the
// race headers reachable here do not declare them.
extern void GfParmInit(void);
extern void GfParmShutdown(void);
extern void *GfParmReadBuf(char *buffer);
static void refQualifInsert(tCarElt *car,tSituation *s,void *results,void *params) {
    const int BUFSIZE=1024;
    char path[BUFSIZE],path2[BUFSIZE],buf[BUFSIZE];
    const char *race=ReInfo->_reRaceName;
    int i,nCars;
    void *carparam;const char *carName;
    switch (ReInfo->s->_raceType) {
#include "race/qualif-rank.inc"
        GfParmReleaseHandle(carparam);
        break;
    default: break;
    }
    (void)path2;(void)buf;
}
int ref_race_qualif_rank(const char *fixtures,const RefQualifRun *runs,int count,
                         RefQualifRun *output,int capacity) {
    if (!fixtures || !runs || !output || count<1 || count>64 || capacity<count) return 0;
    std::error_code ec;auto previous=std::filesystem::current_path(ec);
    if (ec) return 0;
    std::filesystem::current_path(fixtures,ec);
    if (ec) return 0;
    GfParmInit();
    std::string emptyResults="<params name='results'></params>";
    std::string emptyParams="<params name='race'></params>";
    void *results=GfParmReadBuf(emptyResults.data());
    void *params=GfParmReadBuf(emptyParams.data());
    tTrack track{};track.name=(char*)"aalborg";
    tSituation situation{};situation._raceType=RM_TYPE_QUALIF;
    tRmInfo info{};info.track=&track;info.s=&situation;info.results=results;info.params=params;
    info._reRaceName=(char*)"Qualifying";
    auto saved=ReInfo;ReInfo=&info;
    for (int run=0;run<count;++run) {
        tCarElt car{};
        snprintf(car.info.name,sizeof car.info.name,"%s",runs[run].name);
        car._bestLapTime=runs[run].bestLapTime;
        car._driverIndex=runs[run].index;
        snprintf(car.info.carName,sizeof car.info.carName,"155-DTM");
        snprintf(car.priv.modName,sizeof car.priv.modName,"bt");
        tCarElt *cars[]={&car};situation.cars=cars;situation._ncars=1;
        refQualifInsert(&car,&situation,results,params);
    }
    char path[1024];
    snprintf(path,sizeof path,"%s/%s/%s/%s","aalborg",RE_SECT_RESULTS,"Qualifying",RE_SECT_RANK);
    int ranked=GfParmGetEltNb(results,path);
    if (ranked>capacity) ranked=capacity;
    for (int i=0;i<ranked;++i) {
        snprintf(path,sizeof path,"%s/%s/%s/%s/%d","aalborg",RE_SECT_RESULTS,"Qualifying",RE_SECT_RANK,i+1);
        snprintf(output[i].name,sizeof output[i].name,"%s",GfParmGetStr(results,path,RE_ATTR_NAME,""));
        output[i].bestLapTime=GfParmGetNum(results,path,RE_ATTR_BEST_LAP_TIME,NULL,0);
        output[i].index=(int)GfParmGetNum(results,path,RE_ATTR_IDX,NULL,-1);
    }
    ReInfo=saved;
    GfParmReleaseHandle(results);GfParmReleaseHandle(params);GfParmShutdown();
    std::filesystem::current_path(previous,ec);
    return ranked;
}
void ref_race_manage_original(tRmInfo *info,tCarElt *car) { ReInfo=info; ReManage(car); }
void ref_race_time_original(tRmInfo *info,tCarElt *car) { ReInfo=info; ReUpdtPitTime(car); }
void ref_race_clear_original() { ReInfo=nullptr; menuCar=nullptr; menuCallback=nullptr; }
int ref_race_complete_menu_original(tRmInfo *info,tCarElt *car) {
    if (!menuCallback || menuCar!=car) return 0;
    ReInfo=info; auto callback=menuCallback; menuCallback=nullptr; menuCar=nullptr; callback(car); return 1;
}

void ref_race_step_original(tRmInfo *info) { ReInfo=info; ReOneStep(RCM_MAX_DT_SIMU); }
void ref_race_sort_original(tRmInfo *info) { ReInfo=info;ReSortCars(); }

int ref_race_order(const float *distances,const unsigned int *flags,int *order,int count) {
    if(!distances || !flags || !order || count<1 || count>16) return -1;
    std::vector<tCarElt> cars(count);
    std::vector<tCarElt*> ordered(count);
    std::vector<bool> seen(count,false);
    for(int i=0;i<count;i++) {
        if(order[i]<0 || order[i]>=count || seen[order[i]]) return -1;
        seen[order[i]]=true;
        cars[i].index=i;cars[i]._distRaced=distances[i];cars[i]._state=flags[i];
        ordered[i]=&cars[order[i]];
    }
    tSituation s={};s._ncars=count;s.cars=ordered.data();s._raceState=RM_RACE_RUNNING;
    tRmInfo info={};info.s=&s;
    auto previous=ReInfo;ReInfo=&info;ReSortCars();ReInfo=previous;
    for(int i=0;i<count;i++) order[i]=s.cars[i]->index;
    return s._raceState;
}
static int clockObservedState=0;
static void clockOnlySimulation(tSituation *s,double,int) { clockObservedState=s->_raceState; }
int ref_race_start_clock(int ticks,double *times,int *states) {
    if(ticks<1 || !times || !states) return 0;
    // A finished sentinel lets ReSortCars run. No physical car/robot callbacks.
    tCarElt car={};car._state=RM_CAR_STATE_FINISH | RM_CAR_STATE_NO_SIMU;
    tCarElt *cars[]={&car};tSituation s={};s.cars=cars;s.currentTime=-2;
    tRmInfo info={};info.s=&s;info._displayMode=RM_DISP_MODE_NONE;
    info._reSimItf.update=clockOnlySimulation;
    auto previous=ReInfo;ReInfo=&info;
    for(int i=0;i<ticks;i++) {
        // Zero managed cars isolates the real clock/transition in ReOneStep;
        // finished sentinel exists solely for ReSortCars' cars[0] read.
        ReOneStep(RCM_MAX_DT_SIMU);times[i]=s.currentTime;
        states[i]=clockObservedState;
        // ReSortCars ends the empty field; preserve phase for the next step.
        s._raceState=states[i];
    }
    ReInfo=previous;return 1;
}
