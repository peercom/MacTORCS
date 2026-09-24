// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Test-only calls into original ReSortCars and ReOneStep (empty-car clock).
int ref_race_order(const float *distances,const unsigned int *flags,int *order,int count);
int ref_race_start_clock(int ticks,double *times,int *states);
// Selected original SSG draw scheduling; storage/visibility adapters, no GL driver.
int ref_draw_order(const int *parents,const int *flags,const int *visible,const int *driverNames,int count,int wrapDriver,int *output,int capacity);
int ref_scene_anchor_order(int *output);
// Original frame/mesh dispatch with no-op state/geometry adapters; 10 outputs.
int ref_scene_depth_state(int initialWrite,int *output,int capacity);
int ref_alpha_state(const int *care,const int *enabled,const float *clamps,int count,float *output);
int ref_car_draw_order(const float *positions,const float *eye,int *order,int count,float *distances);
float ref_human_axis(int role,float value,float minimum,float maximum,float minimumValue,float deadZone,float gain,float exponent,float speedSensitivity,float speed);

typedef struct {
    float springRate, preload, rest, travel, bellcrank, packers;
    float slowBump, fastBump, bumpThreshold, slowRebound, fastRebound, reboundThreshold;
} RefSuspensionConfig;
typedef struct { float displacement, force; int state; } RefSuspensionResult;
RefSuspensionResult ref_suspension(RefSuspensionConfig config, float displacement, float velocity);
typedef struct { float torque, temperature; } RefBrakeResult;
RefBrakeResult ref_brake(float coefficient, float radius, float pressure, float speed, float spin, float temperature, float dt);
typedef struct { float front, rear; } RefBrakePressures;
RefBrakePressures ref_brake_pressures(float command, float coefficient, float repartition, float clickValue, int maxClicks, int clicks);
typedef struct { float angle, right, left; } RefSteeringResult;
RefSteeringResult ref_steering(float previous, float command, float lock, float speed, float wheelbase, float track, float dt);
// Test-only original PLIB scene-height query, one ordered AC graph per handle.
typedef struct { int index;unsigned flags;int remainingLaps;float distanceFromStart,toMiddle;int pitRequested,collision; } RefTVCar;
void *ref_tv_create(int count,const float *settings,float trackLength,float trackWidth);
void ref_tv_destroy(void *handle);
void ref_tv_step(void *handle,double time,int initialCar,const RefTVCar *cars,const int *otherScreens,int screenCount,double *state,int *selection,int *collisions,float *view);
int ref_shadow_visibility(int carIndex,int currentIndex,int drawCurrent);
void ref_camera_tv_zoom(float saved,const int *commands,int count,float *output);
void ref_camera_fly_zoom(float saved,const int *commands,int count,float *output);
void ref_camera_fly(void *scene,unsigned seed,const double *times,const float *positions,const int *indices,const int *selects,int count,float *output,double *storedTimes,int *draws,int *heightCalls);
void *ref_scene_height_create(void);
int ref_scene_height_add(void *handle,int parent,int kind,const float *matrix,int primitive,int cull,const float *vertices,int count);
void ref_scene_height_query(void *handle,const float *xy,int count,float *heights,int *hits,int *triangles);
void ref_scene_height_spheres(void *handle,float *output);
int ref_scene_height_transform(void *handle,int node,const float *matrix);
int ref_scene_height_select(void *handle,int node,unsigned mask);
int ref_scene_height_driver_selector(void *handle,int parent,int child,int visible);
void ref_scene_height_destroy(void *handle);
void ref_ac_transform(const float *parent,const float *local,const float *point,float *matrix,float *world);
typedef struct { float position[3],orientation[3],spin,radius,width,brakeTemperature; } RefVisualWheel;
typedef struct { float matrix[16],wheelMatrix[4][16],brakeColor[4][3],brakeMatrix[4][16]; int level[4]; RefVisualWheel wheels[4]; unsigned int flags; } RefVehicleVisual;
int ref_graphics_config_xml(const char *xml,float *output,int *type);
void ref_background_camera(const float *input,float *output);
int ref_background_geometry(int type,float *output,int capacity);
void ref_camera_exterior(int kind,const float *samples,int count,float *output);
void ref_camera_chase(const float *samples,int count,float distance,float height,float *output);
void ref_camera_bonnet(const float *body,const float *position,float *output);
void ref_shadow_vertices(float length,float width,const float *body,float *output);
void ref_camera_behind(const float *samples, int count, float *output);
typedef struct { int type;float position[3],size; } RefCarLightConfig;
typedef struct { float vertices[12],uv[8],textureMatrix[16],finalTextureMatrix[16],color[4],offset[2];int count,primitive,randomDraws,depthMask[2],depthMaskCount,offsetEnabled,finalMatrixMode; } RefCarLightDraw;
int ref_carlight_frustum(float nearValue,float farValue,float right,float top,const float *view,const float *position);
void ref_carlight_random(unsigned seed,int count,unsigned *output);
int ref_carlight_config_xml(const char *xml,RefCarLightConfig *output,int capacity);
void ref_carlight_update(int type,float brake,unsigned lightCommand,int display,const float *position,float size,const float *body,int *state,float *world);
void ref_carlight_draw(const float *position,float size,double factor,const float *view,unsigned randomValue,int on,RefCarLightDraw *output);
void ref_brake_geometry(int wheel,float radius,float width,float *vertices,float *normals,float *colors,int *metadata);
void ref_wheel_graphics(const float *body,const RefVisualWheel *wheels,RefVehicleVisual *output);
float ref_unit_to_si(const char *unit, float value);
float ref_si_to_unit(const char *unit, float value);

