// SPDX-License-Identifier: GPL-2.0-only
// This bridge invokes original TORCS functions; no physics is reimplemented here.
#include "CReference.h"
#include "sim.h"
#include <cstdlib>


RefSuspensionResult ref_suspension(RefSuspensionConfig c, float x, float v) {
    tSuspension s{};
    s.spring.K = -c.springRate;
    s.spring.F0 = c.preload / c.bellcrank;
    s.spring.x0 = c.bellcrank * c.rest;
    s.spring.xMax = c.travel;
    s.spring.bellcrank = c.bellcrank;
    s.spring.packers = c.packers;
    s.damper.bump = {c.slowBump, c.bumpThreshold, c.fastBump, (c.slowBump-c.fastBump)*c.bumpThreshold};
    s.damper.rebound = {c.slowRebound, c.reboundThreshold, c.fastRebound, (c.slowRebound-c.fastRebound)*c.reboundThreshold};
    s.x=x; s.v=v;
    SimSuspCheckIn(&s); SimSuspUpdate(&s);
    return {s.x,s.force,s.state};
}
RefBrakeResult ref_brake(float coefficient, float radius, float pressure, float speed, float spin, float temperature, float dt) {
    tCar car{}; tWheel wheel{}; tBrake brake{};
    car.DynGC.vel.x=speed; wheel.spinVel=spin;
    brake.coeff=coefficient; brake.radius=radius; brake.pressure=pressure; brake.temp=temperature;
    SimDeltaTime=dt; SimBrakeUpdate(&car,&wheel,&brake);
    return {brake.Tq,brake.temp};
}
RefBrakePressures ref_brake_pressures(float command, float coefficient, float repartition, float clickValue, int maxClicks, int clicks) {
    tCar car{}; tCarCtrl ctrl{}; car.ctrl=&ctrl;
    ctrl.brakeCmd=command; ctrl.brakeRepartitionCmd=clicks;
    car.brkSyst.rep=repartition; car.brkSyst.coeff=coefficient;
    car.brkSyst.repCmdClickValue=clickValue; car.brkSyst.repCmdMaxClicks=maxClicks;
    SimBrakeSystemUpdate(&car);
    return {car.wheel[FRNT_RGT].brake.pressure,car.wheel[REAR_RGT].brake.pressure};
}
RefSteeringResult ref_steering(float previous, float command, float lock, float speed, float wheelbase, float track, float dt) {
    tCar car{}; tCarCtrl ctrl{}; car.ctrl=&ctrl; ctrl.steer=command;
    car.steer={lock,speed,previous}; car.wheelbase=wheelbase; car.wheeltrack=track;
    SimDeltaTime=dt; SimSteerUpdate(&car);
    return {car.steer.steer,car.wheel[FRNT_RGT].steer,car.wheel[FRNT_LFT].steer};
}
float ref_unit_to_si(const char *unit, float value) { return GfParmUnit2SI(unit,value); }
float ref_si_to_unit(const char *unit, float value) { return GfParmSI2Unit(unit,value); }

