// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/transmission.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public enum DriveLayout: Int32, Sendable { case rear = 0, front = 1, all = 2 }
public struct GearDefinition: Sendable {
    public let ratio, drivenInertia, freeInertia, efficiency: Float
}
public struct TransmissionDefinition: Sendable {
    public let layout: DriveLayout
    public internal(set) var front, rear, central: DifferentialDefinition?
    /// Slots r, n, 1...8; lookup index is selected gear + 1.
    public internal(set) var gears: [GearDefinition]
    public let minimumGear, maximumGear, gearOffset, gearCount: Int
    public let shiftTime: Float
    public let wheelFeedbackInertias: SIMD4<Float>
    let gearInertias: [Float], reverseRatio: Float
    public init(parameters p: ParameterDocument, engine: EngineDefinition, runningGear: RunningGearConfiguration) throws {
        switch p.section("Drivetrain")?.string("type",default:"RWD") ?? "RWD" {
        case "RWD": layout = .rear
        case "FWD": layout = .front
        case "4WD": layout = .all
        default: throw ParameterError.invalid("Unsupported drivetrain type")
        }
        shiftTime = p.section("Gearbox")?.number("shift time",default:0.2) ?? 0.2
        wheelFeedbackInertias = SIMD4(runningGear.wheels[0].feedbackInertia,runningGear.wheels[1].feedbackInertia,
                                      runningGear.wheels[2].feedbackInertia,runningGear.wheels[3].feedbackInertia)
        front = layout == .rear ? nil : try DifferentialDefinition(parameters:p,section:"Front Differential",
            inputInertias:SIMD2(wheelFeedbackInertias.x,wheelFeedbackInertias.y))
        rear = layout == .front ? nil : try DifferentialDefinition(parameters:p,section:"Rear Differential",
            inputInertias:SIMD2(wheelFeedbackInertias.z,wheelFeedbackInertias.w))
        central = layout == .all ? try DifferentialDefinition(parameters:p,section:"Central Differential",
            inputInertias:SIMD2(front!.feedbackInertia,rear!.feedbackInertia)) : nil
        let finalRatio: Float
        switch layout { case .rear: finalRatio = rear!.ratio; case .front: finalRatio = front!.ratio; case .all: finalRatio = central!.ratio }
        guard shiftTime.isFinite, layout != .all || finalRatio != 0 else { throw ParameterError.invalid("Invalid transmission configuration") }
        let names = ["r","n","1","2","3","4","5","6","7","8"]
        gearInertias = names.map { p.section("Gearbox/gears/"+$0)?.number("inertia",default:0) ?? 0 }
        reverseRatio = p.section("Gearbox/gears/r")?.number("ratio",default:0) ?? 0
        var entries = [GearDefinition](repeating:.init(ratio:0,drivenInertia:0,freeInertia:0,efficiency:1),count:10)
        var maxGear = 0, rawRatio: Float = 0
        for i in (0..<10).reversed() {
            let section = p.section("Gearbox/gears/"+names[i])
            rawRatio = section?.number("ratio",default:0) ?? 0
            if maxGear == 0 && rawRatio != 0 { maxGear = i-1 }
            if rawRatio == 0 { continue }
            let efficiency = min(1,max(0,section?.number("efficiency",default:1) ?? 1))
            let inertia = section?.number("inertia",default:0) ?? 0
            let ratio = rawRatio*finalRatio
            let square = rawRatio*rawRatio*finalRatio*finalRatio
            let driven = (engine.inertia+inertia)*square, free = inertia*square
            guard ratio.isFinite, driven.isFinite, free.isFinite, efficiency > 0, inertia >= 0 else {
                throw ParameterError.invalid("Invalid or singular gear \(names[i])")
            }
            entries[i] = GearDefinition(ratio:ratio,drivenInertia:driven,freeInertia:free,efficiency:efficiency)
        }
        gears = entries; maximumGear = maxGear; minimumGear = rawRatio == 0 ? 0 : -1
        gearOffset = rawRatio == 0 ? 0 : 1; gearCount = maxGear+1
    }
}