// Full original simuv2 execution. Upstream owns process-global physics/track
// state, so only one world may be alive, and all calls must be serialized.
// Paths refer to a prepared, trusted TORCS reference fixture installation.
typedef struct RefWorld RefWorld;
// Original BT single-car race oracle. Owns original callbacks and isolated IO.
typedef struct {
    double time,robotTime,robotDelta,lastLap,bestLap,totalTime,distance;
    unsigned long long driveCalls,lastDriveTick;
    float throttle,brake,steering,clutch;
    int gear,laps,remainingLaps,position,raceState,carState,newTrackCalls,newRaceCalls,pitCalls,services,validLap;
} RefRobotRaceState;
RefWorld *ref_world_bt_create(const char *track,const char *car,const char *category,const char *directory,unsigned int seed,int laps);
int ref_world_bt_step(RefWorld *world,RefRobotRaceState *output);
int ref_world_bt_status(RefWorld *world,RefRobotRaceState *output);
int ref_world_bt_input(RefWorld *world,double *values,int capacity);
// Public tCarElt fields captured immediately before the original drive callback.
typedef struct {
    float toStart,toRight,toMiddle,toLeft,x,y,vx,vy,yaw,speed,fuel,rpm,distance;
    float spin[4];
    int segmentID,gear,laps,remainingLaps,lapsBehindLeader,damage,pitFree;
} RefBTObservation;
int ref_world_bt_observation(RefWorld *world,RefBTObservation *output);
typedef struct { RefBTObservation input; float fuel; int repair; } RefBTPitDecision;
int ref_world_bt_pit_decision(RefWorld *world,RefBTPitDecision *output);


int ref_world_visual(RefWorld *world,int car,RefVehicleVisual *output);
RefWorld *ref_world_create(const char *trackPath, const char *carPath, const char *categoryPath,
                          unsigned int seed, int cars, float startDistance, float spacing);
