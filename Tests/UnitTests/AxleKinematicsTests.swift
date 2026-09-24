// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation

final class AxleKinematicsTests: XCTestCase {
    func testWheelPositionsAndBodyVelocityAgainstOriginal() throws {
        let gear = try RunningGearConfiguration(parameters: ParameterDocument.parse(Data(RunningGearTests.xml(variant: 2).utf8)))
        var count = 0, worst: Float = 0
        for roll: Float in [0, -0.0, -1.04, -0.13, 0.82] {
            for pitch: Float in [0, -0.0, -0.92, 0.21, 1.04] {
                for yaw: Float in [-10, -.pi, -1.57, 0, 0.00001, 1.2, .pi, 10] {
                    for origin in [SIMD3<Float>(0,0,0), SIMD3(2260,-430,1.2), SIMD3(-100,300,80)] {
                        let pose = WheelKinematics(worldPosition: origin, roll: roll, pitch: pitch, yaw: yaw,
                                                   bodyVelocity: SIMD2(33.7,-4.2), yawVelocity: -0.73)
                        for wheel in gear.wheels {
                            let a = wheel.staticPosition, n = pose.wheel(at: a)
                            let o = ref_wheel_kinematics(RefTrackVector(x:a.x,y:a.y,z:a.z), RefTrackVector(x:origin.x,y:origin.y,z:origin.z),
                                                        roll,pitch,yaw,33.7,-4.2,-0.73)
                            for (x,y) in [(n.position.x,o.position.x),(n.position.y,o.position.y),(n.position.z,o.position.z),
                                          (n.bodyVelocity.x,o.bodyVelocityX),(n.bodyVelocity.y,o.bodyVelocityY)] {
                                XCTAssertTrue(x.isFinite && y.isFinite)
                                worst = max(worst,abs(x-y)); XCTAssertEqual(x,y,accuracy:1e-5+1e-6*abs(y))
                            }
                            count += 1
                        }
                    }
                }
            }
        }
        print("WHEEL_KINEMATICS samples=\(count) maxAbsolute=\(worst)")
    }
    func testAntiRollAndThirdElementAgainstOriginal() throws {
        var count = 0, active = 0, travelGated = 0, worst: Float = 0
        for variant in 0..<3 {
            let gear = try RunningGearConfiguration(parameters: ParameterDocument.parse(Data(RunningGearTests.xml(variant: variant).utf8)))
            for (index,axle) in gear.axles.enumerated() {
                let s = axle.thirdSuspension
                let c = RefSuspensionConfig(springRate:s.springRate,preload:s.preload,rest:s.rest,travel:s.travel,bellcrank:s.bellcrank,
                    packers:s.packers,slowBump:s.bump.slow,fastBump:s.bump.fast,bumpThreshold:s.bump.threshold,
                    slowRebound:s.rebound.slow,fastRebound:s.rebound.fast,reboundThreshold:s.rebound.threshold)
                for right: Float in [-0.1,0,0.2,0.35,0.5] {
                    for left: Float in [-0.1,0,0.2,0.35,0.5] {
                        for vr: Float in [-15,-0.2,0,0.4,12] {
                            for vl: Float in [-15,-0.2,0,0.4,12] {
                                let n = axle.forces(rightDisplacement:right,leftDisplacement:left,rightVelocity:vr,leftVelocity:vl)
                                let o = ref_axle_force(c,axle.antiRollSpring,right,left,vr,vl,Int32(index))
                                for (x,y) in [(n.rightForce,o.rightForce),(n.leftForce,o.leftForce),(n.thirdDisplacement,o.thirdDisplacement),
                                              (n.thirdVelocity,o.thirdVelocity),(n.thirdForce,o.thirdForce)] {
                                    worst = max(worst,abs(x-y)); XCTAssertEqual(x,y,accuracy:1e-5+1e-6*abs(y))
                                }
                                if n.thirdDisplacement >= s.travel {
                                    travelGated += 1
                                    XCTAssertEqual(n.rightForce,axle.antiRollSpring*(left-right)); XCTAssertEqual(n.leftForce,-n.rightForce)
                                } else if n.thirdForce > 0 { active += 1 }
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(active,0); XCTAssertGreaterThan(travelGated,0)
        print("AXLE_FORCE samples=\(count) maxAbsolute=\(worst) thirdActive=\(active) travelGated=\(travelGated)")
    }
}