public struct TransmissionState: Sendable {
    public private(set) var definition: TransmissionDefinition
    public private(set) var gear = 0
    public private(set) var clutch = ClutchState()
    public private(set) var currentRatio: Float = 0
    public private(set) var currentInertia: Float
    public private(set) var wheelInputs = FourWheels<DriveAxis>(.init(inertia:0),.init(inertia:0),.init(inertia:0),.init(inertia:0))
    public private(set) var frontInput = DriveAxis(inertia:0), rearInput = DriveAxis(inertia:0), centralInput = DriveAxis(inertia:0)
    public private(set) var frontFeedback: DriveAxis, rearFeedback: DriveAxis, centralFeedback: DriveAxis
    public init(definition d: TransmissionDefinition) {
        definition = d; currentInertia = d.gears[1].freeInertia
        frontFeedback = DriveAxis(inertia:d.front?.feedbackInertia ?? 0)
        rearFeedback = DriveAxis(inertia:d.rear?.feedbackInertia ?? 0)
        centralFeedback = DriveAxis(inertia:d.central?.feedbackInertia ?? 0)
        updateOutputInertias() // Initial setup does not initialize primary input inertia.
    }
    private mutating func updateOutputInertias() {
        let efficiency = definition.gears[gear+1].efficiency
        switch definition.layout {
        case .rear:
            for i in 2..<4 { wheelInputs[i].inertia = currentInertia/2+definition.wheelFeedbackInertias[i]/efficiency }
        case .front:
            for i in 0..<2 { wheelInputs[i].inertia = currentInertia/2+definition.wheelFeedbackInertias[i]/efficiency }
        case .all:
            frontInput.inertia = currentInertia/2+frontFeedback.inertia/efficiency
            rearInput.inertia = currentInertia/2+rearFeedback.inertia/efficiency
            for i in 0..<4 { wheelInputs[i].inertia = currentInertia/4+definition.wheelFeedbackInertias[i]/efficiency }
        }
    }
    /// Receives already-checked control transfer (1-clutch pedal). The releasing
    /// branch consumes the whole tick even when its timer reaches zero.
    public mutating func updateGear(requested: Int, clutchTransfer: Float, throttle: inout Float, dt: Float = 0.002) {
        clutch.transfer = clutchTransfer
        let old = definition.gears[gear+1]
        currentInertia = old.drivenInertia*clutch.transfer+old.freeInertia*(1-clutch.transfer)
        if clutch.phase == .releasing {
            clutch.timeToRelease -= dt
            if clutch.timeToRelease <= 0 { clutch.phase = .released }
            else if clutch.transfer > 0.99 {
                clutch.transfer = 0; currentInertia = old.freeInertia
                if throttle > 0.1 { throttle = 0.1 }
            }
        } else if (requested > gear && requested <= definition.maximumGear) || (requested < gear && requested >= definition.minimumGear) {
            gear = requested; clutch.phase = .releasing
            clutch.timeToRelease = gear != 0 ? definition.shiftTime : 0
            let entry = definition.gears[gear+1]
            currentRatio = entry.ratio; currentInertia = entry.freeInertia
            switch definition.layout {
            case .rear: rearInput.inertia = currentInertia+rearFeedback.inertia/entry.efficiency
            case .front: frontInput.inertia = currentInertia+frontFeedback.inertia/entry.efficiency
            case .all: centralInput.inertia = currentInertia+centralFeedback.inertia/entry.efficiency
            }
            // Original cached axis inertias change on shifts, not on each clutch tick.
            updateOutputInertias()
        }
    }
    /// Original prestart path calls RPM coupling with a stationary axle and does
    /// not run differentials or wheel rotation.
    public mutating func updatePrestartRPM(engineDefinition: EngineDefinition, engine: inout EngineState,
                                           fuel: Float, dt: Float = 0.002, random: () -> Float) {
        _ = engine.updateRPM(definition:engineDefinition,axleSpeed:0,overallRatio:currentRatio,gear:gear,
            clutch:&clutch,fuel:fuel,dt:dt,random:random)
    }
    /// Runs after wheel forces and before wheel rotation. The free-axle callback
    /// performs the original undriven wheel update using the same wheel state.
    public mutating func update(engineDefinition: EngineDefinition, engine: inout EngineState, fuel: Float,
                                feedback: FourWheels<DriveAxis>, dt: Float = 0.002,
                                random: () -> Float, freeAxle: (Int) -> SIMD2<Float>) -> SIMD4<Float> {
        let transfer = min(clutch.transfer*3,1), ratio = currentRatio, selectedGear = gear
        let driveTorque = engine.torque*ratio*transfer
        var coupledClutch = clutch
        func reaction(_ axleSpeed: Float) -> Float {
            engine.updateRPM(definition:engineDefinition,axleSpeed:axleSpeed,overallRatio:ratio,gear:selectedGear,
                             clutch:&coupledClutch,fuel:fuel,dt:dt,random:random)
        }
        switch definition.layout {
        case .rear:
            rearInput.torque = driveTorque
            let output = definition.rear!.update(driveTorque:driveTorque,first:feedback.rearRight,second:feedback.rearLeft,
                outputInertias:SIMD2(wheelInputs.rearRight.inertia,wheelInputs.rearLeft.inertia),dt:dt,primary:true,engineReaction:reaction)
            wheelInputs.rearRight = output.first; wheelInputs.rearLeft = output.second
            let free = freeAxle(0); wheelInputs.frontRight.spin = free.x; wheelInputs.frontLeft.spin = free.y
        case .front:
            frontInput.torque = driveTorque
            let output = definition.front!.update(driveTorque:driveTorque,first:feedback.frontRight,second:feedback.frontLeft,
                outputInertias:SIMD2(wheelInputs.frontRight.inertia,wheelInputs.frontLeft.inertia),dt:dt,primary:true,engineReaction:reaction)
            wheelInputs.frontRight = output.first; wheelInputs.frontLeft = output.second
            let free = freeAxle(1); wheelInputs.rearRight.spin = free.x; wheelInputs.rearLeft.spin = free.y
        case .all:
            let d = definition.central!
            centralInput.torque = driveTorque
            frontFeedback.spin = (feedback.frontRight.spin+feedback.frontLeft.spin)/2
            rearFeedback.spin = (feedback.rearRight.spin+feedback.rearLeft.spin)/2
            frontFeedback.torque = (feedback.frontRight.torque+feedback.frontLeft.torque)/d.ratio
            rearFeedback.torque = (feedback.rearRight.torque+feedback.rearLeft.torque)/d.ratio
            frontFeedback.brakeTorque = (feedback.frontRight.brakeTorque+feedback.frontLeft.brakeTorque)/d.ratio
            rearFeedback.brakeTorque = (feedback.rearRight.brakeTorque+feedback.rearLeft.brakeTorque)/d.ratio
            let central = d.update(driveTorque:driveTorque,first:frontFeedback,second:rearFeedback,
                outputInertias:SIMD2(frontInput.inertia,rearInput.inertia),dt:dt,primary:true,engineReaction:reaction)
            frontInput = central.first; rearInput = central.second
            let front = definition.front!.update(driveTorque:frontInput.torque,first:feedback.frontRight,second:feedback.frontLeft,
                outputInertias:SIMD2(wheelInputs.frontRight.inertia,wheelInputs.frontLeft.inertia),dt:dt)
            wheelInputs.frontRight = front.first; wheelInputs.frontLeft = front.second
            let rear = definition.rear!.update(driveTorque:rearInput.torque,first:feedback.rearRight,second:feedback.rearLeft,
                outputInertias:SIMD2(wheelInputs.rearRight.inertia,wheelInputs.rearLeft.inertia),dt:dt)
            wheelInputs.rearRight = rear.first; wheelInputs.rearLeft = rear.second
        }
        clutch = coupledClutch
        return SIMD4(wheelInputs.frontRight.spin,wheelInputs.frontLeft.spin,wheelInputs.rearRight.spin,wheelInputs.rearLeft.spin)
    }
}