const char *ref_world_error(void);
void ref_world_destroy(RefWorld *world);
int ref_world_step(RefWorld *world);
int ref_world_command(RefWorld *world, int car, float throttle, float brake, float steering, float clutch, int gear);
int ref_world_settle(RefWorld *world, int ticks);
double ref_world_track_width(RefWorld *world);
double ref_world_track_length(RefWorld *world);
int ref_world_track_segments(RefWorld *world);
int ref_world_field_count(void);
const char *ref_world_field_name(int field);
int ref_world_read(RefWorld *world, int car, double *values, int capacity);
float ref_world_parameter_number(RefWorld *world, int car, const char *section, const char *key, float fallback);
const char *ref_world_parameter_string(RefWorld *world, int car, const char *section, const char *key);
// Standalone parameter merge oracle. Only inline XML (no DTD/entities) is
// accepted; cannot run while a world is active. mode: 1 source, 2 target, 3 both.
int ref_merge_xml(const char *source, const char *target, int mode, char *output, int capacity);
typedef struct {
    float mass, inverseMass, length, width, height, cgX, cgY, cgZ, inverseInertiaX, inverseInertiaY, inverseInertiaZ;
    float frontRightLoad, frontLeftLoad, rearRightLoad, rearLeftLoad, wheelbase, wheeltrack, tank, fuel;
} RefMassProperties;
int ref_world_mass_properties(RefWorld *world, int car, RefMassProperties *output);
// Track geometry instrumentation: stable array indices replace raw pointers.
typedef struct { float x, y, z; } RefTrackVector;
typedef struct {
    int upstreamID, curve, role, style, mainIndex, previous, next, right, left;
    float length, width, startWidth, endWidth, distanceFromStart, radius, rightRadius, leftRadius, arc;
    RefTrackVector center, startRight, startLeft, endRight, endLeft;
    float headingStart, headingEnd, pitchLeft, pitchRight, bankStart, bankEnd, centerStart;
    float longitudinalSlope, bankingSlope, widthSlope, curbHeight, rightNormalX, rightNormalY;
    float friction, rebound, rollingResistance, roughness, roughWaveNumber, damage;
    unsigned int raceFlags;
} RefTrackSegment;
typedef struct { int segment, mode; float toStart, toRight, toMiddle, toLeft; } RefTrackPosition;
typedef struct {
    float x, y, height, width, tangent, distance;
    RefTrackVector normal, rightNormal, leftNormal;
    int effectiveSegment;
} RefTrackSample;
RefTrackVector ref_world_track_bounds(RefWorld *world);
int ref_world_geometry_count(RefWorld *world);
int ref_world_geometry_segment(RefWorld *world, int index, RefTrackSegment *output);
const char *ref_world_geometry_name(RefWorld *world, int index);
const char *ref_world_geometry_material(RefWorld *world, int index);
int ref_world_track_local(RefWorld *world, RefTrackPosition position, int origin, RefTrackSample *output);
int ref_world_track_global(RefWorld *world, int start, float x, float y, int mode, RefTrackPosition *output);
int ref_world_track_neighbour(RefWorld *world, int main, int current, int side);
typedef struct {
    int style;
    float width, height, normalX, normalY;
    float friction, rebound, rollingResistance, roughness, roughWaveNumber, damage;
} RefTrackBarrier;
typedef struct {
    int type, side, entry, start, end, exit, capacity;
    float stallLength, laneWidth, speedLimit;
} RefTrackPits;
int ref_world_barrier(RefWorld *world, int segment, int side, RefTrackBarrier *output);
const char *ref_world_barrier_material(RefWorld *world, int segment, int side);
int ref_world_pits(RefWorld *world, RefTrackPits *output);
int ref_world_pit_position(RefWorld *world, int stall, RefTrackPosition *output);
int ref_world_pit_distance(RefWorld *world, int stall, RefTrackPosition car, float *longitudinal, float *lateral);
typedef struct {
    RefTrackVector position;
    int mainSegment, flags;
    float displacement, relativeVelocity, bellcrank, packers, maximumTravel;
    float brakeCoefficient, brakeRadius, brakePressure, brakeTemperature, longitudinalSpeed, wheelSpin, dt;
} RefWheelRideInput;
typedef struct {
    RefTrackPosition position;
    RefTrackVector normal;
    float roadHeight, rideHeight, displacement, suspensionVelocity, relativeVelocity, brakeTorque, brakeTemperature;
    int flags, suspensionFlags;
} RefWheelRideResult;
int ref_world_wheel_ride(RefWorld *world, RefWheelRideInput input, RefWheelRideResult *output);
typedef struct {
    RefTrackPosition contact;
    RefSuspensionConfig suspension;
    int mainSegment, wheelIndex, skillLevel, flags, suspensionFlags;
    float displacement, suspensionVelocity, relativeVelocity, brakeTorque;
    float radius, mass, tireWidth, friction, magicB, magicC, magicE;
    float loadMinimum, loadMaximum, loadExponent, operatingLoad, camber, caster, toe;
    float bodyVelocityX, bodyVelocityY, steer, spin, axleForce, grip, dt;
    float previousLateral, previousLongitudinal;
} RefWheelForceInput;
typedef struct {
    RefTrackVector force;
    float suspensionForce, relativeVelocity, relativeHeight, relativeCamber, relativeYaw;
    float spinTorque, rollingResistance, slipAngle, longitudinalSlip, tireLoad, tireSlip;
    float skid, sideSlipSpeed, longitudinalSlipSpeed, feedbackSpin, feedbackTorque, feedbackBrakeTorque;
    float previousLateral, previousLongitudinal, otherSurfaceContribution;
    int flags, otherSurface;
} RefWheelForceResult;
int ref_world_wheel_force(RefWorld *world, RefWheelForceInput input, RefWheelForceResult *output);
typedef struct {
    float pressure, initialTemperature, idealTemperature, treadMass, baseMass, gasMass;
    float convectionSurface, hysteresisFactor, wearFactor;
} RefTireThermalConfig;
typedef struct { float pressure, temperature, graining, grip; double wear; } RefTireThermalState;
RefTireThermalState ref_tire_thermal(RefTireThermalConfig config, RefTireThermalState state,
    float load, float slip, float spin, float radius, float localTemperature, float localPressure,
    int skillLevel, float tireFactor, float dt, int reset);
