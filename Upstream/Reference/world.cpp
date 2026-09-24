// SPDX-License-Identifier: GPL-2.0-only
// Instrumentation only. Track construction, parameter merging, setup, all
// vehicle dynamics and collisions run original TORCS 1.3.9 implementations.
// Grid placement follows raceengineclient/raceinit.cpp (C) Eric Espie and
// Bernhard Wymann, GPL-2.0-or-later. No race timing/robot behavior is fabricated.
#include "CReference.h"
#include "sim.h"
#include "track/trackinc.h"
#include <vector>
#include <string>
#include <memory>
#include <cmath>
#include <algorithm>
#include <robot.h>
#include <filesystem>
extern "C" int bt(tModInfo*);
extern void ref_race_step_original(tRmInfo*);
extern void ref_race_assign_original(tRmInfo*);
extern void ref_race_starting_grid_original(tRmInfo*);
extern void ref_race_manage_original(tRmInfo*,tCarElt*);
extern void ref_race_time_original(tRmInfo*,tCarElt*);
extern void ref_race_clear_original();
extern int ref_race_complete_menu_original(tRmInfo*,tCarElt*);

extern void GfParmInit(void);
extern void GfParmShutdown(void);
extern void *GfParmReadBuf(char *buffer);
extern int GfParmWriteBuf(void *handle, char *buffer, int size);

struct RefWorld {
    tTrack *track = nullptr;
    std::vector<tTrackSeg *> geometry;
    std::vector<int> mainIndices;
    std::vector<tCarElt> cars;
    std::vector<tCarElt *> pointers;
    std::vector<tTrackOwnPit> assignedPits;
    std::vector<tReCarInfo> raceCars;
    std::vector<tRmCarRules> raceCarRules;
    std::vector<tRobotItf> robots;
    std::vector<int> serviceCounts,menuRequests,menuModes,tireOverrides;
    void *raceParameters = nullptr;
    tSituation situation{};
    RmInfo info{};
    bool btMode=false,btNewRace=false;
    // One entry per BT driver index. Single-car accessors read entry zero.
    std::vector<tRobotItf> btOriginals;
    std::vector<RefRobotRaceState> btStates;
    std::vector<std::vector<double>> btInputs;
    std::vector<RefBTObservation> btObservations;
    std::vector<RefBTPitDecision> btPitDecisions;
    std::vector<char> btInputValid;
    RefStartingGrid grid{};
    bool gridPlaced=false;
    std::vector<RefGridSlot> gridSlots;
    std::string previousDataDirectory,previousLocalDirectory;
    bool simulationInitialized = false;
    unsigned long long tick = 0;
    bool componentDynamicsStarted = false;
    unsigned int powertrainRandomSeed = 12345;
};
static RefWorld *activeWorld = nullptr;
static std::string lastError;
static const std::vector<std::string>& fieldNames() {
    static const std::vector<std::string> fields = [] {
        std::vector<std::string> names = {
            "position.x", "position.y", "position.z", "orientation.roll", "orientation.pitch", "orientation.yaw",
            "velocity.world.x", "velocity.world.y", "velocity.world.z", "velocity.local.x", "velocity.local.y", "velocity.local.z",
            "angularVelocity.x", "angularVelocity.y", "angularVelocity.z",
            "acceleration.world.x", "acceleration.world.y", "acceleration.world.z",
            "angularAcceleration.x", "angularAcceleration.y", "angularAcceleration.z",
            "engine.radiansPerSecond", "engine.torque", "gear", "clutch.transfer", "fuel", "damage", "collision", "state",
            "command.throttle", "command.brake", "command.steering", "command.clutch", "command.gear",
            "aero.drag", "aero.lift.front", "aero.lift.rear", "wing.front.x", "wing.front.z", "wing.rear.x", "wing.rear.z",
            "track.segment", "track.toStart", "track.toRight", "track.distance", "steering.angle"
        };
        for (int wheel = 0; wheel < 4; ++wheel) {
            for (const auto* name : {"position.x", "position.y", "position.z", "spin", "slipRatio", "slipAngle", "load",
                                    "force.x", "force.y", "force.z", "suspension.travel", "suspension.velocity", "suspension.force",
                                    "brake.pressure", "brake.torque", "brake.temperature", "steer", "rideHeight", "roadHeight",
                                    "tire.pressure", "tire.temperature", "tire.wear", "state", "track.segment"}) {
                names.push_back("wheel." + std::to_string(wheel) + "." + name);
            }
        }
        return names;
    }();
    return fields;
}
const char *ref_world_error() { return lastError.c_str(); }
int ref_world_field_count() { return static_cast<int>(fieldNames().size()); }
const char *ref_world_field_name(int index) {
    return index >= 0 && index < ref_world_field_count() ? fieldNames()[index].c_str() : nullptr;
}

void ref_world_destroy(RefWorld *world) {
    if (!world || world != activeWorld) return;
    if (world->btNewRace) {
        // Each driver index owns its learning data; endRace then shutdown, as
        // the original race end and ReRaceCleanDrivers do.
        for (size_t i=0;i<world->btOriginals.size();++i) {
            auto &r=world->btOriginals[i];
            r.rbEndRace(r.index,&world->cars[i],&world->situation);
            r.rbShutdown(r.index);
        }
    }
    // ReRaceCleanDrivers releases every penalty the original rules allocated.
    for (auto &car:world->cars) {
        auto *penalty=GF_TAILQ_FIRST(&(car._penaltyList));
        while (penalty) { GF_TAILQ_REMOVE(&(car._penaltyList),penalty,link);free(penalty);penalty=GF_TAILQ_FIRST(&(car._penaltyList)); }
    }
    if (world->btMode) {
        SetDataDir(world->previousDataDirectory.data());SetLocalDir(world->previousLocalDirectory.data());
    }
    ref_race_clear_original();
    if (world->raceParameters) GfParmReleaseHandle(world->raceParameters);
    for (auto &car:world->cars) {
        while (auto *penalty=GF_TAILQ_FIRST(&car._penaltyList)) { GF_TAILQ_REMOVE(&car._penaltyList,penalty,link); free(penalty); }
    }
    if (world->simulationInitialized) SimShutdown();
    for (auto &car : world->cars) if (car._carHandle) GfParmReleaseHandle(car._carHandle);
    if (world->track) TrackShutdown();
    GfParmShutdown();
    activeWorld = nullptr;
    delete world;
}

