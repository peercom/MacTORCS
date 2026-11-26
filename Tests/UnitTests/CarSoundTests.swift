// SPDX-License-Identifier: GPL-2.0-only
// The car sound model's numbers against the original's formulas, and the
// generated stand-in samples.
import XCTest
import TORCSPresentation

final class CarSoundTests: XCTestCase {
    func testEnginePitchFilterAndSilenceFollowTheOriginal() {
        var model=CarSoundModel(rpmScale:1.5)
        // At 600 rad/s the sample plays at the car's scale.
        var frame=model.update(CarSoundInput(engineSpeed:600,redLine:1200,throttle:1,gear:3,speed:40))
        XCTAssertEqual(frame.engine.pitch,1.5,accuracy:1e-6);XCTAssertEqual(frame.engine.volume,1)
        // The filter: smoothed throttle starts at 0, so the first update is the closed-throttle term.
        XCTAssertEqual(frame.engine.lowPass,0.25*0.25*0.5+(0.75*0.25+0.25)*0.5,accuracy:1e-6)
        // Held open, the throttle smoothing converges and the filter reaches its open value.
        for _ in 0..<40 { frame=model.update(CarSoundInput(engineSpeed:1200,redLine:1200,throttle:1,gear:3,speed:40)) }
        XCTAssertEqual(frame.engine.lowPass,1,accuracy:1e-3)
        // Off the throttle at half revs it closes to a sixteenth.
        for _ in 0..<40 { frame=model.update(CarSoundInput(engineSpeed:600,redLine:1200,throttle:0,gear:3,speed:40)) }
        XCTAssertEqual(frame.engine.lowPass,0.01*(0.75*0.25+0.25)+0.99*0.25*0.25,accuracy:1e-3)
        // A car out of the simulation is silent.
        let out=model.update(CarSoundInput(engineSpeed:600,redLine:1200,throttle:1,gear:3,speed:40,simulated:false))
        XCTAssertEqual(out.engine.volume,0);XCTAssertEqual(out.skid.volume,0)
    }
    func testTyresSurfacesGearsAndImpacts() {
        var model=CarSoundModel()
        // Tarmac: road noise from speed and load, skid above the threshold only.
        var input=CarSoundInput(engineSpeed:500,redLine:1000,throttle:0.5,gear:1,speed:50,skid:[0.04,0.45,0,0],wheelLoad:4000)
        var frame=model.update(input)
        XCTAssertEqual(frame.road.volume,0.5*(1+4*0.25),accuracy:1e-6)
        XCTAssertEqual(frame.skid.volume,0.40,accuracy:1e-6,"the loudest wheel, less the 0.05 threshold")
        XCTAssertEqual(frame.grass.volume,0);XCTAssertEqual(frame.curb.volume,0)
        XCTAssertTrue(frame.gearChanged,"first gear from neutral")
        // The same gear again is no change; a collision is reported once.
        input.collided=true
        frame=model.update(input)
        XCTAssertFalse(frame.gearChanged);XCTAssertTrue(frame.crashed)
        // Off the road: grass under the wheels, the skid goes to the grass voice.
        input.collided=false
        input.surfaces=Array(repeating:WheelSoundSurface(offRoad:true,roughWaveNumber:0.2,roughness:0.1),count:4)
        frame=model.update(input)
        XCTAssertEqual(frame.road.volume,0);XCTAssertEqual(frame.skid.volume,0)
        XCTAssertEqual(frame.grass.volume,(0.5+0.2*tanh(0.05))*0.5*4,accuracy:1e-5)
        XCTAssertEqual(frame.grassSkid.volume,0.45,accuracy:1e-6)
        // A wheel on a kerb.
        input.surfaces[0]=WheelSoundSurface(curb:true)
        frame=model.update(input)
        XCTAssertEqual(frame.curb.volume,0.5*(5+4.0/3),accuracy:1e-5)
        // At rest with still wheels, the tyres are silent.
        frame=model.update(CarSoundInput(engineSpeed:200,redLine:1000,throttle:0,gear:1,speed:0,wheelsTurning:false))
        XCTAssertEqual(frame.road.volume,0)
        XCTAssertTrue(WheelSoundSurface.isOffRoad(material:"Grass-b"));XCTAssertTrue(WheelSoundSurface.isOffRoad(material:"sandA"))
        XCTAssertFalse(WheelSoundSurface.isOffRoad(material:"asphalt"))
    }
    func testTurboSpoolsOnlyAboveItsSpeedAndUnderLoad() {
        var model=CarSoundModel(turbo:true,turboSpeed:300,turboLag:0.5)
        var frame=CarSoundFrame()
        for _ in 0..<300 { frame=model.update(CarSoundInput(engineSpeed:250,redLine:900,throttle:1,gear:2,speed:20)) }
        XCTAssertLessThan(frame.turbo.volume,0.001,"below the turbo's speed")
        for _ in 0..<300 { frame=model.update(CarSoundInput(engineSpeed:700,redLine:900,throttle:1,gear:2,speed:40)) }
        XCTAssertEqual(frame.turbo.volume,0.1,accuracy:0.005);XCTAssertEqual(frame.turbo.pitch,700.0/600,accuracy:0.05)
        var plain=CarSoundModel()
        XCTAssertEqual(plain.update(CarSoundInput(engineSpeed:700,redLine:900,throttle:1,gear:2,speed:40)).turbo.volume,0)
    }
    func testStandInSamplesAreBoundedLoopableAndRepeatable() {
        let engine=SyntheticSound.engineLoop(cylinders:6)
        XCTAssertEqual(engine.count,22050)
        XCTAssertLessThanOrEqual(engine.map(abs).max()!,0.8001)
        XCTAssertGreaterThan(engine.map { $0*$0 }.reduce(0,+)/Float(engine.count),0.01,"not silence")
        // A whole number of cycles: the end runs into the start without a step
        // larger than the steps inside the loop.
        let inner=zip(engine,engine.dropFirst()).map { abs($1-$0) }.max()!
        XCTAssertLessThanOrEqual(abs(engine[0]-engine[engine.count-1]),inner*1.01)
        XCTAssertEqual(SyntheticSound.engineLoop(cylinders:6),engine,"the same sample every run")
        XCTAssertNotEqual(SyntheticSound.engineLoop(cylinders:8),engine)
        // The fundamental of the loop is the 48 Hz half-order: 24 cycles.
        var real=0.0,imaginary=0.0
        for (i,x) in engine.enumerated() {
            let angle=2*Double.pi*24*Double(i)/Double(engine.count)
            real += Double(x)*cos(angle);imaginary += Double(x)*sin(angle)
        }
        XCTAssertGreaterThan((real*real+imaginary*imaginary).squareRoot()/Double(engine.count),0.001)
        for loop in [SyntheticSound.noiseLoop(low:60,high:900,seed:1),SyntheticSound.skidLoop()] {
            XCTAssertGreaterThan(loop.count,44100);XCTAssertLessThanOrEqual(loop.map(abs).max()!,0.8001)
            XCTAssertTrue(loop.allSatisfy(\.isFinite))
        }
        let knock=SyntheticSound.impact(seconds:0.12,tone:140,noiseShare:0.5,seed:2)
        XCTAssertEqual(knock.count,5292);XCTAssertLessThan(abs(knock[knock.count-1]),0.02,"it has died away")
        XCTAssertEqual(SyntheticSound.blip(frequency:880).first,0)
    }
}