typedef struct { float spin, previousSpin, angle, inputSpin, publishedSpin; } RefWheelRotation;
RefWheelRotation ref_wheel_rotation(float spin, float previousSpin, float angle, float drivetrainSpin,
    float tireTorque, float brakeTorque, float wheelInertia, float axleInertia, float dt, int axle, int freeWheel);
typedef struct {
    float springK, springPreload, springRest, travel, bellcrank, packers;
    float slowBump, fastBump, bumpThreshold, bumpOffset, slowRebound, fastRebound, reboundThreshold, reboundOffset;
} RefSuspensionSetup;
typedef struct {
    RefTrackVector staticPosition, relativePosition, relativeAngles;
    float staticLoad, rollCenter, inertia, feedbackInertia, tireSpringRate, rimRadius, tireHeight, treadThickness;
    float radius, mass, tireWidth, friction, magicB, magicC, magicE, loadMinimum, loadMaximum, loadExponent, operatingLoad;
    float camber, caster, toe, brakeCoefficient, brakeRadius, brakeInertia;
    RefSuspensionSetup suspension;
    RefTireThermalConfig thermal;
    RefTireThermalState thermalState;
} RefWheelSetup;
typedef struct { float position, inertia, rollCenter, antiRollSpring; RefSuspensionSetup suspension; } RefAxleSetup;
typedef struct { RefWheelSetup wheels[4]; RefAxleSetup axles[2]; } RefRunningGear;
int ref_world_running_gear(RefWorld *world, int car, RefRunningGear *output);
// Isolated component setup: native/reference receive the same already-tested mass context.
int ref_running_gear_xml(const char *xml, RefMassProperties context, RefRunningGear *output);
typedef struct { RefTrackVector position; float bodyVelocityX, bodyVelocityY; } RefWheelKinematics;
RefWheelKinematics ref_wheel_kinematics(RefTrackVector attachment, RefTrackVector worldPosition,
    float roll, float pitch, float yaw, float velocityX, float velocityY, float yawVelocity);
typedef struct { float rightForce, leftForce, thirdDisplacement, thirdVelocity, thirdForce; } RefAxleForce;
RefAxleForce ref_axle_force(RefSuspensionConfig suspension, float antiRollSpring, float rightDisplacement,
    float leftDisplacement, float rightVelocity, float leftVelocity, int axle);
