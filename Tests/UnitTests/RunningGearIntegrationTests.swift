// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

final class RunningGearIntegrationTests: XCTestCase {
    func testConfiguredFourWheelSequenceAgainstOriginal() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let content = try ReferenceContent(fixtures:fixtures)
        let parameters = try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let configuration = try RunningGearConfiguration(parameters:parameters)
        let trackParameters = try ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("aalborg.xml")),entities:[
            "default-surfaces":Data(contentsOf:fixtures.appendingPathComponent("surfaces.xml")),
            "default-objects":Data(contentsOf:fixtures.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true)
        let road = try TrackBuilder.buildRoad(parameters:trackParameters)
        let world = try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        var native = RunningGearState(configuration:configuration), metrics = RunningGearTests.Metrics()
        var blended = 0, thermalResets = 0
        for tick in 0..<10000 {
            let main = road.geometry.mainSegments[(tick/25)%road.geometry.mainSegments.count]
            let local = TrackLocalPosition(segment:main,toStart:road.geometry.segments[main].extent*Float(tick%25)/25,
                                           toRight:6 + 7*sin(Float(tick)*0.003))
            let xy = road.geometry.localToGlobal(local), height = try road.geometry.height(at:xy,startingAt:main)
            let origin = SIMD3(xy.x,xy.y,height + configuration.mass.centerOfGravity.z + 0.2 + 0.1*sin(Float(tick)*0.03))
            let roll: Float = 0.08*sin(Float(tick)*0.01), pitch: Float = 0.06*cos(Float(tick)*0.007)
            let yaw = road.geometry.tangent(local) + 0.1*sin(Float(tick)*0.008)
            let body = SIMD3<Float>(25 + 12*sin(Float(tick)*0.002),2*cos(Float(tick)*0.003),0)
            let yawVelocity: Float = 0.3*cos(Float(tick)*0.008), steer: Float = 0.15*sin(Float(tick)*0.004)
            let steering = SIMD4(steer,steer*0.9,0,0)
            let pressure: Float = tick%800<200 ? 7000000 : 0
            let pressures = SIMD4(pressure,pressure,pressure*0.7,pressure*0.7)
            let preSimulation = tick<500
            var input = RefRunningGearInput()
            input.worldPosition = RefTrackVector(x:origin.x,y:origin.y,z:origin.z)
            input.bodyVelocity = RefTrackVector(x:body.x,y:body.y,z:body.z)
            input.roll = roll; input.pitch = pitch; input.yaw = yaw; input.yawVelocity = yawVelocity
            input.localTemperature = 288.15; input.localPressure = 96000; input.tireFactor = 2; input.dt = 0.002
            input.mainSegment = Int32(main); input.skillLevel = 3; input.preSimulation = preSimulation ? 1 : 0
            input.brakePressures = RefFourValues(frontRight:pressures.x,frontLeft:pressures.y,rearRight:pressures.z,rearLeft:pressures.w)
            input.steering = RefFourValues(frontRight:steering.x,frontLeft:steering.y,rearRight:0,rearLeft:0)
            var original = try world.stepRunningGear(input)
            try native.updateForces(worldPosition:origin,roll:roll,pitch:pitch,yaw:yaw,bodyVelocity:body,yawVelocity:yawVelocity,
                carSegment:main,track:road.geometry,brakePressures:pressures,steering:steering,localTemperature:288.15,localPressure:96000,
                skillLevel:3,tireFactor:2,preSimulation:preSimulation)
            let front = native.freeAxleInputs(0), rear = native.freeAxleInputs(1)
            native.updateRotation(drivetrainSpins:SIMD4(front.x,front.y,rear.x,rear.y))
            let counts = try compareRunningGear(native,&original,tick:tick,preSimulation:preSimulation,metrics:&metrics)
            blended += counts.blended; thermalResets += counts.thermalResets
        }
        XCTAssertGreaterThan(blended,0)
        XCTAssertGreaterThan(native.wheels.frontRight.thermal.wear,0)
        print("RUNNING_GEAR_SEQUENCE ticks=10000 wheelTicks=40000 fields=\(metrics.fields) maxAbsolute=\(metrics.worst) blended=\(blended) thermalResets=\(thermalResets)")
    }
}