static RefWorld *createWorld(const char*,const char*,const char*,unsigned int,int,float,float,float,const char*,int,const RefStartingGrid*);
static bool initializeRaceParameters(RefWorld*,int,const RefStartingGrid*);
static int geometryIndex(RefWorld*,tTrackSeg*);
static void captureBTObservation(tCarElt *car,RefBTObservation &o) {
    o.toStart=car->_trkPos.toStart;o.toRight=car->_trkPos.toRight;o.toMiddle=car->_trkPos.toMiddle;o.toLeft=car->_trkPos.toLeft;
    o.segmentID=car->_trkPos.seg->id;o.x=car->_pos_X;o.y=car->_pos_Y;o.vx=car->_speed_X;o.vy=car->_speed_Y;
    o.yaw=car->_yaw;o.speed=car->_speed_x;o.fuel=car->_fuel;o.rpm=car->_enginerpm;o.distance=car->_distFromStartLine;
    for(int i=0;i<4;i++)o.spin[i]=car->_wheelSpinVel(i);
    o.gear=car->_gear;o.laps=car->_laps;o.remainingLaps=car->_remainingLaps;o.lapsBehindLeader=car->_lapsBehindLeader;
    o.damage=car->_dammage;o.pitFree=car->_pit && car->_pit->pitCarIndex==TR_PIT_STATE_FREE;
}
static void btDrive(int index,tCarElt *car,tSituation *s) {
    auto *w=activeWorld;const int id=car->index;
    w->btInputs[id].resize(ref_world_field_count());
    w->btInputValid[id]=ref_world_read(w,id,w->btInputs[id].data(),int(w->btInputs[id].size()))==ref_world_field_count();
    captureBTObservation(car,w->btObservations[id]);
    w->btOriginals[id].rbDrive(index,car,s);
    auto &r=w->btStates[id];++r.driveCalls;r.lastDriveTick=w->tick;
    r.robotTime=s->currentTime;r.robotDelta=s->deltaTime;
    r.throttle=car->_accelCmd;r.brake=car->_brakeCmd;r.steering=car->_steerCmd;r.clutch=car->_clutchCmd;r.gear=car->_gearCmd;
}
static int btPit(int index,tCarElt *car,tSituation *s) {
    auto *w=activeWorld;const int id=car->index;captureBTObservation(car,w->btPitDecisions[id].input);
    ++w->btStates[id].pitCalls;int result=w->btOriginals[id].rbPitCmd(index,car,s);
    w->btPitDecisions[id].fuel=car->_pitFuel;w->btPitDecisions[id].repair=car->_pitRepair;return result;
}
RefWorld *ref_world_bt_create(const char *track,const char *car,const char *category,const char *directory,unsigned int seed,int laps) {
    if (!directory || laps<1 || laps>1000) { lastError="Invalid BT race configuration";return nullptr; }
    return createWorld(track,car,category,seed,1,0,10,NAN,directory,laps,nullptr);
}
RefWorld *ref_world_bt_field_create(const char *track,const char *car,const char *category,const char *directory,
    unsigned int seed,int laps,int cars,const RefStartingGrid *grid) {
    if (!directory || laps<1 || laps>1000 || cars<1 || cars>10 || !grid) { lastError="Invalid BT field configuration";return nullptr; }
    if (grid->rows<1 || grid->poleSide<-1 || grid->poleSide>1 ||
        !std::isfinite(grid->toStart) || !std::isfinite(grid->columnDistance) || !std::isfinite(grid->columnOffset) ||
        !std::isfinite(grid->initialSpeed) || !std::isfinite(grid->initialHeight)) { lastError="Invalid starting grid";return nullptr; }
    return createWorld(track,car,category,seed,cars,0,10,NAN,directory,laps,grid);
}
RefWorld *ref_world_create(const char *trackPath, const char *carPath, const char *categoryPath,
                          unsigned int seed, int count, float startDistance, float spacing) {
    return ref_world_create_lateral(trackPath,carPath,categoryPath,seed,count,startDistance,spacing,NAN);
}
RefWorld *ref_world_create_lateral(const char *trackPath,const char *carPath,const char *categoryPath,
    unsigned int seed,int count,float startDistance,float spacing,float lateral) {
    return createWorld(trackPath,carPath,categoryPath,seed,count,startDistance,spacing,lateral,nullptr,0,nullptr);
}
static RefWorld *createWorld(const char *trackPath,const char *carPath,const char *categoryPath,
    unsigned int seed,int count,float startDistance,float spacing,float lateral,const char *robotDirectory,int totalLaps,
    const RefStartingGrid *startingGrid) {
    lastError.clear();
    if (activeWorld) { lastError = "An upstream world is already active"; return nullptr; }
    if (!trackPath || !carPath || !categoryPath || count < 1 || count > 16 ||
        !std::isfinite(startDistance) || !std::isfinite(spacing) || startDistance < 0 || spacing < 5) {
        lastError = "Invalid reference world configuration"; return nullptr;
    }
    GfParmInit();
    auto world = new RefWorld(); activeWorld = world;
    auto fail = [&](const char *message) -> RefWorld * { lastError = message; ref_world_destroy(world); return nullptr; };
    // Preflight before the original loader, which assumes nonempty valid track
    // XML. This tool is for pinned fixtures, not an untrusted-content importer.
    void *trackParameters = GfParmReadFile(trackPath, GFPARM_RMODE_STD | GFPARM_RMODE_PRIVATE);
    if (!trackParameters) return fail("Original parameter parser could not load track XML/entities");
    // Versions 0 through 3 use one schema and 4 another; the original loader
    // dispatches on this and handles both. The preflight accepts either,
    // checking the segment list each schema actually uses, so the harness can
    // serve as an oracle for a version-3 port. The nonempty requirement stays:
    // this is for pinned content, not untrusted input.
    const double version = GfParmGetNum(trackParameters, TRK_SECT_HDR, TRK_ATT_VERSION, nullptr, 0);
    const bool supported =
        (version == 4 && GfParmGetEltNb(trackParameters, TRK_SECT_MAIN "/" TRK_LST_SEGMENTS) > 0) ||
        (version >= 0 && version <= 3 &&
         GfParmGetEltNb(trackParameters, TRK_SECT_MAIN "/" TRK_LST_SEG) > 0);
    GfParmReleaseHandle(trackParameters);
    if (!supported) return fail("Reference harness requires a nonempty version 0-4 track");
    srand(seed);
    world->track = TrackBuildv1(const_cast<char *>(trackPath));
    if (!world->track || !world->track->seg || world->track->length <= 0) return fail("Original track construction failed");
    auto segment = world->track->seg->next;
    for (int i = 0; i < world->track->nseg; ++i, segment = segment->next) {
        int main = static_cast<int>(world->geometry.size());
        world->geometry.push_back(segment); world->mainIndices.push_back(main);
        for (int side = 0; side < 2; ++side) {
            auto current = segment->side[side];
            while (current) {
                world->geometry.push_back(current); world->mainIndices.push_back(main);
                current = current->side[side];
            }
        }
    }
    world->cars.resize(count); world->pointers.resize(count); world->assignedPits.resize(count);
    if (robotDirectory) {
        // The original driver reads drivers/bt/<index>/default.xml per index.
        for (int i=0;i<count;++i) {
            std::error_code ec;
            auto file=std::filesystem::path(robotDirectory)/("drivers/bt/"+std::to_string(i)+"/default.xml");
            if (!std::filesystem::is_regular_file(file,ec)) return fail("Missing pinned BT default setup");
            void *preflight=GfParmReadFile(file.c_str(),GFPARM_RMODE_STD|GFPARM_RMODE_PRIVATE);
            if (!preflight) return fail("Invalid BT setup XML");
            GfParmReleaseHandle(preflight);
        }
        world->btMode=true;world->previousDataDirectory=GetDataDir();world->previousLocalDirectory=GetLocalDir();
        std::string data=std::string(robotDirectory)+"/",local=data+"user/";
        SetDataDir(data.data());SetLocalDir(local.data());
        world->situation._totLaps=totalLaps;world->situation._raceType=RM_TYPE_RACE;
        world->btOriginals.resize(count);world->btStates.resize(count);world->btInputs.resize(count);
        world->btObservations.resize(count);world->btPitDecisions.resize(count);world->btInputValid.assign(count,1);
        world->gridSlots.resize(count);
        if (startingGrid) world->grid=*startingGrid;
        // Grid placement and initPits both read the race-manager parameters.
        if (!initializeRaceParameters(world,1,startingGrid)) return fail("Could not create reference race parameters");
    }
    for (int i = 0; i < count; ++i) {
        auto &car = world->cars[i]; world->pointers[i] = &car;
        car.index = i; car._skillLevel = 3; car._driverType = RM_DRV_ROBOT;
        void *parameters = GfParmReadFile(carPath, GFPARM_RMODE_STD | GFPARM_RMODE_PRIVATE);
        void *category = GfParmReadFile(categoryPath, GFPARM_RMODE_STD | GFPARM_RMODE_PRIVATE);
        if (!parameters || !category) {
            if (parameters) GfParmReleaseHandle(parameters);
            if (category) GfParmReleaseHandle(category);
            return fail("Could not read car/category parameters");
        }
        if (GfParmCheckHandle(category, parameters)) {
            GfParmReleaseHandle(parameters); GfParmReleaseHandle(category);
            return fail("Original category validation rejected reference car");
        }
        car._carHandle = GfParmMergeHandles(category, parameters,
            GFPARM_MMODE_SRC | GFPARM_MMODE_DST | GFPARM_MMODE_RELSRC | GFPARM_MMODE_RELDST);
        if (!car._carHandle || GfParmGetEltNb(car._carHandle, "Engine/data points") < 2) return fail("Missing engine torque curve");
        if (world->btMode) {
            // The original callback reads relative installed paths. Only this
            // serialized callback temporarily changes cwd; learning uses explicit
            // data/user roots owned by the staged fixture installation.
            std::error_code ec;auto previous=std::filesystem::current_path(ec);
            if (ec) return fail("Cannot read reference cwd");
            std::filesystem::current_path(robotDirectory,ec);
            if (ec) return fail("Cannot enter reference fixture directory");
            tModInfo modules[10]{};bt(modules);
            modules[i].fctInit(i,&world->btOriginals[i]);
            for (auto &module:modules) { free(module.name);free(module.desc); }
            void *setup=nullptr;
            world->btOriginals[i].rbNewTrack(i,world->track,car._carHandle,&setup,&world->situation);
            ++world->btStates[i].newTrackCalls;
            std::filesystem::current_path(previous,ec);
            // Pinned empty BT setup adds the original calculated starting fuel.
            // No driver-specific setup fields are fabricated by this adapter.
            if (setup) {
                car._carHandle=GfParmMergeHandles(car._carHandle,setup,
                    GFPARM_MMODE_SRC|GFPARM_MMODE_DST|GFPARM_MMODE_RELSRC|GFPARM_MMODE_RELDST);
            }
            world->robots[i]=world->btOriginals[i];world->robots[i].rbDrive=btDrive;world->robots[i].rbPitCmd=btPit;
            car.robot=&world->robots[i];
            // Original module names are "bt 1"…"bt 10" for indices 0…9.
            snprintf(car._name,MAX_NAME_LEN,"bt %d",i+1);strcpy(car._teamname,"bt");
            car._remainingLaps=totalLaps;car._pos=i+1;car._commitBestLapTime=true;
        }
        RtInitCarPitSetup(car._carHandle, &car.pitcmd.setup, false);
    }
    world->situation._ncars = count;
    world->situation.cars = world->pointers.data();
    world->situation.deltaTime = RCM_MAX_DT_SIMU;
    world->situation._raceState = 0; // Upstream pre-simulation settling mode.
    world->info.track = world->track; world->info.s = &world->situation;
    SimInit(count, world->track, 1, 1, world->btMode ? 1:0);
    world->simulationInitialized = true;
    if (startingGrid) {
        // The original routine owns placement, initial speed/height and the
        // per-car configuration callback. Value-initialized cars already carry
        // TR_LPOS_MAIN (zero), exactly as upstream's calloc'd car list does.
        world->info._reSimItf.config=SimConfig;
        ref_race_starting_grid_original(&world->info);
        for (int i = 0; i < count; ++i) {
            const auto &car = world->cars[i]; auto &slot = world->gridSlots[i];
            slot.position={geometryIndex(world,car._trkPos.seg),car._trkPos.type,car._trkPos.toStart,
                car._trkPos.toRight,car._trkPos.toMiddle,car._trkPos.toLeft};
            slot.x=car._pos_X;slot.y=car._pos_Y;slot.z=car._pos_Z;slot.yaw=car._yaw;slot.speed=car._speed_x;
        }
        world->gridPlaced=true;
    } else for (int i = 0; i < count; ++i) {
        auto &car = world->cars[i];
        tdble distance = fmod((world->btMode ? world->track->length-10:startDistance) + i * spacing, world->track->length);
        tTrackSeg *segment = world->track->seg->next;
        while (distance >= segment->length) { distance -= segment->length; segment = segment->next; }
        car._trkPos.type = TR_LPOS_MAIN;
        car._trkPos.seg = segment; car._trkPos.toRight = std::isnan(lateral) ? segment->width / 2:lateral;
        car._trkPos.toStart = segment->type == TR_STR ? distance : distance / segment->radius;
        RtTrackLocal2Global(&car._trkPos, &car._pos_X, &car._pos_Y, TR_TORIGHT);
        car._yaw = segment->angle[TR_ZS];
        if (segment->type == TR_LFT) car._yaw += car._trkPos.toStart;
        if (segment->type == TR_RGT) car._yaw -= car._trkPos.toStart;
        car._pos_Z = RtTrackHeightL(&car._trkPos) + 0.3f;
        NORM0_2PI(car._yaw);
        SimConfig(&car, &world->info);
    }
    if (world->btMode) {
        ref_race_assign_original(&world->info);
        world->info._reSimItf.update=SimUpdate;
        world->info.raceRules={3,1,1,8,0.007f,2,1,16};
        world->situation._maxDammage=10000;
        // racemain.cpp: newRace, one uncommanded settling update, previous
        // position publication, then 500 settling updates with the brake held.
        for (int i=0;i<count;++i) {
            world->btOriginals[i].rbNewRace(i,&world->cars[i],&world->situation);
            ++world->btStates[i].newRaceCalls;
        }
        world->btNewRace=true;
        SimUpdate(&world->situation,RCM_MAX_DT_SIMU,-1);
        for (int i=0;i<count;++i) world->raceCars[i].prevTrkPos=world->cars[i]._trkPos;
        for (auto &car:world->cars) { car.ctrl={};car.ctrl.brakeCmd=1; }
        for (int i=0;i<int(1.0/RCM_MAX_DT_SIMU);++i) SimUpdate(&world->situation,RCM_MAX_DT_SIMU,-1);
        world->info._reTimeMult=1;world->situation.currentTime=-2;world->info._reLastTime=-1;
        world->situation._raceState=RM_RACE_STARTING;world->situation.deltaTime=RCM_MAX_DT_SIMU;
    }
    return world;
}
int ref_world_command(RefWorld *world, int index, float throttle, float brake, float steering, float clutch, int gear) {
    if (!world || world != activeWorld || index < 0 || index >= static_cast<int>(world->cars.size()) ||
        !std::isfinite(throttle) || !std::isfinite(brake) || !std::isfinite(steering) || !std::isfinite(clutch)) return 0;
    auto &control = world->cars[index].ctrl;
    control.accelCmd = throttle; control.brakeCmd = brake; control.steer = steering; control.clutchCmd = clutch; control.gear = gear;
    return 1;
}
int ref_world_settle(RefWorld *world, int ticks) {
    if (!world || world != activeWorld || ticks < 0 || ticks > 10000 || world->tick != 0) return 0;
    for (auto &car : world->cars) car.ctrl.brakeCmd = 1;
    world->situation._raceState = 0;
    for (int i = 0; i < ticks; ++i) SimUpdate(&world->situation, RCM_MAX_DT_SIMU, -1);
    world->situation._raceState = RM_RACE_RUNNING;
    return 1;
}
int ref_world_step(RefWorld *world) { return ref_world_step_mode(world,RM_RACE_RUNNING); }
int ref_world_step_mode(RefWorld *world,unsigned int raceState) {
    if (!world || world != activeWorld || (raceState!=0 && raceState!=RM_RACE_RUNNING && raceState!=RM_RACE_PRESTART)) return 0;
    world->situation._raceState = raceState;
    world->situation.currentTime = ++world->tick * RCM_MAX_DT_SIMU;
    SimUpdate(&world->situation, RCM_MAX_DT_SIMU, -1);
    return 1;
}
double ref_world_track_width(RefWorld *world) { return world && world == activeWorld ? world->track->width : 0; }
double ref_world_track_length(RefWorld *world) { return world && world == activeWorld ? world->track->length : 0; }
int ref_world_track_segments(RefWorld *world) { return world && world == activeWorld ? world->track->nseg : 0; }
int ref_world_read(RefWorld *world, int index, double *values, int capacity) {
    if (!world || world != activeWorld || index < 0 || index >= static_cast<int>(world->cars.size()) || !values || capacity < ref_world_field_count()) return 0;
    const auto &car = SimCarTable[index]; const auto &global = car.DynGCg; const auto &local = car.DynGC;
    int cursor = 0;
    auto put = [&](double value) { values[cursor++] = value; };
    for (auto p : {global.pos, global.vel}) {
        put(p.x); put(p.y); put(p.z);
        if (cursor == 3) { put(p.ax); put(p.ay); put(p.az); }
    }
    put(local.vel.x); put(local.vel.y); put(local.vel.z);
    put(global.vel.ax); put(global.vel.ay); put(global.vel.az);
    put(global.acc.x); put(global.acc.y); put(global.acc.z);
    put(global.acc.ax); put(global.acc.ay); put(global.acc.az);
    put(car.engine.rads); put(car.engine.Tq); put(car.transmission.gearbox.gear); put(car.transmission.clutch.transferValue);
    put(car.fuel); put(car.dammage); put(car.collision); put(car.carElt->_state);
    put(car.ctrl->accelCmd); put(car.ctrl->brakeCmd); put(car.ctrl->steer); put(car.ctrl->clutchCmd); put(car.ctrl->gear);
    put(car.aero.drag); put(car.aero.lift[0]); put(car.aero.lift[1]);
    for (const auto &wing : car.wing) { put(wing.forces.x); put(wing.forces.z); }
    put(car.trkPos.seg->id); put(car.trkPos.toStart); put(car.trkPos.toRight);
    put(car.trkPos.seg->lgfromstart + car.trkPos.toStart * (car.trkPos.seg->type == TR_STR ? 1 : car.trkPos.seg->radius));
    put(car.steer.steer);
    for (const auto &w : car.wheel) {
        put(w.pos.x); put(w.pos.y); put(w.pos.z); put(w.spinVel); put(w.sx); put(w.sa); put(w.tireZForce);
        put(w.forces.x); put(w.forces.y); put(w.forces.z); put(w.susp.x); put(w.susp.v); put(w.susp.force);
        put(w.brake.pressure); put(w.brake.Tq); put(w.brake.temp); put(w.steer); put(w.rideHeight); put(w.zRoad);
        put(w.currentPressure); put(w.currentTemperature); put(w.currentWear); put(w.state); put(w.trkPos.seg ? w.trkPos.seg->id : -1);
    }
    if (cursor != ref_world_field_count()) { lastError = "Telemetry schema/field count mismatch"; return 0; }
    for (int i = 0; i < cursor; ++i) if (!std::isfinite(values[i])) {
        lastError = "Non-finite upstream telemetry: " + fieldNames()[i]; return 0;
    }
    return cursor;
}

float ref_world_parameter_number(RefWorld *world, int car, const char *section, const char *key, float fallback) {
    if (!world || world != activeWorld || car < 0 || car >= static_cast<int>(world->cars.size()) || !section || !key) return fallback;
    return GfParmGetNum(world->cars[car]._carHandle, section, key, nullptr, fallback);
}
const char *ref_world_parameter_string(RefWorld *world, int car, const char *section, const char *key) {
    if (!world || world != activeWorld || car < 0 || car >= static_cast<int>(world->cars.size()) || !section || !key) return nullptr;
    return GfParmGetStr(world->cars[car]._carHandle, section, key, nullptr);
}
int ref_merge_xml(const char *source, const char *target, int mode, char *output, int capacity) {
    if (activeWorld || !source || !target || !output || capacity < 1 || mode < 0 || mode > 3 ||
        strlen(source) > 65536 || strlen(target) > 65536 ||
        strstr(source, "<!DOCTYPE") || strstr(target, "<!DOCTYPE") ||
        strstr(source, "<!ENTITY") || strstr(target, "<!ENTITY")) return 0;
    GfParmInit();
    // The original parser mutates its input buffer while splitting string lists.
    std::string a(source), b(target);
    void *reference = GfParmReadBuf(a.data()), *destination = GfParmReadBuf(b.data());
    int result = 0;
    if (reference && destination) {
        void *merged = GfParmMergeHandles(reference, destination, mode | GFPARM_MMODE_RELSRC | GFPARM_MMODE_RELDST);
        // Public upstream API sets the otherwise unnamed merged document's name.
        GfParmWriteFile("/dev/null", merged, "merged");
        memset(output, 0, capacity);
        result = GfParmWriteBuf(merged, output, capacity) == 0;
        result = result && strstr(output, "</params>");
        GfParmReleaseHandle(merged);
    } else {
        if (reference) GfParmReleaseHandle(reference);
        if (destination) GfParmReleaseHandle(destination);
    }
    GfParmShutdown();
    return result;
}
int ref_world_mass_properties(RefWorld *world, int index, RefMassProperties *out) {
    if (!world || world != activeWorld || index < 0 || index >= static_cast<int>(world->cars.size()) || !out) return 0;
    const auto &car = SimCarTable[index];
    *out = {car.mass, car.Minv, car.dimension.x, car.dimension.y, car.dimension.z,
            car.statGC.x, car.statGC.y, car.statGC.z, car.Iinv.x, car.Iinv.y, car.Iinv.z,
            car.wheel[0].weight0, car.wheel[1].weight0, car.wheel[2].weight0, car.wheel[3].weight0,
            car.wheelbase, car.wheeltrack, car.tank, car.fuel};
    return 1;
}

