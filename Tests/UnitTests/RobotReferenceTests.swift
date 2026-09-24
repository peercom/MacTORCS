// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSReferenceSupport

final class RobotReferenceTests:XCTestCase {
    func testOriginalBTCallbacksAndIsolatedRestart() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var captures:[[[String:Double]]]=[]
        let originalDirectory=FileManager.default.currentDirectoryPath
        for _ in 0..<2 {
            let content=try ReferenceContent(fixtures:fixtures,bt:true)
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,btDirectory:content.directory,laps:1)
            XCTAssertEqual(FileManager.default.currentDirectoryPath,originalDirectory)
            let initial=try world.robotStatus()
            XCTAssertEqual(initial.newTrackCalls,1);XCTAssertEqual(initial.newRaceCalls,1)
            XCTAssertEqual(initial.driveCalls,0);XCTAssertEqual(initial.time,-2)
            var records:[[String:Double]]=[],calls:UInt64=0
            for tick in 1...3000 {
                let state=try world.stepRobot()
                if state.driveCalls>calls {
                    XCTAssertEqual(state.driveCalls,calls+1);XCTAssertEqual(state.lastDriveTick,UInt64(tick))
                    XCTAssertGreaterThanOrEqual(state.robotDelta,0.02)
                    var input=try world.robotInput();XCTAssertEqual(input.count,142)
                    input["raw.steering"]=Double(state.steering);input["raw.throttle"]=Double(state.throttle)
                    input["raw.brake"]=Double(state.brake);input["raw.gear"]=Double(state.gear)
                    input["time"]=state.robotTime;input["delta"]=state.robotDelta
                    records.append(input);calls=state.driveCalls
                }
            }
            XCTAssertGreaterThan(calls,200);XCTAssertEqual(try world.robotStatus().carState,0)
            world.close()
            XCTAssertTrue(FileManager.default.fileExists(atPath:content.directory.appendingPathComponent("user/drivers/bt/0/race/aalborg.karma").path))
            captures.append(records)
        }
        XCTAssertEqual(captures[0],captures[1])
        print("BT_CALLBACKS repeated=2 ticksEach=3000 capturedInputs=142 callbacks=\(captures[0].count) exact=1")
    }
    func testOriginalBTCompletesPhysicalReferenceLap() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),bt:true)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,btDirectory:content.directory,laps:1)
        defer { world.close() }
        var state=try world.robotStatus()
        for _ in 0..<60000 {
            state=try world.stepRobot()
            if state.raceState==4 || state.carState & 0x800 != 0 { break }
        }
        // The original C++ robot is optimization-sensitive. These are separate
        // reference baselines, not a claim of native robot parity.
        #if DEBUG
        XCTAssertEqual(world.tick,44617);XCTAssertEqual(state.driveCalls,4204)
        XCTAssertEqual(state.lastLap,87.2339999999781)
        #else
        XCTAssertEqual(world.tick,44694);XCTAssertEqual(state.driveCalls,4211)
        XCTAssertEqual(state.lastLap,87.38799999997774)
        #endif
        XCTAssertEqual(state.raceState,4);XCTAssertEqual(state.carState,0x100)
        XCTAssertEqual(state.laps,2);XCTAssertEqual(state.remainingLaps,-1)
        XCTAssertGreaterThan(state.distance,2500)
        XCTAssertThrowsError(try world.stepRobot())
        print("BT_PHYSICAL_REFERENCE_LAP tick=\(world.tick) lapTime=\(state.lastLap) driveCalls=\(state.driveCalls) finished=1 nativeParity=0")
    }
}
