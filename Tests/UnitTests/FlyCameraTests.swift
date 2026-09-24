// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSSimulation
@testable import TORCSAssets
@testable import TORCSPresentation

final class FlyCameraTests: XCTestCase {
    func testFlyHoldsInitializationAndRejectsFailedUpdatesAtomically() throws {
        var camera=try FlyCamera(),baseline=camera
        XCTAssertNil(try camera.camera())
        for time: Double in [0,0,0.1,0.1] {
            try camera.update(time:time,carIndex:0,position:SIMD3(1,2,3)) { _ in XCTFail("Held clock queried scene");return 0 }
        }
        XCTAssertEqual(camera.randomDraws,0);XCTAssertEqual(camera.eye,.zero);XCTAssertNil(try camera.camera())
        baseline=camera
        for bad: Float in [.nan,.infinity,-.infinity] {
            XCTAssertThrowsError(try camera.update(time:0.2,carIndex:0,position:SIMD3(1,2,3)){_ in bad})
            XCTAssertEqual(camera.eye,baseline.eye);XCTAssertEqual(camera.currentTime,baseline.currentTime);XCTAssertEqual(camera.randomDraws,0)
        }
        XCTAssertThrowsError(try camera.update(time:0.2,carIndex:0,position:SIMD3(1,2,3)){_ in throw ACError.invalid("Unavailable scene")})
        XCTAssertThrowsError(try camera.update(time:.nan,carIndex:0,position:.zero){_ in 0})
        XCTAssertThrowsError(try camera.update(time:0.2,carIndex:-1,position:.zero){_ in 0})
        XCTAssertThrowsError(try camera.update(time:0.2,carIndex:0,position:SIMD3(.infinity,0,0)){_ in 0})
        try camera.update(time:0.2,carIndex:0,position:SIMD3(1,2,3)){_ in 0}
        try baseline.update(time:0.2,carIndex:0,position:SIMD3(1,2,3)){_ in 0}
        XCTAssertEqual(camera.eye,baseline.eye);XCTAssertEqual(camera.speed,baseline.speed);XCTAssertEqual(camera.randomDraws,baseline.randomDraws)
        let original=try XCTUnwrap(camera.camera()),zoom=try XCTUnwrap(camera.camera(zoom:20))
        XCTAssertEqual(original.eye,zoom.eye);XCTAssertEqual(original.target,zoom.target);XCTAssertNotEqual(original.fieldOfView,zoom.fieldOfView)
        for value: Float in [0,-1,180,.nan,.infinity,.leastNonzeroMagnitude] { XCTAssertThrowsError(try camera.camera(zoom:value)) }
        XCTAssertThrowsError(try FlyCamera(seed:.max))
        print("FLY_CAMERA_FAILURES initialClockHeld=1 failedHeightRollsBackRNG=1 nonfiniteRejected=1 degenerateInitialProjectionSuppressed=1")
    }
    func testIndependentPresentationRandomStreams() throws {
        // Independent value ownership; no global srand/rand in production.
        var a=try FlyCamera(seed:17),b=try FlyCamera(seed:17)
        var physics=DarwinRandomStream(seed:12345),physicsBaseline=physics
        for i in 0..<600 {
            let time=Double(i)/60,position=SIMD3<Float>(Float(i)*0.3,20,3)
            try a.update(time:time,carIndex:0,position:position){_ in 0}
            if i%2==0 { try b.update(time:time,carIndex:0,position:position){_ in 0} }
            XCTAssertEqual(physics.next(),physicsBaseline.next());XCTAssertEqual(physics.state,physicsBaseline.state)
        }
        XCTAssertNotEqual(a.eye,b.eye)
        var repeatA=try FlyCamera(seed:17)
        for i in 0..<600 { try repeatA.update(time:Double(i)/60,carIndex:0,position:SIMD3(Float(i)*0.3,20,3)){_ in 0} }
        XCTAssertEqual(a.eye,repeatA.eye);XCTAssertEqual(a.randomDraws,repeatA.randomDraws)
        print("FLY_CAMERA_OWNERSHIP independentCameraStreams=2 repeatUpdates=600 frameCadenceChangesPresentation=1 physicsStreamUnaffectedDraws=600")
    }
}