static bool validGeometry(RefWorld *world, int index) {
    return world && world == activeWorld && index >= 0 && index < static_cast<int>(world->geometry.size());
}
static int geometryIndex(RefWorld *world, tTrackSeg *segment) {
    auto found = std::find(world->geometry.begin(), world->geometry.end(), segment);
    return found == world->geometry.end() ? -1 : static_cast<int>(found - world->geometry.begin());
}
static RefTrackVector geometryVector(const t3Dd &v) { return {v.x, v.y, v.z}; }
RefTrackVector ref_world_track_bounds(RefWorld *world) {
    return world && world == activeWorld ? geometryVector(world->track->max) : RefTrackVector{};
}
int ref_world_geometry_count(RefWorld *world) {
    return world && world == activeWorld ? static_cast<int>(world->geometry.size()) : 0;
}
const char *ref_world_geometry_name(RefWorld *world, int index) {
    return validGeometry(world, index) ? world->geometry[index]->name : nullptr;
}
const char *ref_world_geometry_material(RefWorld *world, int index) {
    return validGeometry(world, index) ? world->geometry[index]->surface->material : nullptr;
}
int ref_world_geometry_segment(RefWorld *world, int index, RefTrackSegment *out) {
    if (!out || !validGeometry(world, index)) return 0;
    const auto &s = *world->geometry[index]; const auto &surface = *s.surface;
    int main = world->mainIndices[index];
    auto mainSegment = world->geometry[main];
    *out = {s.id, s.type, s.type2, s.style, main, geometryIndex(world, mainSegment->prev), geometryIndex(world, mainSegment->next),
        geometryIndex(world, s.rside), geometryIndex(world, s.lside),
        s.length, s.width, s.startWidth, s.endWidth, s.lgfromstart, s.radius, s.radiusr, s.radiusl, s.arc,
        geometryVector(s.center), geometryVector(s.vertex[TR_SR]), geometryVector(s.vertex[TR_SL]),
        geometryVector(s.vertex[TR_ER]), geometryVector(s.vertex[TR_EL]),
        s.angle[TR_ZS], s.angle[TR_ZE], s.angle[TR_YL], s.angle[TR_YR], s.angle[TR_XS], s.angle[TR_XE], s.angle[TR_CS],
        s.Kzl, s.Kzw, s.Kyl, s.height, s.rgtSideNormal.x, s.rgtSideNormal.y,
        surface.kFriction, surface.kRebound, surface.kRollRes, surface.kRoughness, surface.kRoughWaveLen, surface.kDammage,
        s.raceInfo};
    return 1;
}
int ref_world_track_local(RefWorld *world, RefTrackPosition position, int origin, RefTrackSample *out) {
    if (!out || !validGeometry(world, position.segment) || origin < 0 || origin > 2 ||
        !std::isfinite(position.toStart) || !std::isfinite(position.toRight) ||
        !std::isfinite(position.toMiddle) || !std::isfinite(position.toLeft)) return 0;
    tTrkLocPos p{}; p.seg = world->geometry[position.segment];
    p.toStart = position.toStart; p.toRight = position.toRight; p.toMiddle = position.toMiddle; p.toLeft = position.toLeft;
    RtTrackLocal2Global(&p, &out->x, &out->y, origin);
    out->height = RtTrackHeightL(&p); out->width = RtTrackGetWidth(p.seg, p.toStart);
    out->tangent = RtTrackSideTgAngleL(&p); out->distance = RtGetDistFromStart2(&p);
    t3Dd normal{}, right{}, left{};
    RtTrackSurfaceNormalL(&p, &normal); RtTrackSideNormalG(p.seg, out->x, out->y, TR_RGT, &right);
    RtTrackSideNormalG(p.seg, out->x, out->y, TR_LFT, &left);
    out->normal = geometryVector(normal); out->rightNormal = geometryVector(right); out->leftNormal = geometryVector(left);
    out->effectiveSegment = geometryIndex(world, RtTrackGetSeg(&p));
    return 1;
}
int ref_world_track_global(RefWorld *world, int start, float x, float y, int mode, RefTrackPosition *out) {
    if (!out || !validGeometry(world, start) || world->geometry[start]->type2 != TR_MAIN ||
        !std::isfinite(x) || !std::isfinite(y) || mode < 0 || mode > 2) return 0;
    tTrkLocPos p{}; RtTrackGlobal2Local(world->geometry[start], x, y, &p, mode);
    *out = {geometryIndex(world, p.seg), p.type, p.toStart, p.toRight, p.toMiddle, p.toLeft};
    return 1;
}
int ref_world_track_neighbour(RefWorld *world, int main, int current, int side) {
    if (!validGeometry(world, main) || !validGeometry(world, current) || side < 0 || side > 1) return -1;
    return geometryIndex(world, RtTrackGetSideNeighbourSeg(world->geometry[main], world->geometry[current], side));
}

int ref_world_barrier(RefWorld *world, int segment, int side, RefTrackBarrier *out) {
    if (!out || !validGeometry(world, segment) || side < 0 || side > 1) return 0;
    auto b = world->geometry[segment]->barrier[side];
    if (!b) return 0;
    auto s = b->surface;
    *out = {b->style, b->width, b->height, b->normal.x, b->normal.y,
            s->kFriction, s->kRebound, s->kRollRes, s->kRoughness, s->kRoughWaveLen, s->kDammage};
    return 1;
}
const char *ref_world_barrier_material(RefWorld *world, int segment, int side) {
    if (!validGeometry(world, segment) || side < 0 || side > 1 || !world->geometry[segment]->barrier[side]) return nullptr;
    return world->geometry[segment]->barrier[side]->surface->material;
}
int ref_world_pits(RefWorld *world, RefTrackPits *out) {
    if (!out || !world || world != activeWorld) return 0;
    const auto &p = world->track->pits;
    *out = {p.type, p.side, geometryIndex(world, p.pitEntry), geometryIndex(world, p.pitStart),
            geometryIndex(world, p.pitEnd), geometryIndex(world, p.pitExit), p.nMaxPits, p.len, p.width, p.speedLimit};
    return 1;
}
int ref_world_pit_position(RefWorld *world, int stall, RefTrackPosition *out) {
    if (!out || !world || world != activeWorld || stall < 0 || stall >= world->track->pits.nMaxPits) return 0;
    const auto &p = world->track->pits.driversPits[stall].pos;
    *out = {geometryIndex(world, p.seg), p.type, p.toStart, p.toRight, p.toMiddle, p.toLeft};
    return 1;
}
int ref_world_pit_distance(RefWorld *world, int stall, RefTrackPosition position, float *longitudinal, float *lateral) {
    if (!longitudinal || !lateral || !validGeometry(world, position.segment) || stall < 0 ||
        stall >= world->track->pits.nMaxPits || !std::isfinite(position.toStart) || !std::isfinite(position.toRight)) return 0;
    tCarElt car{};
    car._pit = &world->track->pits.driversPits[stall];
    car._trkPos.seg = world->geometry[position.segment]; car._trkPos.toStart = position.toStart;
    car._trkPos.toRight = position.toRight;
    return RtDistToPit(&car, world->track, longitudinal, lateral) == 0;
}

int ref_world_wheel_ride(RefWorld *world, RefWheelRideInput input, RefWheelRideResult *out) {
    if (!out || !validGeometry(world, input.mainSegment) || world->geometry[input.mainSegment]->type2 != TR_MAIN ||
        input.bellcrank <= 0 || input.dt <= 0) return 0;
    for (auto v : {input.position.x, input.position.y, input.position.z, input.displacement, input.relativeVelocity,
                  input.bellcrank, input.packers, input.maximumTravel, input.brakeCoefficient, input.brakeRadius,
                  input.brakePressure, input.brakeTemperature, input.longitudinalSpeed, input.wheelSpin, input.dt}) {
        if (!std::isfinite(v)) return 0;
    }
    tCar car{};
    car.trkPos.seg = world->geometry[input.mainSegment]; car.DynGC.vel.x = input.longitudinalSpeed;
    auto &wheel = car.wheel[0]; wheel.pos.x = input.position.x; wheel.pos.y = input.position.y; wheel.pos.z = input.position.z;
    wheel.state = input.flags; wheel.susp.x = input.displacement; wheel.rel_vel = input.relativeVelocity;
    wheel.susp.spring.bellcrank = input.bellcrank; wheel.susp.spring.packers = input.packers; wheel.susp.spring.xMax = input.maximumTravel;
    wheel.brake.coeff = input.brakeCoefficient; wheel.brake.radius = input.brakeRadius; wheel.brake.pressure = input.brakePressure;
    wheel.brake.temp = input.brakeTemperature; wheel.spinVel = input.wheelSpin;
    const auto previousDelta = SimDeltaTime; SimDeltaTime = input.dt;
    SimWheelUpdateRide(&car, 0); SimDeltaTime = previousDelta;
    const auto &p = wheel.trkPos;
    *out = {{geometryIndex(world, p.seg), p.type, p.toStart, p.toRight, p.toMiddle, p.toLeft}, geometryVector(wheel.surfaceNormal),
        wheel.zRoad, wheel.rideHeight, wheel.susp.x, wheel.susp.v, wheel.rel_vel, wheel.brake.Tq, wheel.brake.temp, wheel.state, wheel.susp.state};
    return 1;
}

int ref_world_wheel_force(RefWorld *world, RefWheelForceInput in, RefWheelForceResult *out) {
    if (!out || !validGeometry(world, in.mainSegment) || !validGeometry(world, in.contact.segment) ||
        world->geometry[in.mainSegment]->type2 != TR_MAIN || in.wheelIndex < 0 || in.wheelIndex >= 4 ||
        in.skillLevel < 0 || in.skillLevel >= 5 || !(in.dt > 0) || !(in.mass > 0) ||
        !(in.tireWidth > 0) || !(in.operatingLoad > 0) || !(in.suspension.bellcrank > 0) ||
        !std::isfinite(in.steer + in.toe) || std::abs(in.steer + in.toe) >= 65536) return 0;
    tCar car{}; tCarElt elt{}; car.carElt = &elt; elt._skillLevel = in.skillLevel;
    car.trkPos.seg = world->geometry[in.mainSegment];
    auto &w = car.wheel[in.wheelIndex];
    w.trkPos = {world->geometry[in.contact.segment], in.contact.mode, in.contact.toStart,
                in.contact.toRight, in.contact.toMiddle, in.contact.toLeft};
    const auto &c = in.suspension;
    auto &s = w.susp;
    s.spring.K = -c.springRate; s.spring.F0 = c.preload/c.bellcrank;
    s.spring.x0 = c.bellcrank*c.rest; s.spring.xMax = c.travel;
    s.spring.bellcrank = c.bellcrank; s.spring.packers = c.packers;
    s.damper.bump = {c.slowBump, c.bumpThreshold, c.fastBump, (c.slowBump-c.fastBump)*c.bumpThreshold};
    s.damper.rebound = {c.slowRebound, c.reboundThreshold, c.fastRebound, (c.slowRebound-c.fastRebound)*c.reboundThreshold};
    s.x = in.displacement; s.v = in.suspensionVelocity; s.state = in.suspensionFlags;
    w.state = in.flags; w.rel_vel = in.relativeVelocity; w.brake.Tq = in.brakeTorque;
    w.radius = in.radius; w.mass = in.mass; w.tirewidth = in.tireWidth; w.mu = in.friction;
    w.mfB = in.magicB; w.mfC = in.magicC; w.mfE = in.magicE;
    w.lfMin = in.loadMinimum; w.lfMax = in.loadMaximum; w.lfK = in.loadExponent; w.opLoad = in.operatingLoad;
    w.staticPos.ax = in.camber; w.staticPos.ay = in.caster; w.staticPos.az = in.toe;
    w.bodyVel.x = in.bodyVelocityX; w.bodyVel.y = in.bodyVelocityY;
    w.steer = in.steer; w.spinVel = in.spin; w.axleFz = in.axleForce; w.currentGripFactor = in.grip;
    w.preFn = in.previousLateral; w.preFt = in.previousLongitudinal;
    const auto previousDelta = SimDeltaTime; SimDeltaTime = in.dt;
    SimWheelUpdateForce(&car, in.wheelIndex); SimDeltaTime = previousDelta;
    *out = {geometryVector(w.forces), s.force, w.rel_vel, w.relPos.z, w.relPos.ax, w.relPos.az,
            w.spinTq, w.rollRes, w.sa, w.sx, w.tireZForce, w.tireSlip,
            elt._skid[in.wheelIndex], elt._wheelSlipSide(in.wheelIndex), elt._wheelSlipAccel(in.wheelIndex),
            w.feedBack.spinVel, w.feedBack.Tq, w.feedBack.brkTq, w.preFn, w.preFt,
            elt.priv.otherSurfaceContribution[in.wheelIndex], w.state,
            geometryIndex(world, elt.priv.otherSurfaceSeg[in.wheelIndex])};
    return 1;
}

static RefSuspensionSetup readSuspensionSetup(const tSuspension &s) {
    return {s.spring.K, s.spring.F0, s.spring.x0, s.spring.xMax, s.spring.bellcrank, s.spring.packers,
        s.damper.bump.C1, s.damper.bump.C2, s.damper.bump.v1, s.damper.bump.b2,
        s.damper.rebound.C1, s.damper.rebound.C2, s.damper.rebound.v1, s.damper.rebound.b2};
}
static void readRunningGear(const tCar &car, RefRunningGear *out) {
    for (int i = 0; i < 2; ++i) {
        const auto &a = car.axle[i];
        out->axles[i] = {a.xpos, a.I, car.wheel[i*2].rollCenter, a.arbSuspSpringK, readSuspensionSetup(a.thirdSusp)};
    }
    for (int i = 0; i < 4; ++i) {
        const auto &w = car.wheel[i];
        out->wheels[i] = {{w.staticPos.x, w.staticPos.y, w.staticPos.z}, {w.relPos.x, w.relPos.y, w.relPos.z},
            {w.relPos.ax, w.relPos.ay, w.relPos.az}, w.weight0, w.rollCenter, w.I, w.feedBack.I, w.tireSpringRate,
            car.carElt->_rimRadius(i), car.carElt->_tireHeight(i), w.treadThinkness,
            w.radius, w.mass, w.tirewidth, w.mu, w.mfB, w.mfC, w.mfE, w.lfMin, w.lfMax, w.lfK, w.opLoad,
            w.staticPos.ax, w.staticPos.ay, w.staticPos.az, w.brake.coeff, w.brake.radius, w.brake.I, readSuspensionSetup(w.susp),
            {w.pressure, w.initialTemperature, w.idealTemperature, w.treadMass, w.baseMass, w.tireGasMass,
                w.tireConvectionSurface, w.hysteresisFactor, w.wearFactor},
            {w.currentPressure, w.currentTemperature, w.currentGraining, w.currentGripFactor, w.currentWear}};
    }
}
int ref_world_running_gear(RefWorld *world, int index, RefRunningGear *out) {
    if (!out || !world || world != activeWorld || index < 0 || index >= static_cast<int>(world->cars.size())) return 0;
    readRunningGear(SimCarTable[index], out); return 1;
}
int ref_running_gear_xml(const char *xml, RefMassProperties context, RefRunningGear *out) {
    if (activeWorld || !xml || !out || strlen(xml) > 65536 || strstr(xml, "<!DOCTYPE") || strstr(xml, "<!ENTITY")) return 0;
    GfParmInit(); std::string buffer(xml);
    void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    tCar car{}; tCarElt elt{}; car.carElt = &elt; car.params = parameters;
    car.statGC.x = context.cgX; car.statGC.y = context.cgY; car.statGC.z = context.cgZ;
    car.wheel[0].weight0 = context.frontRightLoad; car.wheel[1].weight0 = context.frontLeftLoad;
    car.wheel[2].weight0 = context.rearRightLoad; car.wheel[3].weight0 = context.rearLeftLoad;
    for (int i = 0; i < 2; ++i) SimAxleConfig(&car, i);
    for (int i = 0; i < 4; ++i) SimWheelConfig(&car, i);
    // Same final origin adjustment as SimCarConfig; no component formulas copied.
    for (auto &w : car.wheel) { w.staticPos.x -= car.statGC.x; w.staticPos.y -= car.statGC.y; }
    readRunningGear(car, out);
    GfParmReleaseHandle(parameters); GfParmShutdown(); return 1;
}

