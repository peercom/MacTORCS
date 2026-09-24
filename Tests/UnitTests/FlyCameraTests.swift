// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSSimulation
@testable import TORCSAssets
@testable import TORCSMetal

final class FlyCameraTests: XCTestCase {
    func testFlyMotionRandomResetsAndSceneHeightAgainstOriginal() throws {
        let count=6000
        var times: [Double]=[],positions: [Float]=[],indices: [Int32]=[],selects: [Int32]=[]
        var time: Double=0
        for i in 0..<count {
            // Exercise initial clock hold, pauses, normal cadence, timer expiry,
            // backwards time, >1-second catch-up, exact boundaries and reselection.
            if i>2 {
                switch i%631 {
                case 0: time += 2.5
                case 1: time -= 1.1
                case 2: time += 1
                case 3: time -= 1
                case 4...14: break
                default: time += 1.0/60
                }
            }
            if i==2100 { time=0 }
            times.append(time)
            let t=Float(i)
            positions += [200*sin(t*0.007),140*cos(t*0.011),12+15*sin(t*0.017)]
            indices.append(Int32(i/701%3));selects.append(i%997==0 || i==1 || i==4 ? 1:0)
        }
        var totalDraws=0,totalCalls=0
        for height: Float in [0,150] {
            var floor=SceneRenderingTests.quad(z:height)
            for i in stride(from:0,to:floor.vertices.count,by:3) { floor.vertices[i] *= 1000;floor.vertices[i+1] *= 1000 }
            let scene=SceneRenderingTests.loaded([floor]).asset.scene
            let nativeHeight=try SceneHeightQuery(scene),handle=try SceneHeightTests().oracle(scene)
            defer { ref_scene_height_destroy(handle) }
            for seed: UInt32 in [0,1,12345,2147483646] {
                var original=Array(repeating:Float(0),count:count*28),storedTimes=Array(repeating:Double(0),count:count)
                var draws=Array(repeating:Int32(0),count:count),calls=draws
                ref_camera_fly(handle,seed,times,positions,indices,selects,Int32(count),&original,&storedTimes,&draws,&calls)
                var camera=try FlyCamera(seed:seed),heightCalls=0
                for i in 0..<count {
                    if selects[i] != 0 { camera.select() }
                    try camera.update(time:times[i],carIndex:Int(indices[i]),position:SIMD3(positions[i*3],positions[i*3+1],positions[i*3+2])) { point in
                        heightCalls += 1;return try nativeHeight.query(x:point.x,y:point.y).height
                    }
                    let actual=[camera.eye.x,camera.eye.y,camera.eye.z,camera.target.x,camera.target.y,camera.target.z,0,0,1,67.5,1,1000,500,1000,1,1,1,
                        camera.speed.x,camera.speed.y,camera.speed.z,camera.offset.x,camera.offset.y,camera.offset.z,camera.timer,
                        camera.currentCar<0 ? 0:camera.gain,camera.currentCar<0 ? 0:camera.damping,camera.currentCar<0 ? 0:camera.zOffset,Float(camera.currentCar)]
                    let expected=Array(original[i*28..<(i+1)*28])
                    XCTAssertEqual(actual,expected,"seed=\(seed) height=\(height) sample=\(i)")
                    if actual != expected { throw ACError.invalid("Fly state first divergence at sample \(i)") }
                    XCTAssertEqual(camera.currentTime,storedTimes[i]);XCTAssertEqual(camera.randomDraws,UInt64(draws[i]));XCTAssertEqual(heightCalls,Int(calls[i]))
                    if i%53==0,let view=try camera.camera() { _=SurveyCameraTests().compare(view,expected,.chase) }
                }
                totalDraws += Int(camera.randomDraws);totalCalls += heightCalls
            }
        }
        print("FLY_CAMERA updates=48000 seeds=4 sceneHeights=2 randomDraws=\(totalDraws) heightCalls=\(totalCalls) maximumStateError=0 projectionAspects=3")
    }
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
