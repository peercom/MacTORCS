// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2 steer/brake/aero/axle/wheel/suspension
// and differential reconfiguration. Copyright (C) Eric Espie, Bernhard Wymann;
// upstream GPL-2.0-or-later.
import Foundation

extension DriverControlDefinition {
    mutating func reconfigure(_ s: inout PitSetup) {
        if s[.steeringLock].adjust() { steeringLock=s[.steeringLock].value }
        if s[.brakeRepartition].adjust() { brakes.repartition=s[.brakeRepartition].value }
        if s[.brakePressure].adjust() { brakes.coefficient=s[.brakePressure].value }
    }
}
extension AerodynamicsDefinition {
    mutating func reconfigureWing(_ index: Int,setup s: inout PitSetup) {
        if s[.wingAngle,index].adjust() {
            if index==0 { frontWing.angle=s[.wingAngle,index].value }
            else {
                let old=rearWing.dragCoefficient*sin(rearWing.angle)
                rearWing.angle=s[.wingAngle,index].value
                draftingCoefficient += old
                draftingCoefficient -= rearWing.dragCoefficient*sin(rearWing.angle)
            }
        }
    }
}
extension RunningGearConfiguration {
    mutating func reconfigureAxle(_ i: Int,setup s: inout PitSetup) {
        if s[.antiRoll,i].adjust() { axles[i].antiRollSpring=s[.antiRoll,i].value }
        s[.thirdTravel,i].adjust()
        let old=axles[i].thirdSuspension
        var spring=old.springRate,bump=old.bump,rebound=old.rebound
        if s[.thirdSpring,i].adjust() { spring=s[.thirdSpring,i].value }
        if s[.thirdBump,i].adjust() { bump = .init(slow:s[.thirdBump,i].value,fast:s[.thirdBump,i].value,threshold:bump.threshold) }
        if s[.thirdRebound,i].adjust() { rebound = .init(slow:s[.thirdRebound,i].value,fast:s[.thirdRebound,i].value,threshold:rebound.threshold) }
        axles[i].thirdSuspension = .init(springRate:spring,preload:0,rest:s[.thirdTravel,i].value,travel:s[.thirdTravel,i].value,
            bellcrank:old.bellcrank,packers:old.packers,bump:bump,rebound:rebound)
    }
    mutating func reconfigureWheel(_ i: Int,setup s: inout PitSetup) {
        if s[.camber,i].adjust() { wheels[i].force.camber=s[.camber,i].value }
        if s[.toe,i].adjust() { wheels[i].force.toe=s[.toe,i].value }
        if s[.caster,i].adjust() { wheels[i].force.caster=s[.caster,i].value }
        s[.rideHeight,i].adjust()
        let old=wheels[i].suspension
        var spring=old.springRate,packers=old.packers
        var slowBump=old.bump.slow,fastBump=old.bump.fast,bumpThreshold=old.bump.threshold
        var slowRebound=old.rebound.slow,fastRebound=old.rebound.fast,reboundThreshold=old.rebound.threshold
        if s[.spring,i].adjust() { spring=s[.spring,i].value }
        if s[.packers,i].adjust() { packers=s[.packers,i].value }
        if s[.slowBump,i].adjust() { slowBump=s[.slowBump,i].value }
        if s[.slowRebound,i].adjust() { slowRebound=s[.slowRebound,i].value }
        if s[.fastBump,i].adjust() { fastBump=s[.fastBump,i].value }
        if s[.fastRebound,i].adjust() { fastRebound=s[.fastRebound,i].value }
        if s[.bumpThreshold,i].adjust() { bumpThreshold=s[.bumpThreshold,i].value }
        if s[.reboundThreshold,i].adjust() { reboundThreshold=s[.reboundThreshold,i].value }
        wheels[i].suspension = .init(springRate:spring,preload:wheels[i].staticLoad,rest:s[.rideHeight,i].value,
            travel:old.travel,bellcrank:old.bellcrank,packers:packers,
            bump:.init(slow:slowBump,fast:fastBump,threshold:bumpThreshold),
            rebound:.init(slow:slowRebound,fast:fastRebound,threshold:reboundThreshold))
    }
}
extension DifferentialDefinition {
    mutating func reconfigure(_ i: Int,setup s: inout PitSetup,inputInertias: SIMD2<Float>) {
        if s[.differentialRatio,i].adjust() {
            ratio=s[.differentialRatio,i].value
            feedbackInertia=inertia*ratio*ratio+(inputInertias.x+inputInertias.y)/efficiency
        }
        if s[.minimumTorqueBias,i].adjust() { minimumTorqueBias=s[.minimumTorqueBias,i].value }
        if s[.maximumTorqueBias,i].adjust() {
            torqueBiasRange=s[.maximumTorqueBias,i].value-minimumTorqueBias
            if torqueBiasRange<0 { torqueBiasRange=0; s[.maximumTorqueBias,i].value=minimumTorqueBias }
        }
        if s[.slipBias,i].adjust() { maximumSlipBias=s[.slipBias,i].value }
        if s[.lockingTorque,i].adjust() { lockingTorque=s[.lockingTorque,i].value }
        if s[.brakingLockingTorque,i].adjust() { brakingLockingTorque=s[.brakingLockingTorque,i].value }
        // diffType is setup/UI metadata; upstream does not reconfigure type.
    }
}