static void readRunningGearStep(RefWorld *world, const tCar &car, RefRunningGearStep *out) {
    for (int i = 0; i < 4; ++i) {
        const auto &w = car.wheel[i]; const auto &p = w.trkPos; const auto &e = *car.carElt;
        out->wheels[i] = {{geometryVector(w.pos), w.bodyVel.x, w.bodyVel.y},
            {{geometryIndex(world, p.seg), p.type, p.toStart, p.toRight, p.toMiddle, p.toLeft}, geometryVector(w.surfaceNormal),
                w.zRoad, w.rideHeight, w.susp.x, w.susp.v, w.rel_vel, w.brake.Tq, w.brake.temp, w.state, w.susp.state},
            {geometryVector(w.forces), w.susp.force, w.rel_vel, w.relPos.z, w.relPos.ax, w.relPos.az,
                w.spinTq, w.rollRes, w.sa, w.sx, w.tireZForce, w.tireSlip, e._skid[i], e._wheelSlipSide(i), e._wheelSlipAccel(i),
                w.feedBack.spinVel, w.feedBack.Tq, w.feedBack.brkTq, w.preFn, w.preFt, e.priv.otherSurfaceContribution[i],
                w.state, geometryIndex(world, e.priv.otherSurfaceSeg[i])},
            {w.currentPressure, w.currentTemperature, w.currentGraining, w.currentGripFactor, w.currentWear},
            {w.spinVel, w.prespinVel, w.relPos.ay, w.in.spinVel, e._wheelSpinVel(i)}};
    }
}
static int stepRunningGear(RefWorld *world, RefRunningGearInput in, RefRunningGearStep *out, bool driven) {
    if (!out || !validGeometry(world, in.mainSegment) || world->geometry[in.mainSegment]->type2 != TR_MAIN ||
        in.skillLevel < 0 || in.skillLevel >= 5 || !(in.dt > 0)) return 0;
    world->componentDynamicsStarted = true;
    auto &car = SimCarTable[0];
    car.trkPos.seg = world->geometry[in.mainSegment];
    car.DynGCg.pos.x = in.worldPosition.x; car.DynGCg.pos.y = in.worldPosition.y; car.DynGCg.pos.z = in.worldPosition.z;
    car.DynGC.pos.ax = in.roll; car.DynGC.pos.ay = in.pitch; car.DynGC.pos.az = in.yaw;
    car.DynGC.vel.x = in.bodyVelocity.x; car.DynGC.vel.y = in.bodyVelocity.y; car.DynGC.vel.z = in.bodyVelocity.z;
    car.DynGC.vel.az = in.yawVelocity;
    car.localTemperature = in.localTemperature; car.localPressure = in.localPressure; car.carElt->_skillLevel = in.skillLevel;
    const float pressures[] = {in.brakePressures.frontRight, in.brakePressures.frontLeft, in.brakePressures.rearRight, in.brakePressures.rearLeft};
    const float steer[] = {in.steering.frontRight, in.steering.frontLeft, in.steering.rearRight, in.steering.rearLeft};
    for (int i = 0; i < 4; ++i) { car.wheel[i].brake.pressure = pressures[i]; car.wheel[i].steer = steer[i]; }
    const auto oldDelta = SimDeltaTime, oldFactor = rulesTireFactor;
    SimDeltaTime = in.dt; rulesTireFactor = in.tireFactor;
    SimCarUpdateWheelPos(&car);
    for (int i = 0; i < 4; ++i) SimWheelUpdateRide(&car, i);
    for (int i = 0; i < 2; ++i) SimAxleUpdate(&car, i);
    for (int i = 0; i < 4; ++i) {
        SimWheelUpdateForce(&car, i); SimWheelUpdateTire(&car, i);
        if (in.preSimulation) SimWheelResetWear(&car, i);
    }
    if (driven) { srand(world->powertrainRandomSeed); SimTransmissionUpdate(&car); }
    else { SimUpdateFreeWheels(&car, 0); SimUpdateFreeWheels(&car, 1); }
    SimWheelUpdateRotation(&car);
    SimDeltaTime = oldDelta; rulesTireFactor = oldFactor;
    readRunningGearStep(world,car,out);
    return 1;
}

int ref_world_running_gear_step(RefWorld *world, RefRunningGearInput in, RefRunningGearStep *out) {
    return stepRunningGear(world, in, out, false);
}

static int readEngineSetup(const tCar &car, RefEngineSetup *out, RefEngineCurvePoint *points, int capacity) {
    const auto &e = car.engine;
    if (!out || !points || capacity < e.curve.nbPts) return 0;
    *out = {e.revsLimiter, e.revsMax, e.tickover, e.I, e.fuelcons, e.brakeCoeff,
        e.curve.maxTq, e.curve.maxPw, car.carElt->_enginerpmMaxTq, e.curve.rpmMaxPw, e.curve.TqAtMaxPw, e.curve.nbPts};
    for (int i = 0; i < e.curve.nbPts; ++i) points[i] = {e.curve.data[i].rads, e.curve.data[i].a, e.curve.data[i].b};
    return 1;
}
int ref_world_engine_setup(RefWorld *world, RefEngineSetup *out, RefEngineCurvePoint *points, int capacity) {
    if (!world || world != activeWorld) return 0;
    return readEngineSetup(SimCarTable[0], out, points, capacity);
}
int ref_engine_config_xml(const char *xml, float fuelFactor, RefEngineSetup *out, RefEngineCurvePoint *points, int capacity) {
    if (activeWorld || !xml || !out || !points || strlen(xml) > 65536 || strstr(xml, "<!DOCTYPE") || strstr(xml, "<!ENTITY")) return 0;
    GfParmInit(); std::string buffer(xml); void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    int count = GfParmGetEltNb(parameters, "Engine/data points"), result = 0;
    if (count >= 2 && count <= capacity) {
        tCar car{}; tCarElt elt{}; car.params = parameters; car.carElt = &elt;
        const auto oldFactor = rulesFuelFactor; rulesFuelFactor = fuelFactor;
        SimEngineConfig(&car); rulesFuelFactor = oldFactor;
        result = readEngineSetup(car, out, points, capacity); SimEngineShutdown(&car);
    }
    GfParmReleaseHandle(parameters); GfParmShutdown(); return result;
}
static void setupEngineInput(tCar &car, tCarElt &elt, tCarCtrl &control, const RefEngineInput &in) {
    car.carElt = &elt; car.ctrl = &control;
    car.engine.rads = in.speed; car.engine.Tq = in.torque; car.engine.pressure = in.pressure;
    car.engine.exhaust_pressure = in.exhaustPressure; elt.priv.smoke = in.smoke;
    car.fuel = in.fuel; elt._state = in.carFlags; control.accelCmd = in.throttle;
    car.transmission.curOverallRatio = in.overallRatio; car.transmission.gearbox.gear = in.gear;
    car.transmission.clutch.transferValue = in.clutchTransfer; car.transmission.clutch.state = in.clutchPhase;
}
static RefEngineOutput readEngineOutput(const tCar &car, float reaction) {
    return {car.engine.rads, car.engine.Tq, car.engine.pressure, car.engine.exhaust_pressure, car.carElt->priv.smoke,
        car.fuel, car.transmission.clutch.transferValue, reaction, car.transmission.clutch.state};
}
float ref_uniform_random(unsigned int seed) { srand(seed); return urandom(); }
int ref_world_engine_step(RefWorld *world, RefEngineInput in, RefEngineOutput *out) {
    if (!out || !world || world != activeWorld || !(in.dt > 0)) return 0;
    tCar car{}; tCarElt elt{}; tCarCtrl control{};
    car.engine = SimCarTable[0].engine; // borrow the original configured immutable torque curve
    setupEngineInput(car, elt, control, in);
    const auto oldDelta = SimDeltaTime; SimDeltaTime = in.dt; srand(in.randomSeed);
    if (in.stages & 1) SimEngineUpdateTq(&car);
    const auto reaction = (in.stages & 2) ? SimEngineUpdateRpm(&car, in.axleSpeed) : 0.0f;
    SimDeltaTime = oldDelta; *out = readEngineOutput(car, reaction); return 1;
}
static RefDifferentialConfig readDifferentialConfig(const tDifferential &d) {
    return {d.type, d.I, d.efficiency, d.ratio, d.dTqMin, d.dTqMax, d.dSlipMax,
        d.lockInputTq, d.lockBrakeInputTq, d.viscosity, d.feedBack.I};
}
int ref_differential_config_xml(const char *xml, const char *section, float firstInertia, float secondInertia, RefDifferentialConfig *out) {
    if (activeWorld || !xml || !section || !out || strlen(xml) > 65536 || strstr(xml, "<!DOCTYPE") || strstr(xml, "<!ENTITY")) return 0;
    GfParmInit(); std::string buffer(xml); void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    tDifferential d{}; tDynAxis first{}, second{}; first.I = firstInertia; second.I = secondInertia;
    d.inAxis[0] = &first; d.inAxis[1] = &second; SimDifferentialConfig(parameters, section, &d);
    *out = readDifferentialConfig(d); GfParmReleaseHandle(parameters); GfParmShutdown(); return 1;
}
int ref_world_differential_config(RefWorld *world, int index, RefDifferentialConfig *out) {
    if (!out || !world || world != activeWorld || index < 0 || index > 2) return 0;
    *out = readDifferentialConfig(SimCarTable[0].transmission.differential[index]); return 1;
}
int ref_world_differential_step(RefWorld *world, RefDifferentialConfig c, float driveTorque,
    RefDriveAxis first, RefDriveAxis second, float firstOutputInertia, float secondOutputInertia,
    int primary, RefEngineInput in, RefDifferentialOutput *out) {
    if (!out || !world || world != activeWorld || firstOutputInertia <= 0 || secondOutputInertia <= 0 || in.dt <= 0) return 0;
    tCar car{}; tCarElt elt{}; tCarCtrl control{}; car.engine = SimCarTable[0].engine;
    setupEngineInput(car, elt, control, in);
    tDifferential d{};
    d.type = c.type; d.I = c.inertia; d.efficiency = c.efficiency; d.ratio = c.ratio;
    d.dTqMin = c.minimumTorqueBias; d.dTqMax = c.torqueBiasRange; d.dSlipMax = c.maximumSlipBias;
    d.lockInputTq = c.lockingTorque; d.lockBrakeInputTq = c.brakingLockingTorque; d.viscosity = c.viscosity;
    d.in.Tq = driveTorque;
    tDynAxis a{first.spin,first.torque,first.brakeTorque,first.inertia}, b{second.spin,second.torque,second.brakeTorque,second.inertia};
    tDynAxis x{}, y{}; x.I = firstOutputInertia; y.I = secondOutputInertia;
    d.inAxis[0] = &a; d.inAxis[1] = &b; d.outAxis[0] = &x; d.outAxis[1] = &y;
    const auto oldDelta = SimDeltaTime; SimDeltaTime = in.dt; srand(in.randomSeed);
    SimDifferentialUpdate(&car, &d, primary); SimDeltaTime = oldDelta;
    *out = {{x.spinVel,x.Tq,x.brkTq,x.I},{y.spinVel,y.Tq,y.brkTq,y.I},readEngineOutput(car,0)}; return 1;
}

int ref_engine_configured_step(RefEngineSetup c, const RefEngineCurvePoint *points, int count, RefEngineInput in, RefEngineOutput *out) {
    if (!out || !points || count < 2 || count > 10000 || count != c.curveCount || in.dt <= 0) return 0;
    tCar car{}; tCarElt elt{}; tCarCtrl control{};
    std::vector<tEngineCurveElem> curve;
    for (int i = 0; i < count; ++i) curve.push_back({points[i].limit,points[i].slope,points[i].intercept});
    car.engine.curve.nbPts = count; car.engine.curve.data = curve.data();
    car.engine.revsLimiter = c.limiter; car.engine.revsMax = c.maximumSpeed; car.engine.tickover = c.idleSpeed;
    car.engine.I = c.inertia; car.engine.fuelcons = c.fuelConsumption; car.engine.brakeCoeff = c.brakeCoefficient;
    setupEngineInput(car,elt,control,in);
    const auto oldDelta = SimDeltaTime; SimDeltaTime = in.dt; srand(in.randomSeed);
    if (in.stages & 1) SimEngineUpdateTq(&car);
    const auto reaction = (in.stages & 2) ? SimEngineUpdateRpm(&car,in.axleSpeed) : 0.0f;
    SimDeltaTime = oldDelta; *out = readEngineOutput(car,reaction); return 1;
}

static RefDriveAxis readDriveAxis(const tDynAxis &a) { return {a.spinVel,a.Tq,a.brkTq,a.I}; }
int ref_world_transmission_setup(RefWorld *world, RefTransmissionSetup *out) {
    if (!out || !world || world != activeWorld) return 0;
    const auto &car = SimCarTable[0]; const auto &t = car.transmission;
    out->layout = t.type; out->minimumGear = t.gearbox.gearMin; out->maximumGear = t.gearbox.gearMax;
    out->gearOffset = car.carElt->priv.gearOffset; out->gearCount = car.carElt->priv.gearNb; out->shiftTime = t.clutch.releaseTime;
    for (int i = 0; i < MAX_GEARS; ++i) out->gears[i] = {t.overallRatio[i],t.driveI[i],t.freeI[i],t.gearEff[i]};
    for (int i = 0; i < 3; ++i) out->differentials[i] = readDifferentialConfig(t.differential[i]);
    return 1;
}
int ref_world_transmission_state(RefWorld *world, RefTransmissionState *out) {
    if (!out || !world || world != activeWorld) return 0;
    const auto &car = SimCarTable[0]; const auto &t = car.transmission;
    out->gear = t.gearbox.gear; out->clutchPhase = t.clutch.state; out->clutchTransfer = t.clutch.transferValue;
    out->timeToRelease = t.clutch.timeToRelease; out->currentRatio = t.curOverallRatio; out->currentInertia = t.curI;
    out->throttle = car.ctrl->accelCmd;
    for (int i = 0; i < 4; ++i) out->wheelInputs[i] = readDriveAxis(car.wheel[i].in);
    for (int i = 0; i < 3; ++i) {
        out->differentialInputs[i] = readDriveAxis(t.differential[i].in);
        out->differentialFeedback[i] = readDriveAxis(t.differential[i].feedBack);
    }
    out->engine = readEngineOutput(car,0); return 1;
}
int ref_world_configure_transmission_xml(RefWorld *world, const char *xml) {
    if (!world || world != activeWorld || world->componentDynamicsStarted || world->tick != 0 ||
        !xml || strlen(xml) > 65536 || strstr(xml,"<!DOCTYPE") || strstr(xml,"<!ENTITY")) return 0;
    std::string buffer(xml); void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) return 0;
    const char *layout = GfParmGetStr(parameters,SECT_DRIVETRAIN,PRM_TYPE,VAL_TRANS_RWD);
    if (strcmp(layout,VAL_TRANS_RWD) && strcmp(layout,VAL_TRANS_FWD) && strcmp(layout,VAL_TRANS_4WD)) {
        GfParmReleaseHandle(parameters); return 0;
    }
    auto &car = SimCarTable[0]; void *originalParameters = car.params;
    car.params = parameters;
    memset(&car.transmission,0,sizeof(car.transmission));
    for (auto &wheel : car.wheel) memset(&wheel.in,0,sizeof(wheel.in));
    SimTransmissionConfig(&car);
    car.params = originalParameters; GfParmReleaseHandle(parameters); return 1;
}
int ref_world_powertrain_prepare(RefWorld *world, RefPowertrainControl in, RefTransmissionState *out) {
    if (!out || !world || world != activeWorld || !(in.dt > 0)) return 0;
    world->componentDynamicsStarted = true; world->powertrainRandomSeed = in.randomSeed;
    auto &car = SimCarTable[0]; car.ctrl->gear = in.requestedGear; car.ctrl->accelCmd = in.throttle;
    car.transmission.clutch.transferValue = in.clutchTransfer; car.carElt->_state = in.carFlags;
    const auto oldDelta = SimDeltaTime; SimDeltaTime = in.dt;
    SimGearboxUpdate(&car); if (in.updateEngineTorque) SimEngineUpdateTq(&car);
    SimDeltaTime = oldDelta; return ref_world_transmission_state(world,out);
}
int ref_world_driven_gear_step(RefWorld *world, RefRunningGearInput in, RefRunningGearStep *wheels, RefTransmissionState *out) {
    if (!out || !stepRunningGear(world,in,wheels,true)) return 0;
    return ref_world_transmission_state(world,out);
}