typedef struct { float frontRight, frontLeft, rearRight, rearLeft; } RefFourValues;
typedef struct {
    RefTrackVector worldPosition, bodyVelocity;
    float roll, pitch, yaw, yawVelocity, localTemperature, localPressure, tireFactor, dt;
    int mainSegment, skillLevel, preSimulation;
    RefFourValues brakePressures, steering;
} RefRunningGearInput;
typedef struct {
    RefWheelKinematics kinematics;
    RefWheelRideResult ride;
    RefWheelForceResult force;
    RefTireThermalState thermal;
    RefWheelRotation rotation;
} RefWheelStage;
typedef struct { RefWheelStage wheels[4]; } RefRunningGearStep;
// Chassis is externally forced; both axles are explicitly undriven for this test.
int ref_world_running_gear_step(RefWorld *world, RefRunningGearInput input, RefRunningGearStep *output);
typedef struct {
    float limiter, maximumSpeed, idleSpeed, inertia, fuelConsumption, brakeCoefficient;
    float maximumTorque, maximumPower, maximumTorqueSpeed, maximumPowerSpeed, torqueAtMaximumPower;
    int curveCount;
} RefEngineSetup;
typedef struct { float limit, slope, intercept; } RefEngineCurvePoint;
int ref_world_engine_setup(RefWorld *world, RefEngineSetup *output, RefEngineCurvePoint *points, int capacity);
int ref_engine_config_xml(const char *xml, float fuelFactor, RefEngineSetup *output, RefEngineCurvePoint *points, int capacity);
typedef struct {
    float speed, torque, pressure, exhaustPressure, smoke, fuel, throttle;
    float axleSpeed, overallRatio, clutchTransfer, dt;
    int gear, clutchPhase, stages;
    unsigned int carFlags, randomSeed;
} RefEngineInput;
typedef struct {
    float speed, torque, pressure, exhaustPressure, smoke, fuel, clutchTransfer, reaction;
    int clutchPhase;
} RefEngineOutput;
float ref_uniform_random(unsigned int seed);
int ref_world_engine_step(RefWorld *world, RefEngineInput input, RefEngineOutput *output);
int ref_engine_configured_step(RefEngineSetup config, const RefEngineCurvePoint *points, int count, RefEngineInput input, RefEngineOutput *output);
typedef struct {
    int type;
    float inertia, efficiency, ratio, minimumTorqueBias, torqueBiasRange, maximumSlipBias;
    float lockingTorque, brakingLockingTorque, viscosity, feedbackInertia;
} RefDifferentialConfig;
int ref_differential_config_xml(const char *xml, const char *section, float firstInertia, float secondInertia, RefDifferentialConfig *output);
int ref_world_differential_config(RefWorld *world, int index, RefDifferentialConfig *output);
typedef struct { float spin, torque, brakeTorque, inertia; } RefDriveAxis;
typedef struct { RefDriveAxis first, second; RefEngineOutput engine; } RefDifferentialOutput;
int ref_world_differential_step(RefWorld *world, RefDifferentialConfig config, float driveTorque,
    RefDriveAxis first, RefDriveAxis second, float firstOutputInertia, float secondOutputInertia,
    int primary, RefEngineInput engine, RefDifferentialOutput *output);
typedef struct { float ratio, drivenInertia, freeInertia, efficiency; } RefGearSetup;
typedef struct {
    int layout, minimumGear, maximumGear, gearOffset, gearCount;
    float shiftTime;
    RefGearSetup gears[10];
    RefDifferentialConfig differentials[3];
} RefTransmissionSetup;
typedef struct {
    int gear, clutchPhase;
    float clutchTransfer, timeToRelease, currentRatio, currentInertia, throttle;
    RefDriveAxis wheelInputs[4], differentialInputs[3], differentialFeedback[3];
    RefEngineOutput engine;
} RefTransmissionState;
typedef struct {
    int requestedGear, updateEngineTorque;
    float clutchTransfer, throttle, dt;
    unsigned int carFlags, randomSeed;
} RefPowertrainControl;
int ref_world_transmission_setup(RefWorld *world, RefTransmissionSetup *output);
int ref_world_transmission_state(RefWorld *world, RefTransmissionState *output);
// Component-fixture override, permitted only before dynamics; original engine and wheel context is retained.
int ref_world_configure_transmission_xml(RefWorld *world, const char *xml);
int ref_world_powertrain_prepare(RefWorld *world, RefPowertrainControl input, RefTransmissionState *output);
int ref_world_driven_gear_step(RefWorld *world, RefRunningGearInput input, RefRunningGearStep *wheels, RefTransmissionState *output);
typedef struct { float angle, dragCoefficient, liftCoefficient; RefTrackVector position; } RefWingSetup;
typedef struct { float bodyDragCoefficient, draftingCoefficient, frontLift, rearLift; RefWingSetup frontWing, rearWing; } RefAeroSetup;
typedef struct {
    RefTrackVector position, bodyVelocity, worldVelocity;
    float yaw, speed, draftingCoefficient;
    int damage;
    RefFourValues rideHeights;
} RefAeroInput;
typedef struct { float airSpeedSquared, drag, frontLift, rearLift; RefTrackVector frontWing, rearWing; } RefAeroOutput;
int ref_aero_config_xml(const char *xml, float centerOfGravityX, RefAeroSetup *output);
int ref_world_aero_setup(RefWorld *world, RefAeroSetup *output);
int ref_aero_step(RefAeroSetup setup, const RefAeroInput *cars, int count, int carIndex, RefAeroOutput *output);
typedef struct {
    RefTrackVector position, orientation, velocity, angularVelocity, acceleration, angularAcceleration;
} RefChassisDynamics;
typedef struct {
    RefChassisDynamics publicBody,mechanicalBody,parking;
    RefTrackPosition trackPosition;
    unsigned int flags,collision,publishedCollision,publishedSimCollision;
    int damage,maximumDamage,gear,publishedGear,registered,hasPit,pitOccupant;
    float cgHeight,engineRPM,publishedRPM,dt;
    float matrix[16],skid[4],spin[4],brakeTemperature[4];
} RefRemovalState;
int ref_world_removal_step(RefWorld *world,RefRemovalState input,RefRemovalState *output);
typedef struct {
    RefRemovalState removal;
    RefChassisDynamics publicWorld;
    float publicSpeed,publishedFuel;
    int publishedDamage,blocked;
} RefLifecycleOutput;
int ref_world_status(RefWorld *world,int car,unsigned int mask,unsigned int flags,float fuel,int damage,int pitOccupant,int maximumDamage);
int ref_world_read_lifecycle(RefWorld *world,int car,RefLifecycleOutput *output);
int ref_world_step_mode(RefWorld *world,unsigned int raceState);
int ref_world_random_tail(RefWorld *world,float *values,int count);
typedef struct { float value,minimum,maximum; } RefPitSetupValue;
typedef struct { RefPitSetupValue values[89]; int differentialTypes[3]; } RefPitSetup;
int ref_adjust_pit_value(RefPitSetupValue input,RefPitSetupValue *output);
int ref_pit_setup_xml(const char *xml,RefPitSetup input,int boundsOnly,RefPitSetup *output);
int ref_world_pit_setup(RefWorld *world,int car,RefPitSetup *output);
int ref_world_rule_factors(RefWorld *world,float damageFactor,float tireFactor);
int ref_world_service_publication(RefWorld *world,int car,double *values,int capacity);
int ref_world_service(RefWorld *world,int car,RefPitSetup setup,float fuel,int repair,int changeAllTires,RefPitSetup *output);