RefTireThermalState ref_tire_thermal(RefTireThermalConfig c, RefTireThermalState state,
    float load, float slip, float spin, float radius, float localTemperature, float localPressure,
    int skillLevel, float tireFactor, float dt, int reset) {
    tCar car{}; tCarElt elt{}; car.carElt = &elt; elt._skillLevel = skillLevel;
    car.localTemperature = localTemperature; car.localPressure = localPressure;
    auto &w = car.wheel[0];
    w.pressure = c.pressure; w.initialTemperature = c.initialTemperature; w.idealTemperature = c.idealTemperature;
    w.treadMass = c.treadMass; w.baseMass = c.baseMass; w.tireGasMass = c.gasMass;
    w.tireConvectionSurface = c.convectionSurface; w.hysteresisFactor = c.hysteresisFactor; w.wearFactor = c.wearFactor;
    w.currentPressure = state.pressure; w.currentTemperature = state.temperature;
    w.currentGraining = state.graining; w.currentGripFactor = state.grip; w.currentWear = state.wear;
    w.tireZForce = load; w.tireSlip = slip; w.spinVel = spin; w.radius = radius;
    const auto oldDelta = SimDeltaTime, oldFactor = rulesTireFactor;
    SimDeltaTime = dt; rulesTireFactor = tireFactor;
    if (reset) SimWheelResetWear(&car, 0); else SimWheelUpdateTire(&car, 0);
    SimDeltaTime = oldDelta; rulesTireFactor = oldFactor;
    return {w.currentPressure, w.currentTemperature, w.currentGraining, w.currentGripFactor, w.currentWear};
}
RefWheelRotation ref_wheel_rotation(float spin, float previousSpin, float angle, float drivetrainSpin,
    float tireTorque, float brakeTorque, float wheelInertia, float axleInertia, float dt, int axle, int freeWheel) {
    tCar car{}; tCarElt elt{}; car.carElt = &elt;
    if (axle < 0 || axle > 1) return {};
    // Both axle wheels receive valid inertia because the unchanged original loops over the pair.
    for (int i = axle*2; i < axle*2+2; ++i) {
        auto &w = car.wheel[i];
        w.spinVel = spin; w.prespinVel = previousSpin; w.relPos.ay = angle; w.in.spinVel = drivetrainSpin;
        w.spinTq = tireTorque; w.brake.Tq = brakeTorque; w.I = wheelInertia;
    }
    car.axle[axle].I = axleInertia;
    const auto oldDelta = SimDeltaTime; SimDeltaTime = dt;
    if (freeWheel) SimUpdateFreeWheels(&car, axle);
    const auto input = car.wheel[axle*2].in.spinVel;
    SimWheelUpdateRotation(&car); SimDeltaTime = oldDelta;
    const auto &w = car.wheel[axle*2];
    return {w.spinVel, w.prespinVel, w.relPos.ay, input, elt._wheelSpinVel(axle*2)};
}

RefWheelKinematics ref_wheel_kinematics(RefTrackVector attachment, RefTrackVector worldPosition,
    float roll, float pitch, float yaw, float velocityX, float velocityY, float yawVelocity) {
    tCar car{};
    car.DynGCg.pos.x = worldPosition.x; car.DynGCg.pos.y = worldPosition.y; car.DynGCg.pos.z = worldPosition.z;
    car.DynGC.pos.ax = roll; car.DynGC.pos.ay = pitch; car.DynGC.pos.az = yaw;
    car.DynGC.vel.x = velocityX; car.DynGC.vel.y = velocityY; car.DynGC.vel.az = yawVelocity;
    auto &w = car.wheel[0]; w.staticPos.x = attachment.x; w.staticPos.y = attachment.y; w.staticPos.z = attachment.z;
    SimCarUpdateWheelPos(&car);
    return {{w.pos.x, w.pos.y, w.pos.z}, w.bodyVel.x, w.bodyVel.y};
}
RefAxleForce ref_axle_force(RefSuspensionConfig c, float antiRollSpring, float rightDisplacement,
    float leftDisplacement, float rightVelocity, float leftVelocity, int axle) {
    if (axle < 0 || axle > 1) return {};
    tCar car{}; auto &a = car.axle[axle]; auto &s = a.thirdSusp;
    a.arbSuspSpringK = antiRollSpring;
    s.spring.K = -c.springRate; s.spring.F0 = c.preload/c.bellcrank;
    s.spring.x0 = c.bellcrank*c.rest; s.spring.xMax = c.travel;
    s.spring.bellcrank = c.bellcrank; s.spring.packers = c.packers;
    s.damper.bump = {c.slowBump, c.bumpThreshold, c.fastBump, (c.slowBump-c.fastBump)*c.bumpThreshold};
    s.damper.rebound = {c.slowRebound, c.reboundThreshold, c.fastRebound, (c.slowRebound-c.fastRebound)*c.reboundThreshold};
    car.wheel[axle*2].susp.x = rightDisplacement; car.wheel[axle*2+1].susp.x = leftDisplacement;
    car.wheel[axle*2].susp.v = rightVelocity; car.wheel[axle*2+1].susp.v = leftVelocity;
    SimAxleUpdate(&car, axle);
    return {car.wheel[axle*2].axleFz, car.wheel[axle*2+1].axleFz, s.x, s.v, s.force};
}