static RefWingSetup readWingSetup(const tWing &w) { return {w.angle,w.Kx,w.Kz,geometryVector(w.staticPos)}; }
static RefAeroSetup readAeroSetup(const tCar &car) {
    return {car.aero.SCx2,car.aero.Cd,car.aero.Clift[0],car.aero.Clift[1],readWingSetup(car.wing[0]),readWingSetup(car.wing[1])};
}
int ref_world_aero_setup(RefWorld *world, RefAeroSetup *out) {
    if (!out || !world || world != activeWorld) return 0;
    *out = readAeroSetup(SimCarTable[0]); return 1;
}
int ref_aero_config_xml(const char *xml, float centerOfGravityX, RefAeroSetup *out) {
    if (!out || activeWorld || !xml || strlen(xml)>65536 || strstr(xml,"<!DOCTYPE") || strstr(xml,"<!ENTITY")) return 0;
    std::string buffer(xml); GfParmInit(); void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    tCar car{}; car.params = parameters; car.statGC.x = centerOfGravityX;
    SimAeroConfig(&car); SimWingConfig(&car,0); SimWingConfig(&car,1);
    *out = readAeroSetup(car); GfParmReleaseHandle(parameters); GfParmShutdown(); return 1;
}
int ref_aero_step(RefAeroSetup setup, const RefAeroInput *inputs, int count, int index, RefAeroOutput *out) {
    if (!inputs || !out || count<1 || count>16 || index<0 || index>=count) return 0;
    std::vector<tCar> cars(count); std::vector<tCarElt> elements(count);
    for (int i=0;i<count;++i) {
        const auto &in = inputs[i]; auto &car = cars[i];
        if (!std::isfinite(in.yaw) || fabs(in.yaw)>=65536) return 0;
        car.carElt = &elements[i]; elements[i].index = i;
        car.DynGCg.pos.x = in.position.x; car.DynGCg.pos.y = in.position.y; car.DynGCg.pos.az = in.yaw;
        car.DynGCg.vel.x = in.worldVelocity.x; car.DynGCg.vel.y = in.worldVelocity.y;
        car.DynGC.vel.x = in.bodyVelocity.x; car.DynGC.vel.y = in.bodyVelocity.y; car.DynGC.vel.z = in.bodyVelocity.z;
        car.speed = in.speed; car.dammage = in.damage; car.aero.Cd = in.draftingCoefficient;
        const float heights[] = {in.rideHeights.frontRight,in.rideHeights.frontLeft,in.rideHeights.rearRight,in.rideHeights.rearLeft};
        for (int w=0;w<4;++w) car.wheel[w].rideHeight = heights[w];
    }
    auto &car = cars[index]; car.aero.SCx2 = setup.bodyDragCoefficient; car.aero.Cd = setup.draftingCoefficient;
    car.aero.Clift[0] = setup.frontLift; car.aero.Clift[1] = setup.rearLift;
    const RefWingSetup wings[] = {setup.frontWing,setup.rearWing};
    for (int i=0;i<2;++i) { car.wing[i].angle = wings[i].angle; car.wing[i].Kx = wings[i].dragCoefficient; car.wing[i].Kz = wings[i].liftCoefficient; }
    auto *savedTable = SimCarTable; SimCarTable = cars.data();
    tSituation situation{}; situation._ncars = count;
    SimAeroUpdate(&car,&situation); SimWingUpdate(&car,0,&situation); SimWingUpdate(&car,1,&situation);
    SimCarTable = savedTable;
    *out = {car.airSpeed2,car.aero.drag,car.aero.lift[0],car.aero.lift[1],geometryVector(car.wing[0].forces),geometryVector(car.wing[1].forces)};
    return 1;
}

static tDynPt chassisDynamics(RefChassisDynamics d) {
    return {{d.position.x,d.position.y,d.position.z,d.orientation.x,d.orientation.y,d.orientation.z},
        {d.velocity.x,d.velocity.y,d.velocity.z,d.angularVelocity.x,d.angularVelocity.y,d.angularVelocity.z},
        {d.acceleration.x,d.acceleration.y,d.acceleration.z,d.angularAcceleration.x,d.angularAcceleration.y,d.angularAcceleration.z}};
}
static RefChassisDynamics readChassisDynamics(const tDynPt &d) {
    return {{d.pos.x,d.pos.y,d.pos.z},{d.pos.ax,d.pos.ay,d.pos.az},{d.vel.x,d.vel.y,d.vel.z},
        {d.vel.ax,d.vel.ay,d.vel.az},{d.acc.x,d.acc.y,d.acc.z},{d.acc.ax,d.acc.ay,d.acc.az}};
}
int ref_world_chassis_corners(RefWorld *world, RefTrackVector *corners, int capacity) {
    if (!world || world != activeWorld || !corners || capacity<4) return 0;
    for (int i=0;i<4;++i) { const auto &p = SimCarTable[0].corner[i].pos; corners[i] = {p.x,p.y,p.z}; }
    return 1;
}
static void readChassisOutput(RefWorld *world, const tCar &car, RefChassisOutput *out) {
    out->body = readChassisDynamics(car.DynGC); out->world = readChassisDynamics(car.DynGCg); out->previousWorld = readChassisDynamics(car.preDynGC);
    for (int i=0;i<4;++i) {
        const auto &c = car.corner[i]; out->corners[i] = {{c.pos.ax,c.pos.ay,c.pos.az},{c.vel.ax,c.vel.ay,c.vel.az},{c.vel.x,c.vel.y,c.vel.z}};
    }
    const auto &p = car.trkPos; out->trackPosition = {geometryIndex(world,p.seg),p.type,p.toStart,p.toRight,p.toMiddle,p.toLeft};
    out->speed = car.speed;
}
int ref_world_chassis_step(RefWorld *world, RefChassisInput in, RefChassisOutput *out) {
    if (!out || !validGeometry(world,in.mainSegment) || world->geometry[in.mainSegment]->type2 != TR_MAIN ||
        !(in.dt>0) || !std::isfinite(in.dt) || !std::isfinite(in.world.orientation.z) ||
        fabs(in.world.orientation.z)>=65536) return 0;
    // Clone configured mechanical state; no pointer-referenced subsystem is changed.
    // SimCarUpdate's original environment functions return immediately for NO_SIMU.
    // Calling SimCarUpdate directly still runs its unchanged integration stages.
    tCar car = SimCarTable[0]; tCarElt element = *car.carElt; car.carElt = &element;
    element._state |= RM_CAR_STATE_NO_SIMU;
    car.DynGC = chassisDynamics(in.body); car.DynGCg = chassisDynamics(in.world);
    car.fuel = in.fuel; car.speed = in.speed; car.Cosz = in.cachedYawCosine; car.Sinz = in.cachedYawSine;
    car.trkPos.seg = world->geometry[in.mainSegment];
    for (int i=0;i<4;++i) {
        car.wheel[i].forces = {in.wheels[i].force.x,in.wheels[i].force.y,in.wheels[i].force.z};
        car.wheel[i].rideHeight = in.wheels[i].rideHeight; car.wheel[i].rollRes = in.wheels[i].rollingResistance;
    }
    car.aero.drag = in.aero.drag; car.aero.lift[0] = in.aero.frontLift; car.aero.lift[1] = in.aero.rearLift;
    car.wing[0].forces = {in.aero.frontWing.x,in.aero.frontWing.y,in.aero.frontWing.z};
    car.wing[1].forces = {in.aero.rearWing.x,in.aero.rearWing.y,in.aero.rearWing.z};
    const auto oldDelta = SimDeltaTime; SimDeltaTime = in.dt;
    SimCarUpdate(&car,&world->situation); SimDeltaTime = oldDelta;
    readChassisOutput(world,car,out); return 1;
}

int ref_world_vehicle_initialize(RefWorld *world, RefChassisInput in) {
    if (!validGeometry(world,in.mainSegment) || world->componentDynamicsStarted || world->tick!=0 || world->cars.size()!=1 ||
        world->geometry[in.mainSegment]->type2 != TR_MAIN) return 0;
    auto &car = SimCarTable[0]; car.DynGC = chassisDynamics(in.body); car.DynGCg = chassisDynamics(in.world);
    car.fuel = in.fuel; car.speed = in.speed; car.Cosz = in.cachedYawCosine; car.Sinz = in.cachedYawSine;
    car.trkPos.seg = world->geometry[in.mainSegment];
    return 1;
}
static RefCollisionState readCollision(const tCar &car) {
    return {static_cast<unsigned int>(car.collision),car.blocked,car.dammage,geometryVector(car.normal),geometryVector(car.collpos)};
}
static int stepVehicle(RefWorld *world, RefVehicleControl in, float damageFactor, bool environment, RefVehicleOutput *out) {
    if (!out || !world || world!=activeWorld || world->cars.size()!=1 || in.skillLevel<0 || in.skillLevel>=5 ||
        !in.powertrain.updateEngineTorque || !(in.powertrain.dt>0)) return 0;
    if (!ref_world_powertrain_prepare(world,in.powertrain,&out->powertrain)) return 0;
    auto &car = SimCarTable[0]; car.collision = 0; car.blocked = 0;
    SimAeroUpdate(&car,&world->situation); SimWingUpdate(&car,0,&world->situation); SimWingUpdate(&car,1,&world->situation);
    out->aero = {car.airSpeed2,car.aero.drag,car.aero.lift[0],car.aero.lift[1],geometryVector(car.wing[0].forces),geometryVector(car.wing[1].forces)};
    RefRunningGearInput wheels{};
    wheels.worldPosition = {car.DynGCg.pos.x,car.DynGCg.pos.y,car.DynGCg.pos.z};
    wheels.bodyVelocity = {car.DynGC.vel.x,car.DynGC.vel.y,car.DynGC.vel.z};
    wheels.roll = car.DynGC.pos.ax; wheels.pitch = car.DynGC.pos.ay; wheels.yaw = car.DynGC.pos.az; wheels.yawVelocity = car.DynGC.vel.az;
    wheels.mainSegment = geometryIndex(world,car.trkPos.seg); wheels.brakePressures = in.brakePressures; wheels.steering = in.steering;
    wheels.localTemperature = in.localTemperature; wheels.localPressure = in.localPressure; wheels.tireFactor = in.tireFactor;
    wheels.skillLevel = in.skillLevel; wheels.preSimulation = in.preSimulation; wheels.dt = in.powertrain.dt;
    if (!stepRunningGear(world,wheels,&out->wheels,true)) return 0;
    const auto oldDelta = SimDeltaTime, oldDamageFactor = rulesDamageFactor; const auto oldState = car.carElt->_state;
    SimDeltaTime = in.powertrain.dt; rulesDamageFactor = damageFactor;
    if (!environment) car.carElt->_state |= RM_CAR_STATE_NO_SIMU;
    SimCarUpdate(&car,&world->situation);
    car.carElt->_state = oldState; SimDeltaTime = oldDelta; rulesDamageFactor = oldDamageFactor;
    readChassisOutput(world,car,&out->chassis); out->collision = readCollision(car);
    return ref_world_transmission_state(world,&out->powertrain);
}

int ref_world_vehicle_step_without_collision(RefWorld *world, RefVehicleControl in, RefVehicleOutput *out) {
    return stepVehicle(world,in,1,false,out);
}
int ref_world_vehicle_step(RefWorld *world, RefVehicleControl in, float damageFactor, RefVehicleOutput *out) {
    return stepVehicle(world,in,damageFactor,true,out);
}
int ref_world_environment_step(RefWorld *world, RefEnvironmentInput in, RefEnvironmentOutput *out) {
    const auto &p = in.chassis.trackPosition;
    if (!out || !validGeometry(world,p.segment) || world->geometry[p.segment]->type2 != TR_MAIN || in.skillLevel<0 || in.skillLevel>=5) return 0;
    tCar car = SimCarTable[0]; tCarElt element = *car.carElt; car.carElt = &element;
    element._state = in.carFlags; element._skillLevel = in.skillLevel;
    car.DynGC = chassisDynamics(in.chassis.body); car.DynGCg = chassisDynamics(in.chassis.world); car.preDynGC = chassisDynamics(in.chassis.previousWorld);
    car.speed = in.chassis.speed; car.trkPos = {world->geometry[p.segment],p.mode,p.toStart,p.toRight,p.toMiddle,p.toLeft};
    car.collision = in.collision.flags; car.blocked = in.collision.blocked; car.dammage = in.collision.damage;
    car.normal = {in.collision.normal.x,in.collision.normal.y,in.collision.normal.z};
    car.collpos = {in.collision.position.x,in.collision.position.y,in.collision.position.z};
    for (int i=0;i<4;++i) {
        const auto &c = in.chassis.corners[i]; auto &dst = car.corner[i];
        dst.pos.ax = c.position.x; dst.pos.ay = c.position.y; dst.pos.az = c.position.z;
        dst.vel = {c.worldVelocity.x,c.worldVelocity.y,c.worldVelocity.z,c.bodyVelocity.x,c.bodyVelocity.y,c.bodyVelocity.z};
    }
    const auto oldDamageFactor = rulesDamageFactor; rulesDamageFactor = in.damageFactor;
    if (in.stages&1) SimCarCollideZ(&car);
    if (in.stages&2) SimCarCollideXYScene(&car);
    rulesDamageFactor = oldDamageFactor;
    readChassisOutput(world,car,&out->chassis); out->collision = readCollision(car); return 1;
}

