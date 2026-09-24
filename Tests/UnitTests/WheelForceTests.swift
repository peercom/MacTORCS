// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

final class WheelForceTests: XCTestCase {
    func withRoad(_ body: (TrackRoad, ReferenceWorld) throws -> Void) throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let parameters = try ParameterDocument.parse(Data(contentsOf: fixtures.appendingPathComponent("aalborg.xml")), entities: [
            "default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
            "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))], allowLegacyLatin1: true)
        let road = try TrackBuilder.buildRoad(parameters: parameters)
        let content = try ReferenceContent(fixtures: fixtures)
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try body(road, world)
    }
    func input(contact: TrackLocalPosition, main: Int, variant: Int) -> RefWheelForceInput {
        var p = RefWheelForceInput()
        p.contact = RefTrackPosition(segment: Int32(contact.segment), mode: Int32(contact.mode.rawValue), toStart: contact.toStart,
            toRight: contact.toRight, toMiddle: contact.toMiddle, toLeft: contact.toLeft)
        p.suspension = RefSuspensionConfig(springRate: 175000, preload: 3200, rest: 0.19, travel: 0.5,
            bellcrank: [Float(0.5), 1, 1.7][variant % 3], packers: 0.015,
            slowBump: 3100, fastBump: 1100, bumpThreshold: 0.4, slowRebound: 4900, fastRebound: 2200, reboundThreshold: 0.6)
        p.mainSegment = Int32(main); p.wheelIndex = Int32(variant % 4); p.skillLevel = Int32(variant % 5)
        p.flags = 12; p.suspensionFlags = Int32(variant % 3)
        p.displacement = [Float(0.05), 0.18, 0.5][variant % 3] * p.suspension.bellcrank
        p.suspensionVelocity = [Float(-15), -0.2, 0, 0.4, 12][variant % 5]
        p.relativeVelocity = [Float(-3), 0, 5][(variant / 3) % 3]
        p.radius = 0.32; p.mass = 20; p.tireWidth = 0.245; p.friction = 1.1
        p.magicC = 1.6; p.magicB = 18.75; p.magicE = 0.7
        p.loadMinimum = 0.8; p.loadMaximum = 1.6; p.loadExponent = log(0.25); p.operatingLoad = 3800
        p.camber = -0.03; p.caster = 0.09; p.toe = 0.002
        p.bodyVelocityX = [Float(0), 0.0000001, 0.1, 1.99, 20, -35][variant % 6]
        p.bodyVelocityY = variant % 6 < 2 ? 0 : Float(variant % 7 - 3) * 1.3
        p.steer = Float(variant % 9 - 4) * 0.15; p.spin = [Float(0), 2, -50, 120, 250][variant % 5]
        p.axleForce = Float(variant % 5 - 2) * 1000; p.grip = [Float(0.55), 0.9, 1][variant % 3]; p.dt = 0.002
        p.previousLateral = 712.3125; p.previousLongitudinal = -1319.6875
        return p
    }
    func native(_ p: RefWheelForceInput, ride: inout WheelRideState, state: inout WheelForceState, track: TrackGeometry) throws -> WheelForceResult {
        let s = p.suspension
        let suspension = SuspensionDefinition(springRate: s.springRate, preload: s.preload, rest: s.rest, travel: s.travel,
            bellcrank: s.bellcrank, packers: s.packers,
            bump: .init(slow: s.slowBump, fast: s.fastBump, threshold: s.bumpThreshold),
            rebound: .init(slow: s.slowRebound, fast: s.fastRebound, threshold: s.reboundThreshold))
        let d = WheelForceDefinition(radius: p.radius, mass: p.mass, tireWidth: p.tireWidth, friction: p.friction,
            magicB: p.magicB, magicC: p.magicC, magicE: p.magicE, loadMinimum: p.loadMinimum, loadMaximum: p.loadMaximum,
            loadExponent: p.loadExponent, operatingLoad: p.operatingLoad, camber: p.camber, caster: p.caster, toe: p.toe)
        let contact = TrackLocalPosition(segment: Int(p.contact.segment), toStart: p.contact.toStart, toRight: p.contact.toRight,
            toMiddle: p.contact.toMiddle, toLeft: p.contact.toLeft, mode: .segment)
        return try state.update(ride: &ride, contact: contact, carSegment: Int(p.mainSegment), track: track, definition: d,
            suspension: suspension, wheelIndex: Int(p.wheelIndex), skillLevel: Int(p.skillLevel),
            bodyVelocity: SIMD2(p.bodyVelocityX, p.bodyVelocityY), steer: p.steer, spin: p.spin, axleForce: p.axleForce, grip: p.grip, dt: p.dt)
    }
    func compare(_ n: WheelForceResult, _ o: RefWheelForceResult, ride: WheelRideState, state: WheelForceState,
                 allowNonfinite: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Float {
        XCTAssertEqual(ride.flags, o.flags, file: file, line: line)
        XCTAssertEqual(n.otherSurface ?? -1, Int(o.otherSurface), file: file, line: line)
        let fields: [(String, Float, Float)] = [
            ("x", n.force.x, o.force.x), ("y", n.force.y, o.force.y), ("z", n.force.z, o.force.z),
            ("suspension", n.suspensionForce, o.suspensionForce), ("relativeVelocity", ride.relativeVelocity, o.relativeVelocity),
            ("height", n.relativeHeight, o.relativeHeight), ("camber", n.relativeCamber, o.relativeCamber), ("yaw", n.relativeYaw, o.relativeYaw),
            ("spinTorque", n.spinTorque, o.spinTorque), ("roll", n.rollingResistance, o.rollingResistance),
            ("angle", n.slipAngle, o.slipAngle), ("sx", n.longitudinalSlip, o.longitudinalSlip),
            ("load", n.tireLoad, o.tireLoad), ("slip", n.tireSlip, o.tireSlip), ("skid", n.skid, o.skid),
            ("sideSpeed", n.sideSlipSpeed, o.sideSlipSpeed), ("slipSpeed", n.longitudinalSlipSpeed, o.longitudinalSlipSpeed),
            ("feedbackSpin", n.feedbackSpin, o.feedbackSpin), ("feedbackTorque", n.feedbackTorque, o.feedbackTorque),
            ("feedbackBrake", n.feedbackBrakeTorque, o.feedbackBrakeTorque),
            ("previousLateral", state.previousLateral, o.previousLateral), ("previousLongitudinal", state.previousLongitudinal, o.previousLongitudinal),
            ("contribution", n.otherSurfaceContribution, o.otherSurfaceContribution)]
        var worst: Float = 0
        for (name, a, b) in fields {
            if a.isFinite && b.isFinite {
                worst = max(worst, abs(a-b)); XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-6 * abs(b), name, file: file, line: line)
            } else {
                XCTAssertTrue(allowNonfinite, "Unexpected nonfinite \(name)", file: file, line: line)
                XCTAssertTrue((a.isNaN && b.isNaN) || (a.isInfinite && a == b), "Classification \(name): \(a) vs \(b)", file: file, line: line)
            }
        }
        return worst
    }
    func testForceSweepAgainstOriginal() throws {
        try withRoad { road, world in
            var count = 0, blended = 0, extended = 0, zeroLoad = 0, worst: Float = 0
            var roles: Set<Int> = [], neighbours: Set<Int> = []
            for offset in stride(from: 0, to: road.geometry.mainSegments.count, by: 19) {
                let main = road.geometry.mainSegments[offset], seg = road.geometry.segments[main]
                for lateral: Float in [-9, -0.05, 0.05, 4, seg.width - 0.05, seg.width + 0.05, seg.width + 12] {
                    let xy = road.geometry.localToGlobal(.init(segment: main, toStart: seg.extent * 0.6, toRight: lateral))
                    let contact = try road.geometry.globalToLocal(xy, startingAt: main, mode: .segment)
                    for variant in 0..<60 {
                        let p = input(contact: contact, main: main, variant: variant)
                        var ride = WheelRideState(displacement: p.displacement, relativeVelocity: p.relativeVelocity, flags: p.flags,
                            suspensionVelocity: p.suspensionVelocity, suspensionFlags: p.suspensionFlags)
                        var state = WheelForceState(previousLateral: p.previousLateral, previousLongitudinal: p.previousLongitudinal)
                        let original = try world.wheelForce(p)
                        let n = try native(p, ride: &ride, state: &state, track: road.geometry)
                        worst = max(worst, compare(n, original, ride: ride, state: state))
                        XCTAssertEqual(ride.flags & 12, 0, "Force stage clears original ONAIR and unrelated flags")
                        if n.otherSurfaceContribution > 0 { blended += 1; neighbours.insert(n.otherSurface!) }
                        if ride.flags & 2 != 0 { extended += 1 }
                        if n.tireLoad == 0 { zeroLoad += 1 }
                        roles.insert(road.geometry.segments[contact.segment].role.rawValue); count += 1
                    }
                }
            }
            XCTAssertGreaterThan(blended, 0); XCTAssertGreaterThan(extended, 0); XCTAssertGreaterThan(zeroLoad, 0)
            XCTAssertGreaterThanOrEqual(roles.count, 3); XCTAssertGreaterThan(neighbours.count, 10)
            print("WHEEL_FORCE samples=\(count) maxAbsolute=\(worst) blended=\(blended) extended=\(extended) zeroLoad=\(zeroLoad) roles=\(roles.count)")
        }
    }
    func testOriginalSidewaysSlipSingularities() throws {
        try withRoad { road, world in
            let main = road.geometry.mainSegments[0], width = road.geometry.segments[main].width
            let contact = TrackLocalPosition(segment: main, toStart: 0, toRight: width/2, toMiddle: 0, toLeft: width/2, mode: .segment)
            for spin: Float in [0, 10, -10] {
                var p = input(contact: contact, main: main, variant: 0)
                p.bodyVelocityX = 0; p.bodyVelocityY = 10; p.steer = 0; p.toe = 0; p.spin = spin
                p.suspensionVelocity = 0; p.displacement = 0.05; p.axleForce = 0
                var ride = WheelRideState(displacement: p.displacement, relativeVelocity: p.relativeVelocity)
                var state = WheelForceState(previousLateral: p.previousLateral, previousLongitudinal: p.previousLongitudinal)
                let o = try world.wheelForce(p), n = try native(p, ride: &ride, state: &state, track: road.geometry)
                _ = compare(n, o, ride: ride, state: state, allowNonfinite: true)
                if spin == 0 { XCTAssertTrue(n.longitudinalSlip.isNaN); XCTAssertTrue(n.skid.isNaN) }
                else { XCTAssertTrue(n.longitudinalSlip.isInfinite); XCTAssertTrue(n.force.x.isNaN) }
            }
            print("WHEEL_FORCE_SINGULAR samples=3 classifications=matched")
        }
    }
    func testIndependentRideForceSequenceAgainstOriginal() throws {
        try withRoad { road, world in
            var ride = WheelRideState(displacement: 0.25, relativeVelocity: -1)
            var forces = WheelForceState(), originalRide = RefWheelRideResult(), originalForce = RefWheelForceResult()
            originalRide.displacement = 0.25; originalForce.relativeVelocity = -1
            let suspension = SuspensionDefinition(preload: 3200, rest: 0.19, bellcrank: 1.3, packers: 0.015,
                bump: .init(slow: 3100, fast: 1100, threshold: 0.4), rebound: .init(slow: 4900, fast: 2200, threshold: 0.6))
            var worst: Float = 0, blended = 0
            for tick in 0..<10000 {
                let main = road.geometry.mainSegments[(tick / 30) % road.geometry.mainSegments.count]
                let pos = TrackLocalPosition(segment: main, toStart: road.geometry.segments[main].extent * Float(tick % 30)/30,
                                             toRight: 6 + 9 * sin(Float(tick) * 0.007))
                let xy = road.geometry.localToGlobal(pos), height = try road.geometry.height(at: xy, startingAt: main)
                let point = SIMD3(xy.x, xy.y, height + 0.25 + 0.3 * sin(Float(tick) * 0.021))
                let speed: Float = 25 + 15 * sin(Float(tick) * 0.003), spin: Float = 90 + 110 * sin(Float(tick) * 0.0013)
                let pressure: Float = tick % 900 < 400 ? 700000 : 0
                originalRide = try world.wheelRide(RefWheelRideInput(position: RefTrackVector(x: point.x, y: point.y, z: point.z),
                    mainSegment: Int32(main), flags: originalForce.flags, displacement: originalRide.displacement,
                    relativeVelocity: originalForce.relativeVelocity, bellcrank: 1.3, packers: 0.015, maximumTravel: 0.5,
                    brakeCoefficient: 0.00006, brakeRadius: 0.1, brakePressure: pressure, brakeTemperature: originalRide.brakeTemperature,
                    longitudinalSpeed: speed, wheelSpin: spin, dt: 0.002))
                let contact = try ride.update(position: point, carSegment: main, track: road.geometry, suspension: suspension,
                    brakeCoefficient: 0.00006, brakeRadius: 0.1, brakePressure: pressure, longitudinalSpeed: speed, wheelSpin: spin)
                var p = input(contact: contact.position, main: main, variant: tick % 60)
                p.contact = originalRide.position; p.suspension.bellcrank = 1.3
                p.displacement = originalRide.displacement; p.suspensionVelocity = originalRide.suspensionVelocity
                p.suspensionFlags = originalRide.suspensionFlags; p.relativeVelocity = originalRide.relativeVelocity
                p.flags = originalRide.flags; p.brakeTorque = originalRide.brakeTorque
                p.previousLateral = originalForce.previousLateral; p.previousLongitudinal = originalForce.previousLongitudinal
                p.bodyVelocityX = speed; p.bodyVelocityY = 3 * sin(Float(tick) * 0.011); p.spin = spin
                originalForce = try world.wheelForce(p)
                // Native contacts and state never come from the reference result.
                p.contact = RefTrackPosition(segment: Int32(contact.position.segment), mode: 1, toStart: contact.position.toStart,
                    toRight: contact.position.toRight, toMiddle: contact.position.toMiddle, toLeft: contact.position.toLeft)
                let n = try native(p, ride: &ride, state: &forces, track: road.geometry)
                worst = max(worst, compare(n, originalForce, ride: ride, state: forces))
                XCTAssertEqual(ride.displacement, originalRide.displacement, accuracy: 1e-5 + 1e-6 * abs(originalRide.displacement))
                XCTAssertEqual(ride.brake.temperature, originalRide.brakeTemperature, accuracy: 1e-6)
                if n.otherSurfaceContribution > 0 { blended += 1 }
            }
            XCTAssertGreaterThan(blended, 0)
            print("WHEEL_FORCE_SEQUENTIAL ticks=10000 maxAbsolute=\(worst) blended=\(blended)")
        }
    }

    func testCoupledRideForceThermalAndFreeWheelSequence() throws {
        try withRoad { road, world in
            var ride = WheelRideState(displacement: 0.25), forces = WheelForceState()
            var rotation = WheelRotationState(spin: 100, previousSpin: 100)
            let thermalConfig = RefTireThermalConfig(pressure: 275600, initialTemperature: 293.15, idealTemperature: 368.15,
                treadMass: 2.14, baseMass: 4.87, gasMass: 0.119, convectionSurface: 0.61, hysteresisFactor: 1.12, wearFactor: 1.3)
            let thermalDefinition = TireThermalDefinition(pressure: 275600, initialTemperature: 293.15, idealTemperature: 368.15,
                treadMass: 2.14, baseMass: 4.87, gasMass: 0.119, convectionSurface: 0.61, hysteresisFactor: 1.12, wearFactor: 1.3)
            var thermal = TireThermalState(pressure: 275600, temperature: 293.15)
            var oRide = RefWheelRideResult(), oForce = RefWheelForceResult()
            oRide.displacement = 0.25
            var oRotation = RefWheelRotation(spin: 100, previousSpin: 100, angle: 0, inputSpin: 100, publishedSpin: 100)
            var oThermal = RefTireThermalState(pressure: 275600, temperature: 293.15, graining: 0, grip: 1, wear: 0)
            let suspension = SuspensionDefinition(preload: 3200, rest: 0.19, bellcrank: 1.3, packers: 0.015,
                bump: .init(slow: 3100, fast: 1100, threshold: 0.4), rebound: .init(slow: 4900, fast: 2200, threshold: 0.6))
            var worst: Float = 0, brakeTicks = 0
            for tick in 0..<6000 {
                let main = road.geometry.mainSegments[(tick / 25) % road.geometry.mainSegments.count]
                let pos = TrackLocalPosition(segment: main, toStart: road.geometry.segments[main].extent * Float(tick % 25)/25,
                                             toRight: 6 + 9 * sin(Float(tick) * 0.007))
                let xy = road.geometry.localToGlobal(pos), height = try road.geometry.height(at: xy, startingAt: main)
                let point = SIMD3(xy.x, xy.y, height + 0.24 + 0.15 * sin(Float(tick) * 0.021))
                let speed: Float = 25 + 15 * sin(Float(tick) * 0.003)
                let pressure: Float = tick % 900 < 400 ? 10000000 : 0
                if pressure > 0 { brakeTicks += 1 }
                oRide = try world.wheelRide(RefWheelRideInput(position: RefTrackVector(x: point.x, y: point.y, z: point.z),
                    mainSegment: Int32(main), flags: oForce.flags, displacement: oRide.displacement, relativeVelocity: oForce.relativeVelocity,
                    bellcrank: 1.3, packers: 0.015, maximumTravel: 0.5, brakeCoefficient: 0.00006, brakeRadius: 0.1,
                    brakePressure: pressure, brakeTemperature: oRide.brakeTemperature, longitudinalSpeed: speed, wheelSpin: oRotation.spin, dt: 0.002))
                let contact = try ride.update(position: point, carSegment: main, track: road.geometry, suspension: suspension,
                    brakeCoefficient: 0.00006, brakeRadius: 0.1, brakePressure: pressure, longitudinalSpeed: speed, wheelSpin: rotation.spin)
                var p = input(contact: contact.position, main: main, variant: tick % 60)
                p.contact = oRide.position; p.suspension.bellcrank = 1.3
                p.displacement = oRide.displacement; p.suspensionVelocity = oRide.suspensionVelocity; p.suspensionFlags = oRide.suspensionFlags
                p.relativeVelocity = oRide.relativeVelocity; p.flags = oRide.flags; p.brakeTorque = oRide.brakeTorque
                p.previousLateral = oForce.previousLateral; p.previousLongitudinal = oForce.previousLongitudinal
                p.bodyVelocityX = speed; p.bodyVelocityY = 3 * sin(Float(tick) * 0.011); p.spin = oRotation.spin
                p.skillLevel = 3; p.grip = oThermal.grip
                oForce = try world.wheelForce(p)
                p.spin = rotation.spin; p.grip = thermal.grip
                p.contact = RefTrackPosition(segment: Int32(contact.position.segment), mode: 1, toStart: contact.position.toStart,
                    toRight: contact.position.toRight, toMiddle: contact.position.toMiddle, toLeft: contact.position.toLeft)
                let force = try native(p, ride: &ride, state: &forces, track: road.geometry)
                worst = max(worst, compare(force, oForce, ride: ride, state: forces))
                oThermal = ref_tire_thermal(thermalConfig, oThermal, oForce.tireLoad, oForce.tireSlip, oRotation.spin, 0.32,
                                           288.15, 96000, 3, 2, 0.002, 0)
                thermal.update(definition: thermalDefinition, tireLoad: force.tireLoad, slip: force.tireSlip, spin: rotation.spin,
                               radius: 0.32, localTemperature: 288.15, localPressure: 96000, skillLevel: 3, tireFactor: 2)
                oRotation = ref_wheel_rotation(oRotation.spin, oRotation.previousSpin, oRotation.angle, 0, oForce.spinTorque,
                                              oRide.brakeTorque, 1.7, 0.6, 0.002, 1, 1)
                let freeSpin = rotation.updateFree(tireTorque: force.spinTorque, brakeTorque: ride.brake.torque, wheelInertia: 1.7, axleInertia: 0.6)
                rotation.update(drivetrainSpin: freeSpin)
                for (a,b) in [(rotation.spin, oRotation.spin), (rotation.previousSpin, oRotation.previousSpin), (rotation.angle, oRotation.angle),
                              (thermal.temperature, oThermal.temperature), (thermal.pressure, oThermal.pressure),
                              (thermal.grip, oThermal.grip), (thermal.graining, oThermal.graining),
                              (ride.displacement, oRide.displacement), (ride.brake.temperature, oRide.brakeTemperature)] {
                    XCTAssertTrue(a.isFinite && b.isFinite)
                    worst = max(worst, abs(a-b)); XCTAssertEqual(a,b,accuracy: 1e-5 + 1e-6 * abs(b))
                }
                XCTAssertEqual(thermal.wear, oThermal.wear, accuracy: 1e-12 + 1e-10 * abs(oThermal.wear))
            }
            XCTAssertGreaterThan(thermal.wear, 0); XCTAssertNotEqual(thermal.grip, 1)
            print("WHEEL_COUPLED ticks=6000 maxAbsolute=\(worst) brakeTicks=\(brakeTicks)")
        }
    }
}