extension TransmissionState {
    // RemoveCar changes gear only; it does not perform a normal shift.
    mutating func setRemovalGear(_ gear: Int) { self.gear = gear }
}

extension TransmissionState {
    mutating func reconfigure(_ s: inout PitSetup,engineInertia: Float) {
        let w=definition.wheelFeedbackInertias
        if definition.layout != .rear {
            definition.front!.reconfigure(0,setup:&s,inputInertias:SIMD2(w.x,w.y))
            frontFeedback.inertia=definition.front!.feedbackInertia
        }
        if definition.layout != .front {
            definition.rear!.reconfigure(1,setup:&s,inputInertias:SIMD2(w.z,w.w))
            rearFeedback.inertia=definition.rear!.feedbackInertia
        }
        if definition.layout == .all {
            definition.central!.reconfigure(2,setup:&s,inputInertias:SIMD2(frontFeedback.inertia,rearFeedback.inertia))
            centralFeedback.inertia=definition.central!.feedbackInertia
        }
        let final: Float
        switch definition.layout { case .rear: final=definition.rear!.ratio; case .front: final=definition.front!.ratio; case .all: final=definition.central!.ratio }
        func gearDefinition(_ i: Int,_ ratio: Float) -> GearDefinition {
            let inertia=definition.gearInertias[i],square=ratio*ratio*final*final
            return .init(ratio:ratio*final,drivenInertia:(engineInertia+inertia)*square,freeInertia:inertia*square,efficiency:definition.gears[i].efficiency)
        }
        for i in (2..<10).reversed() where definition.gears[i].ratio>0 {
            s[.gearRatio,i-2].adjust()
            definition.gears[i]=gearDefinition(i,s[.gearRatio,i-2].value)
        }
        if definition.gears[0].ratio != 0 { definition.gears[0]=gearDefinition(0,definition.reverseRatio) }
        gear=0
        // curOverallRatio/curI, clutch and output-axis inertias remain cached.
    }
}