static RefDriverCommand readDriverCommand(const tCarCtrl &c) {
    return {c.accelCmd,c.brakeCmd,c.steer,c.clutchCmd,c.gear,c.brakeRepartitionCmd};
}
static RefDriverSetup readDriverSetup(const tCar &car) {
    return {car.steer.steerLock,car.steer.maxSpeed,car.brkSyst.rep,car.brkSyst.coeff,car.brkSyst.repCmdClickValue,car.brkSyst.repCmdMaxClicks};
}
int ref_driver_config_xml(const char *xml, RefDriverSetup *out) {
    if (!out || activeWorld || !xml || strlen(xml)>65536 || strstr(xml,"<!DOCTYPE") || strstr(xml,"<!ENTITY")) return 0;
    std::string buffer(xml); GfParmInit(); void *parameters = GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    tCar car{}; tCarElt element{}; car.carElt = &element; car.params = parameters;
    SimSteerConfig(&car); SimBrakeSystemConfig(&car); *out = readDriverSetup(car);
    GfParmReleaseHandle(parameters); GfParmShutdown(); return 1;
}
int ref_world_driver_setup(RefWorld *world, RefDriverSetup *out) {
    if (!out || !world || world!=activeWorld) return 0;
    *out = readDriverSetup(SimCarTable[0]); return 1;
}
int ref_world_simulation_step(RefWorld *world, RefDriverCommand in, unsigned int flags, unsigned int raceState,
    unsigned int seed, float damageFactor, float tireFactor, RefSimulationOutput *out) {
    if (!out || !world || world!=activeWorld || world->cars.size()!=1) return 0;
    auto &car = SimCarTable[0]; auto &c = *car.ctrl;
    c.accelCmd = in.throttle; c.brakeCmd = in.brake; c.steer = in.steering; c.clutchCmd = in.clutch;
    c.gear = in.gear; c.brakeRepartitionCmd = in.brakeRepartitionClicks; car.carElt->_state = flags;
    world->componentDynamicsStarted = true; world->situation._raceState = raceState;
    world->situation.currentTime = ++world->tick*RCM_MAX_DT_SIMU;
    const auto oldDamage = rulesDamageFactor, oldTire = rulesTireFactor;
    rulesDamageFactor = damageFactor; rulesTireFactor = tireFactor; srand(seed);
    SimUpdate(&world->situation,RCM_MAX_DT_SIMU,-1);
    rulesDamageFactor = oldDamage; rulesTireFactor = oldTire;
    auto &v = out->vehicle;
    readChassisOutput(world,car,&v.chassis); readRunningGearStep(world,car,&v.wheels);
    ref_world_transmission_state(world,&v.powertrain); v.collision = readCollision(car);
    v.aero = {car.airSpeed2,car.aero.drag,car.aero.lift[0],car.aero.lift[1],geometryVector(car.wing[0].forces),geometryVector(car.wing[1].forces)};
    out->command = readDriverCommand(c); out->steeringAngle = car.steer.steer; out->localTemperature = car.localTemperature; out->localPressure = car.localPressure;
    out->brakePressures = {car.wheel[0].brake.pressure,car.wheel[1].brake.pressure,car.wheel[2].brake.pressure,car.wheel[3].brake.pressure};
    out->carFlags = car.carElt->_state; return 1;
}

int ref_random_sequence(unsigned int seed, float *values, int count) {
    if (activeWorld || !values || count < 1 || count > 200000) return 0;
    srand(seed); for (int i=0;i<count;++i) values[i] = urandom(); return 1;
}

// Response-stage oracles use temporary registered SOLID objects. Detection is
// not invoked here; the supplied double contact data goes to original callbacks.
extern void ref_call_pair_response(tCar*,tCar*,const DtCollData*);
extern void ref_call_wall_response(tCar*,const DtCollData*,bool);
static void fillObjectBody(tCar &car,tCarElt &element,RefObjectBody in) {
    car.carElt = &element; element.index = in.index; element._state = in.carFlags; element._skillLevel = in.skillLevel;
    car.Minv = in.inverseMass; car.Iinv.z = in.inverseYawInertia;
    car.statGC = {in.centerOfGravity.x,in.centerOfGravity.y,in.centerOfGravity.z}; element._statGC = car.statGC;
    car.DynGCg.pos.x = in.position.x; car.DynGCg.pos.y = in.position.y; car.DynGCg.pos.z = in.position.z;
    car.DynGCg.vel.x = in.velocity.x; car.DynGCg.vel.y = in.velocity.y; car.DynGCg.vel.z = in.velocity.z; car.DynGCg.vel.az = in.yawVelocity;
    element._roll = in.publicOrientation.x; element._pitch = in.publicOrientation.y; element._yaw = in.publicOrientation.z;
    car.VelColl.x = in.accumulated.x; car.VelColl.y = in.accumulated.y; car.VelColl.az = in.accumulated.z;
    car.collision = in.collision.flags; car.blocked = in.collision.blocked; car.dammage = in.collision.damage;
    car.normal = {in.collision.normal.x,in.collision.normal.y,in.collision.normal.z};
    car.collpos = {in.collision.position.x,in.collision.position.y,in.collision.position.z};
    sgMakeCoordMat4(element.pub.posMat,in.transformPosition.x,in.transformPosition.y,in.transformPosition.z,
        RAD2DEG(in.transformOrientation.z),RAD2DEG(in.transformOrientation.x),RAD2DEG(in.transformOrientation.y));
    car.shape = dtBox(1,1,1); dtCreateObject(&car,car.shape);
}
static DtCollData objectContact(RefObjectContact in) {
    DtCollData data{};
    data.point1[0] = in.firstPoint.x; data.point1[1] = in.firstPoint.y; data.point1[2] = in.firstPoint.z;
    data.point2[0] = in.secondPoint.x; data.point2[1] = in.secondPoint.y; data.point2[2] = in.secondPoint.z;
    data.normal[0] = in.normal.x; data.normal[1] = in.normal.y; data.normal[2] = in.normal.z;
    return data;
}
static void readObjectResponse(tCar &car,RefObjectResponse *out) {
    out->position = {car.DynGCg.pos.x,car.DynGCg.pos.y,car.DynGCg.pos.z};
    out->velocity = {car.DynGCg.vel.x,car.DynGCg.vel.y,car.DynGCg.vel.z}; out->yawVelocity = car.DynGCg.vel.az;
    out->accumulated = {car.VelColl.x,car.VelColl.y,car.VelColl.az}; out->collision = readCollision(car);
    memcpy(out->transform,car.carElt->_posMat,sizeof(out->transform));
}
static void releaseObjectBody(tCar &car) { dtDeleteObject(&car); dtDeleteShape(car.shape); }
static bool validObjectBody(RefObjectBody body) { return body.skillLevel>=0 && body.skillLevel<5 && body.inverseMass>0 && body.inverseYawInertia>=0; }
int ref_object_pair_response(RefObjectBody first,RefObjectBody second,RefObjectContact contact,float damageFactor,RefObjectResponse *firstOut,RefObjectResponse *secondOut) {
    if (activeWorld || !firstOut || !secondOut || first.index==second.index || !validObjectBody(first) || !validObjectBody(second) || !std::isfinite(damageFactor)) return 0;
    tCar a{},b{}; tCarElt ea{},eb{}; fillObjectBody(a,ea,first); fillObjectBody(b,eb,second);
    const auto previous = rulesDamageFactor; rulesDamageFactor = damageFactor; const auto data = objectContact(contact);
    ref_call_pair_response(&a,&b,&data); rulesDamageFactor = previous;
    readObjectResponse(a,firstOut); readObjectResponse(b,secondOut); releaseObjectBody(a); releaseObjectBody(b); return 1;
}
int ref_object_wall_response(RefObjectBody body,RefObjectContact contact,int wallFirst,float damageFactor,RefObjectResponse *out) {
    if (activeWorld || !out || !validObjectBody(body) || !std::isfinite(damageFactor)) return 0;
    tCar car{}; tCarElt element{}; fillObjectBody(car,element,body);
    const auto previous = rulesDamageFactor; rulesDamageFactor = damageFactor; const auto data = objectContact(contact);
    ref_call_wall_response(&car,&data,wallFirst!=0); rulesDamageFactor = previous;
    readObjectResponse(car,out); releaseObjectBody(car); return 1;
}
int ref_object_response_sequence(const RefObjectBody *bodies,int bodyCount,const RefObjectEvent *events,int eventCount,RefObjectResponse *outputs,int capacity) {
    if (activeWorld || !bodies || !events || !outputs || bodyCount<1 || bodyCount>16 || eventCount<1 || eventCount>10000 || capacity<bodyCount*eventCount) return 0;
    for (int i=0;i<bodyCount;++i) {
        if (!validObjectBody(bodies[i])) return 0;
        for (int j=0;j<i;++j) if (bodies[i].index==bodies[j].index) return 0;
    }
    for (int i=0;i<eventCount;++i) {
        const auto &e = events[i];
        if (e.kind<0 || e.kind>1 || e.first<0 || e.first>=bodyCount || e.second<0 || e.second>=bodyCount ||
            (!e.kind && e.first==e.second) || !std::isfinite(e.damageFactor)) return 0;
    }
    std::vector<tCar> cars(bodyCount); std::vector<tCarElt> elements(bodyCount);
    for (int i=0;i<bodyCount;++i) fillObjectBody(cars[i],elements[i],bodies[i]);
    const auto previous = rulesDamageFactor;
    for (int i=0;i<eventCount;++i) {
        const auto &e = events[i];
        if (e.resetBefore) for (auto &car:cars) {
            car.collision = 0; car.blocked = 0;
            if (!(car.carElt->_state & RM_CAR_STATE_NO_SIMU)) memset(&car.VelColl,0,sizeof(car.VelColl));
        }
        const auto contact = objectContact(e.contact); rulesDamageFactor = e.damageFactor;
        if (e.kind==0) ref_call_pair_response(&cars[e.first],&cars[e.second],&contact);
        else ref_call_wall_response(&cars[e.first],&contact,e.wallFirst!=0);
        if (e.commitAfter) for (auto &car:cars) {
            if (!(car.carElt->_state & RM_CAR_STATE_NO_SIMU) && (car.collision & SEM_COLLISION_CAR)) {
                car.DynGCg.vel.x = car.VelColl.x; car.DynGCg.vel.y = car.VelColl.y; car.DynGCg.vel.az = car.VelColl.az;
            }
        }
        for (int j=0;j<bodyCount;++j) readObjectResponse(cars[j],&outputs[i*bodyCount+j]);
    }
    rulesDamageFactor = previous;
    for (auto &car:cars) releaseObjectBody(car);
    return 1;
}

extern void ref_call_remove_car(tCar*,tSituation*);
int ref_world_removal_step(RefWorld *world,RefRemovalState in,RefRemovalState *out) {
    if (!out || !validGeometry(world,in.trackPosition.segment) || in.dt<=0 || !std::isfinite(in.dt)) return 0;
    if ((in.flags & RM_CAR_STATE_PIT) && in.maximumDamage && in.damage>in.maximumDamage && !in.hasPit) return 0;
    auto &car = SimCarTable[0]; auto &elt = *car.carElt;
    if (in.registered && !car.shape) SimCarCollideConfig(&car,world->track);
    else if (!in.registered && car.shape) SimCollideRemoveCar(&car,world->cars.size());
    tTrackOwnPit pit{}; pit.pitCarIndex = in.pitOccupant;
    auto oldPit = elt._pit; elt._pit = in.hasPit ? &pit : nullptr;
    car.DynGC = chassisDynamics(in.mechanicalBody); elt.pub.DynGC = chassisDynamics(in.publicBody); car.restPos = chassisDynamics(in.parking);
    car.trkPos = {}; car.trkPos.seg = world->geometry[in.trackPosition.segment]; car.trkPos.type = in.trackPosition.mode;
    car.trkPos.toStart = in.trackPosition.toStart; car.trkPos.toRight = in.trackPosition.toRight;
    car.trkPos.toMiddle = in.trackPosition.toMiddle; car.trkPos.toLeft = in.trackPosition.toLeft;
    elt._state = in.flags; elt._statGC_z = in.cgHeight; car.dammage = in.damage;
    car.transmission.gearbox.gear = in.gear; elt._gear = in.publishedGear;
    car.engine.rads = in.engineRPM; elt._enginerpm = in.publishedRPM;
    car.collision = in.collision; elt.priv.collision = in.publishedCollision; elt.priv.simcollision = in.publishedSimCollision;
    memcpy(elt.pub.posMat,in.matrix,sizeof(in.matrix));
    for (int i=0;i<4;++i) { elt._skid[i] = in.skid[i]; elt._wheelSpinVel(i) = in.spin[i]; elt._brakeTemp(i) = in.brakeTemperature[i]; }
    tSituation situation{}; situation._ncars = world->cars.size(); situation._maxDammage = in.maximumDamage;
    SimDeltaTime = in.dt; ref_call_remove_car(&car,&situation);
    *out = in; out->publicBody = readChassisDynamics(elt.pub.DynGC); out->mechanicalBody = readChassisDynamics(car.DynGC); out->parking = readChassisDynamics(car.restPos);
    out->flags = elt._state; out->gear = car.transmission.gearbox.gear; out->publishedGear = elt._gear;
    out->engineRPM = car.engine.rads; out->publishedRPM = elt._enginerpm;
    out->collision = car.collision; out->publishedCollision = elt.priv.collision; out->publishedSimCollision = elt.priv.simcollision;
    out->registered = car.shape != nullptr; out->pitOccupant = pit.pitCarIndex;
    memcpy(out->matrix,elt.pub.posMat,sizeof(out->matrix));
    for (int i=0;i<4;++i) { out->skid[i] = elt._skid[i]; out->spin[i] = elt._wheelSpinVel(i); out->brakeTemperature[i] = elt._brakeTemp(i); }
    elt._pit = oldPit; return 1;
}

int ref_world_status(RefWorld *world,int index,unsigned int mask,unsigned int flags,float fuel,int damage,int pitOccupant,int maximumDamage) {
    if (!world || world!=activeWorld || index<0 || index>=static_cast<int>(world->cars.size()) ||
        ((mask & 2) && (!std::isfinite(fuel) || fuel<0))) return 0;
    auto &car=SimCarTable[index];
    if (mask & 1) car.carElt->_state=flags;
    if (mask & 2) car.fuel=fuel;
    if (mask & 4) car.dammage=damage;
    if (mask & 8) { world->assignedPits[index].pitCarIndex=pitOccupant; car.carElt->_pit=&world->assignedPits[index]; }
    world->situation._maxDammage=maximumDamage;
    return 1;
}
int ref_world_read_lifecycle(RefWorld *world,int index,RefLifecycleOutput *output) {
    if (!world || world!=activeWorld || !output || index<0 || index>=static_cast<int>(world->cars.size())) return 0;
    const auto &car=SimCarTable[index]; const auto &elt=*car.carElt;
    *output={}; auto &out=output->removal;
    out.publicBody=readChassisDynamics(elt.pub.DynGC); out.mechanicalBody=readChassisDynamics(car.DynGC); out.parking=readChassisDynamics(car.restPos);
    out.flags=elt._state; out.collision=car.collision; out.publishedCollision=elt.priv.collision; out.publishedSimCollision=elt.priv.simcollision;
    out.damage=car.dammage; out.maximumDamage=world->situation._maxDammage; out.gear=car.transmission.gearbox.gear; out.publishedGear=elt._gear;
    out.registered=car.shape!=nullptr; out.hasPit=elt._pit!=nullptr; out.pitOccupant=elt._pit ? elt._pit->pitCarIndex : 0;
    out.cgHeight=elt._statGC_z; out.engineRPM=car.engine.rads; out.publishedRPM=elt._enginerpm;
    memcpy(out.matrix,elt.pub.posMat,sizeof(out.matrix));
    for (int i=0;i<4;++i) { out.skid[i]=elt._skid[i]; out.spin[i]=elt._wheelSpinVel(i); out.brakeTemperature[i]=elt._brakeTemp(i); }
    output->publicWorld=readChassisDynamics(elt.pub.DynGCg); output->publicSpeed=elt.pub.speed; output->publishedFuel=elt._fuel;
    output->publishedDamage=elt._dammage; output->blocked=car.blocked;
    return 1;
}