typedef struct { RefTrackVector force; float rideHeight, rollingResistance; } RefChassisWheelLoad;
typedef struct { RefTrackVector position, bodyVelocity, worldVelocity; } RefChassisCorner;
typedef struct {
    RefChassisDynamics body, world;
    float fuel, speed, cachedYawCosine, cachedYawSine, dt;
    int mainSegment;
    RefChassisWheelLoad wheels[4];
    RefAeroOutput aero;
} RefChassisInput;
typedef struct {
    RefChassisDynamics body, world, previousWorld;
    RefChassisCorner corners[4];
    RefTrackPosition trackPosition;
    float speed;
} RefChassisOutput;
int ref_world_chassis_corners(RefWorld *world, RefTrackVector *corners, int capacity);
int ref_world_chassis_step(RefWorld *world, RefChassisInput input, RefChassisOutput *output);
typedef struct {
    RefPowertrainControl powertrain;
    RefFourValues brakePressures, steering;
    float localTemperature, localPressure, tireFactor;
    int skillLevel, preSimulation;
} RefVehicleControl;
typedef struct { unsigned int flags; int blocked, damage; RefTrackVector normal, position; } RefCollisionState;
typedef struct {
    RefChassisOutput chassis;
    RefCollisionState collision;
    unsigned int carFlags;
    int skillLevel, stages;
    float damageFactor;
} RefEnvironmentInput;
typedef struct { RefChassisOutput chassis; RefCollisionState collision; } RefEnvironmentOutput;
int ref_world_environment_step(RefWorld *world, RefEnvironmentInput input, RefEnvironmentOutput *output);
typedef struct {
    RefChassisOutput chassis;
    RefRunningGearStep wheels;
    RefTransmissionState powertrain;
    RefAeroOutput aero;
    RefCollisionState collision;
} RefVehicleOutput;
// Uses only dynamics, fuel, speed, cache and segment fields; force fields are ignored.
int ref_world_vehicle_initialize(RefWorld *world, RefChassisInput initial);
int ref_world_vehicle_step_without_collision(RefWorld *world, RefVehicleControl input, RefVehicleOutput *output);
int ref_world_vehicle_step(RefWorld *world, RefVehicleControl input, float damageFactor, RefVehicleOutput *output);
typedef struct { float throttle, brake, steering, clutch; int gear, brakeRepartitionClicks; } RefDriverCommand;
typedef struct { float steeringLock, maximumSteeringSpeed, repartition, brakeCoefficient, clickValue; int maximumClicks; } RefDriverSetup;
typedef struct { RefDriverCommand command; float clutchTransfer; } RefCheckedCommand;
RefCheckedCommand ref_check_control(RefDriverCommand command, unsigned int carFlags, float longitudinalSpeed, float toRight, float trackWidth);
int ref_driver_config_xml(const char *xml, RefDriverSetup *output);
int ref_world_driver_setup(RefWorld *world, RefDriverSetup *output);
typedef struct {
    RefVehicleOutput vehicle;
    RefDriverCommand command;
    float steeringAngle, localTemperature, localPressure;
    RefFourValues brakePressures;
    unsigned int carFlags;
} RefSimulationOutput;
int ref_world_simulation_step(RefWorld *world, RefDriverCommand command, unsigned int carFlags, unsigned int raceState,
    unsigned int randomSeed, float damageFactor, float tireFactor, RefSimulationOutput *output);
