// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack
import simd
@testable import TORCSMetal

final class TVPresentationTests: XCTestCase {
    func testNativeMultiCarFramesAndSharedScreensAgainstOriginal() throws {
        let initial=try DrivingRuntimeTests().makeRuntime(),road=initial.simulation.road
        var simulation=try MultiVehicleSimulation(definition:initial.simulation.vehicle.definition,road:road,carCount:3)
        try simulation.settle()
        let settings=try TVDirector.Settings(changeInterval:0.4,eventInterval:0.05,proximity:15)
        var presentation=try TVPresentation(carCount:3,settings:settings)
        try presentation.activate(screen:0,car:2);try presentation.activate(screen:1,car:1)
        let references=try (0..<2).map { _ in try XCTUnwrap(ref_tv_create(3,[0.4,0.05,15],road.length,road.width)) }
        defer { for reference in references { ref_tv_destroy(reference) } }
        let world=try CameraWorld(bounds:road.bounds)
        var histories=Array(repeating:PresentationCollisionHistory(),count:3),latches=Array(repeating:false,count:3)
        var selected=[2,1],time:Double=0,updates=0,clears=0,manual=0
        for tick in 0...3000 {
            if tick>0 {
                try simulation.step(commands:(0..<3).map { DriverCommand(throttle:0.6+Float($0)*0.05,steering:0.04*sin(Float(tick)*0.002),gear:1) })
                time += 0.002
            }
            for id in 0..<3 {
                let life=simulation.lifecycle[id]
                try histories[id].observe(tick:tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
                if life.publishedCollision==0 { latches[id]=false }
                else if tick==0 || life.flags & 0xff == 0 && life.publishedSimCollision != 0 { latches[id]=true }
            }
            guard tick%8==0 else { continue }
            // Explicit authored permutations exercise supplied race order; this
            // diagnostic does not claim to implement race standings.
            let order=(0..<3).map { ($0+tick/160)%3 }
            let frame=order.map { id in RacePresentationCar(index:id,visual:simulation.visualSnapshot(car:id),trackPosition:simulation.lifecycle[id].trackPosition,remainingLaps:5,pitRequested:false,collisions:histories[id]) }
            if tick>0 && tick%400==0 {
                selected[0]=(selected[0]+1)%3;latches[selected[0]]=false
                try presentation.selectCar(selected[0],screen:0,frame:frame);manual += 1
            }
            for screen in 0..<2 {
                let input=frame.map { car in RefTVCar(index:Int32(car.index),flags:car.visual.flags,remainingLaps:5,distanceFromStart:road.geometry.distanceFromStart(car.trackPosition),toMiddle:car.trackPosition.toMiddle,pitRequested:0,collision:latches[car.index] ? 1:0) }
                var state=Array(repeating:Double(0),count:8),selection=Array(repeating:Int32(0),count:3),collision=Array(repeating:Int32(0),count:3),view=Array(repeating:Float(0),count:17)
                ref_tv_step(references[screen],time,Int32(selected[screen]),input,[Int32(selected[1-screen])],1,&state,&selection,&collision,&view)
                let actual=try presentation.view(screen:screen,time:time,frame:frame,road:road,world:world)
                XCTAssertEqual(actual.selection.carIndex,Int(selection[0]));XCTAssertEqual(actual.selection.raceSlot,Int(selection[1]));XCTAssertEqual(actual.selection.clearPresentationCollisions,selection[2] != 0)
                selected[screen]=Int(selection[0]);latches=collision.map { $0 != 0 }
                let director=presentation.cameras[screen].director
                XCTAssertEqual(director.lastEventTime,state[0]);XCTAssertEqual(director.lastViewTime,state[1])
                for id in 0..<3 {
                    XCTAssertEqual(director.schedule[id].priority,state[2+id*2]);XCTAssertEqual(director.schedule[id].viewable,state[3+id*2] != 0)
                    XCTAssertEqual(histories[id].pending(clearedThrough:presentation.clearedThrough[id]),latches[id])
                }
                let subject=frame[actual.selection.raceSlot]
                XCTAssertEqual(actual.camera.target,subject.visual.body.position)
                if actual.selection.clearPresentationCollisions { clears += 1 }
                updates += 1
            }
        }
        XCTAssertGreaterThan(clears,10);XCTAssertEqual(manual,7)
        print("TV_PRESENTATION_NATIVE ticks=3000 cars=3 screens=2 updates=\(updates) clears=\(clears) manualChanges=\(manual) originalSelectionPrioritiesClocksAcknowledgements=exact authoredOrder=1")
    }
    func testRejectedFramesAndProjectionPreserveState() throws {
        var runtime=try DrivingRuntimeTests().makeRuntime()
        let old=runtime.frame.presentationCar,road=runtime.simulation.road,world=try CameraWorld(bounds:road.bounds)
        var presentation=try TVPresentation(carCount:1,settings:.init())
        XCTAssertThrowsError(try presentation.view(screen:0,time:0,frame:[old],road:road,world:world))
        try presentation.activate(screen:0,car:0)
        try runtime.advance(elapsed:0.1,command:.init())
        let frame=[runtime.frame.presentationCar]
        _=try presentation.view(screen:0,time:runtime.frame.raceTime,frame:frame,road:road,world:world)
        let before=presentation
        XCTAssertThrowsError(try presentation.view(screen:0,time:1,frame:[old],road:road,world:world))
        XCTAssertThrowsError(try presentation.view(screen:0,time:1,frame:[],road:road,world:world))
        let bad=RacePresentationCar(index:0,visual:frame[0].visual,trackPosition:frame[0].trackPosition,remainingLaps:5,pitRequested:false,collisions:old.collisions)
        XCTAssertThrowsError(try presentation.view(screen:0,time:1,frame:[bad],road:road,world:world))
        for zoom:Float in [.nan,0,-1,.leastNonzeroMagnitude] { XCTAssertThrowsError(try presentation.view(screen:0,time:11,frame:frame,road:road,world:world,zoom:zoom)) }
        XCTAssertThrowsError(try presentation.selectCar(1,screen:0,frame:frame))
        XCTAssertThrowsError(try presentation.activate(screen:4,car:0))
        XCTAssertThrowsError(try presentation.activate(screen:0,car:1))
        XCTAssertEqual(presentation.lastFrameTick,before.lastFrameTick);XCTAssertEqual(presentation.clearedThrough,before.clearedThrough)
        XCTAssertEqual(presentation.cameras[0].director.schedule,before.cameras[0].director.schedule)
        XCTAssertEqual(presentation.cameras[0].director.lastEventTime,before.cameras[0].director.lastEventTime)
        try presentation.setActive(false,screen:0)
        XCTAssertThrowsError(try presentation.view(screen:0,time:1,frame:frame,road:road,world:world))
        XCTAssertNil(presentation.selectedCar(screen:4))
        var rig=DrivingCameraRig()
        XCTAssertThrowsError(try rig.view(preset:.television,body:matrix_identity_float4x4,bonnetPosition:.zero,yaw:0,trackHeading:0) { _ in 0 })
    }
    func testOriginalTVZoomFactoryCommandsAndPreferenceKey() throws {
        let preset=DrivingCameraPreset.television
        let commands:[Int32]=[-1]+Array(repeating:0,count:200)+Array(repeating:1,count:200)+[2,0,3,1,4,-1]
        for saved:Float in [.nan,1.5,200] {
            var output=Array(repeating:Float(0),count:commands.count*6),value=saved.isNaN ? preset.zoomLimits.standard:saved
            ref_camera_tv_zoom(saved,commands,Int32(commands.count),&output)
            for i in commands.indices {
                if let command=CameraZoomCommand(rawValue:Int(commands[i])) { value=try preset.adjustedZoom(value,command:command) }
                XCTAssertEqual(value,output[i*6]);XCTAssertEqual(preset.zoomLimits.standard,output[i*6+1]);XCTAssertEqual(preset.zoomLimits.minimum,output[i*6+2]);XCTAssertEqual(preset.zoomLimits.maximum,output[i*6+3]);XCTAssertEqual(output[i*6+4],1);XCTAssertEqual(output[i*6+5],1)
            }
        }
        XCTAssertEqual(preset.preferenceKey,"fovy-9-0");XCTAssertTrue(preset.distanceScaledZoom)
        print("TV_ZOOM updates=1221 factoryLimits=9,1,90 savedKey=fovy-9-0 originalExact=1")
    }
}