/// Shared assertions for the undriven and powertrain-coupled sequences.
func compareRunningGear(_ native: RunningGearState,_ original: inout RefRunningGearStep,tick: Int,
                        preSimulation: Bool,metrics: inout RunningGearTests.Metrics) throws -> (blended: Int,thermalResets: Int) {
    var blended = 0, thermalResets = 0
    try withUnsafePointer(to:&original.wheels) { ptr in
        try ptr.withMemoryRebound(to:RefWheelStage.self,capacity:4) { buffer in
            for i in 0..<4 {
                let n = native.wheels[i], o = buffer[i], c = try XCTUnwrap(n.contact), f = try XCTUnwrap(n.forces)
                XCTAssertEqual(c.position.segment,Int(o.ride.position.segment)); XCTAssertEqual(n.ride.flags,o.force.flags)
                XCTAssertEqual(n.ride.suspensionFlags,o.ride.suspensionFlags)
                XCTAssertEqual(f.otherSurface ?? -1,Int(o.force.otherSurface))
                let fields: [(String,Float,Float)] = [
                    ("positionX",n.position.x,o.kinematics.position.x),("positionY",n.position.y,o.kinematics.position.y),("positionZ",n.position.z,o.kinematics.position.z),
                    ("bodyX",n.bodyVelocity.x,o.kinematics.bodyVelocityX),("bodyY",n.bodyVelocity.y,o.kinematics.bodyVelocityY),
                    ("toStart",c.position.toStart,o.ride.position.toStart),("toRight",c.position.toRight,o.ride.position.toRight),
                    ("toLeft",c.position.toLeft,o.ride.position.toLeft),("toMiddle",c.position.toMiddle,o.ride.position.toMiddle),
                    ("normalX",c.normal.x,o.ride.normal.x),("normalY",c.normal.y,o.ride.normal.y),("normalZ",c.normal.z,o.ride.normal.z),
                    ("roadHeight",c.roadHeight,o.ride.roadHeight),("rideHeight",c.rideHeight,o.ride.rideHeight),
                    ("displacement",n.ride.displacement,o.ride.displacement),("suspVelocity",n.ride.suspensionVelocity,o.ride.suspensionVelocity),
                    ("relativeVelocity",n.ride.relativeVelocity,o.ride.relativeVelocity),
                    ("brakeTorque",n.ride.brake.torque,o.ride.brakeTorque),("brakeTemp",n.ride.brake.temperature,o.ride.brakeTemperature),
                    ("forceX",f.force.x,o.force.force.x),("forceY",f.force.y,o.force.force.y),("forceZ",f.force.z,o.force.force.z),
                    ("suspForce",f.suspensionForce,o.force.suspensionForce),("height",f.relativeHeight,o.force.relativeHeight),
                    ("camber",f.relativeCamber,o.force.relativeCamber),("yaw",f.relativeYaw,o.force.relativeYaw),
                    ("spinTorque",f.spinTorque,o.force.spinTorque),("rollRes",f.rollingResistance,o.force.rollingResistance),
                    ("angle",f.slipAngle,o.force.slipAngle),("sx",f.longitudinalSlip,o.force.longitudinalSlip),
                    ("load",f.tireLoad,o.force.tireLoad),("slip",f.tireSlip,o.force.tireSlip),("skid",f.skid,o.force.skid),
                    ("sideSpeed",f.sideSlipSpeed,o.force.sideSlipSpeed),("slipSpeed",f.longitudinalSlipSpeed,o.force.longitudinalSlipSpeed),
                    ("feedbackSpin",f.feedbackSpin,o.force.feedbackSpin),("feedbackTorque",f.feedbackTorque,o.force.feedbackTorque),
                    ("feedbackBrake",f.feedbackBrakeTorque,o.force.feedbackBrakeTorque),
                    ("previousLateral",n.forceHistory.previousLateral,o.force.previousLateral),("previousLongitudinal",n.forceHistory.previousLongitudinal,o.force.previousLongitudinal),
                    ("surfaceContribution",f.otherSurfaceContribution,o.force.otherSurfaceContribution),
                    ("temperature",n.thermal.temperature,o.thermal.temperature),("pressure",n.thermal.pressure,o.thermal.pressure),
                    ("graining",n.thermal.graining,o.thermal.graining),("grip",n.thermal.grip,o.thermal.grip),
                    ("spin",n.rotation.spin,o.rotation.spin),("previousSpin",n.rotation.previousSpin,o.rotation.previousSpin),("rotation",n.rotation.angle,o.rotation.angle)]
                for (name,a,b) in fields { metrics.check(a,b,"tick \(tick) wheel \(i) \(name)") }
                XCTAssertEqual(n.thermal.wear,o.thermal.wear,accuracy:1e-12 + 1e-10*abs(o.thermal.wear))
                if f.otherSurfaceContribution>0 { blended += 1 }
                if preSimulation { XCTAssertEqual(n.thermal.wear,0); XCTAssertEqual(n.thermal.grip,1); thermalResets += 1 }
            }
        }
    }
    return (blended,thermalResets)
}