int ref_random_sequence(unsigned int seed, float *values, int count);
typedef struct { double x,y,z; } RefDoubleVector;
typedef struct { RefDoubleVector firstPoint,secondPoint,normal; } RefObjectContact;
typedef struct {
    int index,skillLevel;
    unsigned int carFlags;
    float inverseMass,inverseYawInertia,yawVelocity;
    RefTrackVector centerOfGravity,position,velocity,publicOrientation,transformPosition,transformOrientation,accumulated;
    RefCollisionState collision;
} RefObjectBody;
typedef struct {
    RefTrackVector position,velocity,accumulated;
    float yawVelocity,transform[16];
    RefCollisionState collision;
} RefObjectResponse;
int ref_object_pair_response(RefObjectBody first,RefObjectBody second,RefObjectContact contact,float damageFactor,RefObjectResponse *firstOut,RefObjectResponse *secondOut);
int ref_object_wall_response(RefObjectBody body,RefObjectContact contact,int wallFirst,float damageFactor,RefObjectResponse *output);
typedef struct {
    int kind,first,second,wallFirst,resetBefore,commitAfter;
    float damageFactor;
    RefObjectContact contact;
} RefObjectEvent;
int ref_object_response_sequence(const RefObjectBody *bodies,int bodyCount,const RefObjectEvent *events,int eventCount,RefObjectResponse *outputs,int capacity);
typedef struct { int kind,vertexCount; RefDoubleVector dimensions; } RefConvexShape;
int ref_fixed_wall_count(void);
int ref_fixed_wall_polygon_count(int wall);
int ref_fixed_wall_vertices(int wall,int polygon,RefDoubleVector *outputs,int capacity);
typedef struct { RefDoubleVector rowX,rowY,rowZ,origin; } RefConvexTransform;
typedef struct { int mode; RefConvexTransform matrix; RefDoubleVector translation,quaternion,scale; double quaternionW; } RefAffineInput;
int ref_affine_query(RefAffineInput first,RefAffineInput second,RefConvexTransform *outputs);
typedef struct { int hit; RefDoubleVector axis,firstPoint,secondPoint,probeFirst,probeSecond; } RefConvexResult;
typedef struct { RefConvexResult contact; int primitive; RefDoubleVector center,extent; } RefComplexResult;
typedef struct { RefConvexResult contact; int firstPrimitive,secondPrimitive; } RefComplexPairResult;
typedef struct { RefConvexResult contact; int firstWall,secondWall,wouldAccessCar; } RefFixedPairResult;
int ref_fixed_pair_query(int firstWall,int secondWall,RefFixedPairResult *output);
int ref_complex_pair_sequence(const RefConvexShape *firstPrimitives,const RefDoubleVector *firstVertices,int firstCount,
    const RefConvexShape *secondPrimitives,const RefDoubleVector *secondVertices,int secondCount,
    RefAffineInput first,RefAffineInput initialSecond,const RefAffineInput *poses,int count,int mode,RefComplexPairResult *outputs);
int ref_complex_sequence(const RefConvexShape *primitives,const RefDoubleVector *vertices,int primitiveCount,
    RefConvexShape other,const RefDoubleVector *otherVertices,RefAffineInput first,RefAffineInput initialSecond,
    const RefAffineInput *poses,int count,int mode,RefComplexResult *outputs);