int ref_world_random_tail(RefWorld *world,float *values,int count) {
    if (!world || world!=activeWorld || !values || count<1 || count>1000) return 0;
    for (int i=0;i<count;++i) values[i]=urandom();
    return 1;
}

static std::vector<tCarPitSetupValue*> pitEntries(tCarPitSetup &s) {
    std::vector<tCarPitSetupValue*> values{&s.steerLock};
    for (auto group:{s.wheelcamber,s.wheeltoe,s.wheelrideheight,s.wheelcaster}) for (int i=0;i<4;++i) values.push_back(&group[i]);
    values.push_back(&s.brakePressure); values.push_back(&s.brakeRepartition);
    for (auto group:{s.suspspring,s.susppackers,s.suspslowbump,s.suspslowrebound,s.suspfastbump,s.suspfastrebound,s.suspbumpthreshold,s.suspreboundthreshold}) for (int i=0;i<4;++i) values.push_back(&group[i]);
    for (auto group:{s.arbspring,s.thirdspring,s.thirdbump,s.thirdrebound,s.thirdX0}) for (int i=0;i<2;++i) values.push_back(&group[i]);
    for (auto &v:s.gearsratio) values.push_back(&v);
    for (auto &v:s.wingangle) values.push_back(&v);
    for (auto group:{s.diffratio,s.diffmintqbias,s.diffmaxtqbias,s.diffslipbias,s.difflockinginputtq,s.difflockinginputbraketq}) for (int i=0;i<3;++i) values.push_back(&group[i]);
    return values;
}
static tCarPitSetup pitSetup(RefPitSetup in) {
    tCarPitSetup s{}; auto entries=pitEntries(s);
    for (int i=0;i<89;++i) *entries[i]={in.values[i].value,in.values[i].minimum,in.values[i].maximum};
    for (int i=0;i<3;++i) s.diffType[i]=static_cast<tCarPitSetup::TDiffType>(in.differentialTypes[i]);
    return s;
}
static RefPitSetup readPitSetup(tCarPitSetup s) {
    RefPitSetup out{}; auto entries=pitEntries(s);
    for (int i=0;i<89;++i) out.values[i]={entries[i]->value,entries[i]->min,entries[i]->max};
    for (int i=0;i<3;++i) out.differentialTypes[i]=s.diffType[i];
    return out;
}
int ref_adjust_pit_value(RefPitSetupValue in,RefPitSetupValue *out) {
    tCarPitSetupValue v{in.value,in.minimum,in.maximum};
    bool changed=SimAdjustPitCarSetupParam(&v);
    if (out) *out={v.value,v.min,v.max};
    return changed;
}
int ref_pit_setup_xml(const char *xml,RefPitSetup in,int boundsOnly,RefPitSetup *out) {
    if (activeWorld || !xml || !out || strlen(xml)>65536 || strstr(xml,"<!DOCTYPE") || strstr(xml,"<!ENTITY")) return 0;
    GfParmInit(); std::string buffer(xml); void *parameters=GfParmReadBuf(buffer.data());
    if (!parameters) { GfParmShutdown(); return 0; }
    auto setup=pitSetup(in); RtInitCarPitSetup(parameters,&setup,boundsOnly!=0); *out=readPitSetup(setup);
    GfParmReleaseHandle(parameters); GfParmShutdown(); return 1;
}
int ref_world_pit_setup(RefWorld *world,int index,RefPitSetup *out) {
    if (!world || world!=activeWorld || !out || index<0 || index>=static_cast<int>(world->cars.size())) return 0;
    *out=readPitSetup(world->cars[index].pitcmd.setup); return 1;
}
int ref_world_service(RefWorld *world,int index,RefPitSetup setup,float fuel,int repair,int changeAllTires,RefPitSetup *out) {
    if (!world || world!=activeWorld || !out || index<0 || index>=static_cast<int>(world->cars.size())) return 0;
    auto &elt=world->cars[index]; elt.pitcmd.setup=pitSetup(setup); elt.pitcmd.fuel=fuel; elt.pitcmd.repair=repair;
    elt.pitcmd.tireChange=changeAllTires ? tCarPitCmd::ALL:tCarPitCmd::NONE;
    SimReConfig(&elt); *out=readPitSetup(elt.pitcmd.setup); return 1;
}

int ref_world_rule_factors(RefWorld *world,float damageFactor,float tireFactor) {
    if (!world || world!=activeWorld || !std::isfinite(damageFactor) || !std::isfinite(tireFactor)) return 0;
    rulesDamageFactor=damageFactor; rulesTireFactor=tireFactor; return 1;
}
int ref_world_service_publication(RefWorld *world,int index,double *values,int capacity) {
    if (!world || world!=activeWorld || !values || capacity<27 || index<0 || index>=static_cast<int>(world->cars.size())) return 0;
    const auto &elt=world->cars[index]; int cursor=0;
    values[cursor++]=elt._steerLock;
    for (int i=0;i<MAX_GEARS;++i) values[cursor++]=elt.priv.gearRatio[i];
    for (int i=0;i<4;++i) {
        const auto &w=elt.priv.wheel[i]; values[cursor++]=w.currentGraining; values[cursor++]=w.currentPressure;
        values[cursor++]=w.currentTemperature; values[cursor++]=w.currentWear;
    }
    return cursor;
}

static void raceReconfigure(tCarElt *car) { ++activeWorld->serviceCounts[car->index]; SimReConfig(car); }
static void raceMute() {}
static int racePitCommand(int index,tCarElt *car,tSituation*) {
    auto *w=activeWorld;
    if (w->tireOverrides[index]>=0) car->pitcmd.tireChange=w->tireOverrides[index] ? tCarPitCmd::ALL:tCarPitCmd::NONE;
    if (w->menuModes[index]) { ++w->menuRequests[index]; return ROB_PIT_MENU; }
    return ROB_PIT_IM;
}
int ref_world_race_registration(RefWorld *w,int i,const char *team,float length,float width,int skill) {
    if (!w || w!=activeWorld || i<0 || i>=int(w->cars.size()) || !team || strlen(team)>=MAX_NAME_LEN) return 0;
    auto &car=w->cars[i]; strcpy(car._teamname,team); car._dimension_x=length; car._dimension_y=width; car._skillLevel=skill;
    car._driverType=RM_DRV_HUMAN; return 1; // Human bypasses unrelated lap-time DNF in the pit-boundary oracle.
}
// Original race-manager parameters. A starting grid writes the same attribute
// names the original reads, so initStartingGrid sees an ordinary race handle.
static bool initializeRaceParameters(RefWorld *w,int capacity,const RefStartingGrid *grid) {
    if (w->raceParameters) return false;
    auto number=[](const char *name,float value) {
        char buffer[128];
        // %.9g round-trips every finite float the original stores as tdble.
        snprintf(buffer,sizeof buffer,"<attnum name='%s' val='%.9g'/>",name,value);
        return std::string(buffer);
    };
    std::string xml="<params name='race'><section name='Race'><attnum name='"
        RM_ATTR_CARSPERPIT "' val='"+std::to_string(capacity)+"'/>";
    if (grid) {
        xml+="<section name='" RM_SECT_STARTINGGRID "'>";
        if (grid->poleSide>=0) xml+=std::string("<attstr name='" RM_ATTR_POLE "' val='")+(grid->poleSide ? "left":"right")+"'/>";
        xml+=number(RM_ATTR_ROWS,float(grid->rows));
        xml+=number(RM_ATTR_TOSTART,grid->toStart);
        xml+=number(RM_ATTR_COLDIST,grid->columnDistance);
        xml+=number(RM_ATTR_COLOFFSET,grid->columnOffset);
        xml+=number(RM_ATTR_INITSPEED,grid->initialSpeed);
        xml+=number(RM_ATTR_INITHEIGHT,grid->initialHeight);
        xml+="</section>";
    }
    xml+="</section></params>";
    w->raceParameters=GfParmReadBuf(xml.data()); if (!w->raceParameters) return false;
    int n=w->cars.size(); w->raceCars.resize(n); w->raceCarRules.resize(n); w->robots.resize(n);
    w->serviceCounts.resize(n); w->menuRequests.resize(n); w->menuModes.resize(n); w->tireOverrides.resize(n,-1);
    w->info.params=w->raceParameters; w->info._reRaceName="Race"; w->info.carList=w->cars.data();
    w->info._reCarInfo=w->raceCars.data(); w->info.rules=w->raceCarRules.data(); w->info._displayMode=RM_DISP_MODE_CONSOLE;
    w->info._reSimItf.reconfig=raceReconfigure; w->info._reGraphicItf.muteformenu=raceMute;
    for (int i=0;i<n;++i) { if (!w->btMode) { w->robots[i].index=i; w->robots[i].rbPitCmd=racePitCommand; } w->cars[i].robot=&w->robots[i]; GF_TAILQ_INIT(&w->cars[i]._penaltyList); }
    return true;
}
int ref_world_race_pits_init(RefWorld *w,int capacity) {
    if (!w || w!=activeWorld || !initializeRaceParameters(w,capacity,nullptr)) return 0;
    ref_race_assign_original(&w->info); return 1;
}
int ref_world_race_stall(RefWorld *w,int i,RefRacePitStall *out) {
    if (!w || w!=activeWorld || !out || i<0 || i>=w->track->pits.nMaxPits) return 0;
    auto &pit=w->track->pits.driversPits[i]; *out={}; out->count=pit.freeCarIndex; out->occupant=pit.pitCarIndex;
    out->minimum=pit.lmin; out->maximum=pit.lmax;
    for (int j=0;j<4;++j) out->cars[j]=pit.car[j] ? pit.car[j]->index:-1;
    return 1;
}
int ref_world_race_command(RefWorld *w,int i,unsigned int command,RefPitSetup setup,float fuel,int repair,int tires,int stop,float penalty,int menu,int tireOverride) {
    if (!w || w!=activeWorld || !w->raceParameters || i<0 || i>=int(w->cars.size())) return 0;
    auto &car=w->cars[i]; car.ctrl.raceCmd=command; car.pitcmd.setup=pitSetup(setup); car._pitFuel=fuel; car._pitRepair=repair;
    car.pitcmd.tireChange=tires ? tCarPitCmd::ALL:tCarPitCmd::NONE; car._pitStopType=stop; car._penaltyTime=penalty;
    w->menuModes[i]=menu; w->tireOverrides[i]=tireOverride; return 1;
}
static void raceRules(RefWorld *w,double time,int session,RefRacePitRules r) {
    w->situation.currentTime=time; w->situation._raceType=session;
    w->info.raceRules.pitstopBaseTime=r.baseTime; w->info.raceRules.refuelFuelFlow=r.fuelFlow;
    w->info.raceRules.damageRepairFactor=r.repairFactor; w->info.raceRules.tireFactor=r.tireFactor;
    w->info.raceRules.allTiresChangeTime=r.tireChangeTime;
}
int ref_world_race_manage(RefWorld *w,int i,RefTrackPosition pos,unsigned int flags,int damage,float vx,float vy,double time,int maximumDamage,int session,RefRacePitRules r,int usePublished) {
    if (!w || w!=activeWorld || !w->raceParameters || i<0 || i>=int(w->cars.size()) || !validGeometry(w,pos.segment)) return 0;
    auto &car=w->cars[i]; raceRules(w,time,session,r); w->situation._maxDammage=maximumDamage;
    if (!usePublished) {
        car._state=flags; car._dammage=damage; car._speed_x=vx; car._speed_y=vy;
        car._trkPos.seg=w->geometry[pos.segment]; car._trkPos.type=pos.mode; car._trkPos.toStart=pos.toStart;
        car._trkPos.toRight=pos.toRight; car._trkPos.toLeft=pos.toLeft; car._trkPos.toMiddle=pos.toMiddle;
    }
    // This oracle targets pit management. Suppress unrelated lap crossings by
    // supplying unchanged previous segment; full race timing is not claimed.
    w->raceCars[i].prevTrkPos=car._trkPos;
    ref_race_manage_original(&w->info,&car); return 1;
}
int ref_world_race_pit_time(RefWorld *w,int i,double time,int session,RefRacePitRules r) {
    if (!w || w!=activeWorld || !w->raceParameters || i<0 || i>=int(w->cars.size())) return 0;
    raceRules(w,time,session,r); ref_race_time_original(&w->info,&w->cars[i]); return 1;
}
int ref_world_race_state(RefWorld *w,int i,RefRacePitState *out) {
    if (!w || w!=activeWorld || !w->raceParameters || !out || i<0 || i>=int(w->cars.size())) return 0;
    auto &c=w->cars[i]; auto &r=w->raceCars[i]; *out={}; out->flags=c._state; out->raceCommand=c.ctrl.raceCmd;
    out->stops=c._nbPitStops; out->stall=c._pit ? int(c._pit-w->track->pits.driversPits):-1; out->occupant=c._pit ? c._pit->pitCarIndex:-1;
    out->stopType=c._pitStopType; out->services=w->serviceCounts[i]; out->menuRequests=w->menuRequests[i];
    out->startTime=r.startPitTime; out->totalTime=r.totalPitTime; out->scheduledTime=c._scheduledEventTime; out->penaltyTime=c._penaltyTime;
    memcpy(out->message,c.ctrl.msg[2],32); return 1;
}

int ref_world_race_complete_menu(RefWorld *w,int i) {
    if (!w || w!=activeWorld || !w->raceParameters || i<0 || i>=int(w->cars.size())) return 0;
    return ref_race_complete_menu_original(&w->info,&w->cars[i]);
}