int ref_convex_support(RefConvexShape shape,const RefDoubleVector *vertices,const RefDoubleVector *directions,int count,RefDoubleVector *outputs);
int ref_convex_query(RefConvexShape a,const RefDoubleVector *verticesA,RefConvexShape b,const RefDoubleVector *verticesB,
    RefConvexTransform first,RefConvexTransform second,int mode,RefDoubleVector axis,double tolerance,RefConvexResult *output);
typedef struct { RefConvexTransform first,second; } RefConvexPoses;
int ref_convex_smart_sequence(RefConvexShape a,const RefDoubleVector *verticesA,RefConvexShape b,const RefDoubleVector *verticesB,
    RefConvexPoses initial,const RefConvexPoses *poses,int count,RefConvexResult *outputs);
RefWorld *ref_world_create_lateral(const char*,const char*,const char*,unsigned int,int,float,float,float);
typedef struct {
    double startTime,currentLapTime,lastLapTime,bestLapTime,deltaBestLapTime,totalTime;
    float topSpeed,lapTopSpeed,lapMinimumSpeed,currentMinimumSpeed,distanceFromStart,distanceRaced;
    int laps,remainingLaps,backwardCrossings,previousSegment,commitBestLapTime,raceState;
    unsigned int flags;
} RefLapTiming;
int ref_world_laps_init(RefWorld*,int,int);
int ref_world_laps_manage(RefWorld*,RefTrackPosition,float,float,unsigned int,unsigned int,double,unsigned int,int,int,RefLapTiming*);
typedef struct { RefTrackPosition position;float speed,width;unsigned int flags,collision; } RefRaceProgressSample;
typedef struct { RefLapTiming timing;double behindLeader,behindPrevious,beforeNext;int lapsBehindLeader,position; } RefRaceProgressCar;
int ref_world_progress_init(RefWorld*,const int*,int);
int ref_world_progress_step(RefWorld*,const RefRaceProgressSample*,double,unsigned int,RefRaceProgressCar*,int*);
typedef struct { float baseTime,fuelFlow,repairFactor,tireFactor,tireChangeTime; } RefRacePitRules;
typedef struct {
    unsigned int flags,raceCommand; int stops,stall,occupant,stopType,services,menuRequests;
    double startTime,totalTime,scheduledTime; float penaltyTime;
    char message[32];
} RefRacePitState;
typedef struct { int count,occupant,cars[4]; float minimum,maximum; } RefRacePitStall;
int ref_world_race_registration(RefWorld*,int,const char*,float,float,int);
int ref_world_race_pits_init(RefWorld*,int);
int ref_world_race_stall(RefWorld*,int,RefRacePitStall*);
int ref_world_race_command(RefWorld*,int,unsigned int,RefPitSetup,float,int,int,int,float,int,int);
int ref_world_race_manage(RefWorld*,int,RefTrackPosition,unsigned int,int,float,float,double,int,int,RefRacePitRules,int);
int ref_world_race_pit_time(RefWorld*,int,double,int,RefRacePitRules);
int ref_world_race_state(RefWorld*,int,RefRacePitState*);
int ref_world_race_complete_menu(RefWorld*,int);
const unsigned char *ref_png_load(const char *path, float gamma, int *width, int *height, int *count);
const char *ref_png_version(void);
const unsigned char *ref_texture_sgi(const char *path, int maximum, int *count, int *levels);
const unsigned char *ref_texture_mips(const unsigned char *pixels, int width, int height, int channels, int maximum, int mipmaps, int *count, int *levels);
int ref_texture_mipmap_rule(const char *path, int requested);
const char *ref_ac_load_json(const char *path,int car,int textureUnits);
void ref_car_reflections(float distance, float yaw, int level, float *output);

void ref_car_track_shadow(const float *track, const float *car, const float *position, float yaw, int level, int present, float *output);

void ref_car_shadow_scale_order(const double *ratios, int detailed, float *output, int *loads);

void ref_camera_zoom(int head,int identifier,float saved,const int *commands,const float *positions,int count,float *output);
void ref_camera_trackside(const float *bounds,const float *position,const float *roadPosition,int zoom,float *output);
const char *ref_world_track_camera(RefWorld *world,int index,float *position);
void ref_camera_survey(const float *bounds, const float *position, int kind, float *output);
void ref_camera_driver(const float *body, const float *position, float *output);

void ref_camera_mirror(const float *body,const float *position,int width,int height,float *output);
void ref_camera_mirror_flags(int *output);

#ifdef __cplusplus
}
#endif