// Published carElt values, never native-renderer values, feed the graphics oracle.
int ref_world_visual(RefWorld *world,int index,RefVehicleVisual *output) {
    if(!world||world!=activeWorld||!output||index<0||index>=static_cast<int>(world->cars.size()))return 0;
    auto &e=world->cars[index];RefVisualWheel wheels[4]{};
    for(int i=0;i<4;i++) {
        auto &w=wheels[i];const auto &p=e.priv.wheel[i].relPos;
        w={{p.x,p.y,p.z},{p.ax,p.ay,p.az},e._wheelSpinVel(i),e._rimRadius(i)+e._tireHeight(i),e._tireWidth(i),e._brakeTemp(i)};
    }
    ref_wheel_graphics(&e.pub.posMat[0][0],wheels,output);output->flags=e._state;return 1;
}

// Timing oracle: preserve previous segment across original ReManage calls.
// Single human car avoids unrelated robot timeout and multi-car gap setup.
void ref_race_capture_laps(bool);
extern void ref_race_sort_original(tRmInfo*);
static RefLapTiming lapTiming(RefWorld *w,int id) {
    const auto &c=w->cars[id];const auto &info=w->raceCars[id];RefLapTiming out={};
    out.startTime=info.sTime;out.currentLapTime=c._curLapTime;out.lastLapTime=c._lastLapTime;out.bestLapTime=c._bestLapTime;
    out.deltaBestLapTime=c._deltaBestLapTime;out.totalTime=c._curTime;out.topSpeed=c._topSpeed;
    out.lapTopSpeed=info.topSpd;out.lapMinimumSpeed=info.botSpd;out.currentMinimumSpeed=c._currentMinSpeedForLap;
    out.distanceFromStart=c._distFromStartLine;out.distanceRaced=c._distRaced;out.laps=c._laps;out.remainingLaps=c._remainingLaps;
    out.backwardCrossings=info.lapFlag;out.commitBestLapTime=c._commitBestLapTime;out.raceState=w->situation._raceState;out.flags=c._state;
    out.previousSegment=-1;for(size_t i=0;i<w->geometry.size();i++)if(w->geometry[i]==info.prevTrkPos.seg)out.previousSegment=i;
    return out;
}
int ref_world_progress_init(RefWorld *w,const int *segments,int laps) {
    if(!w||w!=activeWorld||!segments||laps<1)return 0;
    for(size_t i=0;i<w->cars.size();i++)if(!validGeometry(w,segments[i]))return 0;
    if(!w->raceParameters && !ref_world_race_pits_init(w,1))return 0;
    for(size_t i=0;i<w->cars.size();i++) {
        auto &c=w->cars[i];c._pit=nullptr;c._driverType=RM_DRV_HUMAN;c._skillLevel=0;
        c._laps=0;c._remainingLaps=laps;c._pos=i+1;c._state=0;c._commitBestLapTime=true;
        c._curLapTime=c._lastLapTime=c._bestLapTime=c._deltaBestLapTime=c._curTime=0;
        c._topSpeed=c._currentMinSpeedForLap=c._distRaced=c._distFromStartLine=0;
        c._timeBehindLeader=c._timeBehindPrev=c._timeBeforeNext=0;c._lapsBehindLeader=0;
        w->raceCars[i]={};w->raceCars[i].prevTrkPos.seg=w->geometry[segments[i]];w->pointers[i]=&c;
    }
    w->info._displayMode=RM_DISP_MODE_NORMAL;w->situation._raceType=RM_TYPE_PRACTICE;w->situation._raceState=RM_RACE_RUNNING;
    return 1;
}
int ref_world_progress_step(RefWorld *w,const RefRaceProgressSample *samples,double time,unsigned int rules,RefRaceProgressCar *out,int *order) {
    if(!w||w!=activeWorld||!w->raceParameters||!samples||!out||!order)return 0;
    for(size_t i=0;i<w->cars.size();i++)if(!validGeometry(w,samples[i].position.segment))return 0;
    if(w->situation._raceState!=RM_RACE_ENDED) {
        for(size_t i=0;i<w->cars.size();i++) {
            auto &c=w->cars[i];const auto &s=samples[i];const auto &p=s.position;
            c._trkPos.seg=w->geometry[p.segment];c._trkPos.type=p.mode;c._trkPos.toStart=p.toStart;
            c._trkPos.toLeft=p.toLeft;c._trkPos.toRight=p.toRight;c._trkPos.toMiddle=p.toMiddle;
            c._speed_x=s.speed;c._dimension_y=s.width;c._state=s.flags;c.priv.simcollision=s.collision;
        }
        w->situation.currentTime=time;w->info.raceRules.enabled=rules;ref_race_capture_laps(true);
        for(size_t i=0;i<w->cars.size();i++)ref_race_manage_original(&w->info,w->situation.cars[i]);
        ref_race_capture_laps(false);ref_race_sort_original(&w->info);
    }
    for(size_t i=0;i<w->cars.size();i++) {
        const auto &c=w->cars[i];out[i]={lapTiming(w,int(i)),c._timeBehindLeader,c._timeBehindPrev,c._timeBeforeNext,c._lapsBehindLeader,c._pos};
        order[i]=w->situation.cars[i]->index;
    }
    return w->situation._raceState;
}
int ref_world_laps_init(RefWorld *w,int segment,int laps) {
    if(!w||w!=activeWorld||w->cars.size()!=1||!validGeometry(w,segment)||laps<1)return 0;
    if(!w->raceParameters && !ref_world_race_pits_init(w,1))return 0;
    auto &c=w->cars[0];c._pit=nullptr;c._driverType=RM_DRV_HUMAN;
    c._laps=0;c._remainingLaps=laps;c._pos=1;c._state=0;c._commitBestLapTime=true;
    c._curLapTime=c._lastLapTime=c._bestLapTime=c._deltaBestLapTime=c._curTime=0;
    c._topSpeed=c._currentMinSpeedForLap=c._distRaced=c._distFromStartLine=0;
    w->raceCars[0]={};w->raceCars[0].prevTrkPos.seg=w->geometry[segment];
    w->info._displayMode=RM_DISP_MODE_NORMAL;w->situation._raceType=RM_TYPE_PRACTICE;w->situation._raceState=RM_RACE_RUNNING;
    return 1;
}
int ref_world_laps_manage(RefWorld *w,RefTrackPosition p,float speed,float width,unsigned int flags,unsigned int collision,double time,unsigned int rules,int finishing,int usePublished,RefLapTiming *out) {
    if(!w||w!=activeWorld||w->cars.size()!=1||!w->raceParameters||!out||!validGeometry(w,p.segment))return 0;
    auto &c=w->cars[0];auto &info=w->raceCars[0];
    if(!usePublished) {
        c._trkPos.seg=w->geometry[p.segment];c._trkPos.type=p.mode;c._trkPos.toStart=p.toStart;c._trkPos.toLeft=p.toLeft;c._trkPos.toRight=p.toRight;c._trkPos.toMiddle=p.toMiddle;
        c._speed_x=speed;c._dimension_y=width;c._state=flags;c.priv.simcollision=collision;
    }
    w->situation.currentTime=time;w->situation._raceState=finishing ? RM_RACE_FINISHING:RM_RACE_RUNNING;w->info.raceRules.enabled=rules;
    // Isolate human timing from professional pit penalties without changing physics skill.
    const int skill=c._skillLevel;c._skillLevel=0;
    ref_race_capture_laps(true);ref_race_manage_original(&w->info,&c);ref_race_capture_laps(false);c._skillLevel=skill;
    *out={};out->startTime=info.sTime;out->currentLapTime=c._curLapTime;out->lastLapTime=c._lastLapTime;out->bestLapTime=c._bestLapTime;out->deltaBestLapTime=c._deltaBestLapTime;out->totalTime=c._curTime;
    out->topSpeed=c._topSpeed;out->lapTopSpeed=info.topSpd;out->lapMinimumSpeed=info.botSpd;out->currentMinimumSpeed=c._currentMinSpeedForLap;out->distanceFromStart=c._distFromStartLine;out->distanceRaced=c._distRaced;
    out->laps=c._laps;out->remainingLaps=c._remainingLaps;out->backwardCrossings=info.lapFlag;out->commitBestLapTime=c._commitBestLapTime;out->raceState=w->situation._raceState;out->flags=c._state;
    out->previousSegment=-1;for(size_t i=0;i<w->geometry.size();i++)if(w->geometry[i]==info.prevTrkPos.seg)out->previousSegment=i;
    return 1;
}

int ref_world_bt_car_status(RefWorld *w,int car,RefRobotRaceState *out) {
    if (!w||w!=activeWorld||!w->btNewRace||!out||car<0||car>=int(w->cars.size())) return 0;
    auto &c=w->cars[car];auto r=w->btStates[car];
    r.time=w->situation.currentTime;r.lastLap=c._lastLapTime;r.bestLap=c._bestLapTime;r.totalTime=c._curTime;r.distance=c._distRaced;
    r.laps=c._laps;r.remainingLaps=c._remainingLaps;r.position=c._pos;r.raceState=w->situation._raceState;r.carState=c._state;
    r.services=w->serviceCounts[car];r.validLap=c._commitBestLapTime;*out=r;return 1;
}
int ref_world_bt_status(RefWorld *w,RefRobotRaceState *out) { return ref_world_bt_car_status(w,0,out); }
// One original ReOneStep for the whole field: robot callbacks, one physics
// update, per-car ReManage (lap timing, pit service, race rules), ReSortCars.
int ref_world_race_step(RefWorld *w) {
    if (!w||w!=activeWorld||!w->btNewRace||w->situation._raceState==RM_RACE_ENDED) return -1;
    ++w->tick;ref_race_step_original(&w->info);
    for (size_t i=0;i<w->cars.size();++i) if (!w->btInputValid[i]) return -1;
    return w->situation._raceState;
}
int ref_world_bt_step(RefWorld *w,RefRobotRaceState *out) {
    if (ref_world_race_step(w)<0) return 0;
    return ref_world_bt_status(w,out);
}
int ref_world_bt_car_input(RefWorld *w,int car,double *values,int capacity) {
    if (!w||w!=activeWorld||!values||car<0||car>=int(w->cars.size())||!w->btInputValid[car]) return 0;
    const auto &input=w->btInputs[car];
    if (input.empty()||capacity<int(input.size())) return 0;
    std::copy(input.begin(),input.end(),values);return int(input.size());
}
int ref_world_bt_input(RefWorld *w,double *values,int capacity) { return ref_world_bt_car_input(w,0,values,capacity); }
int ref_world_grid_slot(RefWorld *w,int car,RefGridSlot *out) {
    if (!w||w!=activeWorld||!out||!w->gridPlaced||car<0||car>=int(w->gridSlots.size())) return 0;
    *out=w->gridSlots[car];return 1;
}
int ref_world_race_car_state(RefWorld *w,int car,RefRaceCarState *out) {
    if (!w||w!=activeWorld||!out||!w->raceParameters||car<0||car>=int(w->cars.size())) return 0;
    const auto &c=w->cars[car];*out={};
    out->timeBehindLeader=c._timeBehindLeader;out->timeBehindPrevious=c._timeBehindPrev;out->timeBeforeNext=c._timeBeforeNext;
    out->lapsBehindLeader=c._lapsBehindLeader;out->position=c._pos;out->ruleState=w->raceCarRules[car].ruleState;
    out->penaltyTime=c._penaltyTime;out->services=w->serviceCounts[car];
    out->eliminated=(c._state & RM_CAR_STATE_ELIMINATED) != 0;
    out->firstPenalty=-1;out->firstPenaltyLapToClear=-1;
    // The original penalty list is a tail queue owned by ReRaceRules.
    auto *penalty=GF_TAILQ_FIRST(&(c._penaltyList));
    if (penalty) { out->firstPenalty=penalty->penalty;out->firstPenaltyLapToClear=penalty->lapToClear; }
    for (auto *entry=penalty;entry;entry=GF_TAILQ_NEXT(entry,link)) ++out->penalties;
    if (!w->btStates.empty()) { out->pitCalls=w->btStates[car].pitCalls;out->driveCalls=w->btStates[car].driveCalls; }
    return 1;
}
int ref_world_race_configure(RefWorld *w,unsigned int rules,unsigned int raceType,int skill,int driverType) {
    if (!w||w!=activeWorld||!w->raceParameters||skill<0||skill>4) return 0;
    if (driverType!=RM_DRV_HUMAN&&driverType!=RM_DRV_ROBOT) return 0;
    if (raceType!=RM_TYPE_PRACTICE&&raceType!=RM_TYPE_QUALIF&&raceType!=RM_TYPE_RACE) return 0;
    w->info.raceRules.enabled=rules;w->situation._raceType=raceType;
    for (auto &car:w->cars) { car._skillLevel=skill;car._driverType=driverType; }
    return 1;
}
int ref_world_race_classification(RefWorld *w,int *order,int count) {
    if (!w||w!=activeWorld||!order||count!=int(w->cars.size())) return 0;
    for (int i=0;i<count;++i) order[i]=w->situation.cars[i]->index;
    return 1;
}

// Original track/lighting reads, isolated from the legacy GL state calls.
int ref_graphics_config_xml(const char *xml,float *output,int *type) {
    if(activeWorld||!xml||!output||!type||strlen(xml)>65536||strstr(xml,"<!DOCTYPE")||strstr(xml,"<!ENTITY"))return 0;
    GfParmInit();std::string buffer(xml);void *hndl=GfParmReadBuf(buffer.data());
    if(!hndl){GfParmShutdown();return 0;}
    using GLfloat=float;
#include "graphics/lighting-config.inc"
    tTrackGraphicInfo value{};auto *graphic=&value;void *TrackHandle=hndl;
#include "graphics/background-config.inc"
    memcpy(output,graphic->bgColor,12);memcpy(output+3,lmodel_ambient,12);memcpy(output+6,lmodel_diffuse,12);
    memcpy(output+9,mat_specular,12);memcpy(output+12,light_position,12);
    sgCopyVec3(fog_clr,graphic->bgColor);sgScaleVec3(fog_clr,0.8);memcpy(output+15,fog_clr,12);*type=graphic->bgtype;
    GfParmReleaseHandle(hndl);GfParmShutdown();return 1;
}

const char *ref_world_track_camera(RefWorld *world,int index,float *position) {
    if(!validGeometry(world,index) || !position)return nullptr;
    auto camera=world->geometry[index]->cam;
    if(!camera)return nullptr;
    memcpy(position,&camera->pos,3*sizeof(float));return camera->name;
}

int ref_world_bt_car_observation(RefWorld *w,int car,RefBTObservation *out) {
    if(!w||w!=activeWorld||!out||!w->btNewRace||car<0||car>=int(w->cars.size())||!w->btStates[car].driveCalls)return 0;
    *out=w->btObservations[car];return 1;
}
int ref_world_bt_observation(RefWorld *w,RefBTObservation *out) { return ref_world_bt_car_observation(w,0,out); }

int ref_world_bt_car_pit_decision(RefWorld *w,int car,RefBTPitDecision *out) {
    if(!w||w!=activeWorld||!out||!w->btNewRace||car<0||car>=int(w->cars.size())||!w->btStates[car].pitCalls)return 0;
    *out=w->btPitDecisions[car];return 1;
}
int ref_world_bt_pit_decision(RefWorld *w,RefBTPitDecision *out) { return ref_world_bt_car_pit_decision(w,0,out); }
